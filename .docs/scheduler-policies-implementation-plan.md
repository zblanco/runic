# Scheduler Policies — Implementation Plan

**Status:** Active  
**Depends on:** [Scheduler Policies Proposal](scheduler-policies-proposal.md)  
**Related:** [Runner Proposal](runner-proposal.md), [Scheduling Guide](../guides/scheduling.md)  

---

## Overview

This plan implements the scheduler policies system described in the [policy proposal](scheduler-policies-proposal.md). The work is organized into four implementation phases, with Phases 1A and 1B designed for concurrent execution. Each phase has explicit deliverables, file-by-file implementation details, and a testing strategy that validates invariants across the state space.

The guiding constraint: **no changes to the Invokable protocol, the Runnable struct, or any existing component structs**. Policies wrap Phase 2 (Execute) of the existing three-phase model externally.

---

## Phase 1A: SchedulerPolicy — Struct, Resolution, and Matchers

**Goal:** Build the `SchedulerPolicy` struct and the rule-based resolution engine as a standalone, fully tested module with zero integration. This is pure data transformation — no runtime, no Workflow changes.

**Can run concurrently with:** Phase 1B (PolicyDriver)

### Files to Create

#### `lib/workflow/scheduler_policy.ex` — `Runic.Workflow.SchedulerPolicy`

The core module. Contains:

