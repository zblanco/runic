# Phase 6 (Revised): GenStage & Flow Integration

**Priority:** Tier 2 · **Risk:** Medium · **Dependencies:** Phase 1 (Executor), Phase 4 (Promise), Phase 5 (Scheduler)  
**Goal:** Leverage GenStage and Flow as optional core dependencies to enable back-pressure-aware dispatch and optimized parallel execution for dataflow-heavy workflows.

**Note:** The original Phase 6 (Community Executor Adapters) included Oban and GenStage as external adapter plugins. Oban is deferred as a future effort — it remains a valid integration target but is not prioritized. GenStage and Flow are instead promoted to optional core dependencies because they directly power Runic's parallel execution capabilities.

---

## Design Rationale

Flow's computational model maps naturally to Runic's DAG structure:

| Runic Concept | Flow Concept |
|---|---|
| Linear chain (a → b → c) | Sequential Flow stages |
| Fan-out (a → [b, c, d]) | Flow.partition / parallel stages |
| Fan-in / Join | Flow.departition / merge |
| Map component (FanOut over collection) | Flow.flat_map with parallel stages |
| Reduce component (FanIn aggregation) | Flow.reduce |

Rather than treating GenStage/Flow as external adapter plugins, they become part of Runic's core runtime as optional performance optimizations. Users who add `{:flow, "~> 1.2"}` to their deps unlock automatic parallel execution without changing their workflow definitions.

**Key architectural insight:** Flow runs *inside* the Promise resolution `work_fn`, dispatched through the existing Executor. The Worker sees the same `{:promise_result, promise_id, executed_list}` message regardless of whether the Promise resolved sequentially or via Flow. This preserves the Executor message contract and keeps all changes localized to Promise resolution and Scheduler strategy.

### Integration Layer

```
Layer 0-1: Raw API + PolicyDriver (unchanged)
Layer 2:   Executor Behaviour (unchanged — Flow is transparent to it)
Layer 3:   Scheduler Strategy (new FlowBatch strategy)
           Promise Resolution (new :parallel strategy using Flow)
Layer 4:   Runner/Worker (minor: pass full runnable list to scheduler)
```

Flow sits at **Layer 3** — it controls *what* gets executed together and *how* batches resolve internally. The Executor (Layer 2) dispatches the Promise as a single unit, unaware of Flow's internal concurrency.

---

## Concurrency Accounting

**Critical design constraint:** The Worker thinks it dispatched "1 task" for a parallel Promise, but Flow internally spawns N stages. Without guardrails, a single Promise could exceed `max_concurrency`.

**Resolution:** Cap Flow's internal concurrency based on Worker capacity and policy:

- `flow_stages` option on Promise (or inherited from Scheduler opts): controls how many Flow stages run internally
- Default: `min(runnable_count, System.schedulers_online())`
- The Scheduler can factor Worker available slots into this cap
- A parallel Promise still counts as 1 active dispatch unit in the Worker's `active_tasks` map

This is an acceptable tradeoff for the initial implementation. A single parallel Promise is typically dispatched when there are many independent runnables (fan-out), and it replaces what would have been many individual tasks anyway. Net concurrency impact is similar to or better than individual dispatch.

---

## Worker Pre-Filtering Change

**Current behavior:** `dispatch_runnables/1` filters runnables to `Enum.take(max(available_slots, 0))` before calling the Scheduler. This means the Scheduler never sees more than `max_concurrency` runnables at once.

**Problem:** For a FanOut producing 10,000 runnables, the Scheduler only sees ~8 (on an 8-core machine). It cannot detect that all 10,000 are independent and should be grouped into a single parallel Promise.

**Fix:** Pass the full filtered-for-active runnable list to the Scheduler (without the `Enum.take` cap). The Scheduler is responsible for concurrency-aware grouping:
- `FlowBatch` groups all independent runnables into one `:parallel` Promise (counts as 1 slot)
- Remaining individual runnables + `:sequential` Promises are capped to available slots
- The Scheduler returns units in priority order; the Worker dispatches up to capacity

This means `plan_dispatch/3` receives the full candidate set and returns units tagged with their slot cost. A parallel Promise has slot cost 1 regardless of internal runnable count.

---

## Deliverables

### 6A: Optional Dependencies & Compile Guards

- Add to `mix.exs`:
  ```elixir
  {:gen_stage, "~> 1.2", optional: true},
  {:flow, "~> 1.2", optional: true}
  ```
