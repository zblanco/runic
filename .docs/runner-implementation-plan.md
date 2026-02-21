# Runic Runner — Implementation Plan

**Status:** Active  
**Depends on:** [Runner Proposal](runner-proposal.md), [Scheduler Policies (completed)](scheduler-policies-implementation-plan.md)  
**Related:** [Scheduling Guide](../guides/scheduling.md)  

---

## Overview

This plan implements the built-in workflow execution infrastructure described in the [Runner Proposal](runner-proposal.md). The Runner is the primary consumer of the scheduler policies system completed in the [prior implementation](scheduler-policies-implementation-plan.md).

The work is organized into five implementation phases with explicit concurrency opportunities. Phases 1A, 1B, and 1C are designed for concurrent execution — they share no files and produce independent modules that integrate in Phase 2.

**Guiding constraints:**
- Zero external dependencies beyond `:telemetry` (standard OTP ecosystem library)
- All existing APIs and tests continue to pass — backward compatibility is non-negotiable
- The Runner is optional — workflows work without it, as they do today
- The Runner uses the same three-phase model (prepare → execute → apply) as the rest of Runic
- The `Runnable` struct, `Invokable` protocol, and `Workflow` struct are not modified (except adding telemetry as a dependency in `mix.exs`)

---

## Dependency Graph

```
Phase 1A: Store Behaviour + ETS Adapter ──────┐
  (behaviour, default adapter, no processes)   │
                                               │
Phase 1B: Runner Supervisor ──────────────────┼──► Phase 2: Worker GenServer ──► Phase 3 ──► Phase 4
  (Supervisor, child specs, public API shell)  │     (dispatch loop, policy     (telemetry,  (advanced
                                               │      integration, persistence  observability) checkpoint
Phase 1C: Telemetry Foundation ───────────────┘      task tracking, recovery)                 strategies)
  (add :telemetry dep, event definitions)                    │
                                                             ▼
                                                        Phase 5
                                                       (Mnesia adapter sketch,
                                                        adapter docs)
```

**Phase 1A, 1B, and 1C** have no file overlap and can run concurrently.

**Phase 2** requires all three Phase 1 outputs — it wires them together in the Worker GenServer.

**Phase 3** requires Phase 2 — telemetry emission is wired into the Worker's lifecycle.

**Phase 4** requires Phase 2 — advanced checkpoint strategies build on the basic persistence loop.

**Phase 5** requires Phase 1A — adapter sketches implement the Store behaviour.

---

## Phase 1A: Store Behaviour + ETS Adapter

**Goal:** Define the persistence abstraction and build the default zero-dependency ETS adapter. Pure data contracts — no integration with Runner or Worker yet.

**Can run concurrently with:** Phase 1B, Phase 1C

### Files to Create

#### `lib/runic/runner/store.ex` — `Runic.Runner.Store`

The behaviour defining the persistence contract for workflow log storage.

```elixir
defmodule Runic.Runner.Store do
  @moduledoc """
  Behaviour for workflow persistence adapters.

  Adapters handle saving and loading workflow event logs for
  durability across process restarts.
  """

  @type workflow_id :: term()
  @type log :: [struct()]
  @type state :: term()

  @callback init(opts :: keyword()) :: {:ok, state()} | {:error, term()}
  @callback save(workflow_id(), log(), state()) :: :ok | {:error, term()}
  @callback load(workflow_id(), state()) :: {:ok, log()} | {:error, :not_found | term()}
  @callback checkpoint(workflow_id(), log(), state()) :: :ok | {:error, term()}
  @callback delete(workflow_id(), state()) :: :ok | {:error, term()}
  @callback list(state()) :: {:ok, [workflow_id()]} | {:error, term()}
  @callback exists?(workflow_id(), state()) :: boolean()

  @optional_callbacks [checkpoint: 3, delete: 2, list: 1, exists?: 2]
end
```

Key design choices:
- `workflow_id` is `term()` — strings, atoms, tuples all work. Users choose their ID scheme.
- `state` is opaque adapter state returned from `init/1`. The Runner holds it and passes it through.
- `checkpoint/3` is optional — simple adapters can omit it and the Worker falls back to `save/3`.
- `log` is `[struct()]` — the output of `Workflow.log/1`. Serialization is the adapter's responsibility.

#### `lib/runic/runner/store/ets.ex` — `Runic.Runner.Store.ETS`

Default in-memory adapter. Uses a GenServer to own the ETS table (table lifetime tied to process, not caller).

