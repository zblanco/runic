defmodule Runic.Runner.Worker do
  @moduledoc """
  GenServer managing a single workflow's execution lifecycle.

  The Worker implements the dispatch loop: plan → prepare → dispatch → apply,
  using `Task.Supervisor.async_nolink` for fault-isolated task execution and
  `PolicyDriver` for policy-aware invocation.

  Workers are started under the Runner's DynamicSupervisor and registered
  in the Runner's Registry for lookup by workflow ID.
  """

  use GenServer

  require Logger

  alias Runic.Workflow
  alias Runic.Workflow.Runnable
  alias Runic.Workflow.SchedulerPolicy
  alias Runic.Workflow.PolicyDriver
  alias Runic.Runner.Telemetry

  defstruct [
    :id,
    :runner,
    :workflow,
    :store,
    :task_supervisor,
    :max_concurrency,
    :on_complete,
    :checkpoint_strategy,
    status: :idle,
    active_tasks: %{},
    dispatch_times: %{},
    cycle_count: 0,
    started_at: nil
  ]

  # --- Child Spec ---

  def child_spec(opts) do
    id = Keyword.fetch!(opts, :workflow_id)

    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
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
    runner = Keyword.fetch!(opts, :runner)
    workflow_id = Keyword.fetch!(opts, :workflow_id)
    workflow = Keyword.fetch!(opts, :workflow)

    {store_mod, store_state} = Runic.Runner.get_store(runner)

    state = %__MODULE__{
      id: workflow_id,
      runner: runner,
      workflow: workflow,
      store: {store_mod, store_state},
      task_supervisor: Module.concat(runner, TaskSupervisor),
      max_concurrency: Keyword.get(opts, :max_concurrency, System.schedulers_online()),
      on_complete: Keyword.get(opts, :on_complete),
      checkpoint_strategy: Keyword.get(opts, :checkpoint_strategy, :every_cycle),
      started_at: System.monotonic_time(:millisecond)
    }

    Telemetry.workflow_event(:start, %{id: workflow_id, workflow_name: workflow.name})

    state = maybe_recover_in_flight(state)

    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:run, input, opts}, %__MODULE__{status: status} = state)
      when status in [:idle, :running] do
    policies = merge_runtime_policies(opts, state.workflow.scheduler_policies)

    workflow =
      state.workflow
      |> maybe_set_policies(policies, state.workflow.scheduler_policies)
      |> Workflow.plan_eagerly(input)

    state = %{state | workflow: workflow, status: :running}
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

  def handle_call(:get_workflow, _from, state) do
    {:reply, {:ok, state.workflow}, state}
  end

  def handle_call({:stop, opts}, _from, state) do
    persist? = Keyword.get(opts, :persist, true)
    state = if persist?, do: maybe_persist(state), else: state
    {:stop, :normal, :ok, state}
  end

  def handle_call(:checkpoint, _from, state) do
    state = do_checkpoint(state)
    {:reply, :ok, state}
  end

  # Task completed successfully — the result is a %Runnable{}
  @impl GenServer
  def handle_info({ref, %Runnable{} = executed}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    state = handle_task_result(ref, executed, [], state)
    {:noreply, state}
  end

  # Task completed with durable events — {%Runnable{}, [event]}
  def handle_info({ref, {%Runnable{} = executed, events}}, state)
      when is_reference(ref) and is_list(events) do
    Process.demonitor(ref, [:flush])
    state = handle_task_result(ref, executed, events, state)
    {:noreply, state}
  end

  # Task crashed
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    case Map.pop(state.active_tasks, ref) do
      {nil, _} ->
        {:noreply, state}

      {runnable_id, active_tasks} ->
        if reason != :normal do
          Logger.warning(
            "Runner task crashed for workflow #{inspect(state.id)}, " <>
              "runnable #{inspect(runnable_id)}: #{inspect(reason)}"
          )
        end

        {dispatch_time, dispatch_times} = Map.pop(state.dispatch_times, ref)
        state = %{state | active_tasks: active_tasks, dispatch_times: dispatch_times}

        state = mark_crashed_runnable(state, runnable_id, reason, dispatch_time)
        state = maybe_checkpoint(state)
        state = dispatch_runnables(state)
        state = maybe_transition_to_idle(state)

        {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private ---

  defp mark_crashed_runnable(state, runnable_id, reason, dispatch_time) do
    # Find the runnable in the workflow graph so we can mark it as failed.
    # Without this, the :runnable edge stays in the graph and is_runnable?
    # returns true forever — causing a deadlock.
    case find_runnable_by_id(state.workflow, runnable_id) do
      nil ->
        state

      runnable ->
        failed = Runnable.fail(runnable, {:task_crashed, reason})
        emit_runnable_result(failed, state.id, dispatch_time)
        workflow = Workflow.apply_runnable(state.workflow, failed)
        %{state | workflow: workflow}
    end
  end

  defp find_runnable_by_id(workflow, runnable_id) do
    Workflow.prepared_runnables(workflow)
    |> Enum.find(fn r -> r.id == runnable_id end)
  end

  defp handle_task_result(ref, executed, events, state) do
    {_runnable_id, active_tasks} = Map.pop(state.active_tasks, ref)
    {dispatch_time, dispatch_times} = Map.pop(state.dispatch_times, ref)

    emit_runnable_result(executed, state.id, dispatch_time)

    workflow = Workflow.apply_runnable(state.workflow, executed)

    workflow =
      if events != [] do
        Workflow.append_runnable_events(workflow, events)
      else
        workflow
      end

    state = %{
      state
      | workflow: workflow,
        active_tasks: active_tasks,
        dispatch_times: dispatch_times
    }

    state = maybe_checkpoint(state)
    state = dispatch_runnables(state)
    maybe_transition_to_idle(state)
  end

  defp dispatch_runnables(%__MODULE__{} = state) do
    {workflow, runnables} = Workflow.prepare_for_dispatch(state.workflow)
    state = %{state | workflow: workflow}

    available_slots = state.max_concurrency - map_size(state.active_tasks)
    active_runnable_ids = MapSet.new(Map.values(state.active_tasks))

    runnables_to_dispatch =
      runnables
      |> Enum.reject(fn r -> MapSet.member?(active_runnable_ids, r.id) end)
      |> Enum.take(max(available_slots, 0))

    Enum.reduce(runnables_to_dispatch, state, fn runnable, acc ->
      policy = SchedulerPolicy.resolve(runnable, acc.workflow.scheduler_policies)

      task =
        Task.Supervisor.async_nolink(acc.task_supervisor, fn ->
          if policy.execution_mode == :durable do
            PolicyDriver.execute(runnable, policy, emit_events: true)
          else
            PolicyDriver.execute(runnable, policy)
          end
        end)

      now = System.monotonic_time(:millisecond)

      Telemetry.runnable_event(:dispatch, %{
        workflow_id: acc.id,
        node_name: node_name(runnable.node),
        runnable_id: runnable.id,
        policy: policy
      })

      %{
        acc
        | active_tasks: Map.put(acc.active_tasks, task.ref, runnable.id),
          dispatch_times: Map.put(acc.dispatch_times, task.ref, now)
      }
    end)
  end

  defp maybe_transition_to_idle(%__MODULE__{active_tasks: tasks, workflow: wf} = state)
       when map_size(tasks) == 0 do
    if not Workflow.is_runnable?(wf) do
      if state.status == :running do
        duration = System.monotonic_time(:millisecond) - state.started_at

        Telemetry.workflow_event(:stop, %{duration: duration}, %{
          id: state.id,
          workflow_name: state.workflow.name
        })

        state = maybe_persist(state)
        maybe_notify_complete(state)
      end

      %{state | status: :idle}
    else
      state
    end
  end

  defp maybe_transition_to_idle(state), do: state

  defp maybe_recover_in_flight(%__MODULE__{workflow: workflow} = state) do
    case Workflow.pending_runnables(workflow) do
      [] ->
        state

      pending ->
        Logger.info(
          "Worker #{inspect(state.id)} recovering #{length(pending)} in-flight runnables"
        )

        workflow = Workflow.plan_eagerly(workflow)
        state = %{state | workflow: workflow, status: :running}
        state = dispatch_runnables(state)
        maybe_transition_to_idle(state)
    end
  end

  defp merge_runtime_policies(opts, workflow_policies) do
    case Keyword.get(opts, :scheduler_policies) do
      nil -> workflow_policies
      overrides -> SchedulerPolicy.merge_policies(overrides, workflow_policies)
    end
  end

  defp maybe_set_policies(workflow, policies, current) when policies == current, do: workflow

  defp maybe_set_policies(workflow, policies, _current),
    do: Workflow.set_scheduler_policies(workflow, policies)

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

  # --- Checkpointing ---

  defp maybe_checkpoint(%{store: nil} = state), do: state
  defp maybe_checkpoint(%{checkpoint_strategy: :manual} = state), do: state
  defp maybe_checkpoint(%{checkpoint_strategy: :on_complete} = state), do: state

  defp maybe_checkpoint(%{checkpoint_strategy: :every_cycle} = state) do
    do_checkpoint(state)
  end

  defp maybe_checkpoint(%{checkpoint_strategy: {:every_n, n}} = state) do
    new_count = state.cycle_count + 1
    state = %{state | cycle_count: new_count}
    if rem(new_count, n) == 0, do: do_checkpoint(state), else: state
  end

  defp do_checkpoint(%{store: {store_mod, store_state}, id: id, workflow: wf} = state) do
    Telemetry.store_span(:checkpoint, %{workflow_id: id}, fn ->
      log = Workflow.log(wf)

      if function_exported?(store_mod, :checkpoint, 3) do
        store_mod.checkpoint(id, log, store_state)
      else
        store_mod.save(id, log, store_state)
      end
    end)

    state
  end

  # --- Persistence ---

  defp maybe_persist(%{store: nil} = state), do: state

  defp maybe_persist(%{store: {store_mod, store_state}, id: id, workflow: wf} = state) do
    Telemetry.store_span(:save, %{workflow_id: id}, fn ->
      store_mod.save(id, Workflow.log(wf), store_state)
    end)

    state
  end

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
