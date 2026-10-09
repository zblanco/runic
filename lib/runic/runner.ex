defmodule Runic.Runner do
  @moduledoc """
  Built-in workflow execution infrastructure.

  Provides supervision, persistence, registry, and lifecycle management
  for running workflows as managed processes.

  ## Starting a Runner

      {:ok, _pid} = Runic.Runner.start_link(name: MyApp.Runner)

  ## Store Ownership

  If no `:store` is configured, the Runner starts its built-in ETS store as
  part of the supervision tree. This preserves the zero-configuration,
  in-memory execution path.

  If `:store` is configured explicitly, the Runner assumes that store's
  supervision and lifecycle are managed elsewhere. This applies to custom
  adapters and to built-in stores when you want to own their startup in your
  application's supervision tree.

  For adapters backed by an externally supervised dependency such as an Ecto
  repo:

      {:ok, _pid} =
        Runic.Runner.start_link(
          name: MyApp.Runner,
          store: MyApp.SQLiteStore,
          store_opts: [repo: MyApp.Repo]
        )

  To use the built-in ETS store explicitly, start it before the Runner:

      children = [
        {Runic.Runner.Store.ETS, runner_name: MyApp.Runner},
        {Runic.Runner, name: MyApp.Runner, store: Runic.Runner.Store.ETS}
      ]

  ## Running Workflows

      {:ok, pid} = Runic.Runner.start_workflow(MyApp.Runner, :my_workflow, workflow)
      :ok = Runic.Runner.run(MyApp.Runner, :my_workflow, input)
      {:ok, results} = Runic.Runner.get_results(MyApp.Runner, :my_workflow)

      # Structured results using output port contracts
      {:ok, %{total: value}} = Runic.Runner.get_results(MyApp.Runner, :my_workflow, [])

      # Select specific components
      {:ok, %{price: p}} = Runic.Runner.get_results(MyApp.Runner, :id, components: [:price])
  """

  use Supervisor

  alias Runic.Workflow

  @snapshot_tag :runic_workflow_snapshot
  @snapshot_version 1
  @cancel_grace_timeout 250

  # --- Public API ---

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl Supervisor
  def init(opts) do
    name = Keyword.fetch!(opts, :name)

    store_module = Keyword.get(opts, :store, Runic.Runner.Store.ETS)
    store_opts = Keyword.get(opts, :store_opts, []) |> Keyword.put(:runner_name, name)
    explicit_store? = Keyword.has_key?(opts, :store)

    task_supervisor_opts = Keyword.get(opts, :task_supervisor, [])

    children =
      build_store_children(store_module, store_opts, explicit_store?) ++
        [
          {Registry,
           keys: :unique,
           name: Module.concat(name, Registry),
           meta: [partitioned_task_supervisor: match?({:partition, _}, task_supervisor_opts)]},
          build_task_supervisor_child(name, task_supervisor_opts),
          {DynamicSupervisor, name: Module.concat(name, WorkerSupervisor), strategy: :one_for_one}
        ]

    :persistent_term.put({__MODULE__, name, :store_module}, store_module)
    :persistent_term.put({__MODULE__, name, :store_opts}, store_opts)

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp build_store_children(_store_module, _store_opts, true), do: []
  defp build_store_children(store_module, store_opts, false), do: [{store_module, store_opts}]

  defp build_task_supervisor_child(name, opts) when is_list(opts) do
    {Task.Supervisor, Keyword.put(opts, :name, Module.concat(name, TaskSupervisor))}
  end

  defp build_task_supervisor_child(name, {:partition, n}) do
    {PartitionSupervisor,
     child_spec: Task.Supervisor, name: Module.concat(name, TaskSupervisor), partitions: n}
  end

  # --- Workflow Lifecycle ---

  @doc """
  Starts a new workflow under this runner.

  ## Options

  - `:dispatch_mode` - Controls when ready work is dispatched. Use
    `:automatic` (default) for normal execution or `:manual` to dispatch one
    scheduler unit at a time with `step/2`.
  - `:owner` - `:background` (default) lets the workflow outlive its caller.
    A local PID selects owned execution: owner death cancels the Worker and
    its native work without persistence. Owned Workers are not restarted
    automatically. Supply the owner again when resuming.

  Returns `{:ok, pid}` or `{:error, {:already_started, pid}}`.
  Initial event-stream persistence failures return
  `{:error, {:persistence_failed, reason}}` without starting a Worker.
  """
  def start_workflow(runner, workflow_id, workflow, opts \\ []) do
    worker_spec =
      {Runic.Runner.Worker,
       Keyword.merge(opts,
         runner: runner,
         workflow_id: workflow_id,
         workflow: workflow
       )}

    DynamicSupervisor.start_child(
      Module.concat(runner, WorkerSupervisor),
      worker_spec
    )
  end

  @doc """
  Feeds input to a running workflow.

  ## Options

  - `:run_context` - A map of external values keyed by component name, made available
    to components that use `context/1` expressions. Supports a `:_global` key for
    values available to all components.
  """
  def run(runner, workflow_id, input, opts \\ []) do
    case lookup(runner, workflow_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.cast(pid, {:run, input, opts})
    end
  end

  @doc """
  Dispatches one ready scheduler unit from a manually dispatched workflow.

  The call returns after the unit is dispatched. It returns `{:error, :busy}`
  while prior work is active and `{:error, :not_runnable}` when the workflow
  has no ready work.

  `:ok` acknowledges admission, not completion or persistence. An inline unit
  may finish during the call. A Promise is one unit and may contain several
  components. Manual mode is Worker-local configuration, not a durable pause
  or human-approval record; pass `dispatch_mode: :manual` again when resuming.
  """
  def step(runner, workflow_id) do
    case lookup(runner, workflow_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :step)
    end
  end

  @doc """
  Changes a manually dispatched workflow to automatic dispatch.

  Ready work is dispatched immediately. The workflow stays in automatic mode
  for the rest of the Worker process.
  """
  def continue(runner, workflow_id) do
    case lookup(runner, workflow_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :continue)
    end
  end

  @doc """
  Returns the raw productions from a running workflow.

  For structured results using port contracts, use `get_results/3`.
  """
  def get_results(runner, workflow_id) do
    case lookup(runner, workflow_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :get_results)
    end
  end

  @doc """
  Returns structured results from a running workflow.

  ## Options

    - `:components` — list of component names to extract. When `nil` (default),
      uses the workflow's output port contract.
    - `:facts` — when `true`, returns `%Fact{}` structs. Default `false`.
    - `:all` — when `true`, returns all produced values as lists. Default `false`.

  ## Examples

      # Use output port contract
      {:ok, %{total: 42.50}} = Runner.get_results(runner, :order_pipeline, [])

      # Explicit component selection
      {:ok, %{price: 42.50}} = Runner.get_results(runner, :order_pipeline, components: [:price])

      # All values as facts
      {:ok, %{total: [%Fact{}, ...]}} = Runner.get_results(runner, :id, facts: true, all: true)
  """
  def get_results(runner, workflow_id, opts) when is_list(opts) do
    case lookup(runner, workflow_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:get_results, opts})
    end
  end

  @doc """
  Returns the full workflow struct from a running workflow.
  """
  def get_workflow(runner, workflow_id) do
    case lookup(runner, workflow_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :get_workflow)
    end
  end

  @doc """
  Stops a running workflow.

  Options:
    - `persist: true` (default) — saves final state to the store before stopping
    - `persist: false` — stops without saving

  If persistence fails, returns `{:error, {:persistence_failed, reason}}` and
  leaves the Worker alive with its pending data for retry. `persist: false`
  explicitly discards the Worker's in-memory progress and stops without saving.
  A successful stop waits for default-executor native work to stop. Inline
  work must return before this call can be handled; use `cancel/2` to interrupt
  an unresponsive Worker.
  """
  def stop(runner, workflow_id, opts \\ []) do
    case lookup(runner, workflow_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:stop, opts})
    end
  end

  @doc """
  Cancels a Worker without saving, and waits for its native work to stop.

  Cancellation removes the Worker from its supervisor, including an inline
  Worker that cannot handle calls. `:ok` confirms that the Worker and its task
  scope have stopped. It does not acknowledge persistence or undo completed
  external effects. Custom executors retain their own cleanup contract.
  Cancellation first gives the Worker 250 milliseconds to stop without saving
  and run executor cleanup. It then uses supervisor termination if the Worker
  is still alive. Forced termination can interrupt or bypass custom cleanup.
  If the scope registration is unavailable, the Worker is still stopped, but
  cancellation returns an error because native quiescence cannot be confirmed.
  If another Worker is registered for the same ID before confirmation,
  returns `{:error, :worker_replaced}`. The replacement is left alive so the
  caller can decide whether to cancel it in a new call.

  Cancelling a Worker cancels all of its inputs. A concurrent result already
  accepted by the Worker remains accepted; later results cannot be applied by
  the cancelled Worker. A new or resumed Worker rejects the old handles.
  """
  def cancel(runner, workflow_id) do
    case lookup(runner, workflow_id) do
      nil ->
        {:error, :not_found}

      worker ->
        scope =
          case Registry.lookup(Module.concat(runner, Registry), {Runic.TaskScope, worker}) do
            [{pid, _}] -> {pid, Process.monitor(pid)}
            [] -> nil
          end

        cancel_gracefully(worker)

        case DynamicSupervisor.terminate_child(Module.concat(runner, WorkerSupervisor), worker) do
          result when result in [:ok, {:error, :not_found}] ->
            confirm_cancel(runner, workflow_id, scope)

          error ->
            if scope, do: Process.demonitor(elem(scope, 1), [:flush])
            error
        end
    end
  end

  defp cancel_gracefully(worker) do
    # A responsive Worker closes native work, then runs all executor cleanup callbacks.
    GenServer.call(worker, {:stop, [persist: false]}, @cancel_grace_timeout)
  catch
    :exit, _reason -> :ok
  end

  defp confirm_cancel(_runner, _workflow_id, nil),
    do: {:error, :ownership_scope_unavailable}

  defp confirm_cancel(runner, workflow_id, {scope, ref}) do
    case Runic.TaskScope.await_closed(ref, scope) do
      :ok ->
        case lookup(runner, workflow_id) do
          nil -> :ok
          _replacement -> {:error, :worker_replaced}
        end

      error ->
        error
    end
  end

  @doc """
  Triggers an explicit checkpoint for a running workflow.

  Persists the current workflow state to the store regardless of
  the configured checkpoint strategy. Useful with `checkpoint_strategy: :manual`.

  Returns `:ok` only after the Store acknowledges persistence, or
  `{:error, {:persistence_failed, reason}}` with pending data retained for retry.
  Store acknowledgement has the durability guarantees of the configured adapter;
  the default ETS Store only survives Worker restarts within the same VM.
  """
  def checkpoint(runner, workflow_id) do
    case lookup(runner, workflow_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :checkpoint)
    end
  end

  @doc """
  Returns the persistence status of a workflow Worker.

  Returns `{:ok, %{status: status, event_cursor: cursor, pending_events: count}}`,
  or `{:error, :not_found}`. Status is `:saved`, `:pending`, or
  `{:error, {:persistence_failed, reason}}`. Computation may finish while
  persistence remains pending or failed. The cursor is the latest Store cursor
  acknowledged by this Worker (zero until an append is acknowledged). Legacy
  snapshot Stores have no cursor and the event count only covers stream buffers.

  No retries are scheduled by this query. Use `checkpoint/2` to retry. Like other
  Worker calls, do not call this synchronously from a Worker lifecycle hook.
  """
  def persistence_status(runner, workflow_id) do
    case lookup(runner, workflow_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :persistence_status)
    end
  end

  @doc """
  Lists all active workflow IDs managed by this runner.
  """
  def list_workflows(runner) do
    registry = Module.concat(runner, Registry)

    Registry.select(registry, [
      {{{Runic.Runner.Worker, :"$1"}, :_, :_}, [], [:"$1"]}
    ])
  end

  @doc """
  Looks up the PID of a running workflow by ID.

  Returns `pid` or `nil`.
  """
  def lookup(runner, workflow_id) do
    registry = Module.concat(runner, Registry)

    case Registry.lookup(registry, {Runic.Runner.Worker, workflow_id}) do
      [{pid, _value}] -> if Process.alive?(pid), do: pid
      [] -> nil
    end
  end

  @doc """
  Encodes a workflow snapshot for stores implementing `Runic.Runner.Store`.

  The encoded format is tagged and versioned so `resume/3` can distinguish
  Runic workflow snapshots from legacy adapter-specific blobs.

  Top-level `run_context` is omitted and must be supplied again on resume.
  This does not sanitize captured bindings, policies, or resources embedded
  elsewhere in the graph; raw snapshots are trusted, version-coupled data,
  not a portable or secret-free workflow format.
  """
  @spec encode_snapshot(Workflow.t()) :: binary()
  def encode_snapshot(%Workflow{} = workflow) do
    workflow = %{workflow | run_context: %{}}
    :erlang.term_to_binary({@snapshot_tag, @snapshot_version, workflow})
  end

  @doc """
  Decodes a workflow snapshot produced by `encode_snapshot/1`.
  """
  @spec decode_snapshot(binary()) ::
          {:ok, Workflow.t()} | {:error, :invalid_snapshot | {:unsupported_snapshot, term()}}
  def decode_snapshot(snapshot) when is_binary(snapshot) do
    case :erlang.binary_to_term(snapshot) do
      {@snapshot_tag, @snapshot_version, %Workflow{} = workflow} ->
        {:ok, normalize_snapshot_workflow(workflow)}

      {@snapshot_tag, version, _workflow} ->
        {:error, {:unsupported_snapshot, version}}

      _other ->
        {:error, :invalid_snapshot}
    end
  rescue
    ArgumentError -> {:error, :invalid_snapshot}
  end

  defp normalize_snapshot_workflow(workflow) do
    Map.put(workflow, :run_context, %{})
  end

  @doc """
  Resumes a workflow from persisted state.

  Loads persisted workflow state from the configured store and starts a new
  Worker. Event-sourced stores are replayed through `Workflow.from_events/2`.
  Stores that implement snapshots plus cursor-aware replay can resume from a
  saved workflow snapshot and replay only events after its cursor.

  ## Options

    - `:rehydration` — Controls how fact values are loaded during recovery.
      - `:full` (default) — All fact values are loaded into memory.
      - `:hybrid` — Uses lean replay to create `FactRef` vertices, classifies
        hot/cold facts, then resolves only hot values from the fact store.
        Requires a store that implements `save_fact/3` and `load_fact/2`.
      - `:lazy` — All facts stay as `FactRef` structs, resolved on demand
        during dispatch. Maximum memory savings, but requires resolution
        before any fact value can be used.
    - `:run_context` — Runtime-only component context. It is applied before
      pending work is recovered and is not loaded from persisted state.
    - `:scheduler_policies` — Runtime policy overrides. They are applied before
      pending work is recovered.
    - `:scheduler_policies_mode` — `:merge` (default) or `:replace`.
  """
  def resume(runner, workflow_id, opts \\ []) do
    {store_mod, store_state} = get_store(runner)

    if Runic.Runner.Store.supports_stream?(store_mod) do
      rehydration = Keyword.get(opts, :rehydration, :full)
      store = {store_mod, store_state}

      case resume_from_streaming_store(workflow_id, rehydration, store) do
        {:ok, workflow, resolver} ->
          worker_opts =
            opts
            |> Keyword.put(:resumed, true)
            |> Keyword.put(:resolver, resolver)

          start_workflow(runner, workflow_id, workflow, worker_opts)

        {:error, :not_found} ->
          # Fall back to legacy load
          resume_from_log(runner, workflow_id, store_mod, store_state, opts)

        {:error, _} = error ->
          error
      end
    else
      resume_from_log(runner, workflow_id, store_mod, store_state, opts)
    end
  end

  defp resume_from_streaming_store(workflow_id, rehydration, {store_mod, store_state} = store) do
    if Runic.Runner.Store.supports_snapshots?(store_mod) and
         Runic.Runner.Store.supports_stream_options?(store_mod) do
      case store_mod.load_snapshot(workflow_id, store_state) do
        {:ok, {cursor, snapshot}} ->
          resume_from_snapshot(workflow_id, cursor, snapshot, rehydration, store)

        {:error, :not_found} ->
          resume_from_full_stream(workflow_id, rehydration, store)

        {:error, _} = error ->
          error
      end
    else
      resume_from_full_stream(workflow_id, rehydration, store)
    end
  end

  defp resume_from_snapshot(workflow_id, cursor, snapshot, rehydration, store) do
    case decode_snapshot(snapshot) do
      {:ok, %Workflow{} = base_workflow} ->
        resume_from_snapshot_tail(workflow_id, cursor, base_workflow, rehydration, store)

      {:error, _reason} ->
        resume_from_full_stream(workflow_id, rehydration, store)
    end
  end

  defp resume_from_snapshot_tail(
         workflow_id,
         cursor,
         %Workflow{} = base_workflow,
         rehydration,
         {store_mod, store_state} = store
       ) do
    case store_mod.stream(workflow_id, store_state, after_cursor: cursor) do
      {:ok, event_stream} ->
        events = Enum.to_list(event_stream)
        {workflow, resolver} = resume_from_events(events, rehydration, store, base_workflow)
        {:ok, workflow, resolver}

      {:error, :not_found} ->
        {workflow, resolver} = resume_from_events([], rehydration, store, base_workflow)
        {:ok, workflow, resolver}

      {:error, _} = error ->
        error
    end
  end

  defp resume_from_full_stream(workflow_id, rehydration, {store_mod, store_state} = store) do
    case store_mod.stream(workflow_id, store_state) do
      {:ok, event_stream} ->
        events = Enum.to_list(event_stream)
        {workflow, resolver} = resume_from_events(events, rehydration, store)
        {:ok, workflow, resolver}

      {:error, _} = error ->
        error
    end
  end

  defp resume_from_events(events, rehydration, store, base_workflow \\ nil)

  defp resume_from_events(events, :full, store, base_workflow) do
    # Check if any FactProduced events have been stripped of values
    has_stripped =
      Enum.any?(events, fn
        %Runic.Workflow.Events.FactProduced{value: nil} -> true
        _ -> false
      end)

    if has_stripped do
      # Lean replay + resolve all facts to restore full in-memory state
      workflow = Workflow.from_events(events, base_workflow, fact_mode: :ref)

      all_ref_hashes =
        for {hash, %Workflow.FactRef{}} <- workflow.graph.vertices,
            into: MapSet.new(),
            do: hash

      resolver = Workflow.FactResolver.new(store)

      {workflow, _resolver} =
        Workflow.Rehydration.resolve_hot(workflow, all_ref_hashes, resolver)

      {workflow, nil}
    else
      {Workflow.from_events(events, base_workflow), nil}
    end
  end

  defp resume_from_events(events, :hybrid, store, base_workflow) do
    workflow = Workflow.from_events(events, base_workflow, fact_mode: :ref)
    %{hot: hot} = Workflow.Rehydration.classify(workflow)
    resolver = Workflow.FactResolver.new(store)
    {workflow, resolver} = Workflow.Rehydration.resolve_hot(workflow, hot, resolver)
    {workflow, resolver}
  end

  defp resume_from_events(events, :lazy, store, base_workflow) do
    workflow = Workflow.from_events(events, base_workflow, fact_mode: :ref)
    {workflow, Workflow.FactResolver.new(store)}
  end

  defp resume_from_log(runner, workflow_id, store_mod, store_state, opts) do
    case store_mod.load(workflow_id, store_state) do
      {:ok, log} ->
        workflow = Runic.Workflow.from_events(log)
        start_workflow(runner, workflow_id, workflow, Keyword.put(opts, :resumed, true))

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Returns the via tuple for addressing a worker through the registry.
  """
  def via(runner, workflow_id) do
    {:via, Registry, {Module.concat(runner, Registry), {Runic.Runner.Worker, workflow_id}}}
  end

  @doc """
  Returns the `{store_module, store_state}` tuple for this runner.

  The store state is initialized lazily on first access and cached in persistent_term.
  """
  def get_store(runner) do
    case :persistent_term.get({__MODULE__, runner, :store}, nil) do
      nil ->
        store_module = :persistent_term.get({__MODULE__, runner, :store_module})
        store_opts = :persistent_term.get({__MODULE__, runner, :store_opts})
        {:ok, store_state} = store_module.init_store(store_opts)
        :persistent_term.put({__MODULE__, runner, :store}, {store_module, store_state})
        {store_module, store_state}

      result ->
        result
    end
  end
end
