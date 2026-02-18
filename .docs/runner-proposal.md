# Runic Runner — Built-in Workflow Execution Infrastructure

**Status:** Draft  
**Scope:** `Runic.Runner` module tree — supervision, persistence, registry, durable execution  
**Related:** [Scheduler Policies Proposal](scheduler-policies-proposal.md), [Scheduling Guide](../guides/scheduling.md)

---

## Table of Contents

- [Motivation](#motivation)
- [Design Principles](#design-principles)
- [Architecture Overview](#architecture-overview)
- [Module Map](#module-map)
- [Runic.Runner — The Supervisor Entry Point](#runicrunner--the-supervisor-entry-point)
- [Runic.Runner.Worker — The GenServer Core](#runicrunnerworker--the-genserver-core)
  - [State Machine](#state-machine)
  - [Dispatch Loop](#dispatch-loop)
  - [Policy Integration](#policy-integration)
  - [Completion Callbacks](#completion-callbacks)
- [Runic.Runner.Store — Persistence Behaviour](#runicrunnerstore--persistence-behaviour)
  - [Behaviour Definition](#behaviour-definition)
  - [Built-in Adapters](#built-in-adapters)
  - [Adapter Interface Examples](#adapter-interface-examples)
- [Registry & Distribution](#registry--distribution)
  - [Default: Elixir Registry](#default-elixir-registry)
  - [Custom Registry Adapters](#custom-registry-adapters)
  - [Distributed Registry](#distributed-registry)
- [Lifecycle & API](#lifecycle--api)
  - [Starting Workflows](#starting-workflows)
  - [Feeding Input](#feeding-input)
  - [Querying State](#querying-state)
  - [Stopping & Cleanup](#stopping--cleanup)
- [Durability Model](#durability-model)
  - [Event Sourcing via Workflow.log/1](#event-sourcing-via-workflowlog1)
  - [Checkpoint Strategy](#checkpoint-strategy)
  - [Recovery on Restart](#recovery-on-restart)
  - [In-Flight Runnable Recovery](#in-flight-runnable-recovery)
- [Interaction with Scheduler Policies](#interaction-with-scheduler-policies)
- [Telemetry & Observability](#telemetry--observability)
- [Extension Points](#extension-points)
  - [Custom Worker Behaviour](#custom-worker-behaviour)
  - [Executor Behaviour](#executor-behaviour)
- [Adapter Sketches](#adapter-sketches)
  - [ETS Adapter (Default)](#ets-adapter-default)
  - [Mnesia Adapter](#mnesia-adapter)
  - [Postgres Adapter](#postgres-adapter)
  - [SQLite Adapter](#sqlite-adapter)
  - [Oban Adapter](#oban-adapter)
  - [Khepri Adapter](#khepri-adapter)
  - [RocksDB Adapter](#rocksdb-adapter)
- [Full API Examples](#full-api-examples)
- [Implementation Phases](#implementation-phases)

---

## Motivation

The [scheduling guide](../guides/scheduling.md) walks users through building their own GenServer-based workflow runners from scratch. This is by design — Runic workflows are process-agnostic data structures, and the three-phase execution model enables any scheduling strategy.

But every user building a real system ends up writing the same boilerplate:

1. A `DynamicSupervisor` to manage workflow runner processes
2. A `Task.Supervisor` (or `PartitionSupervisor`) for isolated task dispatch
3. A `Registry` for looking up runners by workflow ID
4. A `GenServer` that implements the plan → prepare → dispatch → apply loop
5. Active/dispatched task tracking to prevent duplicate dispatch
6. Some form of persistence for crash recovery

This is 200+ lines of infrastructure code before any application logic. Runic should provide this as a batteries-included, dependency-free module that users can start with `Runic.Runner.start_link/1` and extend with adapters for their persistence and distribution needs.

---

## Design Principles

1. **Zero external dependencies.** The default Runner uses only OTP primitives: `DynamicSupervisor`, `Task.Supervisor`, `Registry`, `GenServer`, and `:ets`. No Postgres, no Redis, no Mnesia by default.

2. **Adapter-based extension.** Persistence and registry are defined by behaviours. Users bring their own adapter for Postgres, Oban, Khepri, RocksDB, SQLite, etc. Adapters are optional dependencies — the Runner works without them.

3. **Policy-aware.** The Runner reads `scheduler_policies` from the workflow and routes runnables through the `PolicyDriver`. Runtime policy overrides are supported per `run/3` invocation.

4. **Supervision-first.** Every workflow run is a supervised process. Task dispatch uses `Task.Supervisor` for fault isolation. The entire tree is restartable.

5. **Registry-pluggable.** Default uses Elixir's built-in `Registry`. Users can swap in `:global`, `Horde.Registry`, `pg`, `:syn`, or any module implementing a simple lookup behaviour for distributed deployments.

6. **Event-sourced recovery.** Durability is achieved by persisting `Workflow.log/1` events through the Store adapter. On restart, `Workflow.from_log/1` rebuilds state. In-flight runnables are re-prepared and re-dispatched.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                   Runic.Runner (Supervisor)              │
│                                                          │
│  ┌──────────────┐  ┌───────────────┐  ┌──────────────┐  │
│  │ DynamicSup   │  │ Task.Sup /    │  │  Registry    │  │
│  │ (Workers)    │  │ PartitionSup  │  │  (Lookup)    │  │
│  └──────┬───────┘  └───────┬───────┘  └──────────────┘  │
│         │                  │                             │
│  ┌──────▼───────┐  ┌──────▼───────┐                     │
│  │ Worker(wf-1) │──│ Task: step_a │                     │
│  │ Worker(wf-2) │  │ Task: step_b │                     │
│  │ Worker(wf-3) │  │ Task: step_c │                     │
│  └──────────────┘  └──────────────┘                     │
│                                                          │
│  ┌──────────────────────────────────────────────────┐   │
│  │           Store Adapter (optional)                │   │
│  │  ETS (default) │ Postgres │ Mnesia │ SQLite │ ... │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

---

## Module Map

| Module | Role |
|--------|------|
| `Runic.Runner` | Top-level `Supervisor`. Entry point. Starts DynamicSup, TaskSup, Registry. |
| `Runic.Runner.Worker` | `GenServer` managing a single workflow's lifecycle. |
| `Runic.Runner.Store` | `@behaviour` for persistence adapters. |
| `Runic.Runner.Store.ETS` | Default in-memory adapter using `:ets`. |
| `Runic.Runner.Registry` | Thin wrapper/behaviour for registry implementations. |
| `Runic.Runner.Executor` | `@behaviour` for custom execution strategies (optional). |

---

## Runic.Runner — The Supervisor Entry Point

```elixir
defmodule Runic.Runner do
  @moduledoc """
  Supervisor that manages workflow runner infrastructure.

  Starts a supervision tree containing:
  - A DynamicSupervisor for Worker processes
  - A Task.Supervisor (or Task.PartitionSupervisor) for isolated task execution
  - A Registry for looking up workers by workflow ID

  ## Quick Start

      # In your application supervisor
      children = [
        {Runic.Runner, name: MyApp.Runner}
      ]

      # Start a workflow
      Runic.Runner.start_workflow(MyApp.Runner, workflow, "order-123")

      # Feed input
      Runic.Runner.run(MyApp.Runner, "order-123", %{items: ["a", "b"]})

      # Get results
      Runic.Runner.get_results(MyApp.Runner, "order-123")

  ## Options

  - `:name` — Required. The name for this Runner instance. Used as a prefix for child names.
  - `:store` — Persistence adapter module. Default: `Runic.Runner.Store.ETS`
  - `:store_opts` — Options passed to the store adapter's `init/1`.
  - `:registry` — Registry module. Default: `Registry` (Elixir built-in)
  - `:registry_opts` — Options passed to registry startup.
  - `:task_supervisor` — Strategy for task supervision.
    - `:task_supervisor` (default) — Single `Task.Supervisor`
    - `{:partition, n}` — `PartitionSupervisor` with `n` partitions
  - `:max_concurrency` — Default max concurrent tasks per worker. Default: `System.schedulers_online()`
  - `:shutdown_timeout` — Grace period for workers on shutdown. Default: `60_000`
  """

  use Supervisor

  @type runner_name :: atom() | {:via, module(), term()}

  @type option ::
    {:name, runner_name()}
    | {:store, module()}
    | {:store_opts, keyword()}
    | {:registry, module()}
    | {:registry_opts, keyword()}
    | {:task_supervisor, :task_supervisor | {:partition, pos_integer()}}
    | {:max_concurrency, pos_integer()}
    | {:shutdown_timeout, pos_integer()}

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    store = Keyword.get(opts, :store, Runic.Runner.Store.ETS)
    store_opts = Keyword.get(opts, :store_opts, [])
    registry_mod = Keyword.get(opts, :registry, Registry)
    task_sup_strategy = Keyword.get(opts, :task_supervisor, :task_supervisor)

    children = [
      # Store adapter (if it's a process — ETS adapter starts an ets owner)
      {store, [{:runner_name, name} | store_opts]},

      # Registry for worker lookup
      registry_child_spec(registry_mod, name),

      # Task supervisor for isolated dispatch
      task_supervisor_child_spec(task_sup_strategy, name),

      # DynamicSupervisor for worker processes
      {DynamicSupervisor,
        name: worker_sup_name(name),
        strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  # --- Public API ---

  @doc """
  Starts a new workflow runner for the given workflow and ID.
  """
  def start_workflow(runner, %Runic.Workflow{} = workflow, workflow_id, opts \\ []) do
    DynamicSupervisor.start_child(
      worker_sup_name(runner),
      {Runic.Runner.Worker, [
        runner: runner,
        workflow: workflow,
        id: workflow_id,
        store: get_store(runner),
        task_supervisor: task_sup_name(runner),
        registry: get_registry(runner)
      ] ++ opts}
    )
  end

  @doc """
  Feeds input to a running workflow, triggering execution.
  """
  def run(runner, workflow_id, input, opts \\ []) do
    GenServer.cast(via(runner, workflow_id), {:run, input, opts})
  end

  @doc """
  Returns the current results of a workflow.
  """
  def get_results(runner, workflow_id) do
    GenServer.call(via(runner, workflow_id), :get_results)
  end

  @doc """
  Returns the current workflow state.
  """
  def get_workflow(runner, workflow_id) do
    GenServer.call(via(runner, workflow_id), :get_workflow)
  end

  @doc """
  Stops a workflow runner, optionally persisting final state.
  """
  def stop(runner, workflow_id, opts \\ []) do
    case lookup(runner, workflow_id) do
      nil -> :ok
      pid ->
        if Keyword.get(opts, :persist, true) do
          GenServer.call(pid, :persist_and_stop)
        else
          DynamicSupervisor.terminate_child(worker_sup_name(runner), pid)
        end
    end
  end

  @doc """
  Lists all active workflow IDs.
  """
  def list_workflows(runner) do
    Registry.select(registry_name(runner), [{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.map(fn {_module, id} -> id end)
  end

  @doc """
  Looks up a workflow runner PID by ID.
  """
  def lookup(runner, workflow_id) do
    GenServer.whereis(via(runner, workflow_id))
  end

  @doc """
  Resumes a workflow from persisted state.
  """
  def resume(runner, workflow_id, opts \\ []) do
    store = get_store(runner)
    case store.load(workflow_id) do
      {:ok, log} ->
        workflow = Runic.Workflow.from_log(log)
        start_workflow(runner, workflow, workflow_id, opts)

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # --- Internal ---

  defp via(runner, workflow_id) do
    {:via, Registry, {registry_name(runner), {Runic.Runner.Worker, workflow_id}}}
  end

  defp worker_sup_name(runner), do: Module.concat(runner, WorkerSupervisor)
  defp task_sup_name(runner), do: Module.concat(runner, TaskSupervisor)
  defp registry_name(runner), do: Module.concat(runner, Registry)

  defp get_store(runner) do
    # Stored in persistent_term or ets during init
    :persistent_term.get({__MODULE__, runner, :store})
  end

  defp get_registry(runner) do
    :persistent_term.get({__MODULE__, runner, :registry})
  end

  defp registry_child_spec(Registry, name) do
    {Registry, name: registry_name(name), keys: :unique}
  end

  defp registry_child_spec(custom_mod, name) do
    {custom_mod, name: registry_name(name)}
  end

  defp task_supervisor_child_spec(:task_supervisor, name) do
    {Task.Supervisor, name: task_sup_name(name)}
  end

  defp task_supervisor_child_spec({:partition, n}, name) do
    {PartitionSupervisor,
      child_spec: Task.Supervisor,
      name: task_sup_name(name),
      partitions: n}
  end
end
```

---

## Runic.Runner.Worker — The GenServer Core

### State Machine

Each Worker process manages a single workflow through its lifecycle:

```
         start_workflow/4
              │
              ▼
         ┌─────────┐
         │  :idle   │◄──────────────────────┐
         └────┬─────┘                       │
              │ run/3                        │
              ▼                             │
         ┌─────────┐   all tasks done      │
         │:running  │──────────────────────►│
         └────┬─────┘                       │
              │ dispatch tasks              │
              ▼                             │
         ┌──────────┐  task completes       │
         │:executing│──► apply + re-plan ───┘
         └──────────┘
              │ workflow error / shutdown
              ▼
         ┌─────────┐
         │ :failed  │
         └─────────┘
```

### Worker Implementation

```elixir
defmodule Runic.Runner.Worker do
  @moduledoc """
  GenServer managing a single workflow's execution lifecycle.

  Implements the plan → prepare → dispatch → apply loop with:
  - Policy-driven execution via PolicyDriver
  - Supervised task dispatch for fault isolation
  - Duplicate dispatch prevention
  - Optional persistence via Store adapter
  """
  use GenServer, restart: :transient

  alias Runic.Workflow
  alias Runic.Workflow.{Runnable, SchedulerPolicy, PolicyDriver}
  require Logger

  defstruct [
    :id,
    :runner,
    :workflow,
    :store,
    :task_supervisor,
    :registry,
    :status,
    :max_concurrency,
    active_tasks: %{},       # ref -> runnable_id
    dispatched_ids: MapSet.new(),
    on_complete: nil,        # optional callback {module, function, args}
    started_at: nil,
    last_activity_at: nil
  ]

  # --- Child Spec ---

  def child_spec(opts) do
    id = Keyword.fetch!(opts, :id)
    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      shutdown: Keyword.get(opts, :shutdown_timeout, 60_000)
    }
  end

  def start_link(opts) do
    runner = Keyword.fetch!(opts, :runner)
    id = Keyword.fetch!(opts, :id)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {
        Module.concat(runner, Registry),
        {__MODULE__, id}
      }}
    )
  end

  # --- Init ---

  @impl true
  def init(opts) do
    state = %__MODULE__{
      id: Keyword.fetch!(opts, :id),
      runner: Keyword.fetch!(opts, :runner),
      workflow: Keyword.fetch!(opts, :workflow),
      store: Keyword.get(opts, :store),
      task_supervisor: Keyword.fetch!(opts, :task_supervisor),
      registry: Keyword.get(opts, :registry),
      max_concurrency: Keyword.get(opts, :max_concurrency, System.schedulers_online()),
      on_complete: Keyword.get(opts, :on_complete),
      status: :idle,
      started_at: DateTime.utc_now()
    }

    # Persist initial state if store is configured
    maybe_persist(state)

    {:ok, state}
  end

  # --- Callbacks ---

  @impl true
  def handle_cast({:run, input, opts}, %{status: status} = state)
      when status in [:idle, :running] do
    # Allow runtime policy overrides per run invocation
    runtime_policies = Keyword.get(opts, :scheduler_policies)

    workflow =
      if runtime_policies do
        # Merge runtime overrides: prepend to workflow base
        merged = SchedulerPolicy.merge_policies(runtime_policies, state.workflow.scheduler_policies)
        %{state.workflow | scheduler_policies: merged}
        |> Workflow.plan_eagerly(input)
      else
        Workflow.plan_eagerly(state.workflow, input)
      end

    state = %{state | workflow: workflow, status: :running, last_activity_at: DateTime.utc_now()}
    state = dispatch_runnables(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_results, _from, state) do
    {:reply, Workflow.raw_productions(state.workflow), state}
  end

  @impl true
  def handle_call(:get_workflow, _from, state) do
    {:reply, state.workflow, state}
  end

  @impl true
  def handle_call(:persist_and_stop, _from, state) do
    maybe_persist(state)
    {:stop, :normal, :ok, state}
  end

  # Task completion
  @impl true
  def handle_info({ref, %Runnable{} = executed}, state) do
    Process.demonitor(ref, [:flush])

    Logger.debug("Workflow #{state.id}: completed #{inspect(executed.node.name)}")

    workflow =
      state.workflow
      |> Workflow.apply_runnable(executed)
      |> Workflow.plan_eagerly()

    state = %{
      state
      | workflow: workflow,
        active_tasks: Map.delete(state.active_tasks, ref),
        last_activity_at: DateTime.utc_now()
    }

    # Checkpoint after apply
    maybe_checkpoint(state)

    state =
      if Workflow.is_runnable?(workflow) do
        dispatch_runnables(state)
      else
        if map_size(state.active_tasks) == 0 do
          Logger.info("Workflow #{state.id}: satisfied")
          maybe_persist(state)
          maybe_notify_complete(state)
          %{state | status: :idle}
        else
          # Still waiting on other tasks
          state
        end
      end

    {:noreply, state}
  end

  # Task crash
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when reason != :normal do
    Logger.warning("Workflow #{state.id}: task crashed: #{inspect(reason)}")

    state = %{
      state
      | active_tasks: Map.delete(state.active_tasks, ref)
    }

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, :normal}, state) do
    {:noreply, state}
  end

  # --- Dispatch ---

  defp dispatch_runnables(state) do
    {workflow, runnables} = Workflow.prepare_for_dispatch(state.workflow)

    available_slots = state.max_concurrency - map_size(state.active_tasks)

    runnables
    |> Enum.reject(fn r -> r.id in state.dispatched_ids end)
    |> Enum.take(max(available_slots, 0))
    |> Enum.reduce(%{state | workflow: workflow}, fn runnable, acc ->
      policy = SchedulerPolicy.resolve(runnable, workflow.scheduler_policies)

      task = Task.Supervisor.async_nolink(acc.task_supervisor, fn ->
        PolicyDriver.execute(runnable, policy)
      end)

      %{acc |
        active_tasks: Map.put(acc.active_tasks, task.ref, runnable.id),
        dispatched_ids: MapSet.put(acc.dispatched_ids, runnable.id)
      }
    end)
  end

  # --- Persistence ---

  defp maybe_persist(%{store: nil}), do: :ok
  defp maybe_persist(%{store: store, id: id, workflow: wf}) do
    store.save(id, Workflow.log(wf))
  end

  defp maybe_checkpoint(%{store: nil}), do: :ok
  defp maybe_checkpoint(%{store: store, id: id, workflow: wf}) do
    store.checkpoint(id, Workflow.log(wf))
  end

  defp maybe_notify_complete(%{on_complete: nil}), do: :ok
  defp maybe_notify_complete(%{on_complete: {m, f, a}} = state) do
    apply(m, f, [state.id, state.workflow | a])
  end
  defp maybe_notify_complete(%{on_complete: callback}) when is_function(callback, 2) do
    callback.(callback, callback)
  end
end
```

### Dispatch Loop

The dispatch loop follows the same pattern from the scheduling guide, enhanced with:

1. **Policy resolution** — each runnable's policy is resolved from the workflow's `scheduler_policies`
2. **Concurrency limiting** — respects `max_concurrency` by tracking `active_tasks`
3. **Duplicate prevention** — `dispatched_ids` MapSet prevents re-dispatch
4. **Fault isolation** — `Task.Supervisor.async_nolink` prevents task crashes from killing the worker

### Policy Integration

The Worker reads policies from `workflow.scheduler_policies` (set via `Workflow.set_scheduler_policies/2`). Runtime overrides can be passed per `run/3` call:

```elixir
# Base policies are on the workflow
Runic.Runner.run(MyApp.Runner, "order-123", input)

# Override for this specific invocation
Runic.Runner.run(MyApp.Runner, "order-123", input,
  scheduler_policies: [
    {:check_inventory, %{timeout_ms: 30_000}}  # extra time for slow warehouse API
  ]
)
```

---

## Runic.Runner.Store — Persistence Behaviour

### Behaviour Definition

```elixir
defmodule Runic.Runner.Store do
  @moduledoc """
  Behaviour for workflow persistence adapters.

  Adapters handle saving and loading workflow event logs for
  durability across process restarts. All operations are
  synchronous from the caller's perspective.

  ## Implementing an Adapter

  Implement the required callbacks and optionally the optional ones:

      defmodule MyApp.PostgresStore do
        @behaviour Runic.Runner.Store

        @impl true
        def init(opts), do: {:ok, opts}

        @impl true
        def save(workflow_id, log, _state), do: ...

        @impl true
        def load(workflow_id, _state), do: ...

        # ... etc
      end
  """

  @type workflow_id :: String.t() | atom()
  @type log :: [struct()]
  @type state :: term()

  @doc "Initialize the store. Return {:ok, state} or {:error, reason}."
  @callback init(opts :: keyword()) :: {:ok, state()} | {:error, term()}

  @doc "Save a full workflow log (replaces previous)."
  @callback save(workflow_id(), log(), state()) :: :ok | {:error, term()}

  @doc "Load a workflow log by ID."
  @callback load(workflow_id(), state()) :: {:ok, log()} | {:error, :not_found | term()}

  @doc "Save a checkpoint (incremental — may be same as save for simple adapters)."
  @callback checkpoint(workflow_id(), log(), state()) :: :ok | {:error, term()}

  @doc "Delete a workflow's persisted state."
  @callback delete(workflow_id(), state()) :: :ok | {:error, term()}

  @doc "List all persisted workflow IDs."
  @callback list(state()) :: {:ok, [workflow_id()]} | {:error, term()}

  @doc "Check if a workflow exists in the store."
  @callback exists?(workflow_id(), state()) :: boolean()

  # Optional callbacks with defaults
  @optional_callbacks [checkpoint: 3, delete: 2, list: 1, exists?: 2]
end
```

### Built-in Adapters

#### ETS Adapter (Default)

Zero-dependency, in-memory. Survives worker restarts within the same VM but not VM restarts. Good for development, testing, and ephemeral workflows.

```elixir
defmodule Runic.Runner.Store.ETS do
  @behaviour Runic.Runner.Store

  use GenServer

  @impl Runic.Runner.Store
  def init(opts) do
    runner_name = Keyword.fetch!(opts, :runner_name)
    table = :ets.new(Module.concat(runner_name, StoreTable), [
      :named_table, :set, :public, read_concurrency: true
    ])
    {:ok, %{table: table}}
  end

  @impl Runic.Runner.Store
  def save(workflow_id, log, %{table: table}) do
    :ets.insert(table, {workflow_id, log, DateTime.utc_now()})
    :ok
  end

  @impl Runic.Runner.Store
  def load(workflow_id, %{table: table}) do
    case :ets.lookup(table, workflow_id) do
      [{^workflow_id, log, _updated_at}] -> {:ok, log}
      [] -> {:error, :not_found}
    end
  end

  @impl Runic.Runner.Store
  def checkpoint(workflow_id, log, state), do: save(workflow_id, log, state)

  @impl Runic.Runner.Store
  def delete(workflow_id, %{table: table}) do
    :ets.delete(table, workflow_id)
    :ok
  end

  @impl Runic.Runner.Store
  def list(%{table: table}) do
    ids = :ets.select(table, [{{:"$1", :_, :_}, [], [:"$1"]}])
    {:ok, ids}
  end

  @impl Runic.Runner.Store
  def exists?(workflow_id, %{table: table}) do
    :ets.member(table, workflow_id)
  end
end
```

### Adapter Interface Examples

Each adapter implements the same behaviour. Here's how the interface maps to various backends:

| Operation | ETS | Postgres | Oban | Mnesia | SQLite | Khepri | RocksDB |
|-----------|-----|----------|------|--------|--------|--------|---------|
| `save/3` | `:ets.insert` | `INSERT ON CONFLICT UPDATE` | Oban job insert | `:mnesia.write` | `INSERT OR REPLACE` | `:khepri.put` | `:rocksdb.put` |
| `load/2` | `:ets.lookup` | `SELECT` | Oban job lookup | `:mnesia.read` | `SELECT` | `:khepri.get` | `:rocksdb.get` |
| `checkpoint/3` | Same as save | Upsert with version | Update job args | `:mnesia.write` | `INSERT OR REPLACE` | `:khepri.put` | `:rocksdb.put` |
| `delete/2` | `:ets.delete` | `DELETE` | Cancel job | `:mnesia.delete` | `DELETE` | `:khepri.delete` | `:rocksdb.delete` |
| `list/1` | `:ets.select` | `SELECT id` | List jobs | `:mnesia.all_keys` | `SELECT id` | `:khepri.get_many` | Iterate prefix |

**Serialization format:** All adapters serialize the workflow log using `:erlang.term_to_binary/1` for binary stores (Postgres, SQLite, RocksDB) or store the term directly for term-native stores (ETS, Mnesia, Khepri).

---

## Registry & Distribution

### Default: Elixir Registry

The built-in `Registry` provides local process lookup by workflow ID:

```elixir
# Default — works out of the box
{Runic.Runner, name: MyApp.Runner}
# Uses Registry internally
```

### Custom Registry Adapters

Users can swap in any registry that supports `:via` tuple lookups:

```elixir
# Horde for distributed
{Runic.Runner,
  name: MyApp.Runner,
  registry: Horde.Registry,
  registry_opts: [
    name: MyApp.Runner.Registry,
    keys: :unique,
    members: :auto
  ]}
```

### Distributed Registry

For distributed deployments, the Runner accepts any module that implements the standard `{:via, Module, term()}` naming convention. Common choices:

| Registry | Use Case | Notes |
|----------|----------|-------|
| `Registry` | Single node (default) | Built into Elixir, zero config |
| `Horde.Registry` | Multi-node, eventually consistent | CRDT-based, handles netsplits |
| `:global` | Multi-node, strong consistency | Built into OTP, leader-elected |
| `Syn` | Multi-node, ETS-backed | Fast lookups, pg-based distribution |
| `:pg` | Process groups | OTP built-in, good for pub/sub patterns |

The Runner doesn't implement distributed dispatch itself — it delegates to the registry for name resolution and to the Store adapter for state distribution. This means:

- **Active-passive:** One node runs the worker, Store persists to shared storage. On failover, another node calls `Runner.resume/3`.
- **Active-active:** Use `Horde.Registry` + `Horde.DynamicSupervisor`. Workers migrate automatically. Store must handle concurrent access.

---

## Lifecycle & API

### Starting Workflows

```elixir
# Start the runner infrastructure (once, in your application supervisor)
children = [
  {Runic.Runner, name: MyApp.Runner, store: MyApp.PostgresStore}
]

# Start a workflow instance
{:ok, _pid} = Runic.Runner.start_workflow(MyApp.Runner, workflow, "order-123",
  max_concurrency: 4,
  on_complete: {MyApp.Notifier, :workflow_done, []}
)
```

### Feeding Input

```elixir
# Basic
Runic.Runner.run(MyApp.Runner, "order-123", %{items: ["a"]})

# With runtime policy override
Runic.Runner.run(MyApp.Runner, "order-123", %{items: ["a"]},
  scheduler_policies: [{:check_inventory, %{timeout_ms: 30_000}}]
)

# Feed additional inputs (workflow accumulates)
Runic.Runner.run(MyApp.Runner, "order-123", %{coupon: "SAVE10"})
```

### Querying State

```elixir
# Final outputs
Runic.Runner.get_results(MyApp.Runner, "order-123")

# Full workflow for introspection
wf = Runic.Runner.get_workflow(MyApp.Runner, "order-123")
Workflow.productions_by_component(wf)
Workflow.to_mermaid(wf)

# List all active workflows
Runic.Runner.list_workflows(MyApp.Runner)

# Check if a specific workflow is running
Runic.Runner.lookup(MyApp.Runner, "order-123")
```

### Stopping & Cleanup

```elixir
# Stop and persist final state (default)
Runic.Runner.stop(MyApp.Runner, "order-123")

# Stop without persisting
Runic.Runner.stop(MyApp.Runner, "order-123", persist: false)

# Resume from persisted state
{:ok, _pid} = Runic.Runner.resume(MyApp.Runner, "order-123")
```

---

## Durability Model

### Event Sourcing via Workflow.log/1

The durability model builds on Runic's existing event sourcing:

```
Workflow.build_log/1 → [%ComponentAdded{}, ...]     # structure
Workflow.log/1       → [%ComponentAdded{}, ...,      # structure +
                         %ReactionOccurred{}, ...]    # execution state
Workflow.from_log/1  → %Workflow{}                   # reconstruct
```

The Store adapter persists the output of `Workflow.log/1`. On recovery, `Workflow.from_log/1` rebuilds the full workflow state including all produced facts.

### Checkpoint Strategy

Checkpointing happens at natural boundaries in the execution cycle:

1. **After each apply cycle** — when a runnable result is applied and the workflow advances
2. **On workflow satisfaction** — when `is_runnable?` returns false and all tasks are done
3. **On shutdown** — graceful shutdown persists final state

The frequency of checkpointing is configurable:

```elixir
Runic.Runner.start_workflow(MyApp.Runner, workflow, "order-123",
  checkpoint_strategy: :every_cycle,   # default — checkpoint after each apply
  # or
  checkpoint_strategy: :on_complete,   # only persist when workflow satisfies
  # or
  checkpoint_strategy: {:every_n, 5},  # checkpoint every 5th apply
  # or
  checkpoint_strategy: :manual         # only persist on explicit call
)
```

### Recovery on Restart

When a Worker crashes and the DynamicSupervisor restarts it (for `:permanent` or `:transient` restarts), or when `Runner.resume/3` is called:

1. `Store.load/2` retrieves the persisted log
2. `Workflow.from_log/1` rebuilds the workflow state
3. The Worker inspects the rebuilt workflow for pending runnables
4. Any runnables that were in-flight (dispatched but not applied) are re-prepared and re-dispatched

### In-Flight Runnable Recovery

When the scheduler policy system adds `RunnableDispatched`/`RunnableCompleted` events to the log (Phase 2 of the policies proposal), the recovery process becomes:

```elixir
# On resume, identify work that was dispatched but never completed
log = Store.load(workflow_id)
workflow = Workflow.from_log(log)

dispatched = Enum.filter(log, &match?(%RunnableDispatched{}, &1))
completed = Enum.filter(log, &match?(%RunnableCompleted{}, &1))
completed_ids = MapSet.new(completed, & &1.runnable_id)

in_flight = Enum.reject(dispatched, fn d -> d.runnable_id in completed_ids end)

# Re-prepare and re-dispatch in-flight runnables
for ref <- in_flight do
  runnable = RunnableRef.to_runnable(ref, workflow)
  # dispatch...
end
```

---

## Interaction with Scheduler Policies

The Runner is the primary consumer of scheduler policies. Here's how they flow:

```
┌────────────────────┐     ┌──────────────────┐     ┌────────────────────┐
│  Workflow Struct    │────►│  Runner.Worker    │────►│  PolicyDriver      │
│  .scheduler_policies│     │  dispatch_runnables│     │  execute(r, policy)│
└────────────────────┘     └──────────────────┘     └────────────────────┘
         ▲                          ▲
         │                          │
    Base config              Runtime override
    (set once)               (per run/3 call)
```

1. **Workflow carries base policies** — set via `Workflow.set_scheduler_policies/2`
2. **Worker reads workflow policies** — during `dispatch_runnables/1`
3. **Runtime overrides are prepended** — via `run/3` opts, merged with `SchedulerPolicy.merge_policies/2`
4. **PolicyDriver executes** — handles retry, timeout, backoff, fallback per resolved policy
5. **Worker applies result** — `Workflow.apply_runnable/2` regardless of policy outcome

The `execution_mode` policy option has special meaning for the Runner:

| Mode | Runner Behavior |
|------|----------------|
| `:sync` | Execute inline in the Worker process (no task dispatch) |
| `:async` | Dispatch to `Task.Supervisor` (default Runner behavior) |
| `:durable` | Dispatch + persist `RunnableDispatched` event before execution |
| `:external` | Prepare runnable, persist ref, wait for external completion signal |

---

## Telemetry & Observability

The Runner emits `:telemetry` events at key lifecycle points:

```elixir
# Workflow lifecycle
[:runic, :runner, :workflow, :start]    # metadata: %{id, workflow_name}
[:runic, :runner, :workflow, :complete] # metadata: %{id, duration_ms}
[:runic, :runner, :workflow, :failed]   # metadata: %{id, reason}

# Runnable lifecycle
[:runic, :runner, :runnable, :dispatch]  # metadata: %{id, node_name, policy}
[:runic, :runner, :runnable, :complete]  # metadata: %{id, node_name, duration_ms, attempt}
[:runic, :runner, :runnable, :retry]     # metadata: %{id, node_name, attempt, delay_ms}
[:runic, :runner, :runnable, :timeout]   # metadata: %{id, node_name, timeout_ms}
[:runic, :runner, :runnable, :fallback]  # metadata: %{id, node_name, error}
[:runic, :runner, :runnable, :failed]    # metadata: %{id, node_name, error, attempts}

# Persistence lifecycle
[:runic, :runner, :store, :save]         # measurements: %{duration_ms}
[:runic, :runner, :store, :load]         # measurements: %{duration_ms, log_size}
[:runic, :runner, :store, :checkpoint]   # measurements: %{duration_ms}
```

---

## Extension Points

### Custom Worker Behaviour

For advanced use cases, users can implement their own Worker that uses the Runner's infrastructure:

```elixir
# Use the Runner with a custom worker module
Runic.Runner.start_workflow(MyApp.Runner, workflow, "order-123",
  worker: MyApp.CustomWorker
)
```

The custom worker must implement the `Runic.Runner.Worker` behaviour (or simply be a GenServer that handles the same message protocol).

### Executor Behaviour

For users who want to customize _how_ runnables are executed beyond what policies provide:

```elixir
defmodule Runic.Runner.Executor do
  @moduledoc """
  Behaviour for custom execution strategies.

  The default executor dispatches to Task.Supervisor with PolicyDriver.
  Custom executors can route to Oban jobs, external services, etc.
  """

  @callback execute(
    runnable :: Runnable.t(),
    policy :: SchedulerPolicy.t(),
    opts :: keyword()
  ) :: {:ok, Runnable.t()} | {:async, reference()} | {:error, term()}
end
```

```elixir
# Route certain steps to Oban instead of Task.Supervisor
defmodule MyApp.ObanExecutor do
  @behaviour Runic.Runner.Executor

  def execute(runnable, _policy, _opts) do
    ref = RunnableRef.from_runnable(runnable)
    %{runnable_ref: :erlang.term_to_binary(ref)}
    |> MyApp.Workers.RunStep.new()
    |> Oban.insert()
    {:async, ref.runnable_id}
  end
end
```

---

## Adapter Sketches

### Mnesia Adapter

Uses Mnesia for durable, distributed storage without external dependencies. Tables are created on init.

```elixir
defmodule Runic.Runner.Store.Mnesia do
  @behaviour Runic.Runner.Store

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :table, :runic_workflow_logs)
    nodes = Keyword.get(opts, :nodes, [node()])

    :mnesia.create_table(table, [
      attributes: [:workflow_id, :log, :updated_at],
      disc_copies: nodes,
      type: :set
    ])

    :mnesia.wait_for_tables([table], 5_000)
    {:ok, %{table: table}}
  end

  @impl true
  def save(workflow_id, log, %{table: table}) do
    :mnesia.transaction(fn ->
      :mnesia.write({table, workflow_id, log, DateTime.utc_now()})
    end)
    |> case do
      {:atomic, :ok} -> :ok
      {:aborted, reason} -> {:error, reason}
    end
  end

  @impl true
  def load(workflow_id, %{table: table}) do
    :mnesia.transaction(fn ->
      :mnesia.read(table, workflow_id)
    end)
    |> case do
      {:atomic, [{^table, ^workflow_id, log, _}]} -> {:ok, log}
      {:atomic, []} -> {:error, :not_found}
      {:aborted, reason} -> {:error, reason}
    end
  end
end
```

### Postgres Adapter

Uses Ecto for Postgres persistence. Requires the user to add `:ecto` and `:postgrex` as dependencies and run a migration.

```elixir
defmodule Runic.Runner.Store.Postgres do
  @behaviour Runic.Runner.Store

  @impl true
  def init(opts) do
    repo = Keyword.fetch!(opts, :repo)
    table = Keyword.get(opts, :table, "runic_workflow_logs")
    {:ok, %{repo: repo, table: table}}
  end

  @impl true
  def save(workflow_id, log, %{repo: repo, table: table}) do
    binary = :erlang.term_to_binary(log)

    repo.query!("""
      INSERT INTO #{table} (workflow_id, log, updated_at)
      VALUES ($1, $2, $3)
      ON CONFLICT (workflow_id) DO UPDATE SET log = $2, updated_at = $3
    """, [workflow_id, binary, DateTime.utc_now()])

    :ok
  end

  @impl true
  def load(workflow_id, %{repo: repo, table: table}) do
    case repo.query("SELECT log FROM #{table} WHERE workflow_id = $1", [workflow_id]) do
      {:ok, %{rows: [[binary]]}} -> {:ok, :erlang.binary_to_term(binary)}
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # Migration helper
  def migration(table \\ "runic_workflow_logs") do
    """
    CREATE TABLE IF NOT EXISTS #{table} (
      workflow_id TEXT PRIMARY KEY,
      log BYTEA NOT NULL,
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
    CREATE INDEX IF NOT EXISTS idx_#{table}_updated_at ON #{table} (updated_at);
    """
  end
end
```

### SQLite Adapter

Uses `Exqlite` for local, file-based persistence. Good for embedded systems, CLI tools, and single-node deployments.

```elixir
defmodule Runic.Runner.Store.SQLite do
  @behaviour Runic.Runner.Store

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, "runic_workflows.db")
    {:ok, conn} = Exqlite.Sqlite3.open(path)

    Exqlite.Sqlite3.execute(conn, """
      CREATE TABLE IF NOT EXISTS workflow_logs (
        workflow_id TEXT PRIMARY KEY,
        log BLOB NOT NULL,
        updated_at TEXT NOT NULL
      )
    """)

    {:ok, %{conn: conn}}
  end

  @impl true
  def save(workflow_id, log, %{conn: conn}) do
    binary = :erlang.term_to_binary(log)
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn,
      "INSERT OR REPLACE INTO workflow_logs VALUES (?1, ?2, ?3)")
    Exqlite.Sqlite3.bind(conn, stmt, [workflow_id, binary, DateTime.to_iso8601(DateTime.utc_now())])
    Exqlite.Sqlite3.step(conn, stmt)
    :ok
  end

  @impl true
  def load(workflow_id, %{conn: conn}) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn,
      "SELECT log FROM workflow_logs WHERE workflow_id = ?1")
    Exqlite.Sqlite3.bind(conn, stmt, [workflow_id])

    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, [binary]} -> {:ok, :erlang.binary_to_term(binary)}
      :done -> {:error, :not_found}
    end
  end
end
```

### Oban Adapter

Uses Oban for job-queue-based durable execution. Each workflow checkpoint is an Oban job. Recovery uses Oban's built-in retry and persistence.

```elixir
defmodule Runic.Runner.Store.Oban do
  @behaviour Runic.Runner.Store

  @impl true
  def init(opts) do
    queue = Keyword.get(opts, :queue, :runic_workflows)
    {:ok, %{queue: queue}}
  end

  @impl true
  def save(workflow_id, log, %{queue: queue}) do
    # Store as Oban job args — Oban handles Postgres persistence
    binary = Base.encode64(:erlang.term_to_binary(log))

    %{workflow_id: workflow_id, log: binary, action: :checkpoint}
    |> Runic.Runner.ObanWorker.new(queue: queue, unique: [keys: [:workflow_id]])
    |> Oban.insert()

    :ok
  end

  @impl true
  def load(workflow_id, _state) do
    # Query Oban jobs table for the latest checkpoint
    import Ecto.Query

    case Oban.Repo.one(
      from j in Oban.Job,
      where: fragment("?->>'workflow_id' = ?", j.args, ^workflow_id),
      where: j.state in ["available", "completed"],
      order_by: [desc: j.inserted_at],
      limit: 1
    ) do
      %{args: %{"log" => binary}} ->
        {:ok, :erlang.binary_to_term(Base.decode64!(binary))}
      nil ->
        {:error, :not_found}
    end
  end
end
```

### Khepri Adapter

Uses Khepri (Raft-based replicated store) for strongly consistent distributed storage without external databases.

```elixir
defmodule Runic.Runner.Store.Khepri do
  @behaviour Runic.Runner.Store

  @impl true
  def init(opts) do
    store = Keyword.get(opts, :store, :runic_store)
    {:ok, %{store: store, base_path: [:runic, :workflows]}}
  end

  @impl true
  def save(workflow_id, log, %{store: store, base_path: base}) do
    :khepri.put(store, base ++ [workflow_id], %{log: log, updated_at: DateTime.utc_now()})
    :ok
  end

  @impl true
  def load(workflow_id, %{store: store, base_path: base}) do
    case :khepri.get(store, base ++ [workflow_id]) do
      {:ok, %{log: log}} -> {:ok, log}
      {:ok, :undefined} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

### RocksDB Adapter

Uses `RocksDB` for high-performance local storage with LSM-tree efficiency.

```elixir
defmodule Runic.Runner.Store.RocksDB do
  @behaviour Runic.Runner.Store

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, "./runic_rocksdb")
    {:ok, db} = :rocksdb.open(String.to_charlist(path), [create_if_missing: true])
    {:ok, %{db: db}}
  end

  @impl true
  def save(workflow_id, log, %{db: db}) do
    key = "workflow:#{workflow_id}"
    value = :erlang.term_to_binary(log)
    :rocksdb.put(db, key, value, [])
    :ok
  end

  @impl true
  def load(workflow_id, %{db: db}) do
    key = "workflow:#{workflow_id}"
    case :rocksdb.get(db, key, []) do
      {:ok, binary} -> {:ok, :erlang.binary_to_term(binary)}
      :not_found -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

---

## Full API Examples

### Minimal: In-Memory Runner

```elixir
# application.ex
children = [
  {Runic.Runner, name: MyApp.Runner}
]

# Usage
require Runic
alias Runic.Workflow

workflow =
  Runic.workflow(steps: [
    {Runic.step(fn x -> x + 1 end, name: :add), [
      Runic.step(fn x -> x * 2 end, name: :double)
    ]}
  ])

{:ok, _pid} = Runic.Runner.start_workflow(MyApp.Runner, workflow, "calc-1")
Runic.Runner.run(MyApp.Runner, "calc-1", 5)

# After workflow satisfies...
Runic.Runner.get_results(MyApp.Runner, "calc-1")
# => [12]
```

### Production: Durable with Postgres

```elixir
# application.ex
children = [
  MyApp.Repo,
  {Runic.Runner,
    name: MyApp.Runner,
    store: Runic.Runner.Store.Postgres,
    store_opts: [repo: MyApp.Repo],
    task_supervisor: {:partition, System.schedulers_online()}}
]

# Build workflow with policies
workflow =
  build_order_workflow()
  |> Workflow.set_scheduler_policies([
    {{:name, ~r/^api_/}, %{max_retries: 3, backoff: :exponential, timeout_ms: 10_000}},
    {{:type, Condition}, %{timeout_ms: :infinity}},
    {:default, %{max_retries: 1, timeout_ms: 5_000}}
  ])

# Start
{:ok, _} = Runic.Runner.start_workflow(MyApp.Runner, workflow, order_id,
  on_complete: {MyApp.Orders, :fulfill, []}
)

# Process
Runic.Runner.run(MyApp.Runner, order_id, order_params)

# On crash/restart — resume from Postgres
Runic.Runner.resume(MyApp.Runner, order_id)
```

### Distributed: Horde Registry + Mnesia Store

```elixir
# application.ex
children = [
  {Horde.Registry, name: MyApp.Runner.Registry, keys: :unique, members: :auto},
  {Horde.DynamicSupervisor, name: MyApp.Runner.WorkerSupervisor, strategy: :one_for_one},
  {Runic.Runner,
    name: MyApp.Runner,
    store: Runic.Runner.Store.Mnesia,
    store_opts: [nodes: Node.list([:this, :visible])],
    registry: Horde.Registry}
]

# Workflows automatically rebalance across nodes
{:ok, _} = Runic.Runner.start_workflow(MyApp.Runner, workflow, "distributed-1")
```

---

## Implementation Phases

### Phase 1: Core Runner (Dependency-Free)

**Modules:**
- `Runic.Runner` — Supervisor, public API
- `Runic.Runner.Worker` — GenServer, dispatch loop
- `Runic.Runner.Store` — Behaviour definition
- `Runic.Runner.Store.ETS` — Default in-memory adapter

**Capabilities:**
- Start/stop/list workflows
- Async dispatch with Task.Supervisor
- Duplicate dispatch prevention
- `max_concurrency` limiting
- PolicyDriver integration (reads `workflow.scheduler_policies`)
- Runtime policy overrides per `run/3` call
- ETS-based persistence (survives worker restarts within VM)
- `resume/3` from ETS store
- Basic telemetry events

**No external dependencies added.**

### Phase 2: Persistence Adapters

- `Runic.Runner.Store.Mnesia` — distributed, OTP-native, no external deps
- Postgres adapter sketch (user provides Ecto repo)
- SQLite adapter sketch (user provides Exqlite)
- Documentation for writing custom adapters

### Phase 3: Distribution & Registry

- Registry behaviour definition
- Horde integration guide
- `:global` integration guide
- Active-passive failover documentation

### Phase 4: Advanced Features

- `Runic.Runner.Executor` behaviour for custom dispatch targets
- Oban adapter sketch
- Khepri adapter sketch
- RocksDB adapter sketch
- Checkpoint strategies (`:every_cycle`, `:on_complete`, `{:every_n, n}`, `:manual`)
- In-flight runnable recovery using `RunnableDispatched`/`RunnableCompleted` events
- `execution_mode: :external` support (wait for external completion signal)