1. **The `%SchedulerPolicy{}` struct** with all Phase 1 fields and defaults per the proposal ([§ The SchedulerPolicy Struct](scheduler-policies-proposal.md#the-schedulerpolicy-struct)):

   ```
   max_retries: 0, backoff: :none, base_delay_ms: 500, max_delay_ms: 30_000,
   timeout_ms: :infinity, on_failure: :halt, fallback: nil, execution_mode: :sync,
   priority: :normal, idempotency_key: nil
   ```

   Defer `deadline_ms` and `circuit_breaker` fields to Phase 3 — include the struct fields with `nil` defaults but do not implement runtime behavior for them yet.

2. **`new/1`** — Construct from map or keyword list. Validate option types at construction time. Raise `ArgumentError` for unknown keys. Accept both maps (user-facing API) and keyword lists.

3. **`resolve/2`** — `resolve(%Runnable{}, scheduler_policies) :: %SchedulerPolicy{}`  
   Takes a runnable and a `scheduler_policies` list (the merged runtime + workflow-base list). Walks the list top-to-bottom, first match wins, merges the matched policy map over `@default_policy`, returns a `%SchedulerPolicy{}` struct.  
   If `policies` is `nil` or `[]`, returns `@default_policy`.

4. **`merge_policies/2`** — `merge_policies(runtime_overrides, workflow_base) :: scheduler_policies()`  
   Handles the `:merge` (prepend) vs `:replace` semantics. When mode is `:merge` (default), prepends runtime overrides to workflow base. When mode is `:replace`, returns only the overrides.

5. **Matcher functions (private)** — `matches?/2` implementing all six matcher types per the proposal ([§ Policy Matchers](scheduler-policies-proposal.md#policy-matchers--rule-based-resolution)):

   | Matcher | Implementation |
   |---------|----------------|
   | `atom()` (not `:default`) | Compare `normalize_name(node.name) == matcher` |
   | `:default` | Always `true` |
   | `{:name, %Regex{}}` | `Regex.match?(regex, to_string(node.name))` |
   | `{:type, module}` | `node.__struct__ == module` |
   | `{:type, [modules]}` | `node.__struct__ in modules` |
   | `fn/1` predicate | `matcher.(node)` |

   **Edge case:** `normalize_name/1` must handle atom names, binary names, and nil gracefully. Use `String.to_existing_atom/1` for binary→atom conversion, wrapped in a rescue for atoms that don't exist yet (return `nil` for no match rather than crashing).

6. **`default_policy/0`** — Public accessor for the default policy struct (useful for tests and the PolicyDriver).

### Files to Create (Tests)

#### `test/scheduler_policy_test.exs` — `Runic.Workflow.SchedulerPolicyTest`

**Test categories:**

**A. Struct construction & validation:**
- `new/1` creates valid struct from map
- `new/1` creates valid struct from keyword list
- `new/1` raises on unknown keys
- `new/1` applies defaults for omitted fields
- `default_policy/0` returns the expected default values

**B. Matcher evaluation — exhaustive coverage of every matcher type:**
- Exact atom name match (`:generate_narrative` matches node with `name: :generate_narrative`)
- Exact atom name does NOT match different name
- Regex name match (`{:name, ~r/^llm_/}` matches `:llm_classify`, doesn't match `:classify`)
- Regex name match against string node names
- Type match — single module (`{:type, Step}` matches `%Step{}`, doesn't match `%Condition{}`)
- Type match — list of modules (`{:type, [Step, Condition]}` matches both)
- Custom predicate function (matches when true, skips when false)
- `:default` catches everything
- `nil` name on node doesn't crash any matcher

**C. Resolution — policy list ordering and semantics:**
- First match wins: when two rules match, the first one's policy is used
- Runtime overrides prepended take priority over workflow base
- `:default` acts as catch-all at end of list
- No matching rules returns `@default_policy`
- Empty policy list returns `@default_policy`
- `nil` policies returns `@default_policy`
- Partial policy map is merged over defaults (unspecified fields get defaults)

**D. `merge_policies/2`:**
- `merge_policies(overrides, base)` prepends overrides
- `merge_policies(nil, base)` returns base unchanged
- `merge_policies([], base)` returns base unchanged

### Invariants to Validate

- Resolution is **deterministic** — same input always produces same output
- Resolution is **total** — never raises for valid matcher types, always returns a policy
- `normalize_name/1` never crashes on unexpected input types
- Matcher evaluation has **no side effects** (important for predicate fns — test that predicate is only called until match is found)

---

## Phase 1B: PolicyDriver — Execution Engine

**Goal:** Build the execution driver that wraps `Invokable.execute/2` with timeout, retry, backoff, and fallback. Standalone module, testable with synthetic runnables.

**Can run concurrently with:** Phase 1A (SchedulerPolicy)

**Depends on:** Phase 1A types (the `%SchedulerPolicy{}` struct). In practice, develop concurrently against the struct definition.

### Files to Create

#### `lib/workflow/policy_driver.ex` — `Runic.Workflow.PolicyDriver`

The stateless execution driver per the proposal ([§ Execution Driver](scheduler-policies-proposal.md#execution-driver)):

1. **`execute/2`** — `execute(%Runnable{}, %SchedulerPolicy{}) :: %Runnable{}`  
   Main entry point. Delegates to `do_execute/3` with `attempt = 0`.

2. **`execute/3`** — `execute(%Runnable{}, %SchedulerPolicy{}, keyword()) :: %Runnable{}`  
   Accepts options for deadline tracking: `deadline_at: monotonic_time` (used by Phase 3, plumbed now so the function signature doesn't change).

3. **`do_execute/3` (private)** — The retry loop:
   ```
   execute_with_timeout(runnable, timeout_ms)
   → :completed → return
   → :skipped  → return
   → :failed   → check attempt < max_retries
                   → yes: compute_delay, Process.sleep, re-execute
                   → no:  check fallback
                           → exists: handle_fallback
                           → nil:    check on_failure
                                      → :skip: skip_runnable
                                      → :halt: return failed
   ```

4. **`execute_with_timeout/2` (private):**
   - `:infinity` → call `Invokable.execute/2` directly (no Task wrapper, zero overhead)
   - `timeout_ms` → `Task.async/1` + `Task.yield/2` + `Task.shutdown/2` pattern
   - Timeout produces `Runnable.fail(runnable, {:timeout, timeout_ms})`

5. **`compute_delay/2` (private):** All four backoff strategies:
   - `:none` → `0`
   - `:linear` → `min(base * (attempt + 1), max)`
   - `:exponential` → `min(base * 2^attempt, max)`
   - `:jitter` → `min(:rand.uniform(max(base * 2^attempt, 1)), max)`

6. **`reset_for_retry/1` (private):** Reset runnable to `:pending` state, clear result/error/apply_fn.

7. **`handle_fallback/3` (private):** Three return shapes per the proposal ([§ Fallback & Recovery](scheduler-policies-proposal.md#fallback--recovery)):
   - `%Runnable{}` → execute the modified runnable once (policy with `max_retries: 0, fallback: nil`)
   - `{:retry_with, %{overrides}}` → merge overrides into `meta_context`, execute once
   - `{:value, term}` → build a synthetic `%Fact{}` and a synthetic `apply_fn`, return completed
   - Any other return → `Runnable.fail(runnable, {:invalid_fallback_return, other})`

8. **`apply_overrides/2` (private):** Merge override map into `runnable.context.meta_context`.

9. **`skip_runnable/1` (private):** Build a skipped runnable with an `apply_fn` that calls `mark_runnable_as_ran`.

### Files to Create (Tests)

#### `test/policy_driver_test.exs` — `Runic.Workflow.PolicyDriverTest`

This is the most critical test file. It validates the full state space of execution outcomes.

**Test setup helpers:**

```elixir
# Helper: create a runnable from a simple work function
defp make_runnable(work_fn, opts \\ []) do
  name = Keyword.get(opts, :name, :test_step)
  step = Step.new(work: work_fn, name: name)
  fact = Fact.new(value: Keyword.get(opts, :input, :test))
  context = CausalContext.new(
    node_hash: step.hash,
    input_fact: fact,
    ancestry_depth: 0,
    meta_context: Keyword.get(opts, :meta_context, %{})
  )
  Runnable.new(step, fact, context)
end

# Helper: create a runnable that fails N times then succeeds
defp make_flaky_runnable(fail_count) do
  counter = :counters.new(1, [:atomics])
  work = fn _input ->
    count = :counters.get(counter, 1)
    :counters.add(counter, 1, 1)
    if count < fail_count, do: raise("attempt #{count}"), else: :success
  end
  {make_runnable(work), counter}
end
```

**A. Happy path — no policy needed:**
- Execute with `default_policy()` → success for passing work fn
- Execute with `default_policy()` → failure for raising work fn (no retries, returned as-is)

**B. Timeout enforcement:**
- Work fn that sleeps 50ms with `timeout_ms: 10` → `:failed` with `{:timeout, 10}`
- Work fn that completes in 5ms with `timeout_ms: 100` → `:completed`
- `timeout_ms: :infinity` → no Task wrapper, direct execution, completes normally
- Timeout produces a retriable error (subsequent retry can succeed)

**C. Retry with backoff — the core retry loop:**
- Flaky fn (fails 2x, succeeds 3rd) with `max_retries: 3` → `:completed`
- Flaky fn (fails 4x) with `max_retries: 3` → `:failed`
- `max_retries: 0` → no retry, immediate fail
- `:none` backoff → retries happen with 0 delay (measure timing)
- `:linear` backoff → verify delay formula (use `:timer.tc` or capture sleep calls)
- `:exponential` backoff → verify delay formula
- `:jitter` backoff → verify delay is bounded by `max_delay_ms`
- Delay is capped at `max_delay_ms` for all strategies

**D. Fallback — three return shapes:**
- Fallback returning `%Runnable{}` → executes the modified runnable once, returns result
- Fallback returning `{:retry_with, %{key: val}}` → overrides merged into meta_context, executed
- Fallback returning `{:value, synthetic}` → completed runnable with synthetic fact value
- Fallback returning unexpected shape → `:failed` with `{:invalid_fallback_return, _}`
- Fallback is only called after all retries exhausted
- Fallback with `max_retries: 2` and flaky fn → retries 2x, then calls fallback

**E. `on_failure` actions:**
- `:halt` (default) → returns the failed runnable with `:failed` status
- `:skip` → returns a `:skipped` runnable with a valid `apply_fn`
- `:skip` apply_fn, when applied to a workflow, marks the runnable as ran (integration test in Phase 1C)

**F. Combinations and edge cases:**
- Timeout + retry: first attempt times out, retry succeeds
- Timeout + retry + fallback: all retries timeout, fallback provides value
- Retry + fallback + skip: retries exhausted, fallback returns bad shape, on_failure is skip → verify behavior
- Skipped runnable from `Invokable.execute` passes through without retry
- Completed runnable from `Invokable.execute` passes through without retry

### Invariants to Validate

- **Contract preservation:** PolicyDriver always returns a `%Runnable{}` with status in `[:completed, :failed, :skipped]`
- **Retry count:** Exactly `max_retries` retries occur (not `max_retries + 1` — the initial attempt is attempt 0, retries are 1..max_retries)
- **Fallback ordering:** Fallback is called exactly once, only after all retries are exhausted
- **Timeout isolation:** Timed-out work functions are actually killed (verify with a function that writes to an agent — after timeout, the agent should stop being written to)
- **No mutation:** The input runnable is not modified — the return is always a new struct
- **Statelessness:** PolicyDriver holds no process state — all state is in the runnable and policy

---

## Phase 1C: Workflow Integration

**Goal:** Wire policies into the `%Workflow{}` struct and the `react/2` / `react_until_satisfied/3` runtime. This is the integration layer.

**Depends on:** Phase 1A and Phase 1B completed.

### Files to Modify

#### `lib/workflow.ex` — `Runic.Workflow`

**1. Struct change — add `scheduler_policies` field:**

```elixir
defstruct name: nil,
          hash: nil,
          graph: nil,
          components: %{},
          before_hooks: %{},
          after_hooks: %{},
          mapped: %{},
          build_log: [],
          inputs: %{},
          scheduler_policies: []  # NEW: list of {matcher, policy} tuples
```

Update the `@type t()` spec to include `scheduler_policies: list()`.

**Note:** The `new/1` function uses `struct!/2` and then overwrites fields — ensure `scheduler_policies` is preserved from params (not overwritten to `[]` if provided). The current `new/1` does `Map.put(:components, %{})` etc. — add a `Map.put_new(:scheduler_policies, [])` so user-provided values are preserved.

**2. Public API additions:**

- `set_scheduler_policies/2` — Replace the workflow's policy list entirely
- `add_scheduler_policy/3` — Prepend a `{matcher, policy}` rule (higher priority)
- `append_scheduler_policy/3` — Append a `{matcher, policy}` rule (lower priority)

Per the proposal ([§ Storing Policies on the Workflow](scheduler-policies-proposal.md#storing-policies-on-the-workflow)).

**3. Runtime integration — modify `react/2` and `react_until_satisfied/3`:**

The key change is in `execute_runnables_serial/2` and `execute_runnables_async/3`. When policies are present (from the workflow struct or runtime opts), route through PolicyDriver:

```elixir
defp execute_runnables_serial(workflow, runnables, opts) do
  policies = resolve_effective_policies(workflow, opts)

  runnables
  |> Enum.map(fn runnable ->
    if policies == [] do
      Invokable.execute(runnable.node, runnable)
    else
      policy = SchedulerPolicy.resolve(runnable, policies)
      PolicyDriver.execute(runnable, policy)
    end
  end)
  |> Enum.reduce(workflow, fn executed, wrk -> apply_runnable(wrk, executed) end)
end
```

Similarly for `execute_runnables_async/3`.

**4. `resolve_effective_policies/2` (private):**

Merges runtime `:scheduler_policies` opt with workflow base, respecting `:scheduler_policies_mode`:

```elixir
defp resolve_effective_policies(workflow, opts) do
  runtime = Keyword.get(opts, :scheduler_policies)
  mode = Keyword.get(opts, :scheduler_policies_mode, :merge)
  base = workflow.scheduler_policies

  case {runtime, mode} do
    {nil, _} -> base
    {_, :replace} -> runtime
    {_, :merge} -> SchedulerPolicy.merge_policies(runtime, base)
  end
end
```

**5. Pass opts through the call chain:**

Currently `react/2` calls `execute_runnables_serial/2` with only `(workflow, runnables)`. Update signatures to thread `opts` through:

- `react/2` already receives opts → pass to serial/async execute
- `execute_runnables_serial/3` — add opts parameter
- `execute_runnables_async/4` — add opts parameter
- `do_react_until_satisfied/3` already passes opts → no change needed

**6. `execute_with_policies/2` — Public low-level API:**

For external schedulers using `prepare_for_dispatch/1`:

```elixir
def execute_with_policies(runnables, policies) when is_list(runnables) do
  Enum.map(runnables, fn runnable ->
    policy = SchedulerPolicy.resolve(runnable, policies)
    PolicyDriver.execute(runnable, policy)
  end)
end
```

### Files to Create (Tests)

#### `test/scheduler_policy_integration_test.exs` — `Runic.SchedulerPolicyIntegrationTest`

**A. Workflow struct — policy storage:**
- `Workflow.new(scheduler_policies: policies)` stores policies
- `set_scheduler_policies/2` replaces policies
- `add_scheduler_policy/3` prepends to the front
- `append_scheduler_policy/3` appends to the end
- Policy ordering is preserved through round-trip

**B. Runtime override semantics:**
- `react_until_satisfied(wf, input, scheduler_policies: overrides)` — overrides take priority
- `scheduler_policies_mode: :replace` — workflow base is ignored
- No runtime override → workflow base used
- No workflow base, no runtime → no policies, vanilla execution

**C. End-to-end with real workflows:**
- Simple pipeline (step1 → step2) with `max_retries: 2` and a flaky step → completes after retry
- Pipeline with timeout → step fails, on_failure: :skip → downstream doesn't fire, workflow settles
- Pipeline with fallback → fallback provides synthetic value → downstream fires with synthetic
- Rule workflow (condition → reaction) with policies on the reaction step
- Multi-branch workflow (step_a, step_b both off root) → each gets different policy via type matcher
- `async: true` with policies → parallel execution, each runnable gets its resolved policy

**D. Backward compatibility — the critical invariants:**
- Workflow with no policies behaves identically to current behavior
- `react/2` with no opts behaves identically
- `react_until_satisfied/3` with no opts behaves identically
- `prepare_for_dispatch/1` → manual `execute_runnable/1` → `apply_runnable/2` still works without policies
- All existing tests in `test/three_phase_test.exs`, `test/workflow_test.exs`, etc. continue to pass

**E. Policy resolution across component types:**
- `{:type, Step}` matches Steps but not Conditions
- `{:type, Condition}` matches Conditions but not Steps
- `{:name, ~r/^api_/}` matches `:api_fetch` and `:api_send` but not `:compute`
- `:default` applies to all components when no more specific match exists
- Predicate fn `fn node -> node.name == :special end` matches only that node

### State Space Matrix

This is the combinatorial space the tests must cover:

| Dimension | Values |
|-----------|--------|
| Execution outcome | success, failure (raise), failure (timeout) |
| max_retries | 0, 1, 3 |
| backoff | :none, :linear, :exponential, :jitter |
| on_failure | :halt, :skip |
| fallback | nil, returns `%Runnable{}`, returns `{:retry_with, _}`, returns `{:value, _}` |
| timeout_ms | :infinity, 100, 10 |
| Policy source | workflow-stored, runtime-only, merged, none |
| Execution mode | serial (async: false), parallel (async: true) |
| Matcher type | atom, regex, type, predicate, default |

Not every cell needs a dedicated test — the strategy is:
1. **Unit tests** (Phase 1A/1B) cover each dimension in isolation
2. **Integration tests** (Phase 1C) cover the most important cross-dimension combinations
3. **Property: backward compat** — run all existing tests with zero policies to prove no regression

---

## Phase 2: Durable Execution Events

**Goal:** Add runnable lifecycle events to the workflow event log for durability and observability.

**Depends on:** Phase 1C completed.

### Files to Create

#### `lib/workflow/runnable_dispatched.ex`

```elixir
defmodule Runic.Workflow.RunnableDispatched do
  defstruct [:runnable_id, :node_name, :node_hash, :input_fact, :dispatched_at, :policy, :attempt]
end
```

Per the proposal ([§ RunnableEvent Struct](scheduler-policies-proposal.md#runnableevent-struct)). The `policy` field stores the `%SchedulerPolicy{}` **without** the `fallback` field (which is a function and not serializable). Strip it during event construction.

#### `lib/workflow/runnable_completed.ex`

```elixir
defmodule Runic.Workflow.RunnableCompleted do
  defstruct [:runnable_id, :node_hash, :result_fact, :completed_at, :attempt, :duration_ms]
end
```

#### `lib/workflow/runnable_failed.ex`

```elixir
defmodule Runic.Workflow.RunnableFailed do
  defstruct [:runnable_id, :node_hash, :error, :failed_at, :attempts, :failure_action]
end
```

### Files to Modify

#### `lib/workflow/policy_driver.ex`

Add event emission. The PolicyDriver should return `{%Runnable{}, [events]}` from an extended API, or the events should be attachable to the runnable.

**Design choice:** Add an optional `:emit_events` flag to PolicyDriver.execute/3 options. When true, return `{runnable, events}`. When false (default), return just the runnable. This avoids changing the Phase 1 API.

Alternatively, accumulate events on the runnable struct itself via a new lightweight wrapper — but this modifies Runnable which violates our constraint. **Preferred approach:** Events are accumulated during execution and returned as a sidecar. The Workflow integration layer captures them.

#### `lib/workflow.ex`

1. Update `log/1` to include runnable lifecycle events
2. Update `from_log/1` to handle `RunnableDispatched`, `RunnableCompleted`, `RunnableFailed` event types
3. Add `pending_runnables/1` — identify dispatched-but-not-completed runnables from the log

### Files to Create (Tests)

#### `test/runnable_events_test.exs`

- PolicyDriver with `emit_events: true` produces `RunnableDispatched` at dispatch time
- Successful execution produces `RunnableCompleted` with `duration_ms`
- Failed execution produces `RunnableFailed` with `attempts` count
- Retried execution produces multiple `RunnableDispatched` events (one per attempt)
- `Workflow.log/1` includes runnable lifecycle events after policy-driven execution
- `Workflow.from_log/1` round-trips runnable events
- `Workflow.pending_runnables/1` correctly identifies in-flight work from log

---

## Phase 3: Advanced Primitives

**Goal:** Deadline enforcement, checkpointing, and observability hooks.

**Depends on:** Phase 2 completed (events needed for checkpointing).

### Deadlines

Modify `PolicyDriver.execute/3` to accept `deadline_at: monotonic_time` option. Before each retry attempt, check `System.monotonic_time(:millisecond)` against the deadline. If remaining time < step's `timeout_ms`, fail immediately with `{:deadline_exceeded, remaining_ms}`.

Wire `deadline_ms` option from `react_until_satisfied/3` through to the PolicyDriver. Convert `deadline_ms` to an absolute `deadline_at` at the start of the `react_until_satisfied` call.

### Checkpointing

Add `checkpoint` option to `react_until_satisfied/3`:

```elixir
Workflow.react_until_satisfied(workflow, input,
  scheduler_policies: policies,
  checkpoint: fn workflow -> MyApp.save(workflow) end
)
```

The checkpoint callback fires after each `react` cycle (after all runnables in a generation are applied). This requires a small change to `do_react_until_satisfied/3` to call the checkpoint between cycles.

### Circuit Breakers

Deferred to a dedicated implementation effort. The policy struct already has the `circuit_breaker` field with `nil` default. Implementation requires external state (Agent or ETS) which is architecturally separate from the stateless PolicyDriver. Document as a Phase 3+ extension point.

### Telemetry (optional, if `:telemetry` is acceptable)

Consider adding telemetry events under `[:runic, :policy, :]` for:
- `[:runic, :policy, :execute, :start]`
- `[:runic, :policy, :execute, :stop]`
- `[:runic, :policy, :retry]`
- `[:runic, :policy, :timeout]`
- `[:runic, :policy, :fallback]`

Check if `:telemetry` is already a dependency before adding. If not, defer to Phase 4 or make optional.

### Tests

- Deadline: workflow with 100ms deadline + step that sleeps 200ms → fails with deadline exceeded
- Deadline: workflow with 5000ms deadline + fast steps → completes normally
- Deadline checked before each retry — no retry if deadline would be exceeded
- Checkpoint: verify callback fires after each cycle with updated workflow
- Checkpoint: verify workflow state in callback reflects applied runnables

---

## Phase 4: Convenience APIs & Presets

**Goal:** Ergonomic policy presets and composition helpers.

**Depends on:** Phase 1C (core policies working).

### Files to Modify

#### `lib/workflow/scheduler_policy.ex`

Add preset functions:

```elixir
def llm_policy(opts \\ []) do
  %SchedulerPolicy{
    max_retries: Keyword.get(opts, :max_retries, 3),
    backoff: :exponential,
    base_delay_ms: 1_000,
    max_delay_ms: 30_000,
    timeout_ms: Keyword.get(opts, :timeout_ms, 30_000),
    on_failure: :halt
  }
end

def io_policy(opts \\ []) do
  %SchedulerPolicy{
    max_retries: Keyword.get(opts, :max_retries, 2),
    backoff: :linear,
    base_delay_ms: 500,
    timeout_ms: Keyword.get(opts, :timeout_ms, 10_000),
    on_failure: :skip
  }
end

def fast_fail do
  %SchedulerPolicy{max_retries: 0, timeout_ms: 5_000, on_failure: :halt}
end

def merge(base, overrides) when is_map(base) and is_map(overrides) do
  Map.merge(base, overrides)
end
```

### Tests

- Presets produce valid `%SchedulerPolicy{}` structs with expected field values
- Presets accept override options
- `merge/2` correctly overlays fields

---

## Implementation Order & Dependency Graph

```
Phase 1A: SchedulerPolicy ──────────┐
  (struct, matchers, resolution)     │
                                     ├──► Phase 1C: Workflow Integration ──► Phase 2 ──► Phase 3
Phase 1B: PolicyDriver ─────────────┘     (struct change, react/           (events)    (deadlines,
  (timeout, retry, backoff, fallback)      react_until_satisfied)                       checkpoints)
                                                                                            │
                                                                                            ▼
                                                                                       Phase 4
                                                                                      (presets)
```

**Phase 1A and 1B** can be implemented concurrently (different files, no shared state). They only share the `%SchedulerPolicy{}` struct definition — agree on it first, then develop in parallel.

**Phase 1C** requires both 1A and 1B. This is where integration bugs will surface.

**Phase 2** requires Phase 1C (PolicyDriver must be integrated before adding events).

**Phase 3** requires Phase 2 (checkpointing uses events). Deadlines can start alongside Phase 2 since they only modify PolicyDriver.

**Phase 4** can start anytime after Phase 1C — presets are just convenience constructors.

---

## Testing Strategy Summary

### Test Files

| File | Phase | Scope |
|------|-------|-------|
| `test/scheduler_policy_test.exs` | 1A | Struct, matchers, resolution (unit) |
| `test/policy_driver_test.exs` | 1B | Timeout, retry, backoff, fallback (unit) |
| `test/scheduler_policy_integration_test.exs` | 1C | End-to-end with real workflows |
| `test/runnable_events_test.exs` | 2 | Event emission and log integration |

### Regression Strategy

After each phase, run `mix test` to verify all existing tests pass. The implementation adds new modules and modifies `Workflow` with backward-compatible changes (new optional field with `[]` default, new optional opts). No existing API should change behavior when policies are absent.

### Key Properties to Verify Across All Phases

1. **Backward compatibility:** No policies → identical behavior to pre-policy codebase
2. **Contract preservation:** PolicyDriver input is `%Runnable{status: :pending}`, output is `%Runnable{status: :completed | :failed | :skipped}`
3. **Invokable protocol untouched:** No changes to `Invokable.execute/2` signatures or behavior
4. **Deterministic resolution:** Same policies + same runnable = same resolved policy
5. **Retry correctness:** Exactly `max_retries` retries (not off by one)
6. **Timeout isolation:** Timed-out tasks are actually killed, not leaked
7. **Fallback exclusivity:** Fallback fires exactly once, only after all retries exhausted
8. **Event accuracy:** Events capture correct timing, attempt counts, and outcomes

---

## Runner Proposal Touchpoints

The [Runner Proposal](runner-proposal.md) is a downstream consumer of scheduler policies. Key integration points to keep in mind during implementation:

1. **`Runner.Worker` will read `workflow.scheduler_policies`** in its dispatch loop — the field must be on the struct (Phase 1C).
2. **`Runner.Worker` will call `PolicyDriver.execute/2`** per-runnable during Task dispatch — the API must be public and stable (Phase 1B).
3. **`Runner.Worker` will pass runtime policy overrides** via its `run/3` opts — the `resolve_effective_policies` logic must be extractable or reusable (Phase 1C).
4. **The Runner's `Store` adapter will persist `Workflow.log/1`** which will include runnable events — the event structs must be serializable (Phase 2).
5. **`Runner.Worker.resume/1`** will call `Workflow.pending_runnables/1` to find in-flight work — this API must exist (Phase 2).

No Runner code is implemented as part of this plan. These are forward-compatibility constraints.
