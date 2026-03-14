# Runner Scheduling & Execution — Implementation Plan

**Status:** Actionable  
**Source:** [Full-Breadth Runner Scheduling Considerations](full-breadth-runner-scheduling-considerations.md)  
**Scope:** Phases A–H, sequenced by priority tiers with concrete deliverables and open-question resolutions.

---

## Phase 1: Executor Behaviour + TaskExecutor Extraction (Phase A)

**Priority:** Tier 1 · **Risk:** Low · **Dependencies:** None  
**Goal:** Extract the hardcoded `Task.Supervisor.async_nolink` dispatch from Worker into a pluggable behaviour. Zero behavioral change — existing tests must pass unchanged.

### Deliverables

1. **`Runic.Runner.Executor` behaviour** (`lib/runic/runner/executor.ex`)
   - Callbacks: `init/1`, `dispatch/3`, `cleanup/1` (optional)
   - Types: `handle :: reference()`, `dispatch_opts :: keyword()`, `executor_state :: term()`
   - Message contract: executor MUST send `{handle, result}` on success, `{:DOWN, handle, :process, pid, reason}` on crash — matching `Task.async_nolink` semantics

2. **`Runic.Runner.Executor.Task`** (`lib/runic/runner/executor/task.ex`)
   - Wraps `Task.Supervisor.async_nolink(sup, work_fn)` — direct extraction of existing Worker code
   - `init/1` takes `:task_supervisor` from opts
   - `dispatch/3` returns `{task.ref, state}`

3. **Worker refactor** (`lib/runic/runner/worker.ex`)
   - Add `:executor` and `:executor_opts` to Worker state
   - Default executor: `Runic.Runner.Executor.Task`
   - Replace inline `Task.Supervisor.async_nolink(...)` call in `dispatch_runnables/1` with `Executor.dispatch(work_fn, opts, executor_state)`
   - Call `Executor.init/1` in Worker `init/1`, store `executor_state`
   - Call `Executor.cleanup/1` (if implemented) in `terminate/2`
   - No changes to `handle_info({ref, %Runnable{}}, state)` — message contract is identical

4. **`:inline` execution support**
   - When executor is `:inline`, execute `work_fn.()` synchronously in the Worker process
   - Skip timeout enforcement for inline execution (per open question 3 recommendation); preserve retry/fallback
   - Return result directly, bypassing the async message path

### Tests

- Existing Worker/Runner tests pass with zero modification (proves behavioral equivalence)
- New test: Worker with explicit `executor: Runic.Runner.Executor.Task` produces identical results
- New test: Worker with `executor: :inline` executes synchronously, no task spawned
- Executor behaviour contract test module (like Store contract tests) — adapter authors can use `use Runic.Runner.Executor.ContractTest` to verify their implementation (resolves open question 15)

### Acceptance Criteria

- `mix test` passes with no regressions
- Worker accepts `:executor` and `:executor_opts` in its start options
- Default behavior (no executor specified) is identical to current behavior

---

## Phase 2: Worker Hooks (Phase B)

**Priority:** Tier 1 · **Risk:** Low · **Dependencies:** None (parallel with Phase 1)

**Goal:** Add lifecycle hook callbacks to the existing Worker for observability and light customization without replacing the Worker.

### Deliverables

1. **Hook option on Worker init** — accept `:hooks` keyword in Worker opts
   - `on_dispatch: (Runnable.t(), worker_state -> :ok)` — called before each dispatch
   - `on_complete: (Runnable.t(), duration_ms :: non_neg_integer(), worker_state -> :ok)` — called after apply
   - `on_failed: (Runnable.t(), reason :: term(), worker_state -> :ok)` — called on task failure
   - `on_idle: (worker_state -> :ok)` — called when workflow becomes idle (no runnables)
   - `transform_runnables: ([Runnable.t()], Workflow.t() -> [Runnable.t()])` — intercept dispatch pipeline

2. **Hook invocation points** in Worker
   - `dispatch_runnables/1`: call `transform_runnables` before dispatch loop, `on_dispatch` per runnable
   - `handle_info({ref, result})`: call `on_complete` with duration (track dispatch timestamp in `active_tasks`)
   - `handle_info({:DOWN, ...})`: call `on_failed`
   - After apply cycle when `is_runnable?` returns false and no active tasks: call `on_idle`

