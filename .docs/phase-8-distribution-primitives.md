# Phase 8: Distribution Primitives — Architectural Exploration & Implementation Plan

**Status:** Planning  
**Scope:** Distributed workflow execution via native OTP primitives, with Raft-based alternatives as separate packages  
**Dependencies:** Phases 1 (Executor), 5 (Scheduler), Store behaviour  
**Principle:** Runic's value is its expressive model for arbitrary runtime topologies — distribution serves this, not constrains it.

---

## Table of Contents

1. [Why Distribute Runic?](#1-why-distribute-runic)
2. [Distribution Scenarios](#2-distribution-scenarios)
3. [Current Architecture & Extension Points](#3-current-architecture--extension-points)
4. [Native OTP Primitives](#4-native-otp-primitives)
5. [Raft-Based Alternatives (Ra / Khepri)](#5-raft-based-alternatives-ra--khepri)
6. [Trade-off Analysis](#6-trade-off-analysis)
7. [Implementation Plan: Core (OTP Primitives)](#7-implementation-plan-core-otp-primitives)
8. [Implementation Plan: RunicRaft (Separate Package)](#8-implementation-plan-runicraft-separate-package)
9. [Testing Strategy](#9-testing-strategy)
10. [Execution Timeline](#10-execution-timeline)
11. [Open Questions](#11-open-questions)

---

## 1. Why Distribute Runic?

Runic is a dataflow compute engine. The workflow graph is a DAG of pure(ish) functions consuming and producing facts. This model is inherently parallelizable and — by extension — distributable. The reasons to distribute are not about fault tolerance of the workflow engine itself (OTP supervisors already handle that locally), but about **accessing heterogeneous compute resources**:

- **GPU / specialized hardware** — Route ML inference runnables to GPU nodes, data transforms to CPU-optimized nodes.
- **Data locality** — Execute runnables near large input datasets rather than copying data to the Worker.
- **Horizontal throughput** — Fan-out 100,000 runnables across a cluster rather than saturating one node's schedulers.
- **Multi-region** — Execute runnables close to external services they call (API endpoints, databases).
- **Resource isolation** — Run untrusted or resource-intensive runnables on dedicated nodes without impacting the coordinator.

Crucially, **not all workflows need distribution**. The system must remain zero-cost for single-node usage. Distribution is opt-in at the Executor and Scheduler layers, not a fundamental change to how Worker or Workflow operate.

---

## 2. Distribution Scenarios

### Scenario A: Distributed Runnable Execution (Primary)

The Worker stays on one node. Individual runnables (or Promises) are dispatched to remote nodes for execution. Results flow back to the Worker via Erlang distribution. This is the highest-value, lowest-risk scenario.

```
  Node A (Coordinator)              Node B (Compute)           Node C (GPU)
  ┌─────────────────┐              ┌──────────────┐           ┌──────────────┐
  │ Runner           │              │ TaskSupervisor│           │ TaskSupervisor│
  │  └─ Worker       │──dispatch──▶│  └─ Task      │           │  └─ Task      │
  │     (owns wf)    │◀─result────│    (runnable)  │           │    (runnable)  │
  │                  │──dispatch──────────────────────────────▶│               │
  │                  │◀─result──────────────────────────────── │               │
  └─────────────────┘              └──────────────┘           └──────────────┘
```

The Worker owns the workflow state, applies results, manages the dispatch loop. Remote nodes are stateless compute — they run a `work_fn` and return the result. This maps directly to the Executor abstraction.

### Scenario B: Distributed Worker Registration

Workers are registered in a cluster-wide registry so that any node can route `run/3`, `get_results/2`, etc. to the Worker regardless of which node hosts it. This enables:

- Client code on any node can interact with any workflow.
- Workers can be restarted on different nodes after crashes (with Store-based recovery).

```
  Node A                Node B                Node C
  ┌──────────┐         ┌──────────┐          ┌──────────┐
  │ Client    │         │ Worker W1│          │ Worker W2│
  │           │──via──▶│          │          │          │
  │           │         │          │          │          │
  └──────────┘         └──────────┘          └──────────┘
       │                                          ▲
       └──────────────────via─────────────────────┘
```

### Scenario C: Workflow Migration

Move a running workflow from Node A to Node B — drain in-flight tasks, checkpoint to Store, stop Worker on A, resume from Store on B. Relevant for node maintenance, rebalancing, and failure recovery.

### Priority: A ≫ B > C

Scenario A is the primary deliverable. B and C build on A and the Store infrastructure.

---

## 3. Current Architecture & Extension Points

### What Exists

```
Runic.Runner (Supervisor)
├── Store (ETS / Mnesia / custom)
├── Registry (Elixir Registry — local only)
├── TaskSupervisor (Task.Supervisor — local only)
└── WorkerSupervisor (DynamicSupervisor)
    └── Worker (GenServer — owns one workflow)
        ├── Executor (Task / :inline / GenStage)
        ├── Scheduler (Default / ChainBatching / FlowBatch / Adaptive)
        └── Hooks (on_dispatch, on_complete, on_failed, on_idle)
```

### Natural Extension Points

1. **Executor.Distributed** — New executor that dispatches `work_fn` to remote nodes. The Worker already handles async completion via `{ref, result}` and `{:DOWN, ref, ...}` messages. A distributed executor just needs to arrange for those messages to arrive from a remote process.

2. **Runner.via/2** — Currently returns `{:via, Registry, ...}` for local Elixir Registry. Can be extended to use `:pg` or `:global` for cluster-wide lookup.

3. **SchedulerPolicy.executor** — Already supports per-component executor overrides. A policy can set `executor: Runic.Runner.Executor.Distributed, executor_opts: [node_selector: ...]` for specific runnables.

4. **Store** — Already supports event-sourced replay (`append/3`, `stream/2`) and snapshots. A distributed store (Mnesia, Khepri, etc.) enables cross-node recovery.

5. **Hooks** — `transform_runnables` can annotate runnables with node affinity hints before the scheduler sees them.

---

## 4. Native OTP Primitives

### 4.1 `:pg` (Process Groups)

**What it is:** Distributed named process groups with strong eventual consistency. Processes join groups; any node can query group membership. Automatic cleanup on process exit. Part of `kernel` — always available.

**Semantics:**
- Groups are arbitrary terms (atoms, tuples, etc.)
- Membership is eventually consistent across connected nodes (not transitive — requires full mesh or intermediary)
- `get_members/1` returns all members cluster-wide; `get_local_members/1` returns only local
- `monitor/2` subscribes to join/leave notifications for a group
- `monitor_scope/1` subscribes to all group changes in a scope
- Scopes partition the namespace — independent overlay networks

**Runic application — Worker discovery:**

```elixir
# Worker joins a pg group on init
:pg.join(:runic_workers, {:workflow, workflow_id}, self())

# Any node can find the Worker
case :pg.get_members(:runic_workers, {:workflow, workflow_id}) do
  [pid] -> pid
  [] -> :not_found
  [pid | _] -> pid  # multiple = split-brain or migration
end
```

**Runic application — Compute node advertising:**

```elixir
# Compute node advertises its capabilities
:pg.join(:runic_compute, {:capability, :gpu}, self())
:pg.join(:runic_compute, {:capability, :cpu}, self())

# Executor queries for nodes with specific capabilities
gpu_workers = :pg.get_members(:runic_compute, {:capability, :gpu})
```

**Limitations:**
- No data attached to group membership (just PIDs) — capability metadata must be stored elsewhere
- Eventually consistent — concurrent joins/leaves can produce temporarily divergent views
- No leader election — just unordered membership sets
- Requires Erlang distribution (epmd, full mesh, or intermediary like `partisan`)

### 4.2 `:global` (Global Process Registration)

**What it is:** Cluster-wide unique process registration. At most one process per name across all connected nodes. Built into `kernel`.

**Semantics:**
- `register_name/2` — register a process under a globally unique name (blocks until resolved)
- `whereis_name/1` — look up a globally registered process
- Uses a distributed lock protocol — **significantly slower** than local Registry or `:pg`
- On net-split: resolves conflicts via a configurable resolver (default: random kill)

**Runic application — Singleton Workers:**

```elixir
# Register Worker globally (exactly one instance cluster-wide)
:global.register_name({:runic_worker, workflow_id}, self())

# Lookup from any node
:global.whereis_name({:runic_worker, workflow_id})
```

**Limitations:**
- Performance: global name operations require a cluster-wide lock — unsuitable for high-frequency registration
- Split-brain resolution kills one of the conflicting processes — acceptable for Workers (they can recover from Store) but must be handled
- Not suitable for capability discovery (it's 1:1 name→pid, not 1:many)
- Best used sparingly: singleton coordination, not bulk registration

### 4.3 `:erpc` / `:rpc`

**What it is:** Remote procedure call. Execute a function on a remote node and return the result.

**`:erpc` vs `:rpc`:**
- `:erpc` (OTP 23+) — proper error handling, timeouts, no middleman process
- `:rpc` — older, uses a single `rex` GenServer per node (potential bottleneck), less precise errors

**Runic application — Remote execution:**

```elixir
# Execute a work_fn on a remote node
:erpc.call(target_node, fn -> work_fn.() end, timeout)

# Or with better control:
ref = :erpc.send_request(target_node, fn -> work_fn.() end)
# ... do other work ...
result = :erpc.receive_response(ref, timeout)
```

**Limitations:**
- Synchronous (blocks caller) unless using `send_request` / `receive_response`
- No monitoring of the remote process — if the remote node dies mid-execution, you get `{:EXIT, ...}` or timeout
- Large data must be copied across the network (ETF serialization)

### 4.4 `:net_kernel.monitor_nodes/1`

**What it is:** Subscribe to `{:nodeup, node}` and `{:nodedown, node}` messages.

**Runic application:** Detect when compute nodes join/leave the cluster. Update routing tables, rebalance work.

### 4.5 `Node.spawn_monitor/4`

**What it is:** Spawn a process on a remote node and monitor it from the local node. The monitor fires `{:DOWN, ref, :process, pid, reason}` — exactly what the Worker's existing `handle_info({:DOWN, ...})` expects.

**This is the key primitive for `Executor.Distributed`.** It naturally produces the same messages as `Task.Supervisor.async_nolink`:

```elixir
{pid, ref} = Node.spawn_monitor(target_node, fn ->
  result = work_fn.()
  send(caller, {ref, result})  # ... but ref isn't known yet
end)
```

The challenge: `ref` isn't known until `spawn_monitor` returns, but the spawned function needs to send `{ref, result}`. Solution: use a relay ref.

### 4.6 Summary: What Native OTP Gives Us

| Need | Primitive | Consistency | Performance |
|---|---|---|---|
| Worker lookup (cluster-wide) | `:pg` | Eventually consistent | Fast reads |
| Worker singleton guarantee | `:global` | Strong (lock-based) | Slow writes |
| Compute node discovery | `:pg` | Eventually consistent | Fast reads |
| Remote execution | `:erpc` / `Node.spawn_monitor` | N/A (execution) | Network-bound |
| Node membership changes | `:net_kernel.monitor_nodes` | Reliable | Async notifications |
| Capability metadata | ETS + `:pg` join/leave events | Per-node local | Very fast reads |

---

## 5. Raft-Based Alternatives (Ra / Khepri)

### 5.1 Ra Overview

[Ra](https://github.com/rabbitmq/ra) is RabbitMQ's Raft consensus library for Erlang. Key properties:

- **Replicated state machine**: All state changes go through the Raft log. Every member applies the same sequence of commands deterministically.
- **Strong consistency**: Writes require majority quorum. Reads can be linearizable (`consistent_query`) or local (`local_query`).
- **Effect system**: State machine's `apply/3` returns `{new_state, reply, effects}` — effects are side effects (send messages, monitor processes, set timers) executed only on the leader. Clean separation of deterministic state from side effects.
- **Shared WAL**: Thousands of Ra clusters can run on a single node with one shared write-ahead log.
- **State machine versioning**: Safe rolling upgrades via `version/0` + `which_module/1` callbacks.
- **Process monitoring**: Leader can monitor remote processes; delivers `{down, pid, reason}` as a committed command — crash handling is consistent across replicas.

### 5.2 Khepri Overview

[Khepri](https://github.com/rabbitmq/khepri) is a tree-structured distributed database built on Ra:

- **Hierarchical namespace**: Paths like `[:runic, :workers, workflow_id]` — natural fit for workflow/runnable state.
- **CRUD + transactions**: `put`, `get`, `delete`, `compare_and_swap`, read-write transactions (executed inside the Raft state machine via bytecode extraction).
- **Projections**: ETS-backed read replicas of tree subsets — ultra-low-latency local reads, eventually consistent with writes.
- **Keep-while conditions**: Ephemeral nodes that auto-delete when a condition becomes false — like ZooKeeper ephemeral znodes.
- **Triggers & stored procedures**: Event-driven callbacks on tree mutations.
- **Consistency modes**: `favor: :low_latency` (local read) or `favor: :consistency` (fenced read via leader heartbeat).

### 5.3 ra-registry

[ra-registry](https://github.com/eliasdarruda/ra-registry) demonstrates building a distributed Registry on Ra:

- Implements Elixir's `:via` protocol — `GenServer.start_link(name: {:via, RaRegistry, {reg, key}})`
- State machine is a simple map `%{unique: %{key => {pid, value}}, duplicate: ...}`
- Process death cleanup via `{:process_down, pid}` commands through the Raft log
- Consistent reads via `ra:consistent_query/2`
- One Ra cluster for the entire registry

**Key insight from ra-registry:** Process monitoring must be done via Ra effects (leader monitors, `{down, pid, reason}` becomes a committed command), not via the Manager process. ra-registry takes a shortcut (Manager monitors locally, fires command on DOWN) — this works but isn't strictly correct during leader changes.

### 5.4 What Raft Gives That OTP Primitives Don't

| Property | `:pg` / `:global` | Ra / Khepri |
|---|---|---|
| **Consistency** | Eventually consistent (pg) / lock-based (global) | Linearizable (Raft quorum) |
| **State machine** | None (just membership) | Custom replicated state with deterministic transitions |
| **Durable coordination** | No (in-memory only) | Yes (WAL + snapshots on disk) |
| **Workflow state as coordination data** | Must store externally | Can embed workflow metadata in the replicated state |
| **Split-brain safety** | pg diverges; global picks a winner | Minority partition is read-only, majority continues |
| **Transaction support** | None | Read-write transactions with atomicity |
| **Process lifecycle** | pg auto-removes on exit; global deregisters | Ra monitors + committed cleanup commands |
| **Leader election** | Manual via :global or custom | Built-in (Raft) |
| **Dependencies** | Zero (OTP stdlib) | `ra` (and `khepri` for the tree store) |

### 5.5 When Each Makes Sense

**Use OTP primitives when:**
- Workflows are not mission-critical coordination (e.g., data pipelines where retry-from-Store is acceptable)
- The cluster is stable (low churn, trusted network)
- Eventual consistency for Worker discovery is fine (the Worker exists or doesn't — stale reads just cause a retry)
- You want zero external dependencies

**Use Ra/Khepri when:**
- Workflow execution is a coordination primitive itself (e.g., saga orchestration, distributed transactions)
- Exactly-once execution semantics are required across nodes
- Split-brain scenarios must be handled correctly (financial, compliance)
- You need durable coordination state that survives full cluster restarts
- You want atomic claim-and-execute semantics (only one node runs a runnable)

---

## 6. Trade-off Analysis

### 6.1 Distributed Executor: `:erpc` + `Node.spawn_monitor` vs. Ra

**For remote runnable execution**, Ra is overkill. The Worker already has:
- A durable event log (Store) that records what was dispatched and what completed
- Retry policies (SchedulerPolicy) for handling failures
- Idempotent `apply_runnable` — re-applying a completed runnable is safe

The coordination question is simple: "run this function on that node, tell me when it's done." This is `:erpc.send_request` or `Node.spawn_monitor` territory. If the remote node dies, the Worker gets `{:DOWN, ...}` and retries per policy — same as local Task crashes.

**Recommendation: Use `:erpc` / spawn_monitor for Executor.Distributed (core).** Reserve Ra for the coordination layer (RunicRaft package) where atomic claim semantics matter.

### 6.2 Worker Discovery: `:pg` vs. `:global` vs. Ra-Registry

| Approach | Uniqueness guarantee | Read perf | Write perf | Deps |
|---|---|---|---|---|
| `:pg` | None (multiple members OK) | Very fast | Fast | Zero |
| `:global` | Strong (one per name) | Fast | Slow (lock) | Zero |
| Ra-Registry | Strong (Raft quorum) | Consistent or local | Moderate (Raft) | `ra` |
| Local Registry (current) | Per-node unique | Very fast | Very fast | Zero |

For Scenario B (distributed Worker registration):

- **`:pg`** is the right default. Workers join a pg group on init. Lookup returns a PID list — if there's exactly one, route to it. If there are zero, the workflow isn't running. If there are multiple, it's a migration/split-brain scenario — pick one (or error).
- **`:global`** can optionally wrap the Worker start to guarantee singleton — `GenServer.start_link(name: {:global, {:runic_worker, id}})`. Useful when exactly-one semantics matter.
- **Ra-Registry** is the Raft-based option for mission-critical uniqueness. Separate package.

**Recommendation: `:pg` as default, `:global` as opt-in singleton mode, Ra-Registry as separate package.**

### 6.3 Compute Node Discovery

Compute nodes need to advertise capabilities (`:gpu`, `:high_memory`, custom tags). `:pg` groups are ideal — each compute node joins capability groups, and the Executor queries `get_members/2` to find candidates.

```elixir
# Compute node
:pg.join(:runic_compute, :gpu, self())
:pg.join(:runic_compute, :cpu, self())

# Executor node_selector
fn runnable, _opts ->
  caps = required_capabilities(runnable)
  candidates = Enum.flat_map(caps, &:pg.get_members(:runic_compute, &1))
  pick_best(candidates)
end
```

Capability metadata (current load, memory, etc.) can be stored in a local ETS table per compute node, queried via `:erpc.call(node, fn -> :ets.lookup(...) end)` when the Executor needs fresh data for routing decisions. This is the Handoff pattern — no shared state for metadata, just lazy RPC reads.

### 6.4 Data Transfer

The biggest cost in distributed execution is copying fact data across the network. Strategies:

1. **Copy on dispatch** (simple): Serialize the Runnable (including input facts) and send to the remote node. Works for small-to-medium facts. This is what Executor.Distributed does by default.

2. **Reference + fetch** (Handoff pattern): Send only fact references (hashes). Remote node fetches values from the Store or the originating node on demand. Better for large facts, but adds latency.

3. **Data locality routing** (smart): Route the runnable to the node where its input facts already reside. Requires tracking fact locations — fits naturally with `:pg` groups (facts produced on Node B → route downstream runnables to Node B).

**Recommendation: Start with (1). Add (3) as a Scheduler strategy option.**

---

## 7. Implementation Plan: Core (OTP Primitives)

### Phase 8A: Executor.Distributed

**Goal:** Dispatch individual runnables to remote nodes for execution. The Worker handles completion/failure via existing message patterns.

**Key design:** Use `Node.spawn_monitor/2` on the target node to get a monitored process. The spawned process executes `work_fn`, sends `{ref, result}` back to the Worker, and exits. If it crashes, the Worker receives `{:DOWN, ref, :process, pid, reason}` — identical to the local Task contract.

```
  Worker (Node A)                        Compute (Node B)
  ┌──────────────────┐                  ┌────────────────────┐
  │ dispatch(work_fn) │                  │                    │
  │   │               │                  │                    │
  │   ├─ ref = make_ref()               │                    │
  │   ├─ Node.spawn_monitor(B, fn ->    │                    │
  │   │    result = work_fn.()  ────────▶│  execute work_fn   │
  │   │    send(caller, {ref, result}) ◀─│  send result back  │
  │   │  end)                            │                    │
  │   │                │                  │                    │
  │   ◀─ {ref, result} │ ◀ ◀ ◀ ◀ ◀ ◀ ◀ ◀ │                    │
  │   or                                 │                    │
  │   ◀─ {:DOWN, mon, :process, pid, r}  │  (on crash)        │
  └──────────────────┘                  └────────────────────┘
```

#### Deliverables

1. **`Runic.Runner.Executor.Distributed`** (`lib/runic/runner/executor/distributed.ex`)

   ```elixir
   defmodule Runic.Runner.Executor.Distributed do
     @behaviour Runic.Runner.Executor
     
     @impl true
     def init(opts) do
       node_selector = Keyword.fetch!(opts, :node_selector)
       pg_scope = Keyword.get(opts, :pg_scope, :runic_compute)
       fallback = Keyword.get(opts, :fallback, :local)
       
       {:ok, %{
         node_selector: node_selector,
         pg_scope: pg_scope,
         fallback: fallback
       }}
     end
     
     @impl true
     def dispatch(work_fn, opts, state) do
       caller = self()
       ref = make_ref()
       target = select_node(state, opts)
       
       {_pid, monitor_ref} = Node.spawn_monitor(target, fn ->
         try do
           result = work_fn.()
           send(caller, {ref, result})
         catch
           kind, reason ->
             send(caller, {:DOWN, ref, :process, self(), {kind, reason}})
         end
       end)
       
       # Map monitor_ref to our ref for the Worker
       # Worker receives {ref, result} or {:DOWN, monitor_ref, ...}
       # Need to handle both refs — see design notes below
       {ref, Map.put(state, {:monitor, monitor_ref}, ref)}
     end
   end
   ```

   **Design note — ref mapping:** `Node.spawn_monitor/2` returns `{pid, monitor_ref}`. The spawned process sends `{ref, result}` (our custom ref). If the process crashes before sending, we get `{:DOWN, monitor_ref, ...}` with the monitor's ref, not ours. The Executor must maintain a mapping `monitor_ref → ref` and the Worker must handle both. Alternative: use `make_ref()` before spawning, pass it into the closure, and translate `{:DOWN, monitor_ref, ...}` into `{:DOWN, ref, ...}` via a relay. This keeps the Worker's `handle_info` unchanged.

2. **Node selector** — A function `(keyword() -> node())` passed as `:node_selector` in executor opts. Built-in selectors:

   - `Runic.Runner.Executor.Distributed.random(pg_scope, group)` — random member from a `:pg` group
   - `Runic.Runner.Executor.Distributed.round_robin(pg_scope, group)` — round-robin across group members
   - `Runic.Runner.Executor.Distributed.local_first(pg_scope, group)` — prefer `get_local_members`, fall back to any member

3. **Fallback behavior** — When no remote nodes are available:
   - `:local` (default) — execute locally via `Task.Supervisor.async_nolink` 
   - `:error` — return `{:error, :no_nodes_available}`

4. **Compute node setup** — A compute node needs only a running `Task.Supervisor` (or `Runic.Runner.ComputeNode` supervisor) to accept work. The `work_fn` closure carries all dependencies (runnable data, policy driver logic). No Runic.Runner or Workflow needed on compute nodes.

   ```elixir
   # On compute node startup (minimal)
   children = [
     {Task.Supervisor, name: Runic.ComputeNode.TaskSupervisor}
   ]
   Supervisor.start_link(children, strategy: :one_for_one)
   ```

   **Enhanced version** using `Task.Supervisor` on the remote node instead of bare `spawn_monitor`:

   ```elixir
   # In dispatch/3, instead of Node.spawn_monitor:
   task = Task.Supervisor.async_nolink(
     {Runic.ComputeNode.TaskSupervisor, target_node},
     fn -> work_fn.() end
   )
   {task.ref, state}
   ```

   This is simpler and matches the Task executor's contract exactly. `Task.Supervisor.async_nolink/2` already works cross-node when given `{supervisor_name, node}`. **This is the recommended approach.**

#### Ref-mapping Simplification via Remote Task.Supervisor

Using `Task.Supervisor.async_nolink({supervisor_name, target_node}, work_fn)` eliminates the ref-mapping problem entirely. The returned `%Task{ref: ref}` is the same ref that appears in both `{ref, result}` and `{:DOWN, ref, :process, pid, reason}` messages. The Worker's existing `handle_info` clauses handle these without modification.

**This means `Executor.Distributed` is essentially `Executor.Task` with a configurable target node.** The simplicity is the point — it means all existing Worker code, retry logic, timeout handling, promise dispatch, and hook invocation work unchanged.

```elixir
@impl true
def dispatch(work_fn, _opts, state) do
  target = select_node(state)
  supervisor = {state.remote_supervisor, target}
  task = Task.Supervisor.async_nolink(supervisor, work_fn)
  {task.ref, state}
end
```

### Phase 8B: Cluster Awareness

**Goal:** Workers and compute nodes discover each other via `:pg`. Workers optionally register globally for cluster-wide lookup.

#### Deliverables

1. **`:pg` scope startup** — Add optional `:pg` scope to Runner supervisor tree.

   ```elixir
   # In Runner.init/1, if distributed: true
   children = [
     %{id: :pg_scope, start: {:pg, :start_link, [:runic_workers]}},
     # ... existing children ...
   ]
   ```

2. **Worker pg registration** — On Worker init, join a `:pg` group:

   ```elixir
   # In Worker.init/1, if runner is distributed
   :pg.join(:runic_workers, {:workflow, workflow_id}, self())
   ```

   On terminate, `:pg` auto-removes the PID. No explicit leave needed.

3. **Distributed lookup** — New `Runic.Runner.lookup/2` path:

   ```elixir
   def lookup(runner, workflow_id) do
     # Try local registry first (fast path)
     case local_lookup(runner, workflow_id) do
       pid when is_pid(pid) -> pid
       nil ->
         # Fall back to pg (distributed)
         case :pg.get_members(:runic_workers, {:workflow, workflow_id}) do
           [pid | _] -> pid
           [] -> nil
         end
     end
   end
   ```

4. **`Runic.Runner.ComputeNode`** — Minimal supervisor for remote compute nodes:

   ```elixir
   defmodule Runic.Runner.ComputeNode do
     use Supervisor
     
     def start_link(opts) do
       Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
     end
     
     def init(opts) do
       pg_scope = Keyword.get(opts, :pg_scope, :runic_compute)
       capabilities = Keyword.get(opts, :capabilities, [:cpu])
       
       children = [
         {Task.Supervisor, name: Runic.ComputeNode.TaskSupervisor},
         {Runic.Runner.ComputeNode.Advertiser, 
           pg_scope: pg_scope, capabilities: capabilities}
       ]
       
       Supervisor.init(children, strategy: :one_for_one)
     end
   end
   ```

5. **Capability Advertiser** — GenServer that joins `:pg` groups for each capability:

   ```elixir
   defmodule Runic.Runner.ComputeNode.Advertiser do
     use GenServer
     
     def init(opts) do
       scope = opts[:pg_scope]
       for cap <- opts[:capabilities] do
         :pg.join(scope, {:capability, cap}, self())
       end
       {:ok, opts}
     end
   end
   ```

### Phase 8C: Distributed Scheduler Strategy

**Goal:** Topology-aware scheduling that routes runnables to appropriate nodes based on capabilities, data locality, and load.

#### Deliverables

1. **`Runic.Runner.Scheduler.Distributed`** — Extends existing scheduler to annotate dispatch units with target node hints:

   ```elixir
   defmodule Runic.Runner.Scheduler.Distributed do
     @behaviour Runic.Runner.Scheduler
     
     @impl true
     def plan_dispatch(workflow, runnables, state) do
       # Delegate structural analysis to ChainBatching/FlowBatch
       {units, state} = state.inner_scheduler.plan_dispatch(
         workflow, runnables, state.inner_state
       )
       
       # Annotate units with node affinity
       annotated = Enum.map(units, &annotate_node_hint(&1, state))
       {annotated, state}
     end
   end
   ```

   **Open question:** How to pass node hints from Scheduler to Executor. Options:
   - Add `:node_hint` to dispatch_opts (second arg to `Executor.dispatch/3`)
   - The Executor's `node_selector` function receives the runnable and can inspect annotations
   - Use `SchedulerPolicy` per-node executor_opts to carry hints

   **Recommendation:** Use dispatch_opts. The Worker already passes `[]` as opts to `Executor.dispatch/3`. The Scheduler can return `{:runnable, r, opts}` as an extended dispatch unit type, and the Worker passes those opts through. This is a minor Worker change.

2. **Node affinity strategies:**

   - **Capability match** — Route runnables to nodes with required capabilities (GPU, high-memory, etc.). Capabilities come from SchedulerPolicy metadata or the workflow node's metadata.
   - **Sticky execution** — Prefer the node where the workflow's Worker runs (data locality).
   - **Load-aware** — Query compute node load via `:erpc.call(node, :erlang, :statistics, [:run_queue])` and route to least-loaded.

### Phase 8D: Workflow Migration

**Goal:** Move a running workflow from one node to another. Depends on Store infrastructure.

#### Deliverables

1. **Drain** — Stop accepting new inputs, wait for in-flight tasks to complete or timeout.

   ```elixir
   def handle_call(:drain, from, state) do
     if map_size(state.active_tasks) == 0 do
       {:reply, :ok, %{state | status: :draining}}
     else
       {:noreply, %{state | status: :draining, drain_from: from}}
     end
   end
   ```

2. **Checkpoint + stop** — After drain, persist final state and stop.

3. **Resume on new node** — Use existing `Runner.resume/3` on the target node. The Store must be accessible from both nodes (distributed Store like Mnesia, or external like Postgres).

4. **Coordinate via `:pg`** — The old Worker leaves the pg group on stop. The new Worker joins on start. Clients monitoring the pg group see the transition.

This is straightforward given the existing Store infrastructure. The hard part is the distributed Store, which is already an optional capability.

### Phase 8E: Node Failure Handling

**Goal:** Handle compute node crashes gracefully.

This is largely already handled:

1. **Compute node dies mid-execution:** Worker receives `{:DOWN, ref, :process, pid, :noconnection}`. Existing `handle_info({:DOWN, ...})` marks the runnable as failed. Retry policy kicks in — next dispatch may route to a different node.

2. **Coordinator node dies:** Workers restart under their Runner supervisor (or are manually resumed from Store on a different node).

3. **Net-split:** `:pg` membership diverges. Workers may be unreachable. After reconnection, `:pg` merges membership. Stale lookups return `{:error, :not_found}` — retry.

**New handling needed:**
- `:net_kernel.monitor_nodes/1` subscription in the Distributed Executor to proactively mark in-flight tasks on dead nodes as failed (rather than waiting for individual `:DOWN` messages).
- Configurable behavior: retry on same node vs. retry on any available node.

---

## 8. Implementation Plan: RunicRaft (Separate Package)

**Package:** `runic_raft` — depends on `ra` (and optionally `khepri`)  
**Goal:** Provide Raft-backed coordination for scenarios requiring strong consistency guarantees.

### 8R-A: Raft-Based Distributed Registry

A Ra state machine that tracks `{workflow_id => {node, pid, status}}` with linearizable reads and writes.

```elixir
defmodule RunicRaft.Registry.StateMachine do
  @behaviour :ra_machine
  
  def init(_config), do: %{workflows: %{}, claims: %{}}
  
  def apply(_meta, {:register, workflow_id, node, pid}, state) do
    case state.workflows do
      %{^workflow_id => _existing} ->
        {state, {:error, :already_registered}}
      _ ->
        state = put_in(state, [:workflows, workflow_id], %{node: node, pid: pid})
        effects = [{:monitor, :process, pid}]
        {state, :ok, effects}
    end
  end
  
  def apply(_meta, {:down, pid, _reason}, state) do
    # Remove all registrations for this pid
    workflows = for {id, %{pid: ^pid}} <- state.workflows, into: %{}, do: {id, nil}
    state = %{state | workflows: Map.drop(state.workflows, Map.keys(workflows))}
    {state, :ok}
  end
  
  def state_enter(:leader, state) do
    # Re-issue monitors for all registered pids
    for {_id, %{pid: pid}} <- state.workflows, do: {:monitor, :process, pid}
  end
  def state_enter(_, _), do: []
end
```

**Key differences from ra-registry:**
- `state_enter/2` re-issues monitors on leader change (ra-registry doesn't do this)
- `apply/3` is pure — no `distributed_alive?` side effects inside the state machine
- Workflow-specific commands: `{:claim_runnable, ...}`, `{:complete_runnable, ...}` for distributed work claiming

### 8R-B: Khepri Store Adapter

Implement `Runic.Runner.Store` backed by Khepri for strongly-consistent distributed workflow state.

```elixir
defmodule RunicRaft.Store.Khepri do
  @behaviour Runic.Runner.Store
  
  def init_store(opts) do
    store_id = Keyword.get(opts, :store_id, :runic_store)
    {:ok, %{store_id: store_id}}
  end
  
  def append(workflow_id, events, state) do
    :khepri.transaction(state.store_id, fn ->
      path = [:runic, :workflows, workflow_id, :events]
      existing = case khepri_tx:get(path) do
        {:ok, events} -> events
        _ -> []
      end
      :ok = khepri_tx:put(path, existing ++ events)
    end)
  end
  
  def stream(workflow_id, state) do
    case :khepri.get(state.store_id, [:runic, :workflows, workflow_id, :events]) do
      {:ok, events} -> {:ok, events}
      _ -> {:error, :not_found}
    end
  end
  
  # Fact storage maps naturally to Khepri's tree:
  # [:runic, :facts, fact_hash] => value
  def save_fact(fact_hash, value, state) do
    :khepri.put(state.store_id, [:runic, :facts, fact_hash], value)
  end
  
  def load_fact(fact_hash, state) do
    case :khepri.get(state.store_id, [:runic, :facts, fact_hash]) do
      {:ok, value} -> {:ok, value}
      _ -> {:error, :not_found}
    end
  end
end
```

**Value proposition:** Khepri gives you a distributed, durable, consistent Store with no external infrastructure (no Postgres, no Redis). The entire cluster state lives in the Ra WAL. Recovery is automatic — restart any node and it replays from its log or receives a snapshot from the leader.

**Trade-offs:**
- All state is in-memory on every node (Ra replicates the full state machine). Not suitable for workflows with very large fact values — use `save_fact`/`load_fact` to keep only hashes in the event stream.
- Write throughput is bounded by Raft consensus (majority quorum per write). Fine for workflow coordination, but not for high-frequency fact storage.
- Requires `ra` and `khepri` as dependencies.

### 8R-C: Distributed Work Claiming

For workflows where exactly-once execution across a cluster is critical (e.g., saga orchestration), a Ra state machine can provide atomic claim semantics:

```
Worker A: "I want to execute runnable X"  ──▶ Ra leader
Worker B: "I want to execute runnable X"  ──▶ Ra leader
Ra: commits {claim, X, A} first → A wins, B gets {:error, :already_claimed}
```

This is not needed for Scenario A (one Worker owns the workflow) but becomes relevant when multiple Workers coordinate on a shared workflow.

---

## 9. Testing Strategy

### 9.1 Multi-Node Test Infrastructure

Use `:peer` (OTP 25+) to stand up ephemeral test nodes:

```elixir
defmodule Runic.Runner.ClusterCase do
  use ExUnit.CaseTemplate
  
  setup do
    # Start peer nodes
    {:ok, peer1, node1} = :peer.start(%{name: :compute1})
    {:ok, peer2, node2} = :peer.start(%{name: :compute2})
    
    # Load Runic code on peer nodes
    :peer.call(peer1, :code, :add_paths, [:code.get_path()])
    :peer.call(peer2, :code, :add_paths, [:code.get_path()])
    
    # Start ComputeNode supervisor on peers
    :peer.call(peer1, Runic.Runner.ComputeNode, :start_link, [[capabilities: [:cpu]]])
    :peer.call(peer2, Runic.Runner.ComputeNode, :start_link, [[capabilities: [:gpu]]])
    
    on_exit(fn ->
      :peer.stop(peer1)
      :peer.stop(peer2)
    end)
    
    %{nodes: [node1, node2], peers: [peer1, peer2]}
  end
end
```

### 9.2 Test Categories

1. **Executor.Distributed unit tests**
   - Dispatch to remote node, result returns to calling process
   - Remote node crash → Worker receives `:DOWN`, retries per policy
   - No available nodes → fallback to local execution
   - Node selector strategies (random, round-robin, local-first)

2. **Cluster integration tests**
   - Two-node cluster: workflow dispatches runnables to remote node, applies results, reaches completion
   - Node-down during execution: in-flight tasks fail, Worker retries
   - Mixed executor: some runnables local, some remote (via SchedulerPolicy)
   - Promise dispatch across nodes: sequential Promise runs on remote node

3. **pg integration tests**
   - Worker registers in pg group on init, deregisters on stop
   - Distributed lookup finds Workers on other nodes
   - ComputeNode advertises capabilities, Executor discovers them

4. **Behavioral equivalence tests**
   - Same workflow produces identical results whether executed locally or distributed
   - Compare event streams from local vs. distributed execution

5. **Stress tests**
   - Fan-out 10,000 runnables across 4 compute nodes
   - Measure latency overhead of distributed vs. local dispatch
   - Intermittent node failures during large workflow execution

### 9.3 RunicRaft Tests (separate package)

- Ra state machine unit tests (deterministic, no network)
- Three-node Ra cluster: workflow registration, lookup, deregistration
- Leader failover: registered workflows remain accessible after new leader election
- Khepri Store adapter: append/stream/save_fact/load_fact round-trips
- Split-brain simulation: minority partition cannot write, majority continues

---

## 10. Execution Timeline

```
Phase 8A (Executor.Distributed) ─────── Primary deliverable
    │                                    - Node selector + pg discovery
    │                                    - Remote Task.Supervisor dispatch
    │                                    - Fallback to local
    │
Phase 8B (Cluster Awareness) ────────── Parallel with 8A
    │                                    - pg scope in Runner
    │                                    - Worker pg registration
    │                                    - ComputeNode supervisor
    │                                    - Distributed lookup
    │
Phase 8C (Distributed Scheduler) ────── After 8A
    │                                    - Node hint annotations
    │                                    - Capability matching
    │                                    - Load-aware routing
    │
Phase 8D (Workflow Migration) ───────── After 8B
    │                                    - Drain + checkpoint + resume
    │                                    - Requires distributed Store
    │
Phase 8E (Node Failure Handling) ────── After 8A + 8B
                                         - net_kernel monitoring
                                         - Proactive failure detection

--- Separate package ---

8R-A (Raft Registry) ────────────────── Independent
    │
8R-B (Khepri Store) ────────────────── Independent
    │
8R-C (Distributed Claiming) ────────── After 8R-A
```

**Tier 1 (8A + 8B):** Can begin immediately. These are independent and can be worked in parallel. 8A is the highest-value deliverable.

**Tier 2 (8C + 8E):** After 8A. 8C enhances routing intelligence. 8E hardens failure handling.

**Tier 3 (8D):** After 8B. Requires a distributed Store implementation to be useful.

**RunicRaft (8R-*):** Independent track. Can begin anytime. No dependency on core phases.

---

## 11. Open Questions

### Q1: work_fn Serialization

The Executor dispatches a `work_fn` closure. For local dispatch, closures work because they share the same BEAM. For remote dispatch via `Task.Supervisor.async_nolink({sup, node}, work_fn)`, the closure is sent over Erlang distribution — this works if:
- The modules referenced by the closure exist on the remote node (same code deployed)
- The closure doesn't capture large terms (they're copied over the network)

**For homogeneous clusters** (same code on all nodes), this works out of the box. For heterogeneous clusters (compute nodes with only a subset of the code), we may need to send `{module, function, args}` tuples instead of closures. **Resolution: Start with homogeneous assumption. Document the requirement.**

### Q2: Large Fact Transfer

When runnables have large input facts (e.g., images, datasets), copying them in the closure is expensive. Options:
- Embed fact references (hashes) and have the compute node fetch from a distributed Store
- Use a distributed cache (`:pg`-based fact registry + lazy fetch)
- Stream facts via TCP/UDP outside of Erlang distribution

**Resolution: Defer to Phase 8C. Start with closure-based transfer. Add fact-reference mode as an optimization.**

### Q3: Dispatch Unit Extension

Should `dispatch_unit` be extended to carry node hints? Currently `{:runnable, Runnable.t()} | {:promise, Promise.t()}`. Options:
- `{:runnable, Runnable.t(), keyword()}` — opts including `:target_node`
- Runnable metadata field — already exists, could carry hints
- Separate dispatch plan struct

**Resolution: Extend dispatch_opts (the `opts` arg in `Executor.dispatch/3`). The Scheduler returns hints in the dispatch unit, and the Worker extracts and passes them to the Executor. Minimal change.**

### Q4: pg Scope Naming

What scope name for Runic's pg groups? Options:
- `:runic` — simple, one scope for everything
- `:runic_workers` + `:runic_compute` — separate scopes for worker discovery and compute node discovery
- Per-runner scopes — `Module.concat(runner, :pg_scope)` — isolates runners

**Resolution: Start with a single `:runic` scope. Groups within the scope provide sufficient namespacing (e.g., `{:workflow, id}`, `{:capability, :gpu}`). Add per-runner scopes if needed for isolation.**

### Q5: Compute Node Code Loading

Must compute nodes have the full Runic codebase? With closure-based dispatch, yes — the closure references Runic modules (`PolicyDriver`, `Runnable`, etc.). Options:
- **Full deploy** — same code everywhere. Simplest, recommended.
- **Thin compute nodes** — only core Runic modules + user workflow modules. Requires careful dependency analysis.
- **Code-on-demand** — use `:rpc.call(coordinator, :code, :get_object_code, [Module])` to load modules dynamically on compute nodes. Fragile but useful for dev/testing.

**Resolution: Full deploy as the documented approach. Thin compute nodes as a future optimization.**

### Q6: Relationship to LiveView / Phoenix

Runic workflows running in a Phoenix application may want to push results to LiveView clients regardless of which node executed the runnable. This is already handled by Phoenix.PubSub (which uses `:pg` internally). Document the pattern: Worker hooks publish to PubSub on completion.

---

## Appendix A: Handoff Pattern Analysis

[polvalente/handoff](https://github.com/polvalente/handoff) demonstrates distributed DAG execution using only OTP stdlib. Key patterns relevant to Runic:

1. **Orchestrator = caller node** — No leader election. The node that starts the DAG is the coordinator. Maps to Runic's "Worker owns the workflow" model.

2. **Results stay where produced** — Each node has a local ETS-based result store. Cross-node reads are lazy `:rpc.call` fetches with local caching. Maps to Runic's fact storage model.

3. **Data location registry** — Local GenServer on the orchestrator tracks `{dag_id, data_id} => node`. Workers `:rpc` back to the orchestrator for data lookups. Runic equivalent: the Worker knows which facts are on which nodes via the event log.

4. **Serialization as DAG nodes** — Handoff injects synthetic `:serialize` / `:deserialize` nodes at cross-node data boundaries. Runic could do something similar with the `Transmutable` protocol — auto-insert serialization steps when a runnable's policy routes it to a different node than its producer.

5. **Resource tracking** — Pluggable `ResourceTracker` behaviour with ETS-backed default. Process monitoring for automatic resource release on crash. Maps to Runic's capability-based routing via `:pg` groups.

6. **Zero external dependencies** — Everything built on OTP stdlib. Validates the approach for Runic core.

**Differences from Runic:**
- Handoff is batch/offline (one-shot DAG execution). Runic is live/reactive (continuous workflow with events).
- Handoff has no persistence/recovery. Runic has the Store.
- Handoff's allocator is greedy first-fit. Runic's Scheduler is pluggable and can be adaptive.
- Handoff uses `:rpc.call` (blocking) for all coordination. Runic should prefer `Task.Supervisor.async_nolink` (non-blocking, monitored).

## Appendix B: Ra/Khepri Architecture Summary

### Ra (Raft Consensus)

- **Server ID**: `{name :: atom(), node :: node()}` — stable registered name, not PID
- **State machine**: `init/1` → initial state; `apply/3` → `{new_state, reply, effects}` — must be pure and deterministic
- **Effects**: Side effects returned from `apply/3`, executed only on leader. Key effects: `{send_msg, to, msg}`, `{monitor, process, pid}`, `{timer, name, ms}`, `{release_cursor, idx, state}` (trigger snapshot)
- **Queries**: `local_query/2` (stale OK), `leader_query/2`, `consistent_query/2` (linearizable)
- **Shared WAL**: All Ra clusters on a node share one write-ahead log — enables thousands of clusters per node
- **State enter**: `state_enter/2` callback fires on role change (follower → leader, etc.) — re-issue monitors here
- **Versioning**: `version/0` + `which_module/1` for safe rolling upgrades

### Khepri (Tree-Structured Store on Ra)

- **Data model**: Hierarchical paths `[:a, :b, :c]` → values
- **Operations**: `put`, `get`, `delete`, `compare_and_swap`, `transaction/2`
- **Transactions**: Anonymous functions extracted via Horus (bytecode), executed deterministically inside the state machine
- **Projections**: ETS-backed materialized views of tree subsets — read locally, eventually consistent with writes
- **Keep-while**: Ephemeral nodes with lifecycle conditions (auto-delete when condition fails)
- **Consistency**: Writes always go through Raft quorum. Reads configurable: `favor: :low_latency` vs `favor: :consistency`

### Application to Runic

| Runic Need | Ra Approach | Khepri Approach |
|---|---|---|
| Worker registry | Ra state machine tracking `{wf_id => {node, pid}}` | `khepri:put([:workers, wf_id], %{node: n, pid: p})` |
| Workflow state | Events as Ra commands | Events appended to `[:workflows, wf_id, :events]` |
| Fact storage | Ra too heavyweight for blob storage | `khepri:put([:facts, hash], value)` — but in-memory on all nodes |
| Work claiming | `{:claim, runnable_id, worker_pid}` command | Transaction: read + write atomically |
| Failure detection | Ra monitors (leader tracks pids) | Khepri keep-while conditions |
| Configuration | Store scheduler policies in Ra | `khepri:put([:config, wf_id, :policies], policies)` |