```elixir
defmodule Runic.Runner.Store.ETS do
  @moduledoc """
  Default in-memory persistence adapter using ETS.

  Survives worker restarts within the same VM but not VM restarts.
  """
  @behaviour Runic.Runner.Store
  use GenServer

  # --- Store Behaviour ---

  @impl Runic.Runner.Store
  def init(opts) do
    runner_name = Keyword.fetch!(opts, :runner_name)
    table_name = Module.concat(runner_name, StoreTable)
    # Table is created in GenServer init, we just return the config
    {:ok, %{table: table_name, runner_name: runner_name}}
  end

  @impl Runic.Runner.Store
  def save(workflow_id, log, %{table: table}) do
    :ets.insert(table, {workflow_id, log, System.monotonic_time(:millisecond)})
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

  # --- GenServer (ETS table owner) ---

  def start_link(opts) do
    runner_name = Keyword.fetch!(opts, :runner_name)
    GenServer.start_link(__MODULE__, opts, name: Module.concat(runner_name, Store))
  end

  def child_spec(opts) do
    runner_name = Keyword.fetch!(opts, :runner_name)
    %{
      id: {__MODULE__, runner_name},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @impl GenServer
  def init(opts) do
    runner_name = Keyword.fetch!(opts, :runner_name)
    table_name = Module.concat(runner_name, StoreTable)
    table = :ets.new(table_name, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table, runner_name: runner_name}}
  end
end
```

Design notes:
- The ETS adapter is a GenServer that owns the ETS table. It also implements the `Store` behaviour callbacks as regular functions that operate on the table directly (`:public` access). This dual nature means:
  - The GenServer is started as a child of the Runner supervisor (table lifetime = supervisor lifetime)
  - The Store callbacks are called directly by the Worker (no GenServer.call overhead — direct ETS reads/writes)
- Uses `System.monotonic_time/1` for `updated_at` rather than `DateTime.utc_now/0` to avoid clock skew in timing comparisons

### Files to Create (Tests)

#### `test/runner/store_ets_test.exs` — `Runic.Runner.Store.ETSTest`

**Test categories:**

**A. Lifecycle:**
- `start_link/1` creates a named ETS table
- Table survives caller process exit (owned by GenServer)
- Stopping the GenServer cleans up the table

**B. CRUD operations:**
- `save/3` + `load/2` round-trips a workflow log
- `load/2` returns `{:error, :not_found}` for unknown ID
- `save/3` overwrites existing entry (upsert semantics)
- `delete/2` removes entry, subsequent `load/2` returns not_found
- `checkpoint/3` behaves same as `save/3`

**C. Listing:**
- `list/1` returns empty list when no workflows stored
- `list/1` returns all stored workflow IDs
- `exists?/2` returns true/false correctly

**D. Serialization round-trip:**
- Save a real `Workflow.log/1` output, load it, `Workflow.from_log/1` reconstructs the workflow
- Round-trip includes `RunnableDispatched`, `RunnableCompleted`, `RunnableFailed` events

**E. Concurrent access:**
- Multiple processes writing different workflow IDs concurrently don't interfere
- Read-after-write from a different process sees the write (`:public` table)

### Invariants

- `save/3` then `load/2` always returns `{:ok, log}` with identical data
- `delete/2` then `load/2` always returns `{:error, :not_found}`
- `list/1` always reflects the current set of stored IDs
- ETS table is `:public` and `:set` — no duplicate keys, concurrent reads safe

---

## Phase 1B: Runner Supervisor + Public API Shell

**Goal:** Build the `Runic.Runner` supervision tree and the public API functions. The API functions will be stubs that route to the Worker (built in Phase 2), but the supervision tree itself is fully functional.

**Can run concurrently with:** Phase 1A, Phase 1C

### Files to Create

#### `lib/runic/runner.ex` — `Runic.Runner`

Top-level Supervisor. Starts the supervision tree and exposes the public API.

