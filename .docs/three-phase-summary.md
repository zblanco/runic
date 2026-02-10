# Three-Phase Execution Model - Implementation Summary

**Date:** January 2026  
**Status:** Phases 1-5 Complete, **Phase A Complete** ✅, **Phase B Complete** ✅

---

## Completed Work

### Phase 1-4: Foundation & Core Implementation ✅
- `%Runnable{}` struct for isolated execution units
- `%CausalContext{}` for minimal extracted context
- `Invokable.prepare/3` and `Invokable.execute/2` protocol functions
- Implementations for: Step, Condition, Conjunction, FanOut, FanIn, Join, Rule, MemoryAssertion, StateReaction, StateCondition, Accumulator, StateMachine, Root
- `prepared_runnables/1`, `prepare_for_dispatch/1`, `apply_runnable/2` APIs
- `react_three_phase/1`, `react_three_phase/2`, `react_until_satisfied_three_phase/1`, `/2`
- `react_parallel/2`, `react_until_satisfied_parallel/3` for concurrent execution

### Phase 5: External Scheduler Support ✅
- `prepare_for_dispatch/1` returns `{workflow, [%Runnable{}]}`
- `apply_runnable/2` applies completed runnables back to workflow
- Documentation added to README.md with GenServer scheduler example

### Phase 6: Remove Generation Counter (Partial) ✅
- `ancestry_depth/2` implemented for causal chain depth calculation
- `causal_depth/2` added as new API (replaces `causal_generation/2`)
- `root_ancestor_hash/2` helper for root input tracking
- `react/1` and `react_three_phase/1` now use `is_runnable?/1` instead of `generations > 0` guard

---

## Outstanding Concerns

### 1. ~~Generation Counter Still Present~~ ✅ RESOLVED (Phase B)
Generation counters fully removed. All causal ordering now uses `ancestry_depth/2`.

### 2. Dual Execution Paths
We now have two parallel execution paths:
- **Legacy:** `react/1`, `react/2`, `react_until_satisfied/1,2` using `invoke/3`
- **Three-Phase:** `react_three_phase/1,2`, `react_until_satisfied_three_phase/1,2`, `react_parallel/2,3`

This duplication should be consolidated once the three-phase model is validated.

### 3. Hook Execution Timing
Hooks are currently executed in the `apply_fn` (apply phase). This means:
- Before hooks: Not executed during prepare phase (might expect workflow access)
- After hooks: Executed during apply phase (correct timing)

Need to decide if before hooks should run during prepare or execute.

### 4. Error Handling & Retry
`handle_failed_runnable/3` currently just logs and marks as ran. No retry policy exists. For production use cases:
- Should failed runnables be retried?
- How many retries before giving up?
- Should failure propagate or be isolated?

### 5. Durable Execution
`%Runnable{}` is not currently serializable for persistence. For workflows that span process/node restarts:
- Need serialization/deserialization for Runnable
- Need to handle stale context after deserialization
- May need to re-extract context from workflow on restore

### 6. State Conflicts
Parallel execution of stateful nodes (Accumulator, StateReaction) can cause stale reads:
- Current approach captures last known state at prepare time
- Parallel execution may apply outdated state
- CRDT-style merge or serialized execution needed for correctness

---

## Validating the Three-Phase Approach

### Recommended Validation Steps

1. **Property-Based Testing**
   - Generate random workflows, execute through both legacy and three-phase paths
   - Compare: final facts, edge structure, production order
   - Verify: `react_until_satisfied(input) == react_until_satisfied_three_phase(input)`

2. **Performance Benchmarks**
   ```elixir
   # Memory footprint comparison
   Benchee.run(%{
     "legacy" => fn -> Workflow.react_until_satisfied(workflow, input) end,
     "three_phase" => fn -> Workflow.react_until_satisfied_three_phase(workflow, input) end,
     "parallel" => fn -> Workflow.react_until_satisfied_parallel(workflow, input, []) end
   })
   ```

3. **Integration Tests with Real Schedulers**
   - Build a simple GenServer scheduler using `prepare_for_dispatch/1`
   - Test with actual async execution
   - Verify correct behavior under concurrent apply

4. **Stateful Node Correctness**
   - Create workflows with Accumulators that depend on order
   - Verify parallel execution produces correct (or documented) behavior
   - Document which nodes are safe for parallel vs must serialize

---

## Replacing Legacy APIs

