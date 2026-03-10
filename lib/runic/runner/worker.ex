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
  `Runic.Runner.Executor.Task` is used (wrapping `Task.Supervisor.async_nolink`).
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
    - `transform_runnables: fn runnables, workflow -> runnables end`

  Hook exceptions are logged but do not crash the Worker.
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
    status: :idle,
    active_tasks: %{},
    active_promises: %{},
    dispatch_times: %{},
    cycle_count: 0,
    started_at: nil,
    event_cursor: 0,
    uncommitted_events: [],
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

    task_supervisor = Module.concat(runner, TaskSupervisor)

    # Initialize executor
    executor = Keyword.get(opts, :executor, Runic.Runner.Executor.Task)
    executor_opts = Keyword.get(opts, :executor_opts, [])

    {executor_state, executor} =
      init_executor(executor, executor_opts, task_supervisor)

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

    state = %__MODULE__{
      id: workflow_id,
      runner: runner,
      workflow: workflow,
      store: {store_mod, store_state},
      task_supervisor: task_supervisor,
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
      hooks: hooks,
      promise_opts: promise_opts
    }

    Telemetry.workflow_event(:start, %{id: workflow_id, workflow_name: workflow.name})

    # Persist initial build events for event-sourced stores (skip on resume)
    resumed = Keyword.get(opts, :resumed, false)
    state = maybe_persist_build_log(state, resumed)
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
      |> maybe_apply_run_context(opts)
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
    cleanup_executors(state)
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

      {{:promise, promise_id}, active_tasks} ->
        if reason != :normal do
          Logger.warning(
            "Runner promise task crashed for workflow #{inspect(state.id)}, " <>
              "promise #{inspect(promise_id)}: #{inspect(reason)}"
          )
        end

        {dispatch_time, dispatch_times} = Map.pop(state.dispatch_times, ref)
        {promise, active_promises} = Map.pop(state.active_promises, promise_id)

        state = %{
          state
          | active_tasks: active_tasks,
            dispatch_times: dispatch_times,
            active_promises: active_promises
        }

        # Mark all runnables in the promise as crashed
        state =
          if promise do
            Enum.reduce(promise.runnables, state, fn r, acc ->
              mark_crashed_runnable(acc, r.id, reason, dispatch_time)
            end)
          else
            state
          end

        state = maybe_checkpoint(state)
        state = dispatch_runnables(state)
        state = maybe_transition_to_idle(state)

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

  # Promise completed — batch of executed runnables
  def handle_info({ref, {:promise_result, promise_id, executed_runnables}}, state)
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])

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
      if promise, do: notify_scheduler_complete(state, {:promise, promise}, duration), else: state

    state = maybe_checkpoint(state)
    state = dispatch_runnables(state)
    state = maybe_transition_to_idle(state)

    {:noreply, state}
  end

  # Promise partially failed — some runnables completed, one failed
  def handle_info({ref, {:promise_partial, promise_id, completed, failed}}, state)
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])

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
      if promise, do: notify_scheduler_complete(state, {:promise, promise}, duration), else: state

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

  defp init_executor(:inline, _opts, _task_supervisor) do
    {nil, :inline}
  end

  defp init_executor(executor_mod, executor_opts, task_supervisor) do
    # Default TaskExecutor needs the task_supervisor
    opts =
      if executor_mod == Runic.Runner.Executor.Task do
        Keyword.put_new(executor_opts, :task_supervisor, task_supervisor)
      else
        executor_opts
      end

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

  defp cleanup_executors(%__MODULE__{executor: executor, executor_state: executor_state} = state) do
    # Cleanup default executor
    if executor != :inline and function_exported?(executor, :cleanup, 1) do
      executor.cleanup(executor_state)
    end

    # Cleanup override executors
    Enum.each(state.override_executors, fn {mod, es} ->
      if function_exported?(mod, :cleanup, 1), do: mod.cleanup(es)
    end)
  end

  defp mark_crashed_runnable(state, runnable_id, reason, dispatch_time) do
    # Find the runnable in the workflow graph so we can mark it as failed.
    # Without this, the :runnable edge stays in the graph and is_runnable?
    # returns true forever — causing a deadlock.
    case find_runnable_by_id(state.workflow, runnable_id) do
      nil ->
        state

      runnable ->
        failed = Runnable.fail(runnable, {:task_crashed, reason})
        invoke_hook(state.hooks, :on_failed, [runnable, reason, state])
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

    # Collect uncommitted events from the workflow for event-sourced persistence.
    # Events are stored in reverse order by apply_runnable/2 (prepend for O(1)),
    # so reverse here to restore chronological order.
    {store_mod, store_state} = state.store
    new_uncommitted = Enum.reverse(workflow.uncommitted_events)
    # Include durable lifecycle events in the stream too
    all_new_events = new_uncommitted ++ events

    # Persist fact values to the content-addressed fact store before checkpointing
    # events that reference them by hash.
    flush_pending_facts(all_new_events, store_mod, store_state)

    # Strip values from FactProduced events when the store supports fact-level
    # storage. Values are already persisted via flush_pending_facts above;
    # keeping only hashes in the event stream enables lean replay on recovery.
    lean_events =
      if function_exported?(store_mod, :save_fact, 3) do
        strip_fact_values(all_new_events)
      else
        all_new_events
      end

    state =
      if Runic.Runner.Store.supports_stream?(store_mod) and lean_events != [] do
        %{
          state
          | workflow: %{workflow | uncommitted_events: []},
            active_tasks: active_tasks,
            dispatch_times: dispatch_times,
            uncommitted_events: state.uncommitted_events ++ lean_events,
            event_cursor: state.event_cursor + length(lean_events)
        }
      else
        %{
          state
          | workflow: workflow,
            active_tasks: active_tasks,
            dispatch_times: dispatch_times
        }
      end

    state = notify_scheduler_complete(state, {:runnable, executed}, duration)
    state = maybe_checkpoint(state)
    state = dispatch_runnables(state)
    maybe_transition_to_idle(state)
  end

  defp dispatch_runnables(%__MODULE__{} = state) do
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

    dispatch_via_scheduler(candidates, state)
  end

  defp dispatch_via_scheduler(runnables, state) do
    {units, scheduler_state} =
      safe_plan_dispatch(state.scheduler, state.workflow, runnables, state.scheduler_state)

    state = %{state | scheduler_state: scheduler_state}

    # Dispatch units until available slots are exhausted.
    # Each unit (runnable or promise) costs 1 slot regardless of internal count.
    Enum.reduce_while(units, state, fn unit, acc ->
      available = acc.max_concurrency - map_size(acc.active_tasks)

      if available <= 0 do
        {:halt, acc}
      else
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
    {executor, executor_state, state} = resolve_executor(policy, state)

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
        result = PolicyDriver.execute(runnable, inline_policy)

        # Simulate the async completion path synchronously
        ref = make_ref()

        state = %{
          state
          | active_tasks: Map.put(state.active_tasks, ref, runnable.id),
            dispatch_times: Map.put(state.dispatch_times, ref, now)
        }

        case result do
          {%Runnable{} = executed, events} when is_list(events) ->
            handle_task_result(ref, executed, events, state)

          %Runnable{} = executed ->
            handle_task_result(ref, executed, [], state)
        end

      executor_mod ->
        {handle, new_executor_state} = executor_mod.dispatch(work_fn, [], executor_state)

        state = update_executor_state(state, executor_mod, new_executor_state)

        %{
          state
          | active_tasks: Map.put(state.active_tasks, handle, runnable.id),
            dispatch_times: Map.put(state.dispatch_times, handle, now)
        }
    end
  end

  defp build_work_fn(runnable, policy) do
    fn ->
      if policy.execution_mode == :durable do
        PolicyDriver.execute(runnable, policy, emit_events: true)
      else
        PolicyDriver.execute(runnable, policy)
      end
    end
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

        state = update_executor_state(state, executor_mod, new_executor_state)

        %{
          state
          | active_tasks: Map.put(state.active_tasks, handle, {:promise, promise.id}),
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

    executed =
      if policy.execution_mode == :durable do
        PolicyDriver.execute(runnable, policy, emit_events: true)
      else
        PolicyDriver.execute(runnable, policy)
      end

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

    execute_fn = fn runnable ->
      policy = SchedulerPolicy.resolve(runnable, policies)

      try do
        if policy.execution_mode == :durable do
          PolicyDriver.execute(runnable, policy, emit_events: true)
        else
          PolicyDriver.execute(runnable, policy)
        end
      rescue
        e ->
          Runnable.fail(runnable, {:execution_error, e})
      catch
        kind, reason ->
          Runnable.fail(runnable, {kind, reason})
      end
    end

    results =
      if Code.ensure_loaded?(Flow) do
        resolve_with_flow(runnables, execute_fn, stages, max_demand)
      else
        resolve_with_async_stream(runnables, execute_fn, stages)
      end

    {:promise_result, promise.id, results}
  end

  defp resolve_with_flow(runnables, execute_fn, stages, max_demand) do
    runnables
    |> Flow.from_enumerable(stages: stages, max_demand: max_demand)
    |> Flow.map(execute_fn)
    |> Enum.to_list()
  end

  defp resolve_with_async_stream(runnables, execute_fn, max_concurrency) do
    runnables
    |> Task.async_stream(execute_fn,
      max_concurrency: max_concurrency,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, result} -> result end)
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
      if promise, do: notify_scheduler_complete(state, {:promise, promise}, duration), else: state

    state = maybe_checkpoint(state)
    state = dispatch_runnables(state)
    maybe_transition_to_idle(state)
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
      if promise, do: notify_scheduler_complete(state, {:promise, promise}, duration), else: state

    state = maybe_checkpoint(state)
    state = dispatch_runnables(state)
    maybe_transition_to_idle(state)
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

      {store_mod, store_state} = acc.store
      new_uncommitted = Enum.reverse(workflow.uncommitted_events)
      all_new_events = new_uncommitted ++ events

      flush_pending_facts(all_new_events, store_mod, store_state)

      lean_events =
        if function_exported?(store_mod, :save_fact, 3) do
          strip_fact_values(all_new_events)
        else
          all_new_events
        end

      if Runic.Runner.Store.supports_stream?(store_mod) and lean_events != [] do
        %{
          acc
          | workflow: %{workflow | uncommitted_events: []},
            uncommitted_events: acc.uncommitted_events ++ lean_events,
            event_cursor: acc.event_cursor + length(lean_events)
        }
      else
        %{acc | workflow: workflow}
      end
    end)
  end

  defp resolve_executor(policy, state) do
    override_executor = Map.get(policy, :executor)
    override_opts = Map.get(policy, :executor_opts, [])

    case override_executor do
      nil ->
        {state.executor, state.executor_state, state}

      :inline ->
        {:inline, nil, state}

      override_mod ->
        case Map.get(state.override_executors, override_mod) do
          nil ->
            # Lazy-init the override executor
            {es, _mod} = init_executor(override_mod, override_opts, state.task_supervisor)

            state = %{
              state
              | override_executors: Map.put(state.override_executors, override_mod, es)
            }

            {override_mod, es, state}

          es ->
            {override_mod, es, state}
        end
    end
  end

  defp update_executor_state(state, executor_mod, new_executor_state) do
    if executor_mod == state.executor do
      %{state | executor_state: new_executor_state}
    else
      %{
        state
        | override_executors: Map.put(state.override_executors, executor_mod, new_executor_state)
      }
    end
  end

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
    if not Workflow.is_runnable?(wf) do
      if state.status == :running do
        duration = System.monotonic_time(:millisecond) - state.started_at

        Telemetry.workflow_event(:stop, %{duration: duration}, %{
          id: state.id,
          workflow_name: state.workflow.name
        })

        state = maybe_persist(state)
        maybe_notify_complete(state)
        invoke_hook(state.hooks, :on_idle, [state])
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

  defp maybe_apply_run_context(workflow, opts) do
    case Keyword.get(opts, :run_context) do
      nil -> workflow
      ctx when is_map(ctx) -> Workflow.put_run_context(workflow, ctx)
    end
  end

  # --- Hooks ---

  defp parse_hooks(hook_list) when is_list(hook_list) do
    %{
      on_dispatch: Keyword.get(hook_list, :on_dispatch),
      on_complete: Keyword.get(hook_list, :on_complete),
      on_failed: Keyword.get(hook_list, :on_failed),
      on_idle: Keyword.get(hook_list, :on_idle),
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
    if function_exported?(store_mod, :save_fact, 3) do
      Enum.each(events, fn
        %FactProduced{hash: h, value: v} -> store_mod.save_fact(h, v, store_state)
        _ -> :ok
      end)
    end
  end

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
    do_checkpoint(state)
  end

  defp maybe_checkpoint(%{checkpoint_strategy: {:every_n, n}} = state) do
    new_count = state.cycle_count + 1
    state = %{state | cycle_count: new_count}
    if rem(new_count, n) == 0, do: do_checkpoint(state), else: state
  end

  defp do_checkpoint(%{store: {store_mod, store_state}, id: id} = state) do
    if Runic.Runner.Store.supports_stream?(store_mod) do
      # Event-sourced path: append only uncommitted events
      unless Enum.empty?(state.uncommitted_events) do
        Telemetry.store_span(:checkpoint, %{workflow_id: id}, fn ->
          store_mod.append(id, state.uncommitted_events, store_state)
        end)
      end

      %{state | uncommitted_events: []}
    else
      # Legacy path: save full log
      Telemetry.store_span(:checkpoint, %{workflow_id: id}, fn ->
        log = Workflow.log(state.workflow)

        if function_exported?(store_mod, :checkpoint, 3) do
          store_mod.checkpoint(id, log, store_state)
        else
          store_mod.save(id, log, store_state)
        end
      end)

      state
    end
  end

  # --- Persistence ---

  defp maybe_persist_build_log(
         %{store: {store_mod, store_state}, id: id, workflow: wf} = state,
         resumed
       ) do
    if Runic.Runner.Store.supports_stream?(store_mod) and not resumed do
      build_events = Workflow.build_log(wf)

      unless Enum.empty?(build_events) do
        {:ok, cursor} = store_mod.append(id, build_events, store_state)
        %{state | event_cursor: cursor}
      else
        state
      end
    else
      state
    end
  end

  defp maybe_persist(%{store: nil} = state), do: state

  defp maybe_persist(%{store: {store_mod, store_state}, id: id} = state) do
    if Runic.Runner.Store.supports_stream?(store_mod) do
      # Event-sourced: flush any remaining uncommitted events
      unless Enum.empty?(state.uncommitted_events) do
        Telemetry.store_span(:save, %{workflow_id: id}, fn ->
          store_mod.append(id, state.uncommitted_events, store_state)
        end)
      end

      %{state | uncommitted_events: []}
    else
      # Legacy: save full log snapshot
      Telemetry.store_span(:save, %{workflow_id: id}, fn ->
        store_mod.save(id, Workflow.log(state.workflow), store_state)
      end)

      state
    end
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