- All GenStage/Flow modules guarded by `Code.ensure_loaded?/1` at compile time
- Runtime checks: Worker init raises clear error when user requests GenStage executor or Flow scheduler without deps
- Pattern: modules exist in `lib/` but raise `RuntimeError` with install instructions when deps not available

### 6B: Parallel Promise Resolution via Flow

Extend the existing Promise system with `:parallel` strategy, powered by Flow.

**Key semantic difference from `:sequential`:**

- `:sequential` promises use `resolve_promise_loop/5` — execute head → apply to local workflow copy → prepare_for_dispatch → discover next chain member → recurse
- `:parallel` promises execute all runnables concurrently with **no intermediate apply** — runnables are independent by construction, so they don't need to see each other's results

**Implementation:**

1. **New resolver in Worker** (`resolve_promise_parallel/3`):
   ```elixir
   defp resolve_promise_parallel(promise, workflow, policies) do
     results =
       promise.runnables
       |> Flow.from_enumerable(
         stages: min(length(promise.runnables), System.schedulers_online()),
         max_demand: 1
       )
       |> Flow.map(fn runnable ->
         policy = SchedulerPolicy.resolve(runnable, policies)
         try do
           if policy.execution_mode == :durable do
             PolicyDriver.execute(runnable, policy, emit_events: true)
           else
             PolicyDriver.execute(runnable, policy)
           end
         rescue
           e -> Runnable.fail(runnable, {:execution_error, e})
         end
       end)
       |> Enum.to_list()

     # All results returned — Worker applies them sequentially
     {:promise_result, promise.id, results}
   end
   ```

2. **Fallback when Flow unavailable**: Use `Task.async_stream/3` with same semantics:
   ```elixir
   defp resolve_promise_parallel_fallback(promise, workflow, policies) do
     results =
       promise.runnables
       |> Task.async_stream(
         fn runnable -> execute_runnable(runnable, policies) end,
         max_concurrency: System.schedulers_online(),
         timeout: :infinity
       )
       |> Enum.map(fn {:ok, result} -> result end)

     {:promise_result, promise.id, results}
   end
   ```

3. **Dispatch routing in Worker**: `resolve_promise/3` checks `promise.strategy` and delegates:
   - `:sequential` → existing `resolve_promise_loop/5`
   - `:parallel` → `resolve_promise_parallel/3` (or fallback)

4. **Failure semantics**: Individual runnable failures are caught inside Flow.map. The returned list contains mixed completed/failed runnables. `apply_promise_results/2` handles both — no batch-level failure. This preserves "commit what succeeded" semantics.

5. **Concurrency configuration**: Promise gains optional `:flow_opts` field:
   - `:stages` — Flow stages (default: `min(count, schedulers_online)`)
   - `:max_demand` — Flow max_demand (default: 1 for fine-grained scheduling)
   - Inherited from Scheduler opts or SchedulerPolicy

### 6C: Flow-Aware Scheduler Strategy

`Runic.Runner.Scheduler.FlowBatch` (`lib/runic/runner/scheduler/flow_batch.ex`)

Extends ChainBatching to detect both sequential chains AND parallel batch opportunities:

1. **Sequential chains** (existing): linear chains via PromiseBuilder → `:sequential` Promises
2. **Parallel batches** (new): independent runnables grouped into `:parallel` Promises

**Detection algorithm:**

```
1. Run PromiseBuilder.build_promises for sequential chain detection (existing)
2. From remaining standalone runnables, build a dependency subgraph
3. Identify connected components of independent runnables:
   - No :flow edges between runnables in the same batch
   - No shared Join/FanIn coordination targets
   - No :meta_ref dependencies
4. Groups of N+ independent runnables → :parallel Promise
5. Remaining singletons → {:runnable, r}
```

**Independence rules (conservative):**
- No graph path between any two runnables in the parallel batch
- No shared output nodes (runnables must write to disjoint fact spaces)
- Preserve existing exclusions: no Join/FanIn, no `:meta_ref`
- Runnables in a parallel batch must have compatible policies (no mixing `:durable` and `:sync` within a batch)

**Options:**
- `:min_chain_length` — sequential chain threshold (default: 2)
- `:min_batch_size` — parallel batch threshold (default: 4, since Flow overhead not worth it for small batches)
- `:flow_stages` — max Flow stages for parallel Promises
- `:flow_max_demand` — Flow max_demand

**Killer use case: FanOut → parallel Promise**

