# Full-Breadth Runner Scheduling & Execution Considerations

**Status:** Draft  
**Depends on:** [Runner Implementation Plan](runner-implementation-plan.md), [Scheduler Policies](scheduler-policies-implementation-plan.md)  
**Related:** [Checkpointing Strategies](checkpointing-strategies-proposal.md), [Causal Runtime Architecture](causal-runtime-architecture.md), [Runner Proposal](runner-proposal.md)

---

## Table of Contents

- [Motivation & Scope](#motivation--scope)
- [Current Architecture Recap](#current-architecture-recap)
- [Layered Abstraction Model](#layered-abstraction-model)
- [Executor Behaviour](#executor-behaviour)
  - [Design Rationale](#executor-design-rationale)
  - [Behaviour Definition](#executor-behaviour-definition)
  - [Built-in Executor: TaskExecutor](#built-in-executor-taskexecutor)
  - [Adapter Sketches](#executor-adapter-sketches)
  - [Per-Component Executor Overrides](#per-component-executor-overrides)
- [Promise Model](#promise-model)
  - [Design Rationale](#promise-design-rationale)
  - [Promise Struct](#promise-struct)
  - [Promise Construction & Subgraph Analysis](#promise-construction--subgraph-analysis)
  - [Promise Resolution](#promise-resolution)
  - [Promise ↔ Executor Integration](#promise--executor-integration)
  - [Promise ↔ Policy Integration](#promise--policy-integration)
- [Intelligent Scheduling](#intelligent-scheduling)
  - [Subgraph Analysis: Linear Chains](#subgraph-analysis-linear-chains)
  - [Runtime Adaptive Scheduling](#runtime-adaptive-scheduling)
  - [Scheduling Heuristics](#scheduling-heuristics)
  - [Scheduler Strategy Behaviour](#scheduler-strategy-behaviour)
- [Worker Behaviour & Customization](#worker-behaviour--customization)
  - [Design Rationale](#worker-design-rationale)
  - [Custom Worker Behaviour](#custom-worker-behaviour)
  - [Partial Override Model](#partial-override-model)
- [Distribution & Process Topology](#distribution--process-topology)
  - [Single-Node Topologies](#single-node-topologies)
  - [Multi-Node Distribution](#multi-node-distribution)
  - [Topology-Aware Scheduling](#topology-aware-scheduling)
- [Dependency Graph & Phasing](#dependency-graph--phasing)
- [Prior Art & System Comparisons](#prior-art--system-comparisons)
  - [Restate](#restate)
  - [Azure Durable Functions](#azure-durable-functions)
  - [Oban](#oban)
  - [Rivet](#rivet)
  - [Temporal](#temporal)
  - [Broadway & GenStage](#broadway--genstage)
  - [Synthesis: Runic's Position](#synthesis-runics-position)
- [Prioritized Roadmap](#prioritized-roadmap)
- [Open Questions](#open-questions)

---

## Motivation & Scope

The [Runner Implementation Plan](runner-implementation-plan.md) delivered a minimum compelling addition of durable workflow execution: supervised workers, policy-driven dispatch via `Task.Supervisor.async_nolink`, ETS/Mnesia persistence, and telemetry. This unlocked the core value proposition — users get batteries-included scheduling without building 200+ lines of boilerplate.

However, the implementation deferred several capabilities that become critical as Runic moves toward production use cases:

1. **Executor customization** — The Worker hardcodes `Task.Supervisor.async_nolink` as the execution mechanism. Users wanting GenStage back-pressure, Broadway batching, Poolboy worker pools, or external job queues (Oban) have no integration point.

2. **Intelligent dispatch** — Every runnable is dispatched as an independent task. For linear chains (`a → b → c`), this means three process spawns, three message passes, and three potential copies of intermediate facts across process boundaries — when all three could execute sequentially in a single task.

3. **Execution granularity control** — Users cannot control _which_ runnables execute together, _how_ subgraphs resolve, or _where_ execution happens in the process topology.

4. **Worker extensibility** — The Worker GenServer is a concrete module. Users wanting custom lifecycle hooks, alternative state management, or integration with existing supervision trees must fork or wrap it.

This document explores how to layer these capabilities into Runic's architecture while preserving the core design principles: functional core, lazy evaluation, full scheduling control, and no assumed runtime topology.

---

## Current Architecture Recap

The execution pipeline as shipped:

```
User Input
    │
    ▼
┌─────────────────────────────────────────────────────┐
│  Runner.Worker (GenServer)                           │
│                                                      │
│  1. PLAN:     Workflow.plan_eagerly(input)            │
│  2. PREPARE:  Workflow.prepare_for_dispatch(workflow) │
│               → {workflow, [%Runnable{}]}             │
│  3. DISPATCH: for each runnable:                     │
│               │ policy = SchedulerPolicy.resolve()   │
│               │ Task.Supervisor.async_nolink(fn ->   │
│               │   PolicyDriver.execute(runnable, p)  │
│               │ end)                                 │
│  4. APPLY:    handle_info({ref, %Runnable{}}) →      │
│               Workflow.apply_runnable(wf, executed)   │
│  5. REPEAT:   if is_runnable?(wf), goto 2            │
│                                                      │
│  Persistence: maybe_checkpoint → Store.save/3        │
│  Telemetry:   Telemetry.runnable_event(...)          │
└─────────────────────────────────────────────────────┘
```

The key observation is that **steps 3 and 4** — dispatch and apply — are where all extensibility opportunities live. The plan and prepare phases are pure data transformations on the `Workflow` struct. The dispatch phase decides _how_ and _where_ runnables execute. The apply phase reduces results back into the workflow. Everything between prepare and apply is the **execution gap** that this document addresses.

---

## Layered Abstraction Model

Runic's value comes from not assuming a runtime topology. The abstractions must layer cleanly from maximum user control to fully managed:

```
Layer 0: Raw Three-Phase API
  ╰─ Workflow.prepare_for_dispatch/1 → manual dispatch → Workflow.apply_runnable/2
  ╰─ User manages processes, persistence, scheduling, error handling
  ╰─ Full control, zero opinions

Layer 1: PolicyDriver + SchedulerPolicy
  ╰─ Wraps Layer 0 execution with retry, timeout, backoff, fallback
  ╰─ Still process-agnostic — user manages tasks and lifecycle

Layer 2: Executor Behaviour (NEW)
  ╰─ Abstracts _how_ runnables are dispatched to compute
  ╰─ Implementations: Task pool, GenStage, Broadway, Poolboy, Oban, external
  ╰─ User selects or provides an Executor; controls the compute substrate

Layer 3: Scheduler Strategy (NEW)
  ╰─ Abstracts _what_ gets dispatched together and _when_
  ╰─ Promise construction, subgraph batching, adaptive scheduling
  ╰─ User selects or provides a Strategy; controls dispatch granularity

Layer 4: Runner (existing, enhanced)
  ╰─ Wires Layers 1-3 together with supervision, registry, persistence
  ╰─ Worker GenServer drives the dispatch loop
  ╰─ Batteries-included: start_link, run, get_results, resume

Layer 5: Distribution (future)
  ╰─ Cluster-aware routing, sticky execution, node affinity
  ╰─ Builds on Layer 4 with distributed registry and store
```

Each layer is independently useful. A user at Layer 0 gets zero overhead. A user at Layer 4 gets full managed execution. The layers compose — a custom Executor at Layer 2 plugs into the standard Runner at Layer 4 without modification.

**Design constraint:** Upper layers consume lower layers' _behaviours_, never their _implementations_. The Runner does not know it's using `TaskExecutor` vs `BroadwayExecutor` — it calls `Executor.dispatch/3`.

---

## Executor Behaviour

### Executor Design Rationale

The current Worker dispatches runnables via:

```elixir
Task.Supervisor.async_nolink(task_supervisor, fn ->
  PolicyDriver.execute(runnable, policy)
end)
```

This works for the common case but creates a hard coupling between the Worker's dispatch loop and the Task-based execution model. Users wanting different execution substrates — GenStage for back-pressure, Broadway for batching, Poolboy for bounded worker pools, Oban for persistent job queues — must replace the entire Worker.

The Executor behaviour extracts the dispatch mechanism into a pluggable adapter. The Worker calls `Executor.dispatch/3` instead of `Task.Supervisor.async_nolink`, and the Executor implementation decides how to get the work done.

**Critical design decision:** The Executor receives _already-policy-wrapped_ runnables (or Promises — see below). The PolicyDriver still runs the retry/timeout/backoff loop. The Executor controls _where_ that loop executes (which process, which node, which pool), not _what_ the loop does. This separation means:

- Executor adapters are simple: dispatch work, return a handle
- Policy logic stays centralized in the PolicyDriver
- Users can mix Executors and Policies independently

### Executor Behaviour Definition

```elixir
defmodule Runic.Runner.Executor do
  @moduledoc """
  Behaviour for controlling how runnables are dispatched to compute.

  Executors abstract the process/task/worker mechanism used to execute
  runnables. The Runner's Worker calls `dispatch/3` for each runnable
  (or Promise) and receives a handle for tracking completion.

  Completion is signaled asynchronously to the calling process via
  standard Erlang messages: `{ref, result}` and `{:DOWN, ref, ...}`.
  """

  @type handle :: reference()
  @type dispatch_opts :: keyword()

  @type executor_state :: term()

  @doc """
  Initialize the executor with configuration.

  Called once when the Worker starts. Returns opaque state passed
  to subsequent `dispatch/3` and `cleanup/1` calls.
  """
  @callback init(opts :: keyword()) :: {:ok, executor_state()} | {:error, term()}

  @doc """
  Dispatch a unit of work for execution.

  The `work_fn` is a zero-arity function that, when called, executes
  the runnable through the PolicyDriver and returns the result.

  Returns `{handle, new_state}` where `handle` is a reference the
  Worker uses to correlate completion messages.

  The executor MUST arrange for the calling process to receive:
    - `{handle, result}` on successful completion
    - `{:DOWN, handle, :process, pid, reason}` on crash

  This contract matches `Task.Supervisor.async_nolink` semantics,
  making the default TaskExecutor a zero-cost abstraction.
  """
  @callback dispatch(work_fn :: (-> term()), dispatch_opts(), executor_state()) ::
              {handle(), executor_state()}

  @doc """
  Clean up executor resources.

  Called when the Worker is stopping. Optional.
  """
  @callback cleanup(executor_state()) :: :ok

  @optional_callbacks [cleanup: 1]
end
```

**Why `work_fn` instead of `%Runnable{}`?** The Executor receives a zero-arity closure that encapsulates `PolicyDriver.execute(runnable, policy)`. This keeps the Executor unaware of Runic's domain types — it's a generic "run this function somewhere" adapter. This makes it trivial to implement Executors for systems that don't know about Runic (GenStage, Broadway, Poolboy).

For Executors that cross serialization boundaries (Oban, distributed), the `work_fn` closure cannot be sent as-is. However, Runic's component nodes are serializable via `Runic.Closure` (which captures AST + bindings + metadata), and the Runnable's `node`, `input_fact`, `context`, and `result` fields are all plain data structs. The only non-serializable field on a completed Runnable is `apply_fn` — a convenience closure that reduces the result back into the workflow. This closure is _reconstructible_ from the Runnable's serializable fields (`node`, `input_fact`, `result`) since it only calls `Workflow.log_fact`, `Workflow.draw_connection`, `Workflow.mark_runnable_as_ran`, and `Workflow.prepare_next_runnables` with those values. Remote Executors can therefore serialize the Runnable's data fields, transmit them, and reconstruct the `apply_fn` on the receiving side — or simply let `Workflow.apply_runnable/2` rebuild it from the completed Runnable.

**Message contract:** The `{ref, result}` / `{:DOWN, ref, ...}` contract is the same as `Task.async_nolink`. Every Executor must produce these messages to the calling Worker. This means the Worker's `handle_info` clauses don't change regardless of Executor — the existing `handle_info({ref, %Runnable{}}, state)` works identically.

### Built-in Executor: TaskExecutor

```elixir
defmodule Runic.Runner.Executor.Task do
  @moduledoc """
  Default executor using Task.Supervisor.async_nolink.

  This is the zero-overhead default. The Worker's dispatch loop
  delegates to this executor when no custom executor is configured.
  """
  @behaviour Runic.Runner.Executor

  @impl true
  def init(opts) do
    task_supervisor = Keyword.fetch!(opts, :task_supervisor)
    {:ok, %{task_supervisor: task_supervisor}}
  end

  @impl true
  def dispatch(work_fn, _opts, %{task_supervisor: sup} = state) do
    task = Task.Supervisor.async_nolink(sup, work_fn)
    {task.ref, state}
  end

  @impl true
  def cleanup(_state), do: :ok
end
```

This is a direct extraction of the current Worker code. The refactor is mechanical: replace `Task.Supervisor.async_nolink(...)` with `Executor.dispatch(...)` in the Worker's `dispatch_runnables/1`.

### Executor Adapter Sketches

#### GenStage Executor

For back-pressure-aware execution. Runnables are dispatched to a GenStage producer; downstream consumers pull work at their own pace.

```elixir
defmodule Runic.Runner.Executor.GenStage do
  @behaviour Runic.Runner.Executor

  @impl true
  def init(opts) do
    producer = Keyword.fetch!(opts, :producer)
    {:ok, %{producer: producer, pending: %{}}}
  end

  @impl true
  def dispatch(work_fn, _opts, %{producer: producer} = state) do
    ref = make_ref()
    caller = self()
    # Enqueue work into GenStage producer; consumer will execute
    # and send {ref, result} back to caller
    GenStage.cast(producer, {:enqueue, ref, caller, work_fn})
    {ref, %{state | pending: Map.put(state.pending, ref, true)}}
  end
end
```

#### Broadway Executor

For batched execution where runnables accumulate and are processed in groups.

```elixir
defmodule Runic.Runner.Executor.Broadway do
  @behaviour Runic.Runner.Executor

  @impl true
  def init(opts) do
    broadway = Keyword.fetch!(opts, :broadway)
    {:ok, %{broadway: broadway}}
  end

  @impl true
  def dispatch(work_fn, _opts, %{broadway: broadway} = state) do
    ref = make_ref()
    caller = self()
    # Broadway.test_message/3 or custom producer integration
    Broadway.push_message(broadway, %{ref: ref, caller: caller, work_fn: work_fn})
    {ref, state}
  end
end
```

#### Oban Executor

For durable job-queue execution where runnables are persisted as Oban jobs.

```elixir
defmodule Runic.Runner.Executor.Oban do
  @behaviour Runic.Runner.Executor

  @impl true
  def init(opts) do
    queue = Keyword.get(opts, :queue, :runic)
    {:ok, %{queue: queue}}
  end

  @impl true
  def dispatch(work_fn, opts, %{queue: queue} = state) do
    ref = make_ref()
    caller = self()
    # Serialize the work description (not the closure!) into Oban job args.
    # The Oban worker will reconstruct and execute the runnable,
    # then send the result back to the caller via :pg or Registry.
    job_args = %{
      ref: :erlang.term_to_binary(ref),
      caller: :erlang.term_to_binary(caller),
      runnable_ref: Keyword.get(opts, :runnable_ref)
    }
    {:ok, _job} = Oban.insert(RunicObanWorker.new(job_args, queue: queue))
    {ref, state}
  end
end
```

**Note on Oban:** The Oban executor is more complex because the zero-arity `work_fn` closure cannot be sent through Postgres-backed job args. However, the underlying Runnable _is_ serializable — `Runic.Closure` ensures component work functions carry their AST + bindings, and all other Runnable fields are plain data. The Oban worker on the receiving side reconstructs the Runnable from serialized args, re-resolves its policy, and executes it locally. Alternatively, a `RunnableRef` (from the scheduler policies proposal) can serve as a lightweight serializable dispatch intent that references the workflow ID and node hash, letting the Oban worker load the workflow from the Store and re-prepare the specific runnable.

#### Poolboy Executor

For bounded worker pool execution.

```elixir
defmodule Runic.Runner.Executor.Poolboy do
  @behaviour Runic.Runner.Executor

  @impl true
  def init(opts) do
    pool = Keyword.fetch!(opts, :pool)
    {:ok, %{pool: pool}}
  end

  @impl true
  def dispatch(work_fn, _opts, %{pool: pool} = state) do
    ref = make_ref()
    caller = self()
    :poolboy.transaction(pool, fn worker ->
      GenServer.cast(worker, {:execute, ref, caller, work_fn})
    end)
    {ref, state}
  end
end
```

### Per-Component Executor Overrides

Users may want different executors for different components within the same workflow. An LLM step might use the Oban executor for durable retries, while a fast validation condition uses the default Task executor.

This is achieved via the `SchedulerPolicy` matcher system already in place:

```elixir
policies = [
  # LLM steps get durable Oban execution
  {{:name, ~r/^llm_/}, %{
    execution_mode: :durable,
    executor: Runic.Runner.Executor.Oban,
    executor_opts: [queue: :llm]
  }},

  # Fast conditions run inline (no task overhead)
  {{:type, Condition}, %{
    executor: :inline
  }},

  # Everything else uses default Task executor
  {:default, %{}}
]
```

The `:executor` field on `SchedulerPolicy` tells the Worker which executor to use for a given runnable. When present, the Worker dispatches through that executor instead of the default. The special value `:inline` skips the executor entirely and runs the work synchronously in the Worker process — useful for conditions and other sub-millisecond computations where task spawn overhead dominates.

**Implementation note:** This requires `SchedulerPolicy` to gain optional `executor` and `executor_opts` fields. The Worker's `dispatch_runnables/1` resolves the executor per-runnable from the resolved policy, falling back to the runner-level default executor.

---

## Promise Model

### Promise Design Rationale

Consider a linear chain in a workflow:

```
parse_input → validate → transform → enrich → format_output
```

Under the current model, each step is dispatched as a separate task:

```
Worker → Task 1 (parse_input) → Worker → Task 2 (validate) → Worker → ...
```

This means 5 task spawns, 5 inter-process message passes, and 5 potential copies of intermediate facts. For workflows where these steps are pure functions operating on small data, the scheduling overhead dwarfs the compute time.

The Promise model addresses this by allowing the scheduler to group runnables that can execute together:

```
Worker → Task 1 (parse_input → validate → transform → enrich → format_output) → Worker
```

One task, one message pass, zero intermediate copies. The intermediate facts still materialize — they're still applied to the workflow — but they flow through a single task's memory space.

### Promise Struct

```elixir
defmodule Runic.Runner.Promise do
  @moduledoc """
  A commitment to resolve N runnables of a workflow together.

  Promises describe a batch of runnables that will be executed as a unit.
  The scheduler constructs Promises from subgraph analysis, and the
  executor resolves them. Each runnable within a Promise still follows
  its own policy and produces its own durability events — but the actual
  execution happens in a single process/task context, avoiding inter-process
  IO for intermediate results.

  ## Durability Contract

  When a runnable within a Promise completes:
  1. Its completion event is still emitted (if durable mode)
  2. Its result fact is still recorded
  3. But the fact does NOT need to cross a process boundary until
     the entire Promise resolves or a checkpoint boundary is hit.

  The scheduler and workflow know a Promise is in flight and will
  not dispatch runnables for nodes included in the Promise.
  """

  @type t :: %__MODULE__{
          id: reference(),
          runnables: [Runic.Workflow.Runnable.t()],
          node_hashes: MapSet.t(),
          strategy: :sequential | :parallel,
          status: :pending | :resolving | :resolved | :failed,
          results: [Runic.Workflow.Runnable.t()],
          checkpoint_boundary: boolean()
        }

  defstruct [
    :id,
    :runnables,
    :node_hashes,
    strategy: :sequential,
    status: :pending,
    results: [],
    checkpoint_boundary: false
  ]

  @doc """
  Creates a new Promise from a list of runnables.

  The `node_hashes` set is used by the scheduler to skip dispatch
  for runnables whose nodes are already covered by an in-flight Promise.
  """
  def new(runnables, opts \\ []) do
    node_hashes =
      runnables
      |> Enum.map(& &1.node.hash)
      |> MapSet.new()

    %__MODULE__{
      id: make_ref(),
      runnables: runnables,
      node_hashes: node_hashes,
      strategy: Keyword.get(opts, :strategy, :sequential),
      checkpoint_boundary: Keyword.get(opts, :checkpoint_boundary, false)
    }
  end
end
```

### Promise Construction & Subgraph Analysis

Promises are constructed by the scheduler strategy (Layer 3) during the dispatch phase. The strategy analyzes the workflow graph to identify subgraphs that benefit from batched execution.

**Linear chain detection:**

```elixir
defmodule Runic.Runner.PromiseBuilder do
  @moduledoc """
  Analyzes workflow graphs to construct Promises from subgraph patterns.
  """

  alias Runic.Workflow

  @doc """
  Given a set of prepared runnables, identifies linear chains that
  can be batched into Promises.

  A linear chain is a sequence of nodes where each node has exactly
  one predecessor and one successor in the runnable set, and no node
  has side-dependencies (joins, fan-ins) outside the chain.
  """
  def build_promises(workflow, runnables, opts \\ []) do
    graph = workflow.graph
    runnable_hashes = MapSet.new(runnables, & &1.node.hash)

    # Find chain heads — runnables whose predecessor is NOT in the runnable set
    chains = identify_linear_chains(graph, runnables, runnable_hashes)

    # Convert chains of length > 1 into Promises; leave singletons as-is
    min_chain_length = Keyword.get(opts, :min_chain_length, 2)

    {promises, standalone} =
      Enum.split_with(chains, fn chain -> length(chain) > min_chain_length end)

    {Enum.map(promises, &Promise.new/1), List.flatten(standalone)}
  end
end
```

**What makes a chain "linear"?**

1. Each node in the chain has exactly one `:runnable` edge from the chain's prior node's output
2. No node in the chain is a Join or FanIn waiting on facts from outside the chain
3. No node in the chain has a `checkpoint_after: true` policy (these force a persistence boundary)
4. The chain's nodes share compatible execution modes (can't mix `:durable` and `:sync`)

### Promise Resolution

When a Promise is dispatched to an Executor, the Executor receives a `work_fn` that resolves the entire Promise:

```elixir
defp resolve_promise(promise, workflow) do
  Enum.reduce(promise.runnables, {workflow, []}, fn runnable, {wf, results} ->
    policy = SchedulerPolicy.resolve(runnable, wf.scheduler_policies)
    executed = PolicyDriver.execute(runnable, policy)

    # Apply in-process so the next runnable in the chain sees updated state
    wf = Workflow.apply_runnable(wf, executed)

    # Prepare next runnables that are part of this promise
    {wf, next_runnables} = Workflow.prepare_for_dispatch(wf)
    next_in_promise =
      Enum.filter(next_runnables, &MapSet.member?(promise.node_hashes, &1.node.hash))

    {wf, [executed | results]}
  end)
end
```

**Critical insight:** Inside a Promise, the workflow is applied _locally_ within the task. The intermediate `apply_runnable` calls update a local copy of the workflow so that downstream nodes in the chain see their predecessors' outputs. When the Promise resolves, the Worker receives all completed runnables and applies them to the source-of-truth workflow.

This introduces a subtlety: the local workflow copy inside the Promise can diverge from the source-of-truth if other runnables complete concurrently. This is acceptable because:

1. Linear chains by definition have no external dependencies within the chain
2. The apply phase at the Worker is sequential — results are reduced one at a time
3. The `apply_fn` on each Runnable uses the `node.hash` and `input_fact.hash` for idempotent graph updates

### Promise ↔ Executor Integration

The Executor does not know about Promises. The Worker wraps Promise resolution into the `work_fn` closure:

```elixir
# In Worker dispatch_runnables/1:
defp dispatch_promise(promise, state) do
  work_fn = fn ->
    {_local_wf, executed_runnables} = resolve_promise(promise, state.workflow)
    # Return all completed runnables as a batch
    {:promise_result, promise.id, executed_runnables}
  end

  {handle, executor_state} = Executor.dispatch(work_fn, [], state.executor_state)

  # Track the promise, not individual runnables
  %{state |
    active_tasks: Map.put(state.active_tasks, handle, {:promise, promise.id}),
    active_promises: Map.put(state.active_promises, promise.id, promise)
  }
end
```

The Worker's `handle_info` gains a clause for promise results:

```elixir
def handle_info({ref, {:promise_result, promise_id, executed_runnables}}, state) do
  Process.demonitor(ref, [:flush])
  # Apply all runnables from the promise sequentially
  workflow = Enum.reduce(executed_runnables, state.workflow, fn r, wf ->
    Workflow.apply_runnable(wf, r)
  end)
  # ... checkpoint, dispatch next, etc.
end
```

### Promise ↔ Policy Integration

Each runnable within a Promise still has its own resolved policy. The Promise resolution loop applies policies individually:

- **Retries:** If `parse_input` fails with retries, the PolicyDriver retries _within the task_. The Promise doesn't fail unless the PolicyDriver exhausts retries.
- **Timeouts:** Each step's timeout applies independently. A slow `enrich` step can timeout without affecting `parse_input`'s completed result.
- **Durability events:** If any runnable in the Promise has `execution_mode: :durable`, its events are accumulated and returned alongside the results. The Worker appends them to the workflow log.
- **Checkpoint boundaries:** If a runnable has `checkpoint_after: true`, the Promise builder should not include it — it becomes a promise boundary, splitting the chain.

The key invariant: **from the workflow's perspective, a Promise is transparent.** The same runnables complete with the same results and events regardless of whether they were dispatched individually or as a Promise. The Promise is a scheduling optimization, not a semantic change.

---

## Intelligent Scheduling

### Subgraph Analysis: Linear Chains

The most impactful optimization is identifying linear chains — sequences of nodes where each has exactly one predecessor and successor among the currently-runnable set. These are common in data processing pipelines, ETL workflows, and multi-stage LLM chains.

**Graph-level algorithm:**

```
1. From the set of prepared runnables, build a "runnable subgraph"
   containing only nodes with pending runnables
2. For each node, compute in-degree and out-degree within the subgraph
3. Chain heads: nodes with in-degree 0 (or in-degree from outside the subgraph)
4. Walk forward from each head, following edges where:
   - Current node has out-degree 1 in the subgraph
   - Successor has in-degree 1 in the subgraph
   - Successor is not a Join/FanIn waiting on external inputs
5. Each walk produces a chain; chains of length ≥ 2 become Promise candidates
```

**Example workflow:**

```
       ┌──→ validate_a ──→ enrich_a ──┐
input ─┤                               ├──→ merge ──→ format
       └──→ validate_b ──→ enrich_b ──┘
```

After `input` produces its fact, the runnable set is `{validate_a, validate_b}`. These are two independent chains of length 1 — no Promise benefit yet.

After `validate_a` completes, `enrich_a` becomes runnable. But `enrich_a` is a chain of length 1. However, if the scheduler knows the graph structure ahead of time, it can _preemptively_ construct a Promise for `[validate_a, enrich_a]` before dispatching `validate_a`, knowing that `enrich_a` will become runnable when `validate_a` completes.

This preemptive analysis is the domain of the Scheduler Strategy.

### Runtime Adaptive Scheduling

The scheduler should adapt its strategy based on runtime observations:

1. **Step timing profiling:** Track execution duration per node type. Steps consistently completing in <1ms don't benefit from task isolation — inline or batch them.

2. **Fact size estimation:** Track the byte size of produced facts. Large facts (LLM responses, file contents, API payloads) benefit from task isolation to avoid blocking the Worker. Small facts (booleans, integers, short strings) are cheaper to pass inline.

3. **Concurrency pressure:** When `max_concurrency` slots are full, the scheduler can batch pending runnables into fewer Promises rather than queuing them individually.

4. **Error rates:** Steps with high error rates should be isolated (not batched) to contain failure blast radius.

```elixir
defmodule Runic.Runner.Scheduler.Adaptive do
  @moduledoc """
  Adaptive scheduler that adjusts dispatch strategy based on
  runtime profiling data.
  """

  defstruct [
    :profiling_data,     # %{node_hash => %{avg_duration_ms, avg_fact_bytes, error_rate}}
    :strategy_overrides  # user-specified per-node strategy hints
  ]

  def decide_strategy(runnable, profiling_data) do
    stats = Map.get(profiling_data, runnable.node.hash, %{})

    cond do
      stats[:avg_duration_ms] && stats[:avg_duration_ms] < 1.0 ->
        :inline  # sub-millisecond, skip task overhead

      stats[:error_rate] && stats[:error_rate] > 0.1 ->
        :isolated  # high error rate, don't batch

      stats[:avg_fact_bytes] && stats[:avg_fact_bytes] > 100_000 ->
        :isolated  # large outputs, keep in separate task

      true ->
        :batchable  # candidate for Promise batching
    end
  end
end
```

### Scheduling Heuristics

Beyond linear chain detection, several heuristics improve scheduling efficiency:

| Heuristic | Description | When to Apply |
|-----------|-------------|---------------|
| **Chain batching** | Group linear chains into Promises | Always (default) |
| **Inline execution** | Execute sub-ms runnables synchronously in the Worker | When profiling data available |
| **Fan-out pre-staging** | For Map components, pre-allocate task pool slots | When Map output size is known |
| **Priority ordering** | Dispatch critical-path runnables first | When DAG critical path is computed |
| **Affinity grouping** | Co-locate runnables sharing large input facts | When fact sizes exceed threshold |
| **Checkpoint fencing** | Insert checkpoint boundaries at join points | For durable execution mode |

### Scheduler Strategy Behaviour

```elixir
defmodule Runic.Runner.Scheduler do
  @moduledoc """
  Behaviour for controlling dispatch granularity and ordering.

  The scheduler strategy sits between `prepare_for_dispatch` and
  `Executor.dispatch`. It receives prepared runnables and decides
  how to group, order, and present them for execution.
  """

  alias Runic.Workflow
  alias Runic.Workflow.Runnable
  alias Runic.Runner.Promise

  @type dispatch_unit :: {:runnable, Runnable.t()} | {:promise, Promise.t()}
  @type scheduler_state :: term()

  @doc """
  Initialize the scheduler strategy.
  """
  @callback init(opts :: keyword()) :: {:ok, scheduler_state()}

  @doc """
  Given the current workflow and set of prepared runnables, produce
  an ordered list of dispatch units (individual runnables or Promises).
  """
  @callback plan_dispatch(
              workflow :: Workflow.t(),
              runnables :: [Runnable.t()],
              scheduler_state()
            ) :: {[dispatch_unit()], scheduler_state()}

  @doc """
  Called after a dispatch unit completes. Allows the strategy
  to update profiling data or adjust future decisions.
  """
  @callback on_complete(
              dispatch_unit(),
              duration_ms :: non_neg_integer(),
              scheduler_state()
            ) :: scheduler_state()

  @optional_callbacks [on_complete: 3]
end
```

**Built-in strategies:**

- `Runic.Runner.Scheduler.Default` — Dispatches each runnable individually. Current behavior. Zero overhead.
- `Runic.Runner.Scheduler.ChainBatching` — Identifies linear chains and batches them into Promises.
- `Runic.Runner.Scheduler.Adaptive` — Profiles runtime behavior and dynamically selects between inline, batched, and isolated dispatch.

---

## Worker Behaviour & Customization

### Worker Design Rationale

The current `Runic.Runner.Worker` is a concrete GenServer that implements the full dispatch loop. It integrates all concerns: lifecycle management, dispatch, persistence, telemetry, and completion callbacks.

Users wanting to customize any of these concerns must currently replace the entire Worker. This is heavy-handed — a user who only wants to add a custom lifecycle hook shouldn't need to reimplement checkpointing.

Two complementary approaches address this:

### Custom Worker Behaviour

Define the Worker as a behaviour with overrideable callbacks:

```elixir
defmodule Runic.Runner.WorkerBehaviour do
  @moduledoc """
  Behaviour for custom Worker implementations.

  The default `Runic.Runner.Worker` implements this behaviour.
  Users can provide custom workers for specialized lifecycle
  management, alternative state tracking, or integration with
  existing supervision trees.
  """

  @type worker_state :: term()

  @callback init(opts :: keyword()) :: {:ok, worker_state()} | {:stop, term()}

  @callback handle_input(input :: term(), opts :: keyword(), worker_state()) ::
              {:dispatch, [Runic.Workflow.Runnable.t()], worker_state()}
              | {:noreply, worker_state()}

  @callback handle_runnable_complete(
              Runic.Workflow.Runnable.t(),
              worker_state()
            ) :: {:continue, worker_state()} | {:idle, worker_state()}

  @callback handle_runnable_failed(
              Runic.Workflow.Runnable.t(),
              reason :: term(),
              worker_state()
            ) :: {:continue, worker_state()} | {:halt, term(), worker_state()}

  @callback handle_workflow_complete(worker_state()) :: {:stop, worker_state()}

  @optional_callbacks [handle_workflow_complete: 1]
end
```

This is a "big behaviour" approach — the user implements the full worker contract. It's appropriate for users who need deep control over the execution lifecycle.

### Partial Override Model

For users who only want to customize specific aspects, a hook/callback system on the existing Worker is more ergonomic:

```elixir
# Per-workflow worker hooks
Runic.Runner.start_workflow(runner, :my_wf, workflow,
  hooks: [
    on_dispatch: fn runnable, state -> 
      Logger.info("Dispatching #{runnable.node.name}")
      :ok  
    end,
    on_complete: fn runnable, duration_ms, state ->
      Metrics.histogram("runnable.duration", duration_ms,
        tags: [node: runnable.node.name])
      :ok
    end,
    on_idle: fn state ->
      # Custom logic when workflow becomes idle
      :ok
    end,
    transform_runnables: fn runnables, workflow ->
      # Reorder, filter, or modify runnables before dispatch
      Enum.sort_by(runnables, & &1.node.name)
    end
  ]
)
```

The `transform_runnables` hook is particularly powerful — it lets users intercept the dispatch pipeline without replacing the Worker. A user could use this to:

- Filter out runnables that shouldn't execute yet (manual gating)
- Reorder runnables by priority
- Add logging or metrics per-dispatch
- Implement custom batching logic

**Recommendation:** Ship the partial override model (hooks) first. The full Worker behaviour is a later-phase addition for advanced users. The hooks cover 80% of customization needs with 20% of the complexity.

---

## Distribution & Process Topology

### Single-Node Topologies

The Runner currently supports one topology: `DynamicSupervisor` → `Worker` (GenServer) → `Task.Supervisor` (tasks). This is the right default but not the only option.

**Alternative single-node topologies:**

| Topology | Use Case | Implementation |
|----------|----------|----------------|
| **Inline (no tasks)** | Sub-ms workflows, testing | Executor with `:inline` strategy |
| **PartitionSupervisor** | High-throughput task dispatch | Already supported via `task_supervisor: {:partition, n}` |
| **Named worker pool** | Bounded concurrency with reuse | Poolboy/NimblePool Executor |
| **GenStage pipeline** | Back-pressure-aware pipelines | GenStage Executor + consumer topology |
| **Broadway** | Batched processing with telemetry | Broadway Executor |

The Executor behaviour makes these pluggable without modifying the Runner or Worker.

### Multi-Node Distribution

Distribution introduces three concerns:

1. **Worker placement:** Which node hosts a workflow's Worker?
2. **Task routing:** Where do dispatched tasks execute?
3. **State consistency:** How is workflow state synchronized across nodes?

**Worker placement** is handled by the Registry layer. The current Runner uses Elixir's `Registry` (single-node). Swapping to `Horde.Registry` or `:syn` gives cluster-wide worker lookup. The Runner proposal already supports this via `registry: Horde.Registry`.

**Task routing** is an Executor concern. A distributed Executor could dispatch tasks to remote nodes:

```elixir
defmodule Runic.Runner.Executor.Distributed do
  @behaviour Runic.Runner.Executor

  @impl true
  def dispatch(work_fn, opts, %{node_selector: selector} = state) do
    target_node = selector.(opts)
    ref = make_ref()
    caller = self()

    Node.spawn_link(target_node, fn ->
      result = work_fn.()
      send(caller, {ref, result})
    end)

    {ref, state}
  end
end
```

**State consistency** is handled by the Store layer. Mnesia provides multi-node replication. For stronger consistency, a Khepri (Raft-based) store ensures linearizable reads across nodes.

### Topology-Aware Scheduling

The Scheduler Strategy can factor topology into its decisions:

- **Node affinity:** Route runnables for the same workflow to the same node (sticky execution from the checkpointing proposal)
- **Data locality:** Route runnables near their input data (relevant for large facts stored in distributed caches)
- **Load balancing:** Spread runnables across nodes based on current load
- **Failure domain isolation:** Don't schedule critical-path runnables on the same node

These are advanced capabilities that build on the Executor and Scheduler Strategy behaviours. They don't require changes to the core Runner — they're implemented as custom Executor/Strategy combinations.

---

## Dependency Graph & Phasing

```
Phase A: Executor Behaviour ─────────────────────────────────────────┐
  (behaviour definition, TaskExecutor extraction from Worker)        │
  Depends on: existing Runner implementation                         │
  Risk: Low — mechanical refactor of existing dispatch code          │
                                                                     │
Phase B: Worker Hooks ───────────────────────────────────────────────┤
  (on_dispatch, on_complete, on_idle, transform_runnables)           │
  Depends on: existing Worker                                        │
  Risk: Low — additive, no change to existing dispatch logic         │
                                                                     │
Phase C: Promise Model ──────────────────────────────────────────────┤
  (Promise struct, PromiseBuilder, Worker promise handling)          │
  Depends on: Phase A (Executor dispatches Promises)                 │
  Risk: Medium — local workflow copies inside Promises need          │
         careful testing against concurrent apply                    │
                                                                     │
Phase D: Scheduler Strategy Behaviour ──────────────────────────────┤
  (behaviour definition, Default strategy, ChainBatching strategy)   │
  Depends on: Phase C (strategies produce Promises)                  │
  Risk: Medium — graph analysis algorithms need thorough testing     │
                                                                     │
Phase E: Per-Component Executor Overrides ──────────────────────────┤
  (executor field on SchedulerPolicy, Worker multi-executor routing) │
  Depends on: Phase A (Executor behaviour must exist)                │
  Risk: Low — additive field on existing policy struct               │
                                                                     │
Phase F: Adaptive Scheduling ───────────────────────────────────────┤
  (runtime profiling, adaptive strategy)                             │
  Depends on: Phase D (strategy behaviour), Phase B (hooks for data) │
  Risk: Medium — profiling accuracy affects scheduling quality       │
                                                                     │
Phase G: Community Executor Adapters ───────────────────────────────┤
  (GenStage, Broadway, Poolboy, Oban sketches + docs)                │
  Depends on: Phase A (Executor behaviour)                           │
  Risk: Low — each adapter is independent and optional               │
                                                                     │
Phase H: Distribution Primitives ───────────────────────────────────┘
  (Distributed Executor, topology-aware scheduling)
  Depends on: Phase A, Phase D, distributed Store + Registry
  Risk: High — distributed systems complexity
```

**Parallelism opportunities:**

- **Phases A and B** are independent — different files, no shared types.
- **Phase E** can start alongside Phase C — it only needs Phase A.
- **Phase G** can start as soon as Phase A completes — adapter sketches are independent.
- **Phase F** requires D but can begin design work alongside C.

---

## Prior Art & System Comparisons

### Restate

[Restate](https://restate.dev/) is a journal-based durable execution framework.

**Relevant to Runic:**
- **Virtual Objects:** Named stateful entities with exactly-once processing. Runic's `Runner.Worker` keyed by `workflow_id` is architecturally similar.
- **Journaling:** Every side effect is journaled before execution. On replay, the journal is consulted instead of re-executing. Runic's `RunnableDispatched`/`RunnableCompleted` events serve the same purpose.
- **Handlers as units of work:** Restate handlers are the execution unit. Runic's Runnables fill this role.
- **Suspension:** Restate handlers can suspend waiting for external events. Runic doesn't have explicit suspension yet — this maps to `execution_mode: :external` in the policy system.

**What Runic can learn:**
- Restate's journal is append-only and compactable. Runic should pursue incremental checkpointing (Strategy 2 in checkpointing proposal) to match this property.
- Restate's "awakeables" — named futures that external systems can complete — map naturally to a Promise that waits for an external signal. This could be a future `execution_mode: :awaitable` policy.

### Azure Durable Functions

**Relevant to Runic:**
- **Orchestrator replay model:** The orchestrator function re-executes from scratch, but completed activities return cached results. This is exactly `Workflow.from_log/1` + `pending_runnables/1`.
- **Extended sessions:** Keep the orchestrator in memory between events to avoid replay. This is sticky execution — already natural in Runic's Worker model.
- **Fan-out/fan-in:** Native pattern with `Task.all([...])`. Runic's `Map` component + `FanIn` is the equivalent.
- **Entity pattern:** Stateful objects addressed by ID. Runic's `StateMachine` component.
- **Sub-orchestrations:** Orchestrators calling other orchestrators. Runic supports this via nested workflows — a step that runs another workflow.

**What Runic can learn:**
- Azure's distinction between "orchestrator" (deterministic control flow) and "activity" (side effects) maps to Runic's distinction between the Workflow graph (deterministic) and Invokable execution (side effects). The Executor behaviour formalizes this separation.
- Azure's "continue-as-new" pattern (restart with fresh history when it grows too large) should be adopted. This is referenced in the checkpointing proposal but deserves explicit API design.

### Oban

[Oban](https://getoban.pro/) is Elixir's premier job processing library.

**Relevant to Runic:**
- **Durable job queue:** Jobs are persisted to Postgres and survive VM restarts. An Oban Executor adapter would give Runic workflows durable execution without building a new job queue.
- **Unique jobs:** Oban deduplicates jobs by configurable keys. This maps to Runic's `idempotency_key` on SchedulerPolicy.
- **Rate limiting:** Oban Pro supports rate limiting per queue. Runic's `rate_limit` policy field (from extended policy options) could delegate to Oban's implementation.
- **Workflows (Oban Pro):** Oban Pro has a workflow feature for job dependencies. This is a much simpler model than Runic's DAG — Oban workflows are linear dependencies, not arbitrary graphs.

**Integration strategy:**
- An `Executor.Oban` adapter dispatches runnables as Oban jobs. The Oban worker reconstructs and executes the runnable, then signals completion back to the Runner via `:pg` or Registry.
- The Store and Executor are separate concerns — using Oban as an Executor doesn't require using Oban for state persistence (the Store handles that).
- This positions Runic as the _workflow engine_ and Oban as the _compute substrate_ — a natural division of responsibility.

### Rivet

[Rivet](https://rivet.gg/) is an open-source workflow orchestration platform (formerly focused on game backends).

**Relevant to Runic:**
- **Actor-based execution:** Rivet uses actors (similar to Erlang processes) as the execution unit. Each actor has state, receives messages, and can spawn child actors. Runic's Worker is an actor.
- **Signals:** Rivet actors communicate via signals (typed messages). Runic's fact flow between nodes is the equivalent.
- **Durable state:** Actor state is automatically persisted and restored. This is Runic's Store + checkpoint system.
- **Workflow-as-code:** Rivet defines workflows in code (TypeScript), not YAML/JSON. Runic is the same.

**What Runic can learn:**
- Rivet's actor model naturally supports hierarchical composition — an actor can spawn sub-actors for sub-workflows. Runic should consider explicit sub-workflow support where a Step's work function starts a child workflow under the same Runner.
- Rivet's signal system supports typed, named messages between actors. This could inspire a more explicit inter-workflow communication mechanism for Runic's distributed Runner.

### Temporal

**Relevant to Runic (extending from checkpointing proposal):**
- **Worker polling model:** Temporal workers poll task queues for work. This is the inverse of Runic's push model (Worker dispatches tasks). A queue-based Executor would bridge this gap.
- **Activity heartbeating:** Long-running activities send heartbeats to prevent timeout. Runic's `heartbeat_interval_ms` policy field (from extended options) serves this purpose.
- **Search attributes:** Temporal allows querying workflow state by custom attributes. Runic could expose this through Store adapters that support secondary indexes.
- **Versioning:** Temporal's workflow versioning for code changes during in-flight executions. This is an open question in Runic's checkpointing proposal (question 3).

### Broadway & GenStage

**Relevant to Runic:**
- **Back-pressure:** GenStage's demand-driven model prevents producers from overwhelming consumers. This is relevant for Runic workflows that produce runnables faster than they can be executed.
- **Batching:** Broadway groups messages into batches for efficient processing. This maps to Runic's Promise model — batch runnables for efficient execution.
- **Pipeline topology:** GenStage's producer → processor → consumer pipeline is a subset of Runic's DAG. A GenStage Executor would model each pipeline stage as a GenStage consumer.

**Integration strategy:**
- A `GenStage` Executor creates a producer-consumer topology where the Worker is the producer (emitting runnables) and the consumers execute them. Back-pressure naturally limits concurrency.
- Broadway could serve as an Executor for workflows processing streams of inputs — each input becomes a Broadway message, and the workflow's runnables execute within Broadway's managed pipeline.

### Synthesis: Runic's Position

Runic occupies a unique position in this landscape:

| System | Core Paradigm | Runtime Assumption | Extensibility |
|--------|--------------|-------------------|---------------|
| Temporal | Event-sourced replay | Server + worker polling | Activity types, interceptors |
| Restate | Journal-based | Server + service handlers | Virtual objects |
| Azure Durable | Orchestrator replay | Azure Functions runtime | Activity functions |
| Oban | Job queue | Postgres + Elixir nodes | Workers, plugins |
| Rivet | Actor model | Rivet platform | Actors, signals |
| **Runic** | **Functional DAG** | **None assumed** | **Behaviours at every layer** |

Runic's differentiator is the absence of runtime assumptions. The workflow is a pure data structure. Execution is separated from scheduling. Every layer — execution, persistence, registry, scheduling — is a pluggable behaviour. This means Runic can _target_ any of the above systems as its execution substrate:

- Use Oban as the Executor → get Oban's durability and Postgres backing
- Use GenStage as the Executor → get back-pressure
- Use the built-in TaskExecutor → get zero-dependency simplicity
- Use a custom Executor → get whatever you need

The Executor and Scheduler Strategy behaviours formalize this "workflow engine that runs anywhere" identity.

---

## Prioritized Roadmap

### Tier 1: High Impact, Low Risk (Near-term)

1. **Executor Behaviour + TaskExecutor extraction** (Phase A)
   - *Why first:* Unblocks all other Executor adapters. Mechanical refactor of existing code. Zero behavioral change.
   - *Effort:* Small — define behaviour, extract existing code, update Worker.
   - *Dependencies:* None.

2. **Worker Hooks** (Phase B)
   - *Why early:* Immediate user value for observability and customization. No architectural risk.
   - *Effort:* Small — add opts to Worker init, call hooks at lifecycle points.
   - *Dependencies:* None.

3. **Per-Component Executor Overrides** (Phase E)
   - *Why early:* Unlocks the `executor` field on policies. Users can mix inline and task execution.
   - *Effort:* Small — add field to SchedulerPolicy, routing logic in Worker.
   - *Dependencies:* Phase A.

### Tier 2: High Impact, Medium Risk (Medium-term)

4. **Promise Model** (Phase C)
   - *Why:* Largest performance improvement for pipeline-style workflows. Core architectural addition.
   - *Effort:* Medium — Promise struct, PromiseBuilder graph analysis, Worker handle_info clause.
   - *Dependencies:* Phase A.

5. **Scheduler Strategy Behaviour + ChainBatching** (Phase D)
   - *Why:* Formalizes the dispatch decision layer. ChainBatching is the first "smart" scheduling strategy.
   - *Effort:* Medium — behaviour definition, chain detection algorithm, integration with Worker.
   - *Dependencies:* Phase C.

6. **Community Executor Adapters** (Phase G)
   - *Why:* Demonstrates extensibility, provides reference implementations, enables production use cases.
   - *Effort:* Per-adapter: Small. GenStage and Oban are the highest-value targets.
   - *Dependencies:* Phase A.

### Tier 3: High Impact, High Complexity (Long-term)

7. **Adaptive Scheduling** (Phase F)
   - *Why:* Self-tuning scheduling reduces manual configuration. Best when profiling data is rich.
   - *Effort:* Medium-High — profiling infrastructure, heuristic tuning, testing.
   - *Dependencies:* Phase D, Phase B (hooks for profiling data collection).

8. **Distribution Primitives** (Phase H)
   - *Why:* Multi-node execution is the endgame for production deployments.
   - *Effort:* High — distributed Executor, topology-aware scheduling, consistency.
   - *Dependencies:* Phases A, D, distributed Store + Registry from existing roadmap.

### Cross-cutting: Incremental Checkpointing Integration

The [Checkpointing Strategies Proposal](checkpointing-strategies-proposal.md) is orthogonal to execution control but intersects at Promise boundaries. Incremental checkpointing (Strategy 2) should be implemented alongside Phase C — Promises need clear checkpoint semantics (checkpoint at Promise completion, not between individual runnables within a Promise).

---

## Open Questions

### Executor Design

1. **Remote Executor dispatch format:** The Executor receives a `work_fn` closure locally, but remote Executors (Oban, distributed) need a serializable representation. Runic's `Closure` module already makes component work functions serializable (AST + bindings + metadata), and Runnable fields are plain data structs. The question is: should remote Executors serialize the full Runnable (including its `Closure`-backed node), or use a lightweight `RunnableRef` that references the workflow ID + node hash and lets the remote side re-prepare from the Store? Full serialization is self-contained but larger; refs are small but require Store access on the remote side.

2. **Executor lifecycle management:** Who starts and supervises Executor-specific processes (GenStage producers, Broadway pipelines, Poolboy pools)? Should the Runner's Supervisor accommodate Executor children, or should the Executor manage its own supervision tree independently? The latter is more flexible but introduces lifecycle coupling — if the Executor's supervisor crashes, the Runner needs to handle it.

3. **Inline execution semantics:** When a runnable executes inline (`:inline` executor or sub-ms adaptive heuristic), should it still go through the PolicyDriver's timeout enforcement? A timeout on an inline call would require a Task wrapper anyway, defeating the purpose. Recommend: inline execution skips timeout but preserves retry/fallback.

### Promise Design

4. **Promise failure semantics:** If the 3rd runnable in a 5-runnable Promise fails (after retries), what happens to runnables 1-2 (already completed) and 4-5 (not yet executed)? Options:
   - **Partial commit:** Apply runnables 1-2, fail 3, skip 4-5. The workflow resumes from step 3 on retry.
   - **All-or-nothing:** Discard all results, fail the entire Promise. The workflow retries from step 1.
   - **Configurable:** Let the Promise's `strategy` field control this. Default: partial commit (matches individual dispatch semantics).

5. **Promise and concurrent mutations:** A Promise operates on a local workflow copy. If another task completes and modifies the source-of-truth workflow while the Promise is running, the Promise's local copy is stale. For linear chains this is fine (no shared state). For Promises that include nodes with `:meta_ref` edges (state machine lookups), this could cause stale reads. Should the Promise builder exclude nodes with `:meta_ref` dependencies, or should we implement a reconciliation step?

6. **Promise observability:** Should Promises be visible in telemetry as a distinct concept, or should they be transparent (only individual runnable events are emitted)? Transparency is simpler but loses scheduling insight. Recommendation: emit `[:runic, :runner, :promise, :start | :stop]` events in addition to per-runnable events.

### Scheduling Strategy

7. **Critical path awareness:** Should the scheduler compute the DAG's critical path and prioritize runnables on it? This is valuable for minimizing end-to-end latency but adds O(V+E) overhead per dispatch cycle. For small workflows this is negligible; for large workflows with thousands of nodes, it might matter. Should it be opt-in via the strategy?

8. **Preemptive vs. reactive Promise construction:** Should the scheduler analyze the full graph ahead of time to construct Promises preemptively (before runnables are even prepared), or should it only analyze the current set of prepared runnables reactively? Preemptive analysis produces better Promises (longer chains) but requires graph analysis that may not reflect runtime conditions (e.g., a condition might not fire, breaking the predicted chain).

### Distribution

9. **State consistency model:** For distributed Executors where tasks run on remote nodes, what consistency guarantee does the workflow state have? Options: eventual consistency (facts may arrive out of order), causal consistency (facts respect ancestry ordering), or strong consistency (linearizable applies). Runic's causal ancestry model naturally supports causal consistency — is that sufficient for most use cases?

10. **Workflow migration:** When a node hosting a Worker drains or crashes, the workflow must migrate. Should migration re-execute the workflow from the log (replay-based), transfer the in-memory state (state transfer), or use the sticky execution + fallback rehydration pattern from the checkpointing proposal? The answer likely varies by deployment — the Store adapter determines what's possible.

### Layering

11. **Opt-in complexity:** The layered model (Executor → Scheduler Strategy → Promise → Worker) introduces many new concepts. How do we ensure users at Layer 4 (standard Runner) never need to think about Promises or Executor behaviours unless they want to? The answer is strong defaults: `TaskExecutor` + `DefaultScheduler` + no Promises. But we need to verify that adding these layers doesn't introduce overhead when they're not used.

12. **Testing surface:** Each layer multiplies the testing matrix. The key combinatorial dimensions are: `{Executor} × {Scheduler Strategy} × {Checkpoint Strategy} × {Store Adapter} × {Workflow Shape}`. Should we define a conformance test suite for each behaviour (like the Store contract tests) that adapter authors can run to verify their implementation?