3. **Duration tracking** — store `System.monotonic_time()` at dispatch time in `active_tasks` map value alongside task metadata; compute duration on completion

### Tests

- Hook callbacks invoked at correct lifecycle points
- `transform_runnables` can reorder, filter runnables
- Hooks default to no-ops when not provided (zero overhead path)
- Hook exceptions are logged but do not crash the Worker

---

## Phase 3: Per-Component Executor Overrides (Phase E)

**Priority:** Tier 1 · **Risk:** Low · **Dependencies:** Phase 1

**Goal:** Allow different executors for different components within the same workflow via the existing `SchedulerPolicy` matcher system.

### Deliverables

1. **New fields on `SchedulerPolicy`** (or the policy resolution struct)
   - `executor: module() | :inline | nil` — override executor for matching runnables
   - `executor_opts: keyword()` — per-executor configuration

2. **Worker multi-executor routing** in `dispatch_runnables/1`
   - After resolving policy for a runnable, check for `executor` override
   - If present and different from default, dispatch through override executor
   - Maintain a map of `{executor_module, executor_state}` in Worker state for initialized executors
   - Lazy-init override executors on first use

3. **`:inline` executor shorthand** — `executor: :inline` in policy skips Task dispatch, runs in Worker process

### Tests

- Workflow with mixed policies: some runnables use default TaskExecutor, some use `:inline`
- Verify correct executor receives each runnable based on policy match
- Executor state is maintained per-executor-module across dispatches

---

## Phase 4: Promise Model (Phase C)

**Priority:** Tier 2 · **Risk:** Medium · **Dependencies:** Phase 1

**Goal:** Enable batched execution of linear chains to eliminate per-step task overhead in pipeline-style workflows.

### Open Question Resolutions Applied

- **Q4 (Promise failure semantics):** Use **partial commit** as default — apply completed runnables 1..N-1, fail at N, skip N+1..end. Workflow resumes from failed step on retry. This matches individual dispatch semantics and is the least surprising behavior.
- **Q5 (Concurrent mutations):** PromiseBuilder **excludes** nodes with `:meta_ref` edges (state machine lookups) from chains. Linear chains by definition have no external dependencies, so stale-read risk is confined to `:meta_ref` patterns. This is the conservative path; reconciliation can be added later.
- **Q6 (Promise observability):** Emit `[:runic, :runner, :promise, :start]` and `[:runic, :runner, :promise, :stop]` telemetry events **in addition to** per-runnable events. Include `promise_id`, `runnable_count`, and `node_hashes` in metadata.

### Deliverables

1. **`Runic.Runner.Promise` struct** (`lib/runic/runner/promise.ex`)
   - Fields: `id`, `runnables`, `node_hashes` (MapSet), `strategy` (`:sequential` | `:parallel`), `status`, `results`, `checkpoint_boundary`
   - `new/2` constructor from runnable list + opts

2. **`Runic.Runner.PromiseBuilder`** (`lib/runic/runner/promise_builder.ex`)
   - `build_promises(workflow, runnables, opts)` — identifies linear chains
   - Chain detection algorithm:
     - Build runnable subgraph from prepared runnables
     - Compute in-degree / out-degree per node within subgraph
     - Walk from chain heads (in-degree 0) following single-successor edges
     - Exclude: Join/FanIn nodes with external inputs, nodes with `:meta_ref` edges, nodes with `checkpoint_after: true` policy, incompatible execution modes within chain
   - `min_chain_length` option (default: 2)
   - Returns `{[Promise.t()], [Runnable.t()]}` — promises + standalone runnables

3. **Promise resolution function** (private in Worker or in Promise module)
   - `resolve_promise/2` — reduces over promise runnables sequentially
   - Each runnable: resolve policy → `PolicyDriver.execute` → `Workflow.apply_runnable` on local copy
   - On failure: return partial results (completed runnables before failure) + error
   - Accumulates `uncommitted_events` on local workflow copy naturally via `apply_event/2`