When a Map component's FanOut produces 10,000 runnables, FlowBatch detects them all as independent (same parent, no edges between siblings), groups them into a single `:parallel` Promise, and the Promise resolves via Flow with optimal concurrency. Instead of 10,000 Task dispatches bounded by max_concurrency with repeated dispatch_runnables cycles, a single task runs Flow internally.

### 6D: Worker Dispatch Adjustment

Minor change to `dispatch_runnables/1`:

1. Pass full runnable candidate list to Scheduler (remove `Enum.take(available_slots)` before Scheduler call)
2. Scheduler returns dispatch units with implicit slot cost:
   - `{:runnable, r}` → 1 slot
   - `{:promise, %Promise{strategy: :sequential}}` → 1 slot
   - `{:promise, %Promise{strategy: :parallel}}` → 1 slot
3. Worker dispatches units until available slots exhausted
4. Parallel Promises are dispatched preferentially (they consolidate many runnables into 1 slot)

### 6E: GenStage Executor

`Runic.Runner.Executor.GenStage` (`lib/runic/runner/executor/gen_stage.ex`)

**Lower priority than 6B/6C.** Provides demand-driven dispatch as an alternative to Task.Supervisor. Main value: back-pressure that propagates upstream and better resource utilization under sustained load.

**Architecture:**

```
Worker (caller)
    │ dispatch/3 → cast to Producer
    ▼
GenStage.Producer (buffers {ref, work_fn, caller} tuples, emits on demand)
    │
    ├──────────────────┤
    ▼                  ▼
Consumer 1         Consumer N
(execute work_fn)  (execute work_fn)
    │                  │
    └──── send {ref, result} / {:DOWN, ref, ...} to caller ────┘
```

**Message contract preservation:**

The GenStage Executor owns an internal ref→handle translation layer:
- `dispatch/3` creates `handle = make_ref()`, casts to Producer, returns `{handle, state}`
- When ConsumerSupervisor spawns a child for the work item, the child is monitored by a GenStage-internal coordination process
- Child sends `{handle, result}` to caller on success (using the original handle)
- On child crash: coordination process detects `:DOWN`, sends synthetic `{:DOWN, handle, :process, child_pid, reason}` to caller
- All ref remapping happens inside the Executor — Worker is unaware

**Options:**
- `:max_demand` — concurrent consumer slots (default: System.schedulers_online())
- `:buffer_size` — producer buffer size (default: 1000)

**Note:** The GenStage Executor and Flow batch execution are orthogonal. GenStage Executor controls how individual dispatch units are executed. Flow batch controls how runnables are grouped. They can be combined: GenStage Executor dispatches a parallel Promise whose work_fn runs Flow internally.

### 6F: Workflow-to-Flow Compiler (Stretch / Foundational)

`Runic.Runner.Flow` (`lib/runic/runner/flow.ex`)

**Stretch goal — implement only after 6B/6C are validated.** Compiles a static workflow subgraph into a Flow pipeline, bypassing the Worker dispatch loop entirely.

**API:**

```elixir
# Check if a workflow is Flow-compatible
{:ok, flow_spec} = Runic.Runner.Flow.compile(workflow, opts)
# or
{:error, :not_flow_compatible, reasons}

# Execute the compiled Flow
results = Runic.Runner.Flow.run(flow_spec, input_facts, opts)
```

**Compilation rules:**

| Workflow Pattern | Flow Translation |
|---|---|
| Linear chain (a → b → c) | `Flow.map(a) \|> Flow.map(b) \|> Flow.map(c)` |
| Fan-out (a → [b, c]) | `Flow.partition(stages: branch_count)` |
| Fan-in ([b, c] → d) | `Flow.departition(merge_fn)` |
| Map/FanOut | `Flow.flat_map(mapper)` |
| Reduce/FanIn | `Flow.reduce(reducer)` |

**Exclusions (not Flow-compatible):**
- StateMachine nodes (mutable state)
- Condition/Rule nodes with dynamic branching
- Nodes with `:meta_ref` edges
- Nodes with `checkpoint_after: true` policy
- Nodes requiring durable execution mode

**Value:** For pure data pipelines (ETL, LLM chains, data transforms), this provides maximum throughput by eliminating the Worker GenServer bottleneck entirely. Facts flow through GenStage stages with optimal batching and back-pressure.

