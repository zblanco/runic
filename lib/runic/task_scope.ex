defmodule Runic.TaskScope do
  @moduledoc false
  use GenServer

  @context_key {__MODULE__, :current}

  def start(opts) do
    GenServer.start(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  def current, do: Process.get(@context_key)
  def attach(scope), do: Process.put(@context_key, scope)

  def within(scope, fun) do
    previous = Process.put(@context_key, scope)

    try do
      fun.()
    after
      if previous, do: Process.put(@context_key, previous), else: Process.delete(@context_key)
    end
  end

  def capture_context do
    callers =
      case Process.get(:"$callers") do
        callers when is_list(callers) -> callers
        _ -> []
      end

    %{
      group_leader: Process.group_leader(),
      callers: [self() | callers],
      logger_metadata: Logger.metadata()
    }
  end

  def within_context(context, fun) do
    group_leader = Process.group_leader()
    callers = Process.get(:"$callers")
    logger_metadata = Logger.metadata()

    put_context(context)

    try do
      fun.()
    after
      Process.group_leader(self(), group_leader)
      if callers, do: Process.put(:"$callers", callers), else: Process.delete(:"$callers")
      Logger.reset_metadata(logger_metadata)
    end
  end

  def with_scope(fun) do
    case current() do
      nil ->
        {:ok, scope} = start(owner: self())

        try do
          within(scope, fn -> fun.(scope) end)
        after
          close(scope)
        end

      scope ->
        fun.(scope)
    end
  end

  def dispatch(scope, work, supervisor \\ nil) do
    # Capture at the execution boundary, before the scope becomes the task starter.
    context = capture_context()

    work = fn ->
      put_context(context)
      work.()
    end

    case GenServer.call(scope, {:dispatch, self(), work, supervisor}, :infinity) do
      {:ok, handle, pid} -> {handle, pid}
      {:error, reason} -> exit({:task_dispatch_failed, reason})
    end
  end

  def run(work, timeout) do
    with_scope(fn scope ->
      {handle, _pid} = dispatch(scope, work)

      receive do
        {^handle, result} -> {:ok, result}
        {:DOWN, ^handle, :process, _pid, reason} -> {:exit, reason}
      after
        timeout ->
          GenServer.call(scope, {:cancel, handle}, :infinity)
          flush(handle)
          nil
      end
    end)
  end

  def async_reduce(enumerable, work, initial, reducer, opts) do
    context = capture_context()

    with_scope(fn scope ->
      supervisor = GenServer.call(scope, :supervisor)
      parent = self()

      supervisor
      |> Task.Supervisor.async_stream_nolink(
        enumerable,
        fn input ->
          :ok = track(scope, self(), parent)
          put_context(context)
          within(scope, fn -> work.(input) end)
        end,
        Keyword.put(opts, :shutdown, :brutal_kill)
      )
      |> Enum.reduce(initial, reducer)
    end)
  end

  def track(nil, _pid, _parent), do: :ok

  def track(scope, pid, parent) do
    GenServer.call(scope, {:track, pid, parent}, :infinity)
  end

  def close(scope) do
    GenServer.stop(scope, :normal, :infinity)
  catch
    :exit, {:noproc, _} -> :ok
    :exit, {:normal, _} -> :ok
  end

  def confirm_close(scope) do
    ref = Process.monitor(scope)

    try do
      close(scope)
    catch
      :exit, _reason -> :ok
    end

    await_closed(ref, scope)
  end

  def await_closed(ref, scope) do
    receive do
      {:DOWN, ^ref, :process, ^scope, :normal} -> :ok
      {:DOWN, ^ref, :process, ^scope, reason} -> {:error, {:ownership_scope_failed, reason}}
    end
  end

  def kill(pids) do
    refs = Map.new(pids, fn pid -> {Process.monitor(pid), pid} end)
    Enum.each(pids, &Process.exit(&1, :kill))
    await_down(refs)
  end

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    external_owner = Keyword.get(opts, :external_owner, :background)
    if Keyword.get(opts, :guard_owner, false), do: start_owner_guard(owner)

    {:ok,
     %{
       owner: owner,
       owner_ref: Process.monitor(owner),
       external_ref: if(is_pid(external_owner), do: Process.monitor(external_owner)),
       supervisor: nil,
       tasks: %{},
       guards: %{}
     }}
  end

  @impl true
  def handle_call(:supervisor, _from, state) do
    state = ensure_supervisor(state)
    {:reply, state.supervisor, state}
  end

  def handle_call({:dispatch, caller, work, supervisor}, _from, state) do
    # Cancellation can consume the parent's DOWN before a queued dispatch arrives.
    if Process.alive?(caller) do
      dispatch_task(caller, work, supervisor, state)
    else
      {:reply, {:error, :owner_down}, state}
    end
  end

  def handle_call({:track, pid, parent}, _from, state) do
    if Process.alive?(parent) do
      state =
        if Enum.any?(state.tasks, fn {_ref, task} -> task.pid == pid end),
          do: state,
          else: register(state, pid, parent, nil, nil)

      {:reply, :ok, state}
    else
      {:reply, {:error, :owner_down}, state}
    end
  end

  def handle_call({:cancel, handle}, _from, state) do
    case Enum.find(state.tasks, fn {_ref, task} -> task.handle == handle end) do
      nil -> {:reply, :ok, state}
      {_ref, task} -> {:reply, :ok, cancel_tree(state, task.pid)}
    end
  end

  @impl true
  def handle_info({:result, handle, result}, state) when is_reference(handle) do
    case Enum.find(state.tasks, fn {_ref, task} -> task.handle == handle end) do
      nil ->
        {:noreply, state}

      {ref, task} ->
        # Results and failure notifications use one sender and retain their order.
        send(task.reply_to, {handle, result})
        {:noreply, %{state | tasks: Map.put(state.tasks, ref, %{task | replied: true})}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{external_ref: ref} = state) do
    Process.exit(state.owner, :kill)
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Map.pop(state.tasks, ref) do
      {nil, _} ->
        {:noreply, %{state | guards: Map.delete(state.guards, ref)}}

      {task, tasks} ->
        state = cancel_children(%{state | tasks: tasks}, pid)

        if task.reply_to && !task.replied,
          do: send(task.reply_to, {:DOWN, task.handle, :process, pid, reason})

        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.tasks, fn {_ref, task} -> Process.exit(task.pid, :kill) end)
    refs = Map.new(state.tasks, fn {ref, task} -> {ref, task.pid} end)
    await_down(Map.merge(refs, state.guards))

    if is_pid(state.supervisor) and Process.alive?(state.supervisor),
      do: Supervisor.stop(state.supervisor, :normal, :infinity)
  end

  defp dispatch_task(caller, work, supervisor, state) do
    scope = self()
    handle = make_ref()
    state = if supervisor, do: state, else: ensure_supervisor(state)

    result =
      Task.Supervisor.start_child(
        supervisor || state.supervisor,
        fn ->
          scope_ref = Process.monitor(scope)

          receive do
            {^scope, :start} ->
              Process.demonitor(scope_ref, [:flush])
              result = within(scope, work)
              send(scope, {:result, handle, result})

            {:DOWN, ^scope_ref, :process, ^scope, _} ->
              :ok
          end
        end,
        shutdown: :brutal_kill
      )

    case result do
      {:ok, pid} ->
        # Register before opening the gate, so cancellation covers started work.
        state = register(state, pid, caller, handle, caller)
        send(pid, {scope, :start})
        {:reply, {:ok, handle, pid}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp put_context(context) do
    Process.group_leader(self(), context.group_leader)
    Process.put(:"$callers", context.callers)
    Logger.reset_metadata(context.logger_metadata)
  end

  defp start_owner_guard(owner) do
    scope = self()

    {guard, guard_ref} =
      spawn_monitor(fn ->
        scope_ref = Process.monitor(scope)
        owner_ref = Process.monitor(owner)
        send(scope, {:owner_guard_ready, self()})

        # A blocked inline Worker cannot receive its own scope DOWN message.
        receive do
          {:DOWN, ^scope_ref, :process, ^scope, :normal} -> :ok
          {:DOWN, ^scope_ref, :process, ^scope, _} -> Process.exit(owner, :kill)
          {:DOWN, ^owner_ref, :process, ^owner, _} -> :ok
        end
      end)

    # Install the monitor before returning, including for immediate normal close.
    receive do
      {:owner_guard_ready, ^guard} -> Process.demonitor(guard_ref, [:flush])
      {:DOWN, ^guard_ref, :process, ^guard, reason} -> exit({:owner_guard_failed, reason})
    end
  end

  defp ensure_supervisor(%{supervisor: nil} = state) do
    {:ok, supervisor} = Task.Supervisor.start_link()
    %{state | supervisor: supervisor}
  end

  defp ensure_supervisor(state), do: state

  defp register(state, pid, parent, handle, reply_to) do
    scope = self()
    ref = Process.monitor(pid)

    {guard, guard_ref} =
      spawn_monitor(fn ->
        # Shared-supervisor tasks and Flow stages must also stop if the scope crashes.
        scope_ref = Process.monitor(scope)
        task_ref = Process.monitor(pid)

        receive do
          {:DOWN, ^scope_ref, :process, ^scope, _} -> Process.exit(pid, :kill)
          {:DOWN, ^task_ref, :process, ^pid, _} -> :ok
        end
      end)

    task = %{pid: pid, parent: parent, handle: handle, reply_to: reply_to, replied: false}

    %{
      state
      | tasks: Map.put(state.tasks, ref, task),
        guards: Map.put(state.guards, guard_ref, guard)
    }
  end

  defp cancel_children(state, parent) do
    state.tasks
    |> Enum.filter(fn {_ref, task} -> task.parent == parent end)
    |> Enum.reduce(state, fn {_ref, task}, acc -> cancel_tree(acc, task.pid) end)
  end

  defp cancel_tree(state, pid) do
    state = cancel_children(state, pid)
    {selected, remaining} = Enum.split_with(state.tasks, fn {_ref, task} -> task.pid == pid end)
    Process.exit(pid, :kill)
    await_down(Map.new(selected, fn {ref, task} -> {ref, task.pid} end))
    %{state | tasks: Map.new(remaining)}
  end

  defp await_down(refs) when map_size(refs) == 0, do: :ok

  defp await_down(refs) do
    receive do
      {:DOWN, ref, :process, _pid, _reason} when is_map_key(refs, ref) ->
        await_down(Map.delete(refs, ref))
    end
  end

  defp flush(handle) do
    receive do
      {^handle, _} -> flush(handle)
      {:DOWN, ^handle, :process, _, _} -> flush(handle)
    after
      0 -> :ok
    end
  end
end