4. **Worker integration**
   - `dispatch_promise/2` — wraps `resolve_promise` into `work_fn`, dispatches via Executor
   - Tag in `active_tasks`: `{:promise, promise.id}` instead of `{:runnable, ref}`
   - Track `active_promises` map in state
   - New `handle_info` clause for `{ref, {:promise_result, promise_id, executed_runnables}}`
   - On promise completion: apply all returned runnables to source-of-truth workflow sequentially
   - On promise failure: apply partial results, handle failed runnable per existing error path
   - Promise telemetry: emit `:start` on dispatch, `:stop` on completion

5. **Promise checkpoint semantics**
   - No special-casing needed — `uncommitted_events` accumulate naturally
   - Worker drains events during normal checkpoint cycle after promise completes

### Tests

- Linear chain `a → b → c` dispatched as single Promise, one task spawned
- Standalone runnables (non-chain) still dispatched individually
- Promise partial failure: runnables before failure are applied, workflow resumes from failure point
- Nodes with `:meta_ref` edges excluded from chains
- `checkpoint_after: true` nodes split chains
- Promise telemetry events emitted with correct metadata
- Behavioral equivalence: Promise execution produces identical workflow state as individual dispatch

---

## Phase 5: Scheduler Strategy Behaviour + ChainBatching (Phase D)

**Priority:** Tier 2 · **Risk:** Medium · **Dependencies:** Phase 4

**Goal:** Formalize the dispatch decision layer as a pluggable behaviour. Ship `Default` (current behavior) and `ChainBatching` (Promise-based chain optimization) strategies.

### Open Question Resolutions Applied

- **Q7 (Critical path):** Make critical-path analysis **opt-in** via the strategy, not the default. `ChainBatching` does not compute critical path. A future `CriticalPath` strategy can layer it on. The O(V+E) cost is negligible for typical workflows but the value is only realized in latency-sensitive fan-out/fan-in patterns.
- **Q8 (Preemptive vs. reactive):** Use **reactive** Promise construction as default — only analyze currently-prepared runnables. Preemptive analysis produces speculative Promises that may not materialize (conditions might not fire). Reactive is safe and correct. Preemptive can be added as an opt-in strategy option later.

### Deliverables

1. **`Runic.Runner.Scheduler` behaviour** (`lib/runic/runner/scheduler.ex`)
   - `init/1` → `{:ok, scheduler_state}`
   - `plan_dispatch/3` — receives workflow + runnables, returns `[dispatch_unit]` where `dispatch_unit :: {:runnable, Runnable.t()} | {:promise, Promise.t()}`
   - `on_complete/3` (optional) — receives completed unit + duration for profiling

2. **`Runic.Runner.Scheduler.Default`** (`lib/runic/runner/scheduler/default.ex`)
   - Wraps each runnable as `{:runnable, r}` — zero overhead, current behavior
   - `on_complete/3` is a no-op

3. **`Runic.Runner.Scheduler.ChainBatching`** (`lib/runic/runner/scheduler/chain_batching.ex`)
   - Delegates to `PromiseBuilder.build_promises/3` for chain detection
   - Returns mix of `{:promise, p}` and `{:runnable, r}`
   - Configurable `min_chain_length` (default: 2)

4. **Worker integration**
   - Add `:scheduler` and `:scheduler_opts` to Worker state
   - Default scheduler: `Runic.Runner.Scheduler.Default`
   - In dispatch phase: call `Scheduler.plan_dispatch/3` instead of dispatching runnables directly
   - Iterate over returned dispatch units, routing `{:runnable, r}` and `{:promise, p}` to respective dispatch functions
   - Call `Scheduler.on_complete/3` after each unit completes (if callback implemented)

5. **Scheduler conformance test suite** — `use Runic.Runner.Scheduler.ContractTest`
   - Verifies: `plan_dispatch` returns valid dispatch units, all runnables accounted for, no duplicates

### Tests

- `Default` scheduler produces identical behavior to pre-scheduler Worker
- `ChainBatching` batches linear chains, leaves non-chains as individual runnables
- Worker accepts `:scheduler` option and routes through it
- Fan-out workflows: independent branches dispatched as parallel runnables (not batched)

---

## Phase 6: GenStage & Flow Integration (Revised)

**Priority:** Tier 2 · **Risk:** Medium · **Dependencies:** Phase 1 (Executor), Phase 4 (Promise), Phase 5 (Scheduler)