**Integration with Worker:** The Scheduler could detect Flow-compatible subgraphs and dispatch them as a single unit. The work_fn calls `Runic.Runner.Flow.run/3` internally. This bridges the Worker-managed and Flow-managed worlds.

### 6G: Documentation & Guides

- `guides/flow-integration.md` — when and how to use Flow-based execution
- API docs for all new modules
- Examples:
  - Data pipeline workflow with parallel Promise execution
  - Large fan-out (Map over 10,000 items) with FlowBatch scheduler
  - Benchmark: individual dispatch vs parallel Promise vs Flow-compiled

---

## Tests

### 6A Tests
- Modules compile and load when gen_stage/flow deps are present
- Clear error messages when deps are missing and user requests GenStage/Flow features
- All existing tests pass unchanged (no regression from optional dep addition)

### 6B Tests
- Parallel Promise: N independent runnables execute concurrently, results applied correctly
- Parallel Promise: produces identical workflow state as N individual sequential dispatches (behavioral equivalence)
- Parallel Promise: failure in one runnable returns mixed completed/failed list; succeeded runnables are committed
- Parallel Promise: multiple failures within batch are each handled independently
- Parallel Promise: telemetry events emitted with correct metadata
- Parallel Promise: Flow stages capped to configured limit
- Parallel Promise fallback: Task.async_stream used when Flow not available, same semantics

### 6C Tests
- FlowBatch scheduler detects independent runnables and creates parallel batches
- FlowBatch scheduler still detects sequential chains (inherits ChainBatching)
- FlowBatch scheduler respects min_batch_size threshold
- FlowBatch scheduler excludes Join/FanIn nodes from parallel batches
- FlowBatch scheduler passes Scheduler.ContractTest
- Integration: FanOut producing many runnables → single parallel Promise → all results applied
- Fan-out workflows: independent branches dispatched as one parallel Promise, not individual tasks

### 6D Tests
- Worker passes full runnable list to scheduler (not pre-capped)
- Worker dispatches parallel Promise as 1 slot
- Worker respects max_concurrency across mixed dispatch units

### 6E Tests (if implemented)
- GenStage Executor: dispatches work, receives results via demand-driven consumers
- GenStage Executor: back-pressure limits concurrent execution
- GenStage Executor: consumer crash sends synthetic {:DOWN, ...} to caller
- GenStage Executor: passes Executor.ContractTest
- GenStage Executor: cleanup/1 stops all internal processes

### 6F Tests (if implemented)
- Flow compiler: linear workflow compiles and produces correct results
- Flow compiler: fan-out/fan-in workflow compiles and produces correct results
- Flow compiler: rejects workflows with StateMachine/Condition nodes
- Flow compiler: results match Worker-based execution (behavioral equivalence)

---

## Acceptance Criteria

- `mix test` passes with and without gen_stage/flow deps (optional dep guards work)
- Worker accepts `scheduler: Runic.Runner.Scheduler.FlowBatch` when Flow is available
- Parallel Promises produce identical workflow state as individual sequential dispatch
- No performance regression for default configuration (Default scheduler, Task executor)
- FanOut producing 1000+ runnables runs measurably faster with FlowBatch than Default scheduler

---

## Implementation Order

```
6A (Optional Deps)     ──── foundation for everything else
    │
6B (Parallel Promise)  ──── core new capability
    │
6C (FlowBatch Scheduler) ── uses 6B, extends ChainBatching
    │
6D (Worker Adjustment) ──── enables full-list scheduling for 6C
    │
6E (GenStage Executor) ──── independent of 6B-6D, lower priority
    │
6F (Flow Compiler)     ──── stretch goal, after 6B-6D validated
    │
6G (Docs)              ──── after implementation stabilizes
```

6A → 6B → 6C → 6D is the critical path.  
6E is independent and lower priority.  
6F is a stretch goal.

---

## Relationship to Other Phases

- **Phase 7 (Adaptive Scheduling):** The Adaptive scheduler can use profiling data to decide between sequential, parallel, and inline strategies. When it classifies runnables as `:batchable` (Phase 7 deliverable), FlowBatch groups them into parallel Promises. This is a natural extension.
- **Phase 8 (Distribution):** Distributed Executors can dispatch parallel Promises to remote nodes. The Flow runs on the remote node, results return as events. This requires the event-return approach from the design doc.
- **Original Phase 6 (Oban):** Deferred. Oban executor remains a valid future integration target but is not prioritized. The Executor behaviour is sufficient for community-contributed Oban adapters.
