defmodule Runic.Runner.Worker do
  @moduledoc """
  GenServer managing a single workflow's execution lifecycle.

  The Worker implements the dispatch loop: plan → prepare → dispatch → apply,
  using an `Executor` behaviour for fault-isolated task execution and
  `PolicyDriver` for policy-aware invocation.

  Workers are started under the Runner's DynamicSupervisor and registered
  in the Runner's Registry for lookup by workflow ID.

  ## Executor

  The executor controls _how_ runnables are dispatched to compute. By default,
  `Runic.Runner.Executor.Task` is used with an owned scope of supervised tasks.
  Pass `executor: MyExecutor` and `executor_opts: [...]` to use a custom executor.

  The special value `executor: :inline` executes runnables synchronously in the
  Worker process — useful for sub-millisecond computations where task spawn
  overhead dominates.

  ## Per-Component Executor Overrides

  When a `SchedulerPolicy` for a runnable includes an `:executor` field, the
  Worker dispatches that runnable through the override executor instead of the
  default. This allows mixing execution strategies within a single workflow.

  ## Scheduler

  The scheduler controls _what_ gets dispatched together and _when_.
  Pass `scheduler: MyScheduler` and `scheduler_opts: [...]` to use a
  custom strategy. Built-in schedulers:

    - `Runic.Runner.Scheduler.Default` — dispatches each runnable individually (default)
    - `Runic.Runner.Scheduler.ChainBatching` — batches linear chains into Promises

  The `promise_opts: [min_chain_length: N]` shorthand is equivalent to
  `scheduler: Runic.Runner.Scheduler.ChainBatching, scheduler_opts: [min_chain_length: N]`.
  An explicit `:scheduler` takes precedence over `:promise_opts`.

  ## Hooks

  Lifecycle hooks allow observability and light customization without replacing
  the Worker. Pass `hooks: [...]` in Worker opts:

    - `on_dispatch: fn runnable, worker_state -> :ok end`
    - `on_complete: fn runnable, duration_ms, worker_state -> :ok end`
    - `on_failed: fn runnable, reason, worker_state -> :ok end`
    - `on_idle: fn worker_state -> :ok end`
    - `on_persistence_error: fn operation, reason, worker_state -> :ok end`
    - `transform_runnables: fn runnables, workflow -> runnables end`

  Hook exceptions are logged but do not crash the Worker.

  Computation completion (`on_complete` and `on_idle`) does not imply successful
  persistence. Failed writes retain pending data, invoke `on_persistence_error`,
  and remain visible through `Runic.Runner.persistence_status/2`. Retry is driven
  by the checkpoint strategy or explicit calls; applications must bound admission
  and pending-buffer growth during an extended Store outage.

  Completion callbacks also run when a stopped admission scope has drained.
  The graph can still contain ready work. Callers can use
  `Runic.Runner.admission_status/2` to distinguish open admission from a stopped
  scope. Hooks that receive Worker state can inspect `admission_causes` directly.
  Do not call Worker query APIs synchronously from a callback or hook. Notify an
  observer process and let it query after the callback returns.
  """

  use GenServer

  require Logger

  alias Runic.Workflow
  alias Runic.Workflow.{Runnable, FactRef, FactResolver}
  alias Runic.Workflow.Events.FactProduced
  alias Runic.Workflow.SchedulerPolicy
  alias Runic.Workflow.PolicyDriver
  alias Runic.Runner.{Telemetry, Promise}

  defstruct [
    :id,
    :runner,
    :workflow,
    :store,
    :task_supervisor,
    :task_scope,
    :task_scope_ref,
    :max_concurrency,
    :on_complete,
    :checkpoint_strategy,
    :resolver,
    :executor,
    :executor_opts,
    :executor_state,
    :scheduler,
    :scheduler_opts,
    :scheduler_state,
    dispatch_mode: :automatic,
    status: :idle,
    admission_causes: [],
    active_tasks: %{},
    dispatched_units: %{},
    active_executors: %{},
    active_promises: %{},
    dispatch_times: %{},
    cycle_count: 0,
    started_at: nil,
    event_cursor: 0,
    uncommitted_events: [],
    persistence: :pending,
    hooks: %{},
    override_executors: %{},
    promise_opts: []
  ]

  # --- Child Spec ---

  def child_spec(opts) do
    id = Keyword.fetch!(opts, :workflow_id)

    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [opts]},
      restart:
        if(Keyword.get(opts, :owner, :background) == :background,
          do: :transient,
          else: :temporary
        ),
      type: :worker
    }
  end

  def start_link(opts) do
    runner = Keyword.fetch!(opts, :runner)
    workflow_id = Keyword.fetch!(opts, :workflow_id)
    name = Runic.Runner.via(runner, workflow_id)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # --- GenServer Callbacks ---

  @impl GenServer
  def init(opts) do
    case validate_owner(Keyword.get(opts, :owner, :background)) do
      :ok -> init_owned(opts)
      {:error, reason} -> {:stop, reason}
    end
  end

  defp validate_owner(:background), do: :ok

  defp validate_owner(owner) when is_pid(owner) and node(owner) == node() do
    if Process.alive?(owner), do: :ok, else: {:error, {:owner_not_alive, owner}}
  end

  defp validate_owner(owner), do: {:error, {:invalid_owner, owner}}

  defp init_owned(opts) do
    runner = Keyword.fetch!(opts, :runner)
    workflow_id = Keyword.fetch!(opts, :workflow_id)
    workflow = Keyword.fetch!(opts, :workflow)
    resumed = Keyword.get(opts, :resumed, false)

    workflow = maybe_apply_resume_options(workflow, opts, resumed)

    {store_mod, store_state} = Runic.Runner.get_store(runner)

    workflow =
      if Runic.Runner.Store.supports_stream?(store_mod) do
        Workflow.enable_event_emission(workflow)
      else
        workflow
      end

    resolver =
      case Keyword.get(opts, :resolver) do
        nil ->
          if function_exported?(store_mod, :load_fact, 2) do
            Runic.Workflow.FactResolver.new({store_mod, store_state})
          else
            nil
          end

        resolver ->
          resolver
      end

    task_supervisor = task_supervisor_ref(runner, workflow_id)

    # Initialize executor
    executor = Keyword.get(opts, :executor, Runic.Runner.Executor.Task)
    executor_opts = Keyword.get(opts, :executor_opts, [])

    # Parse hooks
    hooks = parse_hooks(Keyword.get(opts, :hooks, []))

    # Promise options (backward compat shorthand for ChainBatching scheduler)
    promise_opts = Keyword.get(opts, :promise_opts, [])

    # Initialize scheduler
    {scheduler, scheduler_opts} =
      resolve_scheduler_config(
        Keyword.get(opts, :scheduler),
        Keyword.get(opts, :scheduler_opts, []),
        promise_opts
      )

    scheduler_state = init_scheduler(scheduler, scheduler_opts)

    {:ok, task_scope} =
      Runic.TaskScope.start(
        owner: self(),
        guard_owner: true,
        external_owner: Keyword.get(opts, :owner, :background),
        name: {:via, Registry, {Module.concat(runner, Registry), {Runic.TaskScope, self()}}}
      )

    Runic.TaskScope.attach(task_scope)

    # Validate/init the scheduler before allocating executor resources.
    {executor_state, executor} =
      init_executor(executor, executor_opts, task_supervisor, task_scope)

    state = %__MODULE__{
      id: workflow_id,
      runner: runner,
      workflow: workflow,
      store: {store_mod, store_state},
      task_supervisor: task_supervisor,
      task_scope: task_scope,
      task_scope_ref: Process.monitor(task_scope),
      max_concurrency: Keyword.get(opts, :max_concurrency, System.schedulers_online()),
      on_complete: Keyword.get(opts, :on_complete),
      checkpoint_strategy: Keyword.get(opts, :checkpoint_strategy, :every_cycle),
      resolver: resolver,
      started_at: System.monotonic_time(:millisecond),
      executor: executor,
      executor_opts: executor_opts,
      executor_state: executor_state,
      scheduler: scheduler,
      scheduler_opts: scheduler_opts,
      scheduler_state: scheduler_state,
      dispatch_mode: dispatch_mode(opts),
      hooks: hooks,
      promise_opts: promise_opts
    }

    # Persist initial build events for event-sourced stores (skip on resume)
    case maybe_persist_build_log(state, resumed) do
      {:ok, state} ->
        state =
          if state.workflow.uncommitted_events == [],
            do: state,
            else: collect_pending_events(state, state.workflow, [])

        Telemetry.workflow_event(:start, %{id: workflow_id, workflow_name: workflow.name})
        {:ok, maybe_recover_work(state, resumed)}

      {:error, reason, state} ->
        cleanup_executors(state)
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_cast({:run, input, opts}, %__MODULE__{status: status} = state)
      when status in [:idle, :running] do
    policies = merge_runtime_policies(opts, state.workflow.scheduler_policies)

    workflow =
      state.workflow
      |> maybe_set_policies(policies, state.workflow.scheduler_policies)
      |> maybe_apply_run_context(opts)
      |> Workflow.plan_eagerly(input)

    status = if state.admission_causes == [], do: :running, else: state.status
    state = %{state | workflow: workflow, status: status} |> mark_persistence_pending()
    state = dispatch_runnables(state)

    state = maybe_transition_to_idle(state)

    {:noreply, state}
  end

  def handle_cast({:run, _input, _opts}, state) do
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:get_results, _from, state) do
    {:reply, {:ok, Workflow.raw_productions(state.workflow)}, state}
  end

  def handle_call({:get_results, opts}, _from, state) do
    component_names = Keyword.get(opts, :components)
    {:reply, {:ok, Workflow.results(state.workflow, component_names, opts)}, state}
  end

  def handle_call(:get_workflow, _from, state) do
    {:reply, {:ok, state.workflow}, state}
  end

  def handle_call(:persistence_status, _from, state) do
    pending_events = length(state.uncommitted_events) + length(state.workflow.uncommitted_events)

    {:reply,
     {:ok,
      %{
        status: state.persistence,
        event_cursor: state.event_cursor,
        pending_events: pending_events
      }}, state}
  end

  def handle_call(:admission_status, _from, state) do
    {:reply,
     {:ok,
      %{
        status: if(state.admission_causes == [], do: :open, else: :stopped),
        active_units: map_size(state.active_tasks),
        causes: Enum.reverse(state.admission_causes)
      }}, state}
  end

  def handle_call(:step, _from, %__MODULE__{admission_causes: [_ | _]} = state) do
    {:reply, {:error, :admission_stopped}, state}
  end

  def handle_call(:step, _from, %__MODULE__{dispatch_mode: :automatic} = state) do
    {:reply, {:error, :automatic_dispatch}, state}
  end

  def handle_call(:step, _from, %__MODULE__{active_tasks: tasks} = state)
      when map_size(tasks) > 0 do
    {:reply, {:error, :busy}, state}
  end

  def handle_call(:step, _from, %__MODULE__{} = state) do
    if Workflow.is_runnable?(state.workflow) do
      state = dispatch_one(state)
      state = maybe_transition_to_idle(state)
      {:reply, :ok, state}
    else
      {:reply, {:error, :not_runnable}, state}
    end
  end

  def handle_call(
        :continue,
        _from,
        %__MODULE__{admission_causes: [_ | _], active_tasks: tasks} = state
      )
      when map_size(tasks) > 0 do
    {:reply, {:error, :busy}, state}
  end

  def handle_call(:continue, _from, %__MODULE__{} = state) do
    status = if Workflow.is_runnable?(state.workflow), do: :running, else: state.status
    state = %{state | dispatch_mode: :automatic, admission_causes: [], status: status}
    state = dispatch_runnables(state)
    state = maybe_transition_to_idle(state)
    {:reply, :ok, state}
  end

  def handle_call({:stop, opts}, _from, state) do
    persist? = Keyword.get(opts, :persist, true)
    result = if persist?, do: persist(state, :save), else: {:ok, state}

    case result do
      {:ok, state} ->
        case Runic.TaskScope.confirm_close(state.task_scope) do
          :ok -> {:stop, :normal, :ok, state}
          {:error, reason} -> {:stop, reason, {:error, reason}, state}
        end

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:checkpoint, _from, state) do
    case do_checkpoint(state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  # Task completed successfully — the result is a %Runnable{}
  @impl GenServer
  def handle_info({ref, %Runnable{} = executed}, %{active_tasks: tasks} = state)
      when is_reference(ref) and :erlang.map_get(ref, tasks) == executed.id do
    Process.demonitor(ref, [:flush])
    state = handle_task_result(ref, executed, [], state)
    {:noreply, state}
  end

  # Task completed with durable events — {%Runnable{}, [event]}
  def handle_info({ref, {%Runnable{} = executed, events}}, %{active_tasks: tasks} = state)
      when is_reference(ref) and is_list(events) and
             :erlang.map_get(ref, tasks) == executed.id do
    Process.demonitor(ref, [:flush])
    state = handle_task_result(ref, executed, events, state)
    {:noreply, state}
  end

  # A lost scope cannot deliver results or preserve the ownership contract.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_scope_ref: ref} = state) do
    {:stop, {:task_scope_down, reason}, state}
  end

  # Task crashed
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    unit = Map.get(state.dispatched_units, ref)
    dispatch_time = Map.get(state.dispatch_times, ref)
    state = release_executor(state, ref)

    state =
      if unit do
        duration = System.monotonic_time(:millisecond) - dispatch_time
        notify_scheduler_complete(state, unit, duration)
      else
        state
      end

    case Map.pop(state.active_tasks, ref) do
      {nil, _} ->
        {:noreply, state}

      {{:promise, promise_id}, active_tasks} ->
        Logger.warning(
          "Runner Promise ended without a result for workflow #{inspect(state.id)}, " <>
            "promise #{inspect(promise_id)}: #{inspect(reason)}"
        )

        {_dispatch_time, dispatch_times} = Map.pop(state.dispatch_times, ref)
        {_promise, active_promises} = Map.pop(state.active_promises, promise_id)

        state = %{
          state
          | active_tasks: active_tasks,
            dispatch_times: dispatch_times,
            active_promises: active_promises
        }

        state = stop_admission(state, :uncertain, {:promise, promise_id}, reason)

        state = maybe_checkpoint(state)
        state = dispatch_runnables(state)
        state = maybe_transition_to_idle(state)

        {:noreply, state}

      {runnable_id, active_tasks} ->
        Logger.warning(
          "Runner task ended without a result for workflow #{inspect(state.id)}, " <>
            "runnable #{inspect(runnable_id)}: #{inspect(reason)}"
        )

        {_dispatch_time, dispatch_times} = Map.pop(state.dispatch_times, ref)
        state = %{state | active_tasks: active_tasks, dispatch_times: dispatch_times}

        state = stop_admission(state, :uncertain, {:runnable, runnable_id}, reason)
        state = maybe_checkpoint(state)
        state = dispatch_runnables(state)
        state = maybe_transition_to_idle(state)

        {:noreply, state}
    end
  end

  # Promise completed — batch of executed runnables
  def handle_info(
        {ref, {:promise_result, promise_id, executed_runnables}},
        %{active_tasks: tasks} = state
      )
      when is_reference(ref) and :erlang.map_get(ref, tasks) == {:promise, promise_id} do
    Process.demonitor(ref, [:flush])
    state = release_executor(state, ref)

    {_tag, active_tasks} = Map.pop(state.active_tasks, ref)
    {dispatch_time, dispatch_times} = Map.pop(state.dispatch_times, ref)
    {promise, active_promises} = Map.pop(state.active_promises, promise_id)

    duration = if dispatch_time, do: System.monotonic_time(:millisecond) - dispatch_time, else: 0

    state = %{
      state
      | active_tasks: active_tasks,
        dispatch_times: dispatch_times,
        active_promises: active_promises
    }

    # Apply all runnables from the promise sequentially
    state = apply_promise_results(state, executed_runnables)

    # Emit promise completion telemetry
    Telemetry.promise_event(:stop, %{duration: duration}, %{
      promise_id: promise_id,
      runnable_count:
        if(promise, do: length(promise.runnables), else: length(executed_runnables)),
      node_hashes: if(promise, do: promise.node_hashes, else: MapSet.new())
    })

    state =
      if promise,
        do:
          notify_scheduler_complete(state, {:promise, %{promise | status: :resolved}}, duration),
        else: state

    state = maybe_checkpoint(state)
    state = dispatch_runnables(state)
    state = maybe_transition_to_idle(state)

    {:noreply, state}
  end

  # Promise partially failed — some runnables completed, one failed
  def handle_info(
        {ref, {:promise_partial, promise_id, completed, failed}},
        %{active_tasks: tasks} = state
      )
      when is_reference(ref) and :erlang.map_get(ref, tasks) == {:promise, promise_id} do
    Process.demonitor(ref, [:flush])
    state = release_executor(state, ref)

    {_tag, active_tasks} = Map.pop(state.active_tasks, ref)
    {dispatch_time, dispatch_times} = Map.pop(state.dispatch_times, ref)
    {promise, active_promises} = Map.pop(state.active_promises, promise_id)

    duration = if dispatch_time, do: System.monotonic_time(:millisecond) - dispatch_time, else: 0

    state = %{
      state
      | active_tasks: active_tasks,
        dispatch_times: dispatch_times,
        active_promises: active_promises
    }

    # Apply completed runnables first (partial commit)
    state = apply_promise_results(state, completed)

    # Handle the failed runnable through existing error path
    state = apply_promise_results(state, [failed])

    Telemetry.promise_event(:stop, %{duration: duration}, %{
      promise_id: promise_id,
      runnable_count: if(promise, do: length(promise.runnables), else: 0),
      node_hashes: if(promise, do: promise.node_hashes, else: MapSet.new()),
      partial_failure: true
    })

    state =
      if promise,
        do: notify_scheduler_complete(state, {:promise, %{promise | status: :failed}}, duration),
        else: state

    state = maybe_checkpoint(state)
    state = dispatch_runnables(state)
    state = maybe_transition_to_idle(state)

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    cleanup_executors(state)
    :ok
  end

  # --- Private ---

  defp init_executor(:inline, _opts, _task_supervisor, _task_scope) do
    {nil, :inline}
  end

  defp init_executor(executor_mod, executor_opts, task_supervisor, task_scope) do
    opts = Keyword.put_new(executor_opts, :task_supervisor, task_supervisor)

    opts =
      if executor_mod == Runic.Runner.Executor.Task,
        do: Keyword.put(opts, :task_scope, task_scope),
        else: opts

    case executor_mod.init(opts) do
      {:ok, executor_state} ->
        {executor_state, executor_mod}

      {:error, reason} ->
        raise "Failed to initialize executor #{inspect(executor_mod)}: #{inspect(reason)}"
    end
  end

  defp resolve_scheduler_config(nil, _scheduler_opts, []),
    do: {Runic.Runner.Scheduler.Default, []}

  defp resolve_scheduler_config(nil, _scheduler_opts, promise_opts),
    do: {Runic.Runner.Scheduler.ChainBatching, promise_opts}

  defp resolve_scheduler_config(scheduler, scheduler_opts, _promise_opts),
    do: {scheduler, scheduler_opts}

  defp init_scheduler(scheduler, scheduler_opts) do
    case scheduler.init(scheduler_opts) do
      {:ok, scheduler_state} ->
        scheduler_state

      {:error, reason} ->
        raise "Failed to initialize scheduler #{inspect(scheduler)}: #{inspect(reason)}"
    end
  end

  defp dispatch_mode(opts) do
    case Keyword.get(opts, :dispatch_mode, :automatic) do
      mode when mode in [:automatic, :manual] -> mode
      mode -> raise ArgumentError, "invalid dispatch mode: #{inspect(mode)}"
    end
  end

  defp notify_scheduler_complete(state, dispatch_unit, duration) do
    if function_exported?(state.scheduler, :on_complete, 3) do
      scheduler_state =
        state.scheduler.on_complete(dispatch_unit, duration, state.scheduler_state)

      %{state | scheduler_state: scheduler_state}
    else
      state
    end
  rescue
    e ->
      Logger.warning("Scheduler on_complete raised: #{inspect(e)}")
      state
  end

  defp notify_scheduler_dispatch(state, unit) do
    if function_exported?(state.scheduler, :on_dispatch, 2) do
      %{state | scheduler_state: state.scheduler.on_dispatch(unit, state.scheduler_state)}
    else
      state
    end
  rescue
    error ->
      Logger.warning("Scheduler on_dispatch raised: #{inspect(error)}")
      state
  end

  defp safe_executor_callback(module, callback, args, fallback) do
    apply(module, callback, args)
  catch
    kind, reason ->
      Logger.warning("Executor #{inspect(module)}.#{callback} failed: #{inspect({kind, reason})}")

      fallback
  end

  defp cleanup_executors(%__MODULE__{executor: executor, executor_state: executor_state} = state) do
    # Cleanup default executor
    if executor != :inline and function_exported?(executor, :cleanup, 1) do
      safe_executor_callback(executor, :cleanup, [executor_state], :ok)
    end

    # Cleanup override executors
    Enum.each(state.override_executors, fn {{mod, _opts}, es} ->
      if function_exported?(mod, :cleanup, 1),
        do: safe_executor_callback(mod, :cleanup, [es], :ok)
    end)

    Runic.TaskScope.close(state.task_scope)
  end

  defp stop_admission(state, kind, unit, reason) do
    cause = %{kind: kind, unit: unit, reason: reason}
    %{state | admission_causes: [cause | state.admission_causes]}
  end

  defp record_failure(state, %Runnable{status: :failed} = runnable) do
    stop_admission(state, :failed, {:runnable, runnable.id}, runnable.error)
  end

  defp record_failure(state, _runnable), do: state

  defp handle_task_result(ref, executed, events, state, dispatch? \\ true) do
    state = release_executor(state, ref)
    {_runnable_id, active_tasks} = Map.pop(state.active_tasks, ref)
    {dispatch_time, dispatch_times} = Map.pop(state.dispatch_times, ref)

    duration = if dispatch_time, do: System.monotonic_time(:millisecond) - dispatch_time, else: 0
    emit_runnable_result(executed, state.id, dispatch_time)

    case executed.status do
      :completed ->
        invoke_hook(state.hooks, :on_complete, [executed, duration, state])

      :failed ->
        invoke_hook(state.hooks, :on_failed, [executed, executed.error, state])

      _ ->
        :ok
    end

    workflow = Workflow.apply_runnable(state.workflow, executed)

    workflow =
      if events != [] do
        Workflow.append_runnable_events(workflow, events)
      else
        workflow
      end

    state =
      %{state | active_tasks: active_tasks, dispatch_times: dispatch_times}
      |> collect_pending_events(workflow, events)
      |> record_failure(executed)

    state = notify_scheduler_complete(state, {:runnable, executed}, duration)
    state = maybe_checkpoint(state)

    if dispatch? do
      state |> dispatch_runnables() |> maybe_transition_to_idle()
    else
      state
    end
  end

  defp dispatch_runnables(%__MODULE__{admission_causes: [_ | _]} = state), do: state
  defp dispatch_runnables(%__MODULE__{dispatch_mode: :manual} = state), do: state
  defp dispatch_runnables(%__MODULE__{} = state), do: do_dispatch_runnables(state, :all)
  defp dispatch_one(%__MODULE__{} = state), do: do_dispatch_runnables(state, 1)

  defp do_dispatch_runnables(%__MODULE__{} = state, limit) do
    {workflow, runnables} = Workflow.prepare_for_dispatch(state.workflow)
    state = %{state | workflow: workflow}

    # Build set of active runnable IDs and promise-covered node hashes
    active_runnable_ids =
      MapSet.new(Map.values(state.active_tasks), fn
        {:promise, _id} -> nil
        id -> id
      end)

    promise_covered_hashes =
      state.active_promises
      |> Map.values()
      |> Enum.reduce(MapSet.new(), fn p, acc -> MapSet.union(acc, p.node_hashes) end)

    # Pass the full filtered candidate list to the Scheduler without capping
    # to available_slots. This lets schedulers like FlowBatch see all
    # independent runnables (e.g., 10,000 FanOut items) and group them into
    # parallel Promises. The Worker caps dispatch to available slots below.
    candidates =
      Enum.reject(runnables, fn r ->
        MapSet.member?(active_runnable_ids, r.id) or
          MapSet.member?(promise_covered_hashes, r.node.hash)
      end)

    # Apply transform_runnables hook
    candidates = apply_transform_hook(state.hooks, candidates, workflow)

    # Resolve input facts for all candidates
    candidates =
      Enum.map(candidates, &maybe_resolve_input_fact(&1, state.resolver))

    next = dispatch_via_scheduler(candidates, state, limit)

    # Inline completions do not re-enter a stale scheduler proposal. After this
    # proposal is consumed, prepare a new one if it can make further progress.
    if limit == :all and map_size(next.active_tasks) < next.max_concurrency and
         next.workflow != workflow and
         next.admission_causes == [] and Workflow.is_runnable?(next.workflow) do
      dispatch_runnables(next)
    else
      next
    end
  end

  defp dispatch_via_scheduler(runnables, state, limit) do
    {units, scheduler_state} =
      safe_plan_dispatch(state.scheduler, state.workflow, runnables, state.scheduler_state)

    state = %{state | scheduler_state: scheduler_state}

    units = if limit == :all, do: units, else: Enum.take(units, limit)

    # Dispatch units until available slots are exhausted.
    # Each unit (runnable or promise) costs 1 slot regardless of internal count.
    Enum.reduce_while(units, state, fn unit, acc ->
      available = acc.max_concurrency - map_size(acc.active_tasks)

      if available <= 0 or acc.admission_causes != [] do
        {:halt, acc}
      else
        acc = notify_scheduler_dispatch(acc, unit)

        acc =
          case unit do
            {:runnable, runnable} ->
              policy = SchedulerPolicy.resolve(runnable, acc.workflow.scheduler_policies)
              invoke_hook(acc.hooks, :on_dispatch, [runnable, acc])
              dispatch_single_runnable(runnable, policy, acc)

            {:promise, promise} ->
              Enum.each(promise.runnables, fn r ->
                invoke_hook(acc.hooks, :on_dispatch, [r, acc])
              end)

              dispatch_promise(promise, acc)
          end

        {:cont, acc}
      end
    end)
  end

  defp safe_plan_dispatch(scheduler, workflow, runnables, scheduler_state) do
    scheduler.plan_dispatch(workflow, runnables, scheduler_state)
  rescue
    e ->
      Logger.warning(
        "Scheduler #{inspect(scheduler)} raised in plan_dispatch: #{inspect(e)}, " <>
          "falling back to individual dispatch"
      )

      {Enum.map(runnables, &{:runnable, &1}), scheduler_state}
  end

  defp dispatch_single_runnable(runnable, policy, state) do
    work_fn = build_work_fn(runnable, policy)

    # Determine which executor to use: per-component override or default
    {executor, executor_state, executor_origin, state} = resolve_executor(policy, state)

    now = System.monotonic_time(:millisecond)

    Telemetry.runnable_event(:dispatch, %{
      workflow_id: state.id,
      node_name: node_name(runnable.node),
      runnable_id: runnable.id,
      policy: policy
    })

    case executor do
      :inline ->
        # Execute synchronously in the Worker process.
        # Skip timeout enforcement for inline (per design doc); preserve retry/fallback.
        inline_policy = %{policy | timeout_ms: :infinity}
        result = execute_runnable(runnable, inline_policy)

        # Simulate the async completion path synchronously
        ref = make_ref()

        state = %{
          state
          | active_tasks: Map.put(state.active_tasks, ref, runnable.id),
            dispatch_times: Map.put(state.dispatch_times, ref, now)
        }

        case result do
          {%Runnable{} = executed, events} when is_list(events) ->
            handle_task_result(ref, executed, events, state, false)

          %Runnable{} = executed ->
            handle_task_result(ref, executed, [], state, false)
        end

      executor_mod ->
        {handle, new_executor_state} = executor_mod.dispatch(work_fn, [], executor_state)

        state = update_executor_state(state, executor_origin, new_executor_state)

        %{
          state
          | active_tasks: Map.put(state.active_tasks, handle, runnable.id),
            dispatched_units: Map.put(state.dispatched_units, handle, {:runnable, runnable}),
            active_executors: Map.put(state.active_executors, handle, executor_origin),
            dispatch_times: Map.put(state.dispatch_times, handle, now)
        }
    end
  end

  defp build_work_fn(runnable, policy) do
    fn ->
      execute_runnable(runnable, policy)
    end
  end

  defp execute_runnable(runnable, %SchedulerPolicy{execution_mode: :durable} = policy) do
    PolicyDriver.execute(runnable, policy, emit_events: true)
  end

  defp execute_runnable(runnable, policy) do
    PolicyDriver.execute(runnable, policy)
  end

  # --- Promise Dispatch ---

  defp dispatch_promise(%Promise{} = promise, state) do
    workflow = state.workflow
    policies = workflow.scheduler_policies

    work_fn = fn ->
      resolve_promise(promise, workflow, policies)
    end

    # Dispatch via the default executor (promises don't use per-component overrides)
    {executor, executor_state, state} =
      {state.executor, state.executor_state, state}

    now = System.monotonic_time(:millisecond)

    Telemetry.promise_event(:start, %{
      promise_id: promise.id,
      runnable_count: length(promise.runnables),
      node_hashes: promise.node_hashes
    })

    case executor do
      :inline ->
        # Execute promise synchronously
        result = resolve_promise(promise, workflow, policies)
        ref = make_ref()

        state = %{
          state
          | active_tasks: Map.put(state.active_tasks, ref, {:promise, promise.id}),
            active_promises: Map.put(state.active_promises, promise.id, promise),
            dispatch_times: Map.put(state.dispatch_times, ref, now)
        }

        # Simulate async path synchronously
        case result do
          {:promise_result, promise_id, executed} ->
            handle_promise_result_inline(ref, promise_id, executed, state)

          {:promise_partial, promise_id, completed, failed} ->
            handle_promise_partial_inline(ref, promise_id, completed, failed, state)
        end

      executor_mod ->
        {handle, new_executor_state} = executor_mod.dispatch(work_fn, [], executor_state)

        state = update_executor_state(state, :default, new_executor_state)

        %{
          state
          | active_tasks: Map.put(state.active_tasks, handle, {:promise, promise.id}),
            dispatched_units: Map.put(state.dispatched_units, handle, {:promise, promise}),
            active_executors: Map.put(state.active_executors, handle, :default),
            active_promises: Map.put(state.active_promises, promise.id, promise),
            dispatch_times: Map.put(state.dispatch_times, handle, now)
        }
    end
  end

  defp resolve_promise(%Promise{strategy: :parallel} = promise, _workflow, policies) do
    resolve_promise_parallel(promise, policies)
  end

  defp resolve_promise(%Promise{} = promise, workflow, policies) do
    # Start with the initial runnables in the promise, then follow the chain
    resolve_promise_loop(promise, workflow, policies, promise.runnables, [])
  end

  defp resolve_promise_loop(promise, _workflow, _policies, [], completed) do
    {:promise_result, promise.id, Enum.reverse(completed)}
  end

  defp resolve_promise_loop(promise, workflow, policies, [runnable | _rest], completed) do
    policy = SchedulerPolicy.resolve(runnable, policies)

    executed = execute_runnable(runnable, policy)

    # Normalize to {runnable, events}
    {executed_runnable, _events} =
      case executed do
        {%Runnable{} = r, events} -> {r, events}
        %Runnable{} = r -> {r, []}
      end

    case executed_runnable.status do
      :failed ->
        {:promise_partial, promise.id, Enum.reverse(completed), executed}

      _ ->
        # Apply to local workflow copy so next runnable sees updated state
        wf = Workflow.apply_runnable(workflow, executed_runnable)
        # Prepare next runnables and find those in our chain
        {wf, next_runnables} = Workflow.prepare_for_dispatch(wf)

        chain_runnables =
          Enum.filter(next_runnables, fn r ->
            MapSet.member?(promise.node_hashes, r.node.hash)
          end)

        resolve_promise_loop(promise, wf, policies, chain_runnables, [executed | completed])
    end
  end

  # --- Parallel Promise Resolution ---

  defp resolve_promise_parallel(%Promise{} = promise, policies) do
    runnables = promise.runnables
    flow_opts = promise.flow_opts

    stages =
      Keyword.get(flow_opts, :stages, min(length(runnables), System.schedulers_online()))

    max_demand = Keyword.get(flow_opts, :max_demand, 1)
    task_scope = Runic.TaskScope.current()
    context = Runic.TaskScope.capture_context()
    parent = self()

    execute_fn = fn runnable ->
      :ok = Runic.TaskScope.track(task_scope, self(), parent)
      policy = SchedulerPolicy.resolve(runnable, policies)

      try do
        Runic.TaskScope.within(task_scope, fn ->
          Runic.TaskScope.within_context(context, fn -> execute_runnable(runnable, policy) end)
        end)
      rescue
        e ->
          Runnable.fail(runnable, {:execution_error, e})
      catch
        kind, reason ->
          Runnable.fail(runnable, {kind, reason})
      end
    end

    results = resolve_with_flow(runnables, execute_fn, stages, max_demand)

    {:promise_result, promise.id, results}
  end

  defp resolve_with_flow(runnables, execute_fn, stages, max_demand) do
    runnables
    |> Flow.from_enumerable(stages: stages, max_demand: max_demand)
    |> Flow.map(execute_fn)
    |> Enum.to_list()
  end

  defp handle_promise_result_inline(ref, promise_id, executed, state) do
    {_tag, active_tasks} = Map.pop(state.active_tasks, ref)
    {dispatch_time, dispatch_times} = Map.pop(state.dispatch_times, ref)
    {promise, active_promises} = Map.pop(state.active_promises, promise_id)

    duration = if dispatch_time, do: System.monotonic_time(:millisecond) - dispatch_time, else: 0

    state = %{
      state
      | active_tasks: active_tasks,
        dispatch_times: dispatch_times,
        active_promises: active_promises
    }

    state = apply_promise_results(state, executed)

    Telemetry.promise_event(:stop, %{duration: duration}, %{
      promise_id: promise_id,
      runnable_count: if(promise, do: length(promise.runnables), else: length(executed)),
      node_hashes: if(promise, do: promise.node_hashes, else: MapSet.new())
    })

    state =
      if promise,
        do:
          notify_scheduler_complete(state, {:promise, %{promise | status: :resolved}}, duration),
        else: state

    maybe_checkpoint(state)
  end

  defp handle_promise_partial_inline(ref, promise_id, completed, failed, state) do
    {_tag, active_tasks} = Map.pop(state.active_tasks, ref)
    {dispatch_time, dispatch_times} = Map.pop(state.dispatch_times, ref)
    {promise, active_promises} = Map.pop(state.active_promises, promise_id)

    duration = if dispatch_time, do: System.monotonic_time(:millisecond) - dispatch_time, else: 0

    state = %{
      state
      | active_tasks: active_tasks,
        dispatch_times: dispatch_times,
        active_promises: active_promises
    }

    state = apply_promise_results(state, completed)
    state = apply_promise_results(state, [failed])

    Telemetry.promise_event(:stop, %{duration: duration}, %{
      promise_id: promise_id,
      runnable_count: if(promise, do: length(promise.runnables), else: 0),
      node_hashes: if(promise, do: promise.node_hashes, else: MapSet.new()),
      partial_failure: true
    })

    state =
      if promise,
        do: notify_scheduler_complete(state, {:promise, %{promise | status: :failed}}, duration),
        else: state

    maybe_checkpoint(state)
  end

  defp apply_promise_results(state, executed_list) do
    Enum.reduce(executed_list, state, fn executed, acc ->
      # Normalize to {runnable, events}
      {executed_runnable, events} =
        case executed do
          {%Runnable{} = r, evts} when is_list(evts) -> {r, evts}
          %Runnable{} = r -> {r, []}
        end

      emit_runnable_result(executed_runnable, acc.id, nil)

      case executed_runnable.status do
        :completed ->
          invoke_hook(acc.hooks, :on_complete, [executed_runnable, 0, acc])

        :failed ->
          invoke_hook(acc.hooks, :on_failed, [executed_runnable, executed_runnable.error, acc])

        _ ->
          :ok
      end

      workflow = Workflow.apply_runnable(acc.workflow, executed_runnable)

      workflow =
        if events != [] do
          Workflow.append_runnable_events(workflow, events)
        else
          workflow
        end

      acc |> collect_pending_events(workflow, events) |> record_failure(executed_runnable)
    end)
  end

  defp resolve_executor(policy, state) do
    override_executor = Map.get(policy, :executor)
    override_opts = Map.get(policy, :executor_opts, [])

    case override_executor do
      nil ->
        {state.executor, state.executor_state, :default, state}

      :inline ->
        {:inline, nil, :inline, state}

      override_mod ->
        override_key = {override_mod, override_opts}

        case Map.get(state.override_executors, override_key) do
          nil ->
            # Lazy-init the override executor
            {es, _mod} =
              init_executor(override_mod, override_opts, state.task_supervisor, state.task_scope)

            state = %{
              state
              | override_executors: Map.put(state.override_executors, override_key, es)
            }

            {override_mod, es, {:override, override_key}, state}

          es ->
            {override_mod, es, {:override, override_key}, state}
        end
    end
  end

  defp update_executor_state(state, :default, new_executor_state),
    do: %{state | executor_state: new_executor_state}

  defp update_executor_state(state, {:override, override_key}, new_executor_state) do
    %{
      state
      | override_executors: Map.put(state.override_executors, override_key, new_executor_state)
    }
  end

  defp release_executor(state, handle) do
    state = %{state | dispatched_units: Map.delete(state.dispatched_units, handle)}

    case Map.pop(state.active_executors, handle) do
      {nil, active_executors} ->
        %{state | active_executors: active_executors}

      {executor_origin, active_executors} ->
        state = %{state | active_executors: active_executors}
        executor_mod = executor_module(state, executor_origin)

        if function_exported?(executor_mod, :release, 2) do
          executor_state = executor_state(state, executor_origin)

          update_executor_state(
            state,
            executor_origin,
            safe_executor_callback(
              executor_mod,
              :release,
              [handle, executor_state],
              executor_state
            )
          )
        else
          state
        end
    end
  end

  defp executor_module(state, :default), do: state.executor
  defp executor_module(_state, {:override, {executor_mod, _opts}}), do: executor_mod

  defp executor_state(state, :default), do: state.executor_state

  defp executor_state(state, {:override, override_key}),
    do: Map.fetch!(state.override_executors, override_key)

  defp maybe_resolve_input_fact(runnable, nil), do: runnable

  defp maybe_resolve_input_fact(%Runnable{input_fact: %FactRef{} = ref} = runnable, resolver) do
    case FactResolver.resolve(ref, resolver) do
      {:ok, fact} ->
        %{runnable | input_fact: fact}

      {:error, reason} ->
        Logger.warning(
          "Failed to resolve FactRef #{inspect(ref.hash)} for runnable " <>
            "#{inspect(runnable.id)}: #{inspect(reason)}"
        )

        runnable
    end
  end

  defp maybe_resolve_input_fact(runnable, _resolver), do: runnable

  defp maybe_transition_to_idle(%__MODULE__{active_tasks: tasks, workflow: wf} = state)
       when map_size(tasks) == 0 do
    if state.admission_causes != [] or not Workflow.is_runnable?(wf) do
      state =
        if state.status == :running do
          state = state |> persist(:save) |> persistence_state()
          duration = System.monotonic_time(:millisecond) - state.started_at

          Telemetry.workflow_event(:stop, %{duration: duration}, %{
            id: state.id,
            workflow_name: state.workflow.name,
            persistence: state.persistence
          })

          maybe_notify_complete(state)
          invoke_hook(state.hooks, :on_idle, [state])
          state
        else
          state
        end

      %{state | status: :idle}
    else
      state
    end
  end

  defp maybe_transition_to_idle(state), do: state

  defp maybe_recover_work(%__MODULE__{workflow: workflow} = state, resumed) do
    pending_count = workflow |> Workflow.pending_runnables() |> length()

    cond do
      resumed and Workflow.is_runnable?(workflow) ->
        recover_work(state, workflow, pending_count)

      pending_count > 0 ->
        recover_work(state, Workflow.plan_eagerly(workflow), pending_count)

      true ->
        state
    end
  end

  defp recover_work(state, workflow, pending_count) do
    Logger.info(
      "Worker #{inspect(state.id)} recovering runnable workflow state " <>
        "(#{pending_count} recorded in-flight)"
    )

    state = %{state | workflow: workflow, status: :running} |> mark_persistence_pending()
    state = dispatch_runnables(state)
    maybe_transition_to_idle(state)
  end

  defp merge_runtime_policies(opts, workflow_policies) do
    case Keyword.get(opts, :scheduler_policies) do
      nil ->
        workflow_policies

      overrides ->
        mode = Keyword.get(opts, :scheduler_policies_mode, :merge)
        SchedulerPolicy.merge_policies(overrides, workflow_policies, mode)
    end
  end

  defp maybe_apply_resume_options(workflow, _opts, false), do: workflow

  defp maybe_apply_resume_options(workflow, opts, true) do
    policies = merge_runtime_policies(opts, workflow.scheduler_policies)

    workflow
    |> maybe_set_policies(policies, workflow.scheduler_policies)
    |> maybe_apply_run_context(opts)
  end

  defp maybe_set_policies(workflow, policies, current) when policies == current, do: workflow

  defp maybe_set_policies(workflow, policies, _current),
    do: Workflow.set_scheduler_policies(workflow, policies)

  defp maybe_apply_run_context(workflow, opts) do
    case Keyword.get(opts, :run_context) do
      nil -> workflow
      ctx when is_map(ctx) -> Workflow.put_run_context(workflow, ctx)
    end
  end

  defp task_supervisor_ref(runner, workflow_id) do
    supervisor = Module.concat(runner, TaskSupervisor)
    registry = Module.concat(runner, Registry)

    case Registry.meta(registry, :partitioned_task_supervisor) do
      {:ok, true} -> {:via, PartitionSupervisor, {supervisor, workflow_id}}
      _other -> supervisor
    end
  end

  # --- Hooks ---

  defp parse_hooks(hook_list) when is_list(hook_list) do
    %{
      on_dispatch: Keyword.get(hook_list, :on_dispatch),
      on_complete: Keyword.get(hook_list, :on_complete),
      on_failed: Keyword.get(hook_list, :on_failed),
      on_idle: Keyword.get(hook_list, :on_idle),
      on_persistence_error: Keyword.get(hook_list, :on_persistence_error),
      transform_runnables: Keyword.get(hook_list, :transform_runnables)
    }
  end

  defp parse_hooks(_), do: %{}

  defp invoke_hook(hooks, key, args) do
    case Map.get(hooks, key) do
      nil -> :ok
      hook when is_function(hook) -> safe_invoke_hook(hook, args)
    end
  end

  defp safe_invoke_hook(hook, args) do
    apply(hook, args)
  rescue
    e ->
      Logger.warning("Worker hook raised: #{inspect(e)}")
      :ok
  end

  defp apply_transform_hook(hooks, runnables, workflow) do
    case Map.get(hooks, :transform_runnables) do
      nil ->
        runnables

      hook when is_function(hook, 2) ->
        try do
          hook.(runnables, workflow)
        rescue
          e ->
            Logger.warning("transform_runnables hook raised: #{inspect(e)}")
            runnables
        end
    end
  end

  # --- Telemetry Helpers ---

  defp emit_runnable_result(%Runnable{status: :completed} = r, workflow_id, dispatch_time) do
    duration = if dispatch_time, do: System.monotonic_time(:millisecond) - dispatch_time, else: 0

    Telemetry.runnable_event(:complete, %{duration: duration}, %{
      workflow_id: workflow_id,
      node_name: node_name(r.node),
      runnable_id: r.id,
      status: :completed
    })
  end

  defp emit_runnable_result(%Runnable{status: :failed} = r, workflow_id, _dispatch_time) do
    Telemetry.runnable_event(:exception, %{
      workflow_id: workflow_id,
      node_name: node_name(r.node),
      runnable_id: r.id,
      error: r.error
    })
  end

  defp emit_runnable_result(%Runnable{status: :skipped} = r, workflow_id, dispatch_time) do
    duration = if dispatch_time, do: System.monotonic_time(:millisecond) - dispatch_time, else: 0

    Telemetry.runnable_event(:complete, %{duration: duration}, %{
      workflow_id: workflow_id,
      node_name: node_name(r.node),
      runnable_id: r.id,
      status: :skipped
    })
  end

  defp emit_runnable_result(_runnable, _workflow_id, _dispatch_time), do: :ok

  defp node_name(%{name: name}), do: name
  defp node_name(node), do: Map.get(node, :hash)

  # --- Fact Persistence ---

  defp flush_pending_facts(events, store_mod, store_state) do
    Enum.reduce_while(events, :ok, fn
      %FactProduced{} = event, :ok ->
        with :ok <- save_fact(event, store_mod, store_state),
             :ok <- save_payload(event, store_mod, store_state) do
          {:cont, :ok}
        else
          {:error, _} = error -> {:halt, error}
        end

      _event, :ok ->
        {:cont, :ok}
    end)
  end

  defp save_fact(event, store_mod, store_state) do
    if function_exported?(store_mod, :save_fact, 3) do
      store_mod.save_fact(event.hash, event.value, store_state)
    else
      :ok
    end
  end

  defp save_payload(%FactProduced{payload_digest: %Runic.Identity{} = digest} = event, mod, st) do
    if function_exported?(mod, :save_payload, 3) do
      mod.save_payload(digest, :erlang.term_to_binary(event.value, [:deterministic]), st)
    else
      :ok
    end
  end

  defp save_payload(_event, _mod, _st), do: :ok

  defp strip_fact_values(events) do
    Enum.map(events, fn
      %FactProduced{} = e -> %{e | value: nil}
      other -> other
    end)
  end

  # --- Checkpointing ---

  defp maybe_checkpoint(%{store: nil} = state), do: state
  defp maybe_checkpoint(%{checkpoint_strategy: :manual} = state), do: state
  defp maybe_checkpoint(%{checkpoint_strategy: :on_complete} = state), do: state

  defp maybe_checkpoint(%{checkpoint_strategy: :every_cycle} = state) do
    state |> do_checkpoint() |> persistence_state()
  end

  defp maybe_checkpoint(%{checkpoint_strategy: {:every_n, n}} = state) do
    new_count = state.cycle_count + 1
    state = %{state | cycle_count: new_count}
    if rem(new_count, n) == 0, do: state |> do_checkpoint() |> persistence_state(), else: state
  end

  defp do_checkpoint(state), do: persist(state, :checkpoint)

  # --- Persistence ---

  defp maybe_persist_build_log(
         %{store: {store_mod, store_state}, id: id, workflow: wf} = state,
         resumed
       ) do
    if Runic.Runner.Store.supports_stream?(store_mod) and not resumed do
      build_events = Workflow.build_log(wf)

      result =
        Telemetry.store_span(:build, %{workflow_id: id}, fn ->
          if build_events == [],
            do: {:ok, 0},
            else: store_mod.append(id, build_events, store_state)
        end)

      acknowledge_persistence(result, state, :build)
    else
      {:ok, if(resumed, do: %{state | persistence: :saved}, else: state)}
    end
  end

  defp collect_pending_events(state, workflow, lifecycle_events) do
    {store_mod, _store_state} = state.store

    if Runic.Runner.Store.supports_stream?(store_mod) do
      # Workflow buffers are reversed; the Worker owns a chronological retry batch.
      events = Enum.reverse(workflow.uncommitted_events) ++ lifecycle_events

      state = %{
        state
        | workflow: %{workflow | uncommitted_events: []},
          uncommitted_events: state.uncommitted_events ++ events
      }

      if events == [], do: state, else: mark_persistence_pending(state)
    else
      %{state | workflow: workflow} |> mark_persistence_pending()
    end
  end

  defp mark_persistence_pending(%{persistence: {:error, _}} = state), do: state
  defp mark_persistence_pending(state), do: %{state | persistence: :pending}

  defp persist(%{store: {mod, st}, id: id} = state, operation) do
    state = collect_pending_events(state, state.workflow, [])

    result =
      Telemetry.store_span(operation, %{workflow_id: id}, fn ->
        if Runic.Runner.Store.supports_stream?(mod) do
          append_pending_events(state, mod, st)
        else
          log = Workflow.event_log(state.workflow)

          if operation == :checkpoint and function_exported?(mod, :checkpoint, 3) do
            mod.checkpoint(id, log, st)
          else
            mod.save(id, log, st)
          end
        end
      end)

    acknowledge_persistence(result, state, operation)
  end

  defp append_pending_events(%{uncommitted_events: []} = state, _mod, _st),
    do: {:ok, state.event_cursor}

  defp append_pending_events(state, mod, st) do
    # Keep full values in the retry batch until BOTH value writes and append succeed.
    with :ok <- flush_pending_facts(state.uncommitted_events, mod, st) do
      events =
        if function_exported?(mod, :save_fact, 3) do
          strip_fact_values(state.uncommitted_events)
        else
          state.uncommitted_events
        end

      mod.append(state.id, events, st)
    end
  end

  defp acknowledge_persistence({:ok, cursor}, state, _operation) do
    {:ok, %{state | uncommitted_events: [], event_cursor: cursor, persistence: :saved}}
  end

  defp acknowledge_persistence(:ok, state, _operation),
    do: {:ok, %{state | persistence: :saved}}

  defp acknowledge_persistence({:error, reason}, state, operation) do
    error = {:persistence_failed, reason}
    state = %{state | persistence: {:error, error}}
    Logger.warning("Worker #{inspect(state.id)} #{operation} failed: #{inspect(reason)}")
    invoke_hook(state.hooks, :on_persistence_error, [operation, error, state])
    {:error, error, state}
  end

  defp persistence_state({:ok, state}), do: state
  defp persistence_state({:error, _reason, state}), do: state

  # --- Completion Callbacks ---

  defp maybe_notify_complete(%{on_complete: nil}), do: :ok

  defp maybe_notify_complete(%{on_complete: {m, f, a}} = state) do
    apply(m, f, [state.id, state.workflow | a])
  end

  defp maybe_notify_complete(%{on_complete: callback} = state)
       when is_function(callback, 2) do
    callback.(state.id, state.workflow)
  end
end