### Migration Path

#### Step 1: Internal Delegation (Non-Breaking)
```elixir
# Change invoke/3 to delegate to three-phase internally
def invoke(%__MODULE__{} = wrk, step, fact) do
  wrk = run_before_hooks(wrk, step, fact)
  
  case Invokable.prepare(step, wrk, fact) do
    {:ok, runnable} ->
      executed = Invokable.execute(step, runnable)
      executed.apply_fn.(wrk)
    {:skip, reducer} -> reducer.(wrk)
    {:defer, reducer} -> reducer.(wrk)
  end
end
```

#### Step 2: Deprecation Warnings
```elixir
@deprecated "Use react_three_phase/1 instead"
def react(%__MODULE__{} = wrk) do
  # ... existing implementation
end
```

#### Step 3: API Consolidation
- Rename `react_three_phase/1` → `react/1`
- Rename `react_parallel/2` → `react/2` with `parallel: true` option
- Remove legacy implementations

### plan/plan_eagerly Integration
The `plan/1,2` and `plan_eagerly/1,2` functions prepare match-phase runnables. They currently work with both execution models. No changes needed unless we want to:
- Return `[%Runnable{}]` from `plan/1` (prepare phase only)
- Add `plan_three_phase/1` that skips legacy `invoke/3` path

---

## Questions for the Architect

### Architecture & Design

1. **Consolidation Timeline:** Should we consolidate to three-phase now (breaking change) or maintain dual paths for a release cycle?

A: 

   We should consolidate to three-phase now to avoid breaking changes in the future. Breaking 
   changes are fine now because we haven't released to any users to break.

2. **Hook Semantics:** Should before hooks:
   - Execute during prepare phase (current: not at all)? N
   - Execute during execute phase (has context but no workflow)? Y
   - Execute during apply phase (after execution, with workflow)? N

A: 

   We have two kinds of hooks: before hooks and after hooks.

   We'll change our hook's api to not depend on the workflow and instead use the context and have an optional
   apply_fn return option to apply the hook's result to the workflow so we can get continued / dynamically
   updated workflows.

3. **Parallel Safety Classification:** Should we:
   - Add a `parallel_safe?/1` protocol function to Invokable?
   - Maintain a compile-time classification?
   - Let users specify at runtime via options?

   A: For stateful components the user should be able to specify if its parallel-safe in that it has mergeable (e.g. CRDT / conflict-free) properties such as monotonically increasing counters or sets.
      - Properties such as commutativity, idempotence, and associativity.
      - If flagged as true we can parallelize the merge operation and not care about ordering
      - This flag will be passed from the high level component to the invokable node it pertains to like the accumulator or fan_in

### Product Readiness

4. **Error Handling Strategy:** What error model do you want?
   - Fail-fast (current): One failure marks runnable as failed, continues others
   - Fail-all: Any failure stops the entire reaction cycle
   - Retry with backoff: Configurable retry policy

A: Our error handling strategy will be unified with our component model where names are used to identify how
we want to handle the runtime errors. Likewise for specifying guarantees such as durability or purity so the scheduler can dispatch runnables with the correct runtime capabilities.

5. **Observability:** What instrumentation is needed?
   - Telemetry events for prepare/execute/apply phases?
   - Tracing for distributed execution?
   - Metrics for execution time per node type?

A: Our telemetry should ideally be optional via hooks that dispatch events to telemetry sinks.

6. **Serialization:** Is durable execution a v1 requirement?
   - If yes: Need to design Runnable serialization format
   - If no: Can defer to post-v1

A: Durable execution was initially devised with our logged events (ReactionOccurred and ComponentAdded) but with runnables we might add RunnableDispatched, RunnableCompleted, RunnableFailed, and RunnableCancelled.

### Breaking Changes

7. **Generation Counter:** Should v1 include full generation removal?
   - Pros: Cleaner model, smaller graph memory
   - Cons: Breaks `events_produced_since/2`, `from_log/1` compatibility

8. **API Surface:** What should the public API be for v1?
   - Keep all: `react`, `react_three_phase`, `react_parallel` (more options, more docs)
   - Consolidate: Single `react/2` with options (cleaner, breaking)
   - Keep `react/2` and `react_until_satisfied/2` with options for `async: true` with optional async_stream options passed down.
   - Remove `react_parallel/2` in favor of `react/2` with options.
   - Remove the three_phase variations because we'll use the new three-phase model everywhere internally.
   - In a later phase we'll also parallelize planning and/or support conditional nodes dispatched as durable runnables (for expensive computations)