**Goal:** Leverage GenStage and Flow as optional core dependencies to enable back-pressure-aware dispatch and optimized parallel execution for dataflow-heavy workflows.

**Full plan:** [phase-6-genstage-flow-plan.md](phase-6-genstage-flow-plan.md)

**Note:** The original Phase 6 included Oban as an external adapter. **Oban is deferred as a future effort** — it remains a valid integration target but is not prioritized. GenStage and Flow are promoted to optional core dependencies because they directly power Runic's parallel execution capabilities.

### Key Deliverables

1. **Optional Dependencies** — `gen_stage` and `flow` as optional deps with compile guards
2. **Parallel Promise Resolution via Flow** — extend existing Promise `:parallel` strategy with Flow-based concurrent execution. Runnables execute via `Flow.from_enumerable |> Flow.map(execute)` inside the work_fn closure. Worker sees identical `{:promise_result, ...}` messages. Fallback to `Task.async_stream` when Flow unavailable.
3. **FlowBatch Scheduler Strategy** — extends ChainBatching to detect both sequential chains AND parallel batch opportunities. Killer use case: FanOut producing 10,000 runnables → single `:parallel` Promise → Flow executes with optimal concurrency.
4. **Worker Dispatch Adjustment** — pass full runnable candidate list to Scheduler (not pre-capped by available_slots). Parallel Promises count as 1 dispatch slot.
5. **GenStage Executor** (lower priority) — demand-driven dispatch with Producer/ConsumerSupervisor topology and internal ref→handle translation layer.
6. **Workflow-to-Flow Compiler** (stretch) — compile static workflow subgraphs into Flow pipelines, bypassing Worker dispatch loop for pure data pipelines.

### Critical Path

6A (Deps) → 6B (Parallel Promise) → 6C (FlowBatch Scheduler) → 6D (Worker Adjustment)

### Tests

- Parallel Promises produce identical workflow state as individual sequential dispatch
- FlowBatch detects independent runnables and creates parallel batches
- FanOut producing 1000+ runnables runs measurably faster with FlowBatch
- All existing tests pass unchanged (no regression)
- Graceful degradation when gen_stage/flow deps not available

---

## Phase 7: Adaptive Scheduling (Phase F)

**Priority:** Tier 3 · **Risk:** Medium-High · **Dependencies:** Phase 5 (strategy behaviour), Phase 2 (hooks for profiling data)

**Goal:** Self-tuning scheduler that adjusts dispatch strategy based on runtime profiling.

### Deliverables

1. **Profiling data collection**
   - Use `on_complete` callback from Scheduler behaviour
   - Track per-node-hash: `avg_duration_ms`, `avg_fact_bytes`, `error_rate`
   - Exponential moving average for duration/size, sliding window for error rate
   - Store in scheduler state (in-memory, per-Worker)