Implementation per the proposal ([§ Runic.Runner — The Supervisor Entry Point](runner-proposal.md#runicrunner--the-supervisor-entry-point)):

1. **`start_link/1`** — Accepts `opts` with required `:name`. Starts the Supervisor.

2. **`init/1`** — Builds the supervision tree:
   - Store adapter GenServer (ETS by default)
   - Registry for worker lookup (Elixir `Registry` by default, `:unique` keys)
   - Task.Supervisor (or PartitionSupervisor) for isolated task dispatch
   - DynamicSupervisor for Worker processes
   - Strategy: `:rest_for_one` — if the store or registry dies, restart everything downstream

   **Important:** Store the `store` module and its initialized state in `:persistent_term` keyed by `{Runic.Runner, runner_name, :store}` so Workers can retrieve it without message passing. Store the store's initialized state similarly.

3. **`start_workflow/4`** — Starts a Worker under the DynamicSupervisor.

4. **`run/4`** — Casts `{:run, input, opts}` to the Worker via the registry.

5. **`get_results/2`** — Calls `:get_results` on the Worker.

6. **`get_workflow/2`** — Calls `:get_workflow` on the Worker.

7. **`stop/3`** — Stops a Worker, optionally persisting final state.

8. **`list_workflows/1`** — Queries the Registry for all registered workers.

9. **`lookup/2`** — Resolves a worker PID via the registry.

10. **`resume/3`** — Loads log from store, rebuilds workflow via `Workflow.from_log/1`, starts a new Worker.

**Naming convention:** For a runner named `MyApp.Runner`:
- `MyApp.Runner.WorkerSupervisor` — DynamicSupervisor
- `MyApp.Runner.TaskSupervisor` — Task.Supervisor
- `MyApp.Runner.Registry` — Registry
- `MyApp.Runner.Store` — Store GenServer (ETS)
- `MyApp.Runner.StoreTable` — ETS table name

**Supervision strategy consideration:** Use `:rest_for_one` so that if the Store or Registry crashes, downstream Workers are restarted. Workers depend on the Store and Registry being available. The ordering in the children list:
1. Store adapter (ETS GenServer)
2. Registry
3. Task.Supervisor
4. DynamicSupervisor (Workers)

The `run/4` and `get_results/2` API functions should handle the case where the Worker is not found (registry lookup returns `nil`) and return `{:error, :not_found}` rather than crashing.

#### Persistent Term for Store State

During `init/1`, after starting the Store adapter, the Runner stores the store module and its `init/1` return state in `:persistent_term`:

```elixir
:persistent_term.put({Runic.Runner, name, :store}, {store_module, store_state})
```

Workers retrieve this with:

```elixir
{store_mod, store_state} = :persistent_term.get({Runic.Runner, runner_name, :store})
```

This avoids passing store state through messages and enables direct ETS access from Workers. The `:persistent_term` entry is cleaned up in `terminate/2`.

**Alternative considered:** Storing in the Supervisor's state — rejected because Supervisor state is not accessible to children. ETS lookup would work but `:persistent_term` is faster for read-heavy access patterns (workers read on every checkpoint).

### Files to Create (Tests)

#### `test/runner/runner_test.exs` — `Runic.Runner.RunnerTest`

**Test categories:**

**A. Supervision tree startup:**
- `start_link/1` with `:name` starts successfully
- All four children are alive (store, registry, task_supervisor, dynamic_supervisor)
- `start_link/1` without `:name` raises
- Named table for ETS store exists after startup

**B. Naming:**
- Child names follow the convention (`MyApp.Runner.WorkerSupervisor`, etc.)
- Multiple Runner instances with different names don't conflict

**C. API routing (Phase 2 integration — marked `@tag :phase2`):**
- `start_workflow/4` starts a child under the DynamicSupervisor
- `lookup/2` finds the started worker
- `list_workflows/1` returns the workflow ID
- `stop/3` terminates the worker
- `resume/3` loads from store and starts a new worker

**D. Custom options:**
- `task_supervisor: {:partition, 4}` starts a PartitionSupervisor
- Custom `store` and `store_opts` are passed through

---

## Phase 1C: Telemetry Foundation

**Goal:** Add `:telemetry` as a dependency and define the telemetry event module with span helpers. No emission yet — that happens in Phase 3 when the Worker is wired up.

**Can run concurrently with:** Phase 1A, Phase 1B

### Files to Modify

#### `mix.exs`

Add `:telemetry` to deps:

```elixir
{:telemetry, "~> 1.0"}
```

Also add `:telemetry` to `extra_applications` — though `:telemetry` is an OTP app it starts automatically. No change needed to `application/0` since `:telemetry` starts itself.

#### `lib/runic/runner/telemetry.ex` — `Runic.Runner.Telemetry`

A thin module that defines event names and provides helper functions for emitting telemetry events. This centralizes all event name atoms and metadata shapes.

```elixir
defmodule Runic.Runner.Telemetry do
  @moduledoc """
  Telemetry event definitions for Runic.Runner.

  All events are emitted under the `[:runic, :runner, ...]` prefix.
  """

  # Event name constants
  @workflow_start [:runic, :runner, :workflow, :start]
  @workflow_stop [:runic, :runner, :workflow, :stop]
  @workflow_exception [:runic, :runner, :workflow, :exception]

  @runnable_start [:runic, :runner, :runnable, :start]
  @runnable_stop [:runic, :runner, :runnable, :stop]
  @runnable_exception [:runic, :runner, :runnable, :exception]

  @store_start [:runic, :runner, :store, :start]
  @store_stop [:runic, :runner, :store, :stop]
  @store_exception [:runic, :runner, :store, :exception]

  def workflow_span(metadata, fun) do
    :telemetry.span(@workflow_start |> Enum.take(3), metadata, fn ->
      result = fun.()
      {result, metadata}
    end)
  end

  def runnable_event(:dispatch, metadata) do
    :telemetry.execute(@runnable_start, %{system_time: System.system_time()}, metadata)
  end

  def runnable_event(:complete, metadata) do
    :telemetry.execute(@runnable_stop, %{duration: metadata[:duration_ms]}, metadata)
  end

  def runnable_event(:exception, metadata) do
    :telemetry.execute(@runnable_exception, %{}, metadata)
  end

  def store_span(operation, metadata, fun) do
    :telemetry.span(
      [:runic, :runner, :store],
      Map.put(metadata, :operation, operation),
      fn ->
        result = fun.()
        {result, metadata}
      end
    )
  end

  @doc "Returns all event names for `:telemetry.list_handlers/1`."
  def event_names do
    [
      @workflow_start, @workflow_stop, @workflow_exception,
      @runnable_start, @runnable_stop, @runnable_exception,
      @store_start, @store_stop, @store_exception
    ]
  end
end
```

### Files to Create (Tests)

#### `test/runner/telemetry_test.exs` — `Runic.Runner.TelemetryTest`

- `event_names/0` returns a list of 9 event name lists
- Each event name is a list of atoms starting with `:runic`
- `store_span/3` emits `:start` and `:stop` events (attach handler, verify)
- `runnable_event/2` emits the expected event (attach handler, verify metadata keys)

---

## Phase 2: Worker GenServer — The Core

**Goal:** Build the Worker GenServer that manages a single workflow's execution lifecycle. This is the heart of the Runner — the dispatch loop, policy integration, task tracking, persistence, and recovery.

**Depends on:** Phase 1A (Store), Phase 1B (Runner supervisor), Phase 1C (Telemetry)

### Files to Create

#### `lib/runic/runner/worker.ex` — `Runic.Runner.Worker`

The GenServer per the proposal ([§ Runic.Runner.Worker — The GenServer Core](runner-proposal.md#runicrunnerworker--the-genserver-core)).

**State struct:**

```elixir
defstruct [
  :id,                    # workflow_id (user-provided)
  :runner,                # runner name (for child name resolution)
  :workflow,              # %Workflow{} — the live workflow state
  :store,                 # {store_module, store_state} | nil
  :task_supervisor,       # Task.Supervisor name
  :max_concurrency,       # max parallel tasks
  :on_complete,           # callback: {m, f, a} | fn/2 | nil
  :checkpoint_strategy,   # :every_cycle | :on_complete | {:every_n, n} | :manual
  status: :idle,          # :idle | :running | :stopping
  active_tasks: %{},      # task_ref -> runnable_id
  dispatched_ids: MapSet.new(),  # set of runnable IDs dispatched in current run
  cycle_count: 0,         # for {:every_n, n} checkpoint strategy
  started_at: nil
]
```

**Key differences from proposal sketch:**

1. **`:store` is `{module, state}` tuple** — retrieved from `:persistent_term` during init, not a module alone. This avoids a second lookup per checkpoint.

2. **`dispatched_ids` is reset per `run/3`** — a new run invocation clears the dispatched set. Within a single `run`, duplicate dispatch is prevented. Across runs, the same step may need to re-run with new input.

3. **`checkpoint_strategy` field** — controls when `maybe_checkpoint/1` actually persists. Default `:every_cycle`.

4. **No `:failed` status** — a failed runnable doesn't fail the Worker. The Worker stays `:running` or transitions to `:idle`. Individual failures are handled by `Workflow.apply_runnable/2` which logs a warning and marks the runnable as ran. The Worker only stops on explicit `stop/3` or supervisor shutdown.

**GenServer callbacks:**

1. **`init/1`:**
   - Build state struct from opts
   - Retrieve `{store_mod, store_state}` from `:persistent_term`
   - Persist initial workflow state if store is configured
   - Return `{:ok, state}`

2. **`handle_cast({:run, input, opts})`:**
   - Guard: only when `status in [:idle, :running]`
   - Merge runtime scheduler_policies if provided in opts
   - Call `Workflow.plan_eagerly(workflow, input)` 
   - Transition to `:running`
   - Call `dispatch_runnables/1`

3. **`handle_call(:get_results, ...)`:**
   - Return `Workflow.raw_productions(workflow)`

4. **`handle_call(:get_workflow, ...)`:**
   - Return the workflow struct

5. **`handle_call(:persist_and_stop, ...)`:**
   - Persist current state
   - Return `:ok` and `{:stop, :normal, ...}`

6. **`handle_info({ref, %Runnable{} = executed})`:**
   - Demonitor the task ref
   - Apply the runnable: `Workflow.apply_runnable(workflow, executed)`
   - Re-plan: `Workflow.plan_eagerly(workflow)` (plan without input — check for downstream runnables)
   - Remove from `active_tasks`
   - Checkpoint if strategy permits
   - If `is_runnable?`: dispatch more runnables
   - Else if `active_tasks` is empty: workflow satisfied → persist, notify, transition to `:idle`

7. **`handle_info({:DOWN, ref, :process, _pid, reason})`:**
   - Task crashed (reason != :normal)
   - Remove from `active_tasks`
   - Log warning
   - If no active tasks and not runnable → transition to `:idle`

**`dispatch_runnables/1` (private):**

```
1. Call Workflow.prepare_for_dispatch(workflow)
2. Filter out runnables whose IDs are in dispatched_ids
3. Take up to (max_concurrency - active_task_count) runnables
4. For each runnable:
   a. Resolve policy: SchedulerPolicy.resolve(runnable, workflow.scheduler_policies)
   b. Dispatch via Task.Supervisor.async_nolink:
      fn -> PolicyDriver.execute(runnable, policy) end
   c. Track: add task.ref -> runnable_id to active_tasks
   d. Track: add runnable_id to dispatched_ids
5. Update state with new workflow, active_tasks, dispatched_ids
```

**`maybe_checkpoint/1` (private):**

```elixir
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
  log = Workflow.log(wf)
  # Use checkpoint/3 if implemented, fall back to save/3
  if function_exported?(store_mod, :checkpoint, 3) do
    store_mod.checkpoint(id, log, store_state)
  else
    store_mod.save(id, log, store_state)
  end
  state
end
```

**`maybe_persist/1` (private):**

Called on workflow satisfaction and explicit stop. Always persists regardless of checkpoint strategy.

```elixir
defp maybe_persist(%{store: nil} = state), do: state

defp maybe_persist(%{store: {store_mod, store_state}, id: id, workflow: wf} = state) do
  store_mod.save(id, Workflow.log(wf), store_state)
  state
end
```

**`maybe_notify_complete/1` (private):**

```elixir
defp maybe_notify_complete(%{on_complete: nil}), do: :ok
defp maybe_notify_complete(%{on_complete: {m, f, a}} = state) do
  apply(m, f, [state.id, state.workflow | a])
end
defp maybe_notify_complete(%{on_complete: callback} = state) when is_function(callback, 2) do
  callback.(state.id, state.workflow)
end
```

**Edge cases and design decisions:**

- **Re-entrant `run/3`:** If a Worker is `:running` and receives another `run/3` cast, it plans the new input into the existing workflow and dispatches any new runnables. This allows feeding multiple inputs to an in-progress workflow. The `dispatched_ids` prevents duplicate dispatch within a single lifecycle.

- **Task return type:** `Task.Supervisor.async_nolink` returns a `%Task{}`. The task function returns a `%Runnable{}`. The Worker receives `{ref, %Runnable{}}` via `handle_info`. The `%Runnable{}` pattern match in `handle_info` ensures we only process task completions, not arbitrary messages.

- **Cleanup of `dispatched_ids`:** This set grows monotonically during a Worker's lifetime. For long-running workers processing many inputs, this could accumulate. For Phase 2, this is acceptable — a future optimization could clear it when the workflow becomes idle. Document this as a known limitation.

- **GenServer restart strategy:** `:transient` — the Worker stops normally when the workflow satisfies and the user calls `stop/3`. Crashes trigger a restart by the DynamicSupervisor.

### Files to Create (Tests)

#### `test/runner/worker_test.exs` — `Runic.Runner.WorkerTest`

This is the most critical test file. It validates the full lifecycle of a Runner-managed workflow.

**Test setup:**

```elixir
setup do
  runner_name = :"test_runner_#{System.unique_integer([:positive])}"
  start_supervised!({Runic.Runner, name: runner_name})
  %{runner: runner_name}
end
```

**A. Lifecycle — start, run, results, stop:**
- `start_workflow/4` returns `{:ok, pid}`
- `start_workflow/4` with duplicate ID returns `{:error, {:already_started, pid}}`
- `run/4` processes input to completion
- `get_results/2` returns the workflow's raw productions
- `get_workflow/2` returns the `%Workflow{}` struct
- `stop/3` terminates the worker process
- `stop/3` with `persist: false` does not call `store.save`
- `lookup/2` returns `pid` for running workflow, `nil` for stopped
- `list_workflows/1` returns active IDs

**B. Dispatch loop — correctness:**
- Single step workflow: input → output in one cycle
- Multi-step pipeline: `a -> b -> c` completes through all stages
- Branching workflow: `a -> [b, c]` dispatches both branches
- Branching + joining: `a -> [b, c] -> d(join)` produces join result
- Workflow with rules: condition gates prevent/allow step execution

**C. Policy integration:**
- Workflow with `scheduler_policies` set: policies are applied during execution
- Runtime policy override via `run/4` opts: overrides take effect
- Step with `max_retries: 2` and flaky function: retries and succeeds
- Step with `timeout_ms` that's too short: fails with `{:timeout, _}`
- Step with `on_failure: :skip` and always-failing fn: skips without blocking pipeline
- Step with fallback returning `{:value, synthetic}`: synthetic value flows downstream

**D. Concurrency — max_concurrency and task isolation:**
- `max_concurrency: 1` executes runnables one at a time (verify ordering)
- `max_concurrency: 4` with 4 independent steps: all dispatched concurrently (verify with timing)
- Task crash doesn't kill the Worker process
- Duplicate dispatch prevention: same runnable ID not dispatched twice in one run

**E. Persistence — ETS store integration:**
- After `run/4` completes, the store contains the workflow log
- `resume/3` loads from store and starts a new Worker with the restored workflow
- Resumed workflow has the same productions as the original
- `stop/3` with `persist: true` (default) saves final state
- `checkpoint_strategy: :on_complete` only persists when workflow satisfies (not mid-execution)
- `checkpoint_strategy: {:every_n, 3}` persists every 3rd cycle

**F. Completion callbacks:**
- `on_complete: {Module, :function, [extra_arg]}` is called when workflow satisfies
- `on_complete: fn(id, workflow) -> ... end` is called with correct arguments
- Callback receives the workflow ID and final workflow state

**G. Multiple inputs:**
- Send `run/4` twice with different inputs before first completes
- Both inputs are processed, workflow accumulates all productions

**H. Error cases:**
- `run/4` on a non-existent workflow ID returns `{:error, :not_found}`
- `get_results/2` on a non-existent workflow ID returns `{:error, :not_found}`
- `resume/3` with no persisted state returns `{:error, :not_found}`

### Invariants

- **Contract:** After `run/4`, the Worker always transitions back to `:idle` when all runnables are exhausted and all tasks are done
- **No runnable leaks:** Every dispatched task is tracked in `active_tasks`. Every `{ref, result}` message removes from `active_tasks`. Every `{:DOWN, ref, ...}` removes from `active_tasks`.
- **Idempotent apply:** `Workflow.apply_runnable/2` is called exactly once per completed runnable
- **Task isolation:** A crashing task produces a `{:DOWN, ...}` message, not a linked exit
- **Checkpoint correctness:** Checkpointed state is loadable via `Workflow.from_log/1` and produces the same workflow state
- **Policy transparency:** The Worker doesn't interpret policies — it delegates entirely to `SchedulerPolicy.resolve/2` and `PolicyDriver.execute/2`

---

## Phase 3: Telemetry Integration

**Goal:** Wire telemetry events into the Worker's lifecycle and the PolicyDriver's execution path. Users can attach handlers for monitoring, logging, and metrics.

**Depends on:** Phase 2 (Worker), Phase 1C (Telemetry module)

### Files to Modify

#### `lib/runic/runner/worker.ex`

Add telemetry emissions at key lifecycle points:

1. **Workflow start:** In `init/1`, emit `[:runic, :runner, :workflow, :start]` with metadata `%{id: id, workflow_name: workflow.name}`.

2. **Runnable dispatch:** In `dispatch_runnables/1`, after each `Task.Supervisor.async_nolink`, emit `[:runic, :runner, :runnable, :start]` with metadata `%{workflow_id: id, node_name: runnable.node.name, policy: policy}`.

3. **Runnable completion:** In `handle_info({ref, %Runnable{status: :completed}})`, emit `[:runic, :runner, :runnable, :stop]` with measurements `%{duration: duration_ms}` and metadata `%{workflow_id: id, node_name: node_name, status: :completed}`.

4. **Runnable failure:** In `handle_info({ref, %Runnable{status: :failed}})`, emit `[:runic, :runner, :runnable, :exception]` with metadata `%{workflow_id: id, node_name: node_name, error: error}`.

5. **Workflow satisfaction:** When transitioning to `:idle` after all tasks complete, emit `[:runic, :runner, :workflow, :stop]` with measurements `%{duration: System.monotonic_time(:millisecond) - state.started_at}`.

6. **Store operations:** Wrap `maybe_persist/1` and `do_checkpoint/1` with `Telemetry.store_span/3`.

#### `lib/runic/runner/telemetry.ex`

Refine the helpers based on actual usage patterns from the Worker integration.

### Files to Create (Tests)

#### `test/runner/telemetry_integration_test.exs`

- Attach telemetry handler before starting a workflow run
- Verify `[:runic, :runner, :workflow, :start]` fires on `start_workflow/4`
- Verify `[:runic, :runner, :runnable, :start]` fires for each dispatched runnable
- Verify `[:runic, :runner, :runnable, :stop]` fires with `duration` measurement
- Verify `[:runic, :runner, :workflow, :stop]` fires when workflow satisfies
- Verify `[:runic, :runner, :store, :stop]` fires on checkpoint with `duration` measurement
- Verify metadata includes `workflow_id` and `node_name`
- Verify no telemetry events fire when no Runner is used (existing workflow APIs unchanged)

---

## Phase 4: Advanced Checkpoint Strategies

**Goal:** Implement the full set of checkpoint strategies and durable event tracking in the Worker.

**Depends on:** Phase 2 (Worker with basic checkpointing)

### Files to Modify

#### `lib/runic/runner/worker.ex`

1. **Durable execution mode:** When a runnable's resolved policy has `execution_mode: :durable`, the Worker:
   - Uses `PolicyDriver.execute/3` with `emit_events: true`
   - The returned `{runnable, events}` tuple's events are appended to the workflow via `Workflow.append_runnable_events/2`
   - Events are thus captured in `Workflow.log/1` and persisted with the next checkpoint

2. **In-flight recovery in init:** When the Worker is started via `resume/3`, after rebuilding the workflow from log:
   - Call `Workflow.pending_runnables/1` to identify dispatched-but-not-completed runnables
   - Re-prepare and re-dispatch these runnables
   - This provides crash recovery for durable execution mode

3. **`:manual` checkpoint with explicit API:** Add `Runic.Runner.checkpoint/2` to the public API:
   ```elixir
   def checkpoint(runner, workflow_id) do
     GenServer.call(via(runner, workflow_id), :checkpoint)
   end
   ```

### Files to Create (Tests)

#### `test/runner/durable_execution_test.exs`

- Workflow with `execution_mode: :durable` policy: events appear in `Workflow.log/1`
- After crash and resume, `pending_runnables/1` identifies in-flight work
- Resumed worker re-dispatches in-flight runnables
- `RunnableDispatched` event has correct `node_name`, `attempt`, and stripped policy
- `RunnableCompleted` event has correct `duration_ms`
- Manual checkpoint via `Runic.Runner.checkpoint/2` persists current state
- `checkpoint_strategy: {:every_n, 5}` checkpoints exactly every 5th cycle (count across multiple runnables completing)

---

## Phase 5: Mnesia Adapter Sketch + Adapter Documentation

**Goal:** Provide a second Store adapter using Mnesia (zero external deps, distributed capable) and documentation for writing custom adapters.

**Depends on:** Phase 1A (Store behaviour)

### Files to Create

#### `lib/runic/runner/store/mnesia.ex` — `Runic.Runner.Store.Mnesia`

Per the proposal ([§ Mnesia Adapter](runner-proposal.md#mnesia-adapter)). Implementation notes:

- `init/1` creates the Mnesia table if it doesn't exist (idempotent with `:mnesia.create_table` error handling)
- Table attributes: `[:workflow_id, :log, :updated_at]`
- `disc_copies` for persistence across VM restarts
- Transactions for all write operations
- Direct reads (no transaction) for `load/2` — eventually consistent but faster

This adapter is a "sketch" — functional but not production-hardened. It demonstrates the adapter pattern and provides a real distributed storage option. Users who need production Mnesia should audit and extend it.

#### `lib/runic/runner/store/mnesia.ex` (child_spec)

Mnesia adapter needs a `child_spec/1` and `start_link/1` for supervision since it needs to ensure the Mnesia table exists. Unlike ETS which needs a GenServer to own the table, Mnesia tables are persistent. The child_spec can use a simple Task that creates the table and exits normally.

### Files to Create (Tests)

#### `test/runner/store_mnesia_test.exs`

- Same CRUD test suite as ETS (extracted to a shared test helper or `Store` contract test)
- Mnesia-specific: table survives process restart
- Mnesia-specific: `list/1` returns all stored IDs

---

## Testing Strategy Summary

### Test Files

| File | Phase | Scope |
|------|-------|-------|
| `test/runner/store_ets_test.exs` | 1A | ETS adapter CRUD, round-trip, concurrency |
| `test/runner/runner_test.exs` | 1B + 2 | Supervisor tree, public API routing |
| `test/runner/telemetry_test.exs` | 1C | Event name definitions, helper functions |
| `test/runner/worker_test.exs` | 2 | Worker lifecycle, dispatch, policies, persistence, recovery |
| `test/runner/telemetry_integration_test.exs` | 3 | End-to-end telemetry event verification |
| `test/runner/durable_execution_test.exs` | 4 | Durable events, in-flight recovery, checkpoint strategies |
| `test/runner/store_mnesia_test.exs` | 5 | Mnesia adapter CRUD |

### Test Dimensionality

| Dimension | Values |
|-----------|--------|
| Workflow shape | single step, pipeline (a→b→c), branch (a→[b,c]), branch+join, with rules |
| Concurrency | max_concurrency: 1, default, 4 |
| Policies | none, with retries, with timeout, with fallback, with on_failure: :skip |
| Store | nil (no persistence), ETS, Mnesia |
| Checkpoint strategy | :every_cycle, :on_complete, {:every_n, n}, :manual |
| Lifecycle | start→run→complete, start→run→stop, start→run→crash→resume |
| Input pattern | single input, multiple sequential inputs, concurrent inputs |
| Completion callback | nil, {m,f,a}, fn/2 |

### Regression Strategy

After each phase, run `mix test` to verify all 606 existing tests still pass. The Runner adds new modules under `lib/runic/runner/` and new test files under `test/runner/` — no existing files are modified except `mix.exs` (adding `:telemetry` dep).

### Key Properties to Verify Across All Phases

1. **Backward compatibility:** All existing workflows work without a Runner. `mix test` with no Runner code exercises the full existing test suite unchanged.
2. **Task isolation:** Worker never crashes from task failures. `Task.Supervisor.async_nolink` + `{:DOWN, ...}` handling ensures this.
3. **Duplicate dispatch prevention:** Within a single run lifecycle, the same runnable ID is never dispatched twice.
4. **Checkpoint correctness:** `Workflow.from_log(Workflow.log(workflow))` produces a workflow that yields the same `raw_productions/1`.
5. **Store contract:** Any module implementing `Runic.Runner.Store` can be plugged in without code changes to Runner or Worker.
6. **Policy delegation:** The Worker resolves and delegates to PolicyDriver without interpreting policy fields itself.
7. **Concurrency bounds:** `max_concurrency` is respected — never more than N tasks active simultaneously.
8. **Clean shutdown:** `stop/3` persists final state and the Worker exits `:normal`.
9. **Recovery completeness:** `resume/3` from a checkpointed workflow produces the same state as the original run.

---

## Implementation Notes

### What's Deferred

1. **Custom Worker behaviour** — Phase 4 of the proposal. Users wanting custom workers can implement their own GenServer following the same pattern. Not needed for the core Runner.

2. **Executor behaviour** — Phase 4 of the proposal. The default task dispatch is sufficient. Oban/external executor routing is an advanced feature.

3. **Registry behaviour/abstraction** — Phase 3 of the proposal. The default Elixir `Registry` works. Users who need Horde can pass `registry: Horde.Registry` — the Runner uses `{:via, Registry, ...}` naming convention which Horde supports natively. No abstraction layer needed yet.

4. **Postgres, SQLite, Oban, Khepri, RocksDB adapter sketches** — These are documented in the proposal as reference implementations. They require external dependencies and are user-provided. The Store behaviour + ETS + Mnesia adapters demonstrate the pattern sufficiently.

5. **Circuit breaker runtime** — The `circuit_breaker` field exists on `SchedulerPolicy` from the prior implementation but has no runtime behavior. The Runner doesn't need to implement this — it's a PolicyDriver concern for a future effort.

### Integration with Prior Scheduler Policies Work

The Runner builds directly on these completed interfaces:

| Interface | Module | Used By |
|-----------|--------|---------|
| `SchedulerPolicy.resolve/2` | `scheduler_policy.ex` | Worker `dispatch_runnables/1` |
| `PolicyDriver.execute/2,3` | `policy_driver.ex` | Worker task dispatch |
| `Workflow.scheduler_policies` field | `workflow.ex` | Worker reads policies |
| `Workflow.set_scheduler_policies/2` | `workflow.ex` | User API (unchanged) |
| `SchedulerPolicy.merge_policies/2,3` | `scheduler_policy.ex` | Worker `handle_cast({:run, ...})` |
| `PolicyDriver.execute/3` with `emit_events: true` | `policy_driver.ex` | Worker durable mode (Phase 4) |
| `Workflow.append_runnable_events/2` | `workflow.ex` | Worker durable mode (Phase 4) |
| `Workflow.pending_runnables/1` | `workflow.ex` | Worker `resume/3` recovery (Phase 4) |
| `Workflow.log/1` (includes runnable events) | `workflow.ex` | Store persistence |
| `Workflow.from_log/1` (handles runnable events) | `workflow.ex` | Store recovery |