---

## Benchmark Results (January 2026)

See [benchmark-analysis.md](./benchmark-analysis.md) for full details.

### Key Findings

| Metric | Result |
|--------|--------|
| Three-phase vs Legacy | **10-48% faster** |
| ancestry_depth scaling | **O(depth)**, not O(facts) |
| Multigraph index vs filter | **39x faster** edge lookup |
| Parallel vs Serial | Serial faster for sub-1ms work |
| Memory per fact | ~2KB consistent |

### Critical Insight
`ancestry_depth` is O(chain_depth), independent of total fact count. With 500 facts but depth=5, lookup is still ~200ns. This validates removing generation counters.

### Parallel Execution Note
Task.async_stream overhead dominates for fast pure functions. Parallel is only beneficial for I/O-bound or >1ms work functions. Default to serial.

---

## Action Plan

### Phase A: Consolidate to Three-Phase ✅ **COMPLETE**

Benchmarks confirmed three-phase is faster. Consolidation completed.

**Completed Changes:**

1. ✅ **Rewrote `invoke/3`** to delegate to three-phase internally
   - `prepare` → `execute` → `apply_runnable`
   - Before hooks execute in apply_fn (before actual apply logic)
   - After hooks execute in apply_fn (after workflow updates)

2. ✅ **Updated `react/1,2`** with options:
   - `react(workflow, opts)` - single cycle with options
   - `react(workflow, fact, opts)` - with input
   - `async: true` for parallel execution (via Task.async_stream)
   - `max_concurrency: n` for worker pool limits
   - `timeout: t` for task timeouts
   - Default: serial three-phase

3. ✅ **Updated `react_until_satisfied/2,3`** with options:
   - `react_until_satisfied(workflow, fact, opts)` 
   - Same options as `react/2`

4. ✅ **Removed legacy APIs:**
   - Removed `react_three_phase/1,2`
   - Removed `react_until_satisfied_three_phase/1,2`  
   - Removed `react_parallel/2`
   - Removed `react_until_satisfied_parallel/3`

5. ✅ **All 271 tests pass** (0 failures)

### Phase B: Remove Generation Counters ✅ **COMPLETE**

ancestry_depth is O(depth), memory is constant per fact. Generation counters removed.

**Completed Changes:**

1. ✅ **Removed `workflow.generations` field** from struct and `@type`

2. ✅ **Simplified `log_fact/2`** - No longer creates `:generation` edges

3. ✅ **Deprecated `prepare_next_generation/2`** - Now a no-op returning unchanged workflow

4. ✅ **Updated `plan_eagerly/1`** - Finds facts via `:produced`/`:state_produced`/`:reduced` edges

5. ✅ **Updated `events_produced_since/2`** - Uses `ancestry_depth` + `root_ancestor_hash` for causal filtering

6. ✅ **Updated `from_log/1`** - Skips legacy `:generation` reaction edges for backwards compatibility

7. ✅ **Deprecated `causal_generation/2`** - Delegates to `ancestry_depth + 1` for compatibility

8. ✅ **Updated all legacy `invoke/3` implementations** in invokable.ex to use `ancestry_depth`

9. ✅ **All 271 tests pass** (0 failures)

### Phase C: Hook & Parallel Safety Model

1. **Refactor hooks API:**
   - Before hooks execute during execute phase with CausalContext
   - Optional `apply_fn` return for workflow updates
   - No workflow dependency during hook execution

2. **Add `mergeable: true` option** to Accumulator, FanIn, stateful components
   - Components with CRDT-like properties (commutative, idempotent, associative)
   - Safe for parallel merge without ordering

### Phase D: Testing & Validation

1. **Property-based tests:**
   - StreamData generators for pure component functions
   - Assert output equivalence between old invoke/3 and new three-phase

2. **Benchmark regression tests:**
   - Add `bench/` to CI
   - Alert on >10% performance degradation

### Phase E: Future (Post-v1)

1. **Adaptive parallelization** - profile step times, parallelize only slow steps
2. **Durable execution** - Runnable serialization with RunnableDispatched/Completed events
3. **Memory compaction** - optional for long-running workflows (>10K facts)
4. **ancestry_depth caching** - for workflows with depth >100