2. **`Runic.Runner.Scheduler.Adaptive`** (`lib/runic/runner/scheduler/adaptive.ex`)
   - Decision function per runnable based on profiling data:
     - `avg_duration_ms < 1.0` → `:inline` (skip task overhead)
     - `error_rate > 0.1` → `:isolated` (don't batch, contain failure)
     - `avg_fact_bytes > 100_000` → `:isolated` (large outputs)
     - Otherwise → `:batchable` (candidate for Promise chains)
   - Combines with ChainBatching: batchable runnables in linear chains become Promises, isolated ones dispatch individually, inline ones execute synchronously
   - Configurable thresholds via opts

3. **`transform_runnables` hook integration** — Adaptive scheduler can also be used as a `transform_runnables` hook for users who want profiling without replacing the scheduler

### Tests

- Sub-ms runnables classified as `:inline` after warmup period
- High-error runnables classified as `:isolated`
- Profiling data accumulates correctly across dispatch cycles
- Adaptive decisions stabilize after sufficient samples

---

## Phase 8: Distribution Primitives (Phase H)

**Priority:** Tier 3 · **Risk:** High · **Dependencies:** Phases 1, 5, distributed Store + Registry

**Goal:** Multi-node execution support via native OTP primitives (`:pg`, `:erpc`, `Task.Supervisor` cross-node), with Raft-based alternatives (Ra/Khepri) as a separate package.

**Full plan:** [phase-8-distribution-primitives.md](phase-8-distribution-primitives.md)

**Approach:** Use `:pg` for process group discovery and `Task.Supervisor.async_nolink({sup, node}, work_fn)` for remote dispatch — zero external dependencies. Raft-based coordination (linearizable registry, distributed Store) deferred to a separate `runic_raft` package.

### Sub-phases

- **8A: Executor.Distributed** — Remote dispatch via cross-node `Task.Supervisor.async_nolink`. Configurable node selectors. Fallback to local.
- **8B: Cluster Awareness** — `:pg` scope for Worker registration and compute node capability discovery. `ComputeNode` supervisor. Distributed lookup.
- **8C: Distributed Scheduler** — Topology-aware routing with capability matching, data locality hints, and load-aware node selection.
- **8D: Workflow Migration** — Drain → checkpoint → resume on new node via Store.
- **8E: Node Failure Handling** — `:net_kernel.monitor_nodes` for proactive failure detection.

### Separate Package: RunicRaft

- **8R-A:** Ra-based distributed registry (linearizable Worker lookup)
- **8R-B:** Khepri Store adapter (strongly-consistent distributed workflow state)
- **8R-C:** Distributed work claiming (exactly-once execution via Raft consensus)

### Tests

- Two-node cluster: runnable dispatched to remote node, result returns to originating Worker
- Node-down: Worker receives `:DOWN`, retries per policy
- Workflow migration: Worker rehydrates from Store on new node, continues execution
- Behavioral equivalence: distributed execution produces identical workflow state as local

---

## Cross-Cutting Concerns

### Event Capture Completeness (Open Question 13)

**Resolution:** Defer full activation-edge event capture. Current event capture (core + coordination events) is sufficient for Phases 1–6. Full capture is needed for distributed Executors (Phase 8) — add it as a prerequisite deliverable within Phase 8 when remote state synchronization requires it. The tradeoff (event volume) is acceptable at that point because distributed workflows are already higher-overhead.

### Opt-in Complexity (Open Question 14)

**Resolution:** Enforce through strong defaults at every layer:
- Phase 1: Default executor is `Executor.Task` — no config needed
- Phase 2: Hooks default to no-ops — zero overhead when unused
- Phase 5: Default scheduler is `Scheduler.Default` — current behavior
- Users at Layer 4 (standard Runner) never see Promises, Executors, or Strategies unless they opt in
- Verify: benchmark default-config Runner before/after each phase to ensure no overhead regression

### Conformance Test Suites (Open Question 15)

**Resolution:** Build conformance test modules for each behaviour:
- `Runic.Runner.Executor.ContractTest` (Phase 1)
- `Runic.Runner.Scheduler.ContractTest` (Phase 5)
- Pattern: `use ContractTest, executor: MyExecutor, opts: [...]` — runs standard assertions
- Model after existing Store contract tests

---

## Execution Timeline

```
           Phase 1 (Executor)  ──────┐
           Phase 2 (Hooks)     ──────┤──── can be parallel
                                     │
           Phase 3 (Per-Component) ──┘ (after Phase 1)
                     │
           Phase 4 (Promise) ────────── (after Phase 1)
                     │
           Phase 5 (Scheduler) ──────── (after Phase 4)
                     │
           Phase 6 (GenStage/Flow) ──── (after Phase 1 + Phase 4 + Phase 5)
                     │
           Phase 7 (Adaptive) ───────── (after Phase 5 + Phase 2)
                     │
           Phase 8 (Distribution) ───── (after Phase 1 + Phase 5 + distributed Store/Registry)
```

**Tier 1 (Phases 1–3):** Can begin immediately. Phases 1 and 2 are independent — work in parallel. Phase 3 follows Phase 1.

**Tier 2 (Phases 4–6):** Phase 4 follows Phase 1. Phase 5 follows Phase 4. Phase 6 follows Phase 5 (extends Promise + Scheduler with Flow-based parallel execution).

**Tier 3 (Phases 7–8):** Phase 7 requires Phase 5 + Phase 2. Phase 8 requires Phase 1 + Phase 5 + external distributed Store/Registry work.
