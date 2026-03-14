# Event-Sourced Workflow-as-Aggregate: Implementation Plan

**Status:** Complete (Phase 7 done)  
**Prerequisite:** [Exploration Doc](eventsourced-aggregate-exploration.md), [Baseline Benchmarks](baseline-benchmark-results.txt)  
**Approach:** Option C — Events from execute, apply as fold, activation as separate apply-phase step  
**Breaking Changes:** Allowed (noted per phase)

---

## Design Principles

1. **Events are the primary mutation interface.** `Invokable.execute/2` returns `%Runnable{events: [...]}`. The `apply_fn` closure is eliminated.
2. **`apply_event/2` is a pure fold.** `(Workflow, Event) → Workflow`. No cascading, no side effects. Activation of downstream nodes happens as a separate post-fold step in `apply_runnable/2`.
3. **Fact values live in the graph, not duplicated in events.** Events carry `%FactRef{}` (hash + ancestry + producer_label). During `apply_event/2`, the full `%Fact{}` (with value) is constructed from the Runnable's `result` field. When replaying from a journal, the Store provides fact values by hash. This avoids doubling memory.
4. **Causal consistency over temporal ordering.** Independent facts in the event log need not be time-ordered; they must produce the same graph state deterministically when folded.
5. **Hooks are telemetry/logging escape hatches only.** They receive read-only event data, return `:ok` or `{:error, reason}`. No workflow mutation. Hook failures can halt execution but cannot modify graph state.

---

## Event Vocabulary

```elixir
# All events live under Runic.Workflow.Events namespace

# --- Core Runtime Events ---

defmodule Runic.Workflow.Events.FactProduced do
  defstruct [:hash, :value, :ancestry, :producer_label, :weight]
  # producer_label: :produced | :state_produced | :state_initiated | :reduced | :fan_out | :joined
  # value: term() — present at runtime, may be nil during lean replay (FactRef mode)
  # weight: causal depth
end

defmodule Runic.Workflow.Events.ActivationConsumed do
  defstruct [:fact_hash, :node_hash, :from_label]
  # from_label: :runnable | :matchable — the edge label being consumed
end

defmodule Runic.Workflow.Events.RunnableActivated do
  defstruct [:fact_hash, :node_hash, :activation_kind, :weight]
  # activation_kind: :runnable | :matchable
end

defmodule Runic.Workflow.Events.ConditionSatisfied do
  defstruct [:fact_hash, :condition_hash, :weight]
end

defmodule Runic.Workflow.Events.JoinFactReceived do
  defstruct [:fact_hash, :join_hash, :parent_hash, :weight]
end

defmodule Runic.Workflow.Events.JoinCompleted do
  defstruct [:join_hash, :result_fact_hash, :result_value, :result_ancestry, :weight]
end

defmodule Runic.Workflow.Events.JoinEdgeRelabeled do
  defstruct [:fact_hash, :join_hash, :from_label, :to_label]
end

defmodule Runic.Workflow.Events.FanOutFactEmitted do
  defstruct [:fan_out_hash, :source_fact_hash, :emitted_fact_hash, :emitted_value, :emitted_ancestry, :weight]
end

defmodule Runic.Workflow.Events.MapReduceTracked do
  defstruct [:source_fact_hash, :fan_out_hash, :fan_out_fact_hash, :step_hash, :result_fact_hash]
end

defmodule Runic.Workflow.Events.FanInCompleted do
  defstruct [:fan_in_hash, :source_fact_hash, :result_fact_hash, :result_value, :result_ancestry,
             :expected_key, :seen_key, :weight]
end

defmodule Runic.Workflow.Events.StateInitiated do
  defstruct [:accumulator_hash, :init_fact_hash, :init_value, :init_ancestry, :weight]
end

# --- Existing lifecycle events (enhanced) ---
# %RunnableDispatched{}, %RunnableCompleted{}, %RunnableFailed{} — already exist, kept as-is
```

**Design note on `FactProduced.value`:** At runtime, the value is always present (constructed from `Runnable.result`). For journal persistence, the Store adapter can extract values to a content-addressed fact store keyed by hash, writing only the hash into the journal event. On replay, the Store hydrates the value. This is a Store-level concern, not an event-model concern.

---

## Phase 1: Foundation — Event Structs, FactRef, Dual-Mode Runnable

**Goal:** Establish event vocabulary, `%FactRef{}`, `apply_event/2`, and dual-mode `apply_runnable/2`. Migrate `Step`, `Condition`, and `Root` to produce events. Validate with benchmarks.

### 1.1 Event Structs

Create `lib/workflow/events/` directory with one module per event type:
- `fact_produced.ex`
- `activation_consumed.ex`
- `runnable_activated.ex`
- `condition_satisfied.ex`

Only the events needed for Step, Condition, and Root in this phase. Join/FanOut/FanIn/Accumulator events are deferred.

Add a barrel module `lib/workflow/events.ex` that aliases all event types for convenience.

### 1.2 FactRef Struct

Create `lib/workflow/fact_ref.ex`:

```elixir
defmodule Runic.Workflow.FactRef do
  @moduledoc """
  A lightweight reference to a Fact without its value.
  Used during lean replay / hybrid rehydration to reconstruct graph
  topology without loading all fact values into memory.
  """
  defstruct [:hash, :ancestry]

  @type t :: %__MODULE__{
    hash: Runic.Workflow.Fact.hash(),
    ancestry: {Runic.Workflow.Fact.hash(), Runic.Workflow.Fact.hash()} | nil
  }
end
```

Update `Runic.Workflow.Components.vertex_id_of/1` to handle `%FactRef{}` (return `hash`).

### 1.3 Dual-Mode Runnable

Add `events` field to `%Runnable{}`:

```elixir
defstruct [
  :id, :node, :input_fact, :context,
  :status, :result, :error,
  :apply_fn,   # Legacy — used when events is nil/empty
  :events      # NEW — list of event structs produced by execute
]
```

Add `Runnable.complete/3` overload that accepts events:

```elixir
def complete(%__MODULE__{} = runnable, result, events) when is_list(events) do
  %{runnable | status: :completed, result: result, events: events}
end
```

**Breaking change:** The existing `complete/3` takes `(runnable, result, apply_fn)` where `apply_fn` is a function. Differentiate by checking `is_function(apply_fn)` vs `is_list(events)`. During the migration period both paths coexist.

### 1.4 `Workflow.apply_event/2`

Add to `lib/workflow.ex` (or a new `lib/workflow/event_applicator.ex` if it grows large):

```elixir
def apply_event(%__MODULE__{} = wf, %Events.FactProduced{} = e) do
  fact = Fact.new(hash: e.hash, value: e.value, ancestry: e.ancestry)
  wf
  |> log_fact(fact)
  |> draw_connection_for_production(e)
end

def apply_event(%__MODULE__{} = wf, %Events.ActivationConsumed{} = e) do
  node = wf.graph.vertices[e.node_hash]
  fact = wf.graph.vertices[e.fact_hash]
  mark_runnable_as_ran(wf, node, fact)
end

def apply_event(%__MODULE__{} = wf, %Events.ConditionSatisfied{} = e) do
  fact = wf.graph.vertices[e.fact_hash]
  cond_node = wf.graph.vertices[e.condition_hash]
  draw_connection(wf, fact, cond_node, :satisfied, weight: e.weight)
end

def apply_event(%__MODULE__{} = wf, %Events.RunnableActivated{} = e) do
  fact = wf.graph.vertices[e.fact_hash]
  Private.draw_connection(wf, fact, e.node_hash, e.activation_kind)
end
```

### 1.5 `Workflow.apply_runnable/2` — Dual-Mode Dispatch

```elixir
# Event-sourced path (new)
def apply_runnable(%__MODULE__{} = wf, %Runnable{status: :completed, events: events} = runnable)
    when is_list(events) and events != [] do
  # 1. Fold core events
  wf = Enum.reduce(events, wf, &apply_event(&2, &1))

  # 2. Emit downstream activations (topology-dependent, Option C)
  wf = emit_downstream_activations(wf, runnable)

  wf
end

# Legacy path (existing — unchanged)
def apply_runnable(%__MODULE__{} = wf, %Runnable{status: :completed, apply_fn: apply_fn})
    when is_function(apply_fn, 1) do
  apply_fn.(wf)
end
```

`emit_downstream_activations/2` implements Option C's "separate apply-phase step":

```elixir
defp emit_downstream_activations(wf, %Runnable{result: %Fact{} = result_fact, node: node}) do
  # Find :flow successors and activate them
  next_steps = next_steps(wf, node)

  Enum.reduce(next_steps, wf, fn step, w ->
    Private.draw_connection(w, result_fact, step.hash, Private.connection_for_activatable(step))
  end)
end

defp emit_downstream_activations(wf, _runnable), do: wf
```

### 1.6 Migrate Root, Step, Condition

**Root** (simplest — no work function):

```elixir
def execute(%Root{} = root, %Runnable{input_fact: fact} = runnable) do
  events = [
    %Events.FactProduced{
      hash: fact.hash, value: fact.value,
      ancestry: fact.ancestry, producer_label: :input, weight: 0
    }
  ]
  Runnable.complete(runnable, fact, events)
end
```

Note: Root doesn't produce an `ActivationConsumed` because there's no activation edge to consume — it _is_ the entry point.

**Step:**

```elixir
def execute(%Step{} = step, %Runnable{input_fact: fact, context: ctx} = runnable) do
  result = # ... same work function call as today ...
  result_fact = Fact.new(value: result, ancestry: {step.hash, fact.hash})

  events = [
    %Events.FactProduced{
      hash: result_fact.hash, value: result_fact.value,
      ancestry: result_fact.ancestry, producer_label: :produced,
      weight: ctx.ancestry_depth + 1
    },
    %Events.ActivationConsumed{
      fact_hash: fact.hash, node_hash: step.hash, from_label: :runnable
    }
  ]

  Runnable.complete(runnable, result_fact, events)
end
```

Hooks: Before/after hooks run in `execute/2` as today. Their `apply_fns` are collected and run in `apply_runnable/2` _after_ event folding, before downstream activation. This keeps hooks as side-effect escape hatches without being part of the event stream.

**Condition:**

```elixir
def execute(%Condition{} = cond, %Runnable{input_fact: fact, context: ctx} = runnable) do
  satisfied = Condition.check(cond, fact)

  events =
    if satisfied do
      [
        %Events.ConditionSatisfied{
          fact_hash: fact.hash, condition_hash: cond.hash,
          weight: ctx.ancestry_depth + 1
        },
        %Events.ActivationConsumed{
          fact_hash: fact.hash, node_hash: cond.hash, from_label: :matchable
        }
      ]
    else
      [
        %Events.ActivationConsumed{
          fact_hash: fact.hash, node_hash: cond.hash, from_label: :matchable
        }
      ]
    end

  Runnable.complete(runnable, satisfied, events)
end
```

### 1.7 Hook Integration in Event-Sourced Path

`apply_runnable/2` for event-sourced runnables handles hooks:

```elixir
def apply_runnable(%__MODULE__{} = wf, %Runnable{events: events, context: ctx} = runnable)
    when is_list(events) and events != [] do
  # 1. Run before hook apply_fns (collected during execute phase)
  wf = apply_hook_fns(wf, ctx.before_hook_apply_fns || [])

  # 2. Fold events
  wf = Enum.reduce(events, wf, &apply_event(&2, &1))

  # 3. Run after hook apply_fns
  wf = apply_hook_fns(wf, ctx.after_hook_apply_fns || [])

  # 4. Downstream activations
  emit_downstream_activations(wf, runnable)
end
```

**Alternative (simpler):** Store hook apply_fns on the Runnable itself (`hook_apply_fns` field) rather than in CausalContext, since hooks already run during `execute/2` and produce apply_fns that need to run during apply. This keeps CausalContext clean.

### 1.8 Journal Buffer on Workflow

Add to `%Workflow{}` struct:

```elixir
defstruct [
  # ... existing fields ...
  uncommitted_events: []  # NEW — events not yet flushed to store
]
```

The `emit/2` function is the internal interface used during `apply_runnable/2`:

```elixir
def emit(%__MODULE__{} = wf, event) do
  wf
  |> apply_event(event)
  |> buffer_event(event)
end

defp buffer_event(%__MODULE__{} = wf, event) do
  %{wf | uncommitted_events: [event | wf.uncommitted_events]}
end
```

However, in Phase 1 we may not use `emit/2` in `apply_runnable/2` yet — we can fold events directly without buffering, since the journal buffer is only needed when a Store is involved (Phase 4). Keep the buffer infrastructure ready but don't require it for the core `react/react_until_satisfied` path.

### 1.9 FanOut Context Tracking for Steps (Event-Sourced Path)

Steps in mapped pipelines currently call `maybe_prepare_map_reduce` inside their `apply_fn`. In the event-sourced path, this must happen in `apply_runnable/2` after folding events. 

Add a `MapReduceTracked` event that the Step's execute produces when it has `fan_out_context`:

```elixir
# In Step.execute/2, when ctx.fan_out_context is populated:
events = events ++ [
  %Events.MapReduceTracked{
    source_fact_hash: ctx.fan_out_context.source_fact_hash,
    fan_out_hash: ctx.fan_out_context.fan_out_hash,
    fan_out_fact_hash: ctx.fan_out_context.fan_out_fact_hash,
    step_hash: step.hash,
    result_fact_hash: result_fact.hash
  }
]
```

And `apply_event/2` for `MapReduceTracked` updates `workflow.mapped` accordingly.

### 1.10 Validation & Benchmarks

1. **All existing tests must pass.** Run `mix test` — both the legacy `apply_fn` path (for unmigrated components) and the new event path (for Step/Condition/Root) must produce identical graph states.
2. **Write event-specific tests** in `test/eventsourced_test.exs`:
   - Step produces correct events
   - Condition satisfied/unsatisfied produces correct events
   - `apply_event/2` fold produces identical graph to legacy `apply_fn` path
   - `from_events/1` round-trip: build workflow → react → extract events → rebuild from events → graphs match
3. **Benchmark:** Re-run baseline benchmarks from `bench/eventsource_baseline_bench.exs` with Step/Condition/Root on events. Compare IPS and memory. Target: <15% overhead.

### 1.11 Breaking Changes in Phase 1

| Change | Impact |
|--------|--------|
| `Runnable` struct gains `events` field | Low — additive |
| `Workflow` struct gains `uncommitted_events` field | Low — additive |
| `Runnable.complete/3` accepts list of events | Medium — overloaded, backward compatible |
| Root/Step/Condition `execute/2` return events | **High** — custom Invokable impls that extend these patterns must update |
| Hook apply_fns stored differently | Medium — hook return contract unchanged, storage mechanism internal |

---

## Phase 2: Conjunction, MemoryAssertion, StateCondition, StateReaction, Accumulator

**Goal:** Migrate the stateful and compound match nodes to produce events. This phase handles the trickier state semantics.

### 2.1 Conjunction

Straightforward — same pattern as Condition:

```elixir
events =
  if all_satisfied do
    [
      %Events.ConditionSatisfied{fact_hash: fact.hash, condition_hash: conj.hash, weight: ...},
      %Events.ActivationConsumed{fact_hash: fact.hash, node_hash: conj.hash, from_label: :matchable}
    ]
  else
    [%Events.ActivationConsumed{fact_hash: fact.hash, node_hash: conj.hash, from_label: :matchable}]
  end
```

### 2.2 MemoryAssertion

Already computes the assertion result in `prepare/3` (requires workflow access). The `execute/2` just wraps the pre-computed result. Migration is identical to Condition — produce `ConditionSatisfied` + `ActivationConsumed` events.

### 2.3 StateCondition

Same pattern as Condition. Last known state is captured in `CausalContext.last_known_state` during prepare. Execute checks the condition. Events are `ConditionSatisfied` + `ActivationConsumed`.

### 2.4 StateReaction

Produces a fact from accumulator state. Events:

```elixir
events = [
  %Events.FactProduced{
    hash: result_fact.hash, value: result_fact.value,
    ancestry: result_fact.ancestry, producer_label: :produced,
    weight: ctx.ancestry_depth + 1
  },
  %Events.ActivationConsumed{
    fact_hash: fact.hash, node_hash: sr.hash, from_label: :runnable
  }
]
```

When the result is `:no_match`, only `ActivationConsumed` is emitted.

### 2.5 Accumulator

The most complex non-coordination component. Two paths:

**Initialized path** (state already exists):

```elixir
events = [
  %Events.FactProduced{
    hash: next_state_fact.hash, value: next_state_fact.value,
    ancestry: next_state_fact.ancestry, producer_label: :state_produced,
    weight: ctx.ancestry_depth + 1
  },
  %Events.ActivationConsumed{
    fact_hash: fact.hash, node_hash: acc.hash, from_label: :runnable
  }
]
```

`apply_event/2` for `FactProduced` with `producer_label: :state_produced` draws a `:state_produced` edge instead of `:produced`.

**Uninitialized path** (first invocation — needs init fact + state fact):

```elixir
events = [
  %Events.StateInitiated{
    accumulator_hash: acc.hash,
    init_fact_hash: init_fact.hash, init_value: init_fact.value,
    init_ancestry: init_fact.ancestry, weight: ctx.ancestry_depth + 1
  },
  %Events.FactProduced{
    hash: next_state_fact.hash, value: next_state_fact.value,
    ancestry: next_state_fact.ancestry, producer_label: :state_produced,
    weight: ctx.ancestry_depth + 1
  },
  %Events.ActivationConsumed{
    fact_hash: fact.hash, node_hash: acc.hash, from_label: :runnable
  }
]
```

`apply_event/2` for `StateInitiated`:

```elixir
def apply_event(%__MODULE__{} = wf, %Events.StateInitiated{} = e) do
  init_fact = Fact.new(hash: e.init_fact_hash, value: e.init_value, ancestry: e.init_ancestry)
  acc = wf.graph.vertices[e.accumulator_hash]
  wf
  |> log_fact(init_fact)
  |> draw_connection(acc, init_fact, :state_initiated, weight: e.weight)
end
```

### 2.6 Validation

- All existing accumulator/state tests pass
- State machine patterns produce identical graph topology
- `from_events/1` round-trip for stateful workflows

---

## Phase 3: Join — Coordination Events

**Goal:** Migrate Join to event-sourced execution. This is the hardest coordination primitive because Join's `apply_fn` re-examines the graph to check if concurrent arrivals completed the join.

### 3.1 The Join Recheck Problem

Today's Join has two paths in `execute/2`:

1. **Would complete (during prepare):** Produces a `join_fact` and an `apply_fn` that draws edges, relabels `:joined` → `:join_satisfied`, and prepares downstream.
2. **Would NOT complete (during prepare):** Produces an `apply_fn` that draws a `:joined` edge, then **rechecks** the graph (because concurrent execution may have added other branches since prepare), and completes if now satisfied.

The recheck is the crux — it requires graph access during the apply phase.

### 3.2 Options for Join in Event-Sourced Model

#### Option A: Split into Two Event Phases

- `execute/2` always produces `JoinFactReceived` events (no graph access needed).
- `apply_runnable/2`, after folding `JoinFactReceived`, performs the completion check (has graph access) and conditionally emits `JoinCompleted` + `JoinEdgeRelabeled` + downstream activations.

```elixir
# In apply_runnable/2, after folding events:
defp maybe_complete_join(wf, %Runnable{node: %Join{} = join, events: events}) do
  # Check if JoinFactReceived was in events
  join_received = Enum.find(events, &is_struct(&1, Events.JoinFactReceived))

  if join_received do
    # Recheck join satisfaction (same logic as today's recheck)
    satisfied_by_parent = collect_joined_parents(wf, join)

    if map_size(satisfied_by_parent) >= length(join.joins) do
      # Emit completion events
      values = collect_join_values(join, satisfied_by_parent)
      join_fact = Fact.new(value: values, ancestry: {join.hash, join_received.fact_hash})

      completion_events = [
        %Events.FactProduced{hash: join_fact.hash, value: join_fact.value, ...},
        # Relabel all :joined edges to :join_satisfied
        ...relabel_events...,
        # Consume remaining runnable edges
        ...activation_consumed_events...
      ]

      Enum.reduce(completion_events, wf, &apply_event(&2, &1))
      |> emit_downstream_activations_for(join, join_fact)
    else
      wf
    end
  else
    wf
  end
end
```

**Pros:**
- `execute/2` remains pure (no graph access). Produces minimal events.
- Completion check happens with full graph visibility in the apply phase.
- The completion events are produced and buffered in the journal — replay is correct because the journal contains the full sequence (`JoinFactReceived` → `JoinCompleted` → `JoinEdgeRelabeled` → `FactProduced`).
- No dual-mode divergence between live and replay.

**Cons:**
- `apply_runnable/2` needs Join-specific logic (the `maybe_complete_join` step). This makes `apply_runnable/2` more complex — it's no longer just "fold events + activate downstream" but has component-specific post-fold behavior.
- The completion events are produced _during apply_, not during execute. This means they're "derived" events that must also be buffered in the journal for replay. During replay, these derived events are already in the stream, so the completion check must be skipped.

**Replay concern mitigation:** Since `apply_event/2` is a pure fold and doesn't trigger completion checks, replay just folds all events (including `JoinCompleted`) without re-deriving them. The completion check only runs in `apply_runnable/2` (live execution path), not during `apply_event/2` (replay path). This is clean because `apply_runnable/2` is only called during live execution, never during replay.

#### Option B: Capture Full Join State in Prepare, Complete in Execute

During `prepare/3`, capture the full join satisfaction state (which parents have `:joined` edges). In `execute/2`, determine whether to produce `JoinCompleted` or just `JoinFactReceived` based on the captured state.

```elixir
# prepare captures:
join_context: %{
  joins: join.joins,
  satisfied_by_parent: %{parent_hash => fact_value, ...},
  would_complete: true/false,
  values: [v1, v2, ...] | nil
}
```

```elixir
# execute produces:
events = if ctx.join_context.would_complete do
  [
    %Events.JoinFactReceived{...},
    %Events.JoinCompleted{join_hash: join.hash, result_fact_hash: join_fact.hash, ...},
    # Relabel events for all existing :joined edges
    ...
  ]
else
  [%Events.JoinFactReceived{...}]
end
```

**Pros:**
- Execute produces all events. `apply_runnable/2` stays generic (fold + activate).
- No component-specific logic in `apply_runnable/2`.

**Cons:**
- **Stale state risk:** If two join branches execute concurrently, both see `would_complete: false` during prepare (each sees only its own branch). Both produce only `JoinFactReceived`. After both are applied, the join is complete but nobody produced `JoinCompleted`. The recheck must still happen somewhere.
- This is exactly the problem the current `apply_fn` recheck solves. Capturing state in prepare doesn't help with concurrent arrivals.

**Verdict:** Option B doesn't solve the concurrent arrival problem. The recheck must happen in apply.

#### Option C: Hybrid — Execute Optimistically, Apply Confirms

- `execute/2` always produces `JoinFactReceived`. If `would_complete` was true during prepare, also optimistically produces `JoinCompleted` + the full event set.
- `apply_runnable/2` validates: if `JoinCompleted` is in the events, confirm the join is actually complete (recheck). If confirmed, fold normally. If stale (another concurrent branch already completed it, or not enough branches yet), drop the `JoinCompleted` events and only fold `JoinFactReceived`.
- If `JoinCompleted` was NOT in events but the join IS now complete after folding `JoinFactReceived`, derive and fold the completion events.

**Pros:** Optimistic path avoids redundant graph scanning when prepare-time state was accurate (majority case in serial execution).

**Cons:** Complex branching logic in `apply_runnable/2`. Two paths to produce the same outcome.

---

**Recommendation: Option A** (Split into Two Event Phases)

It's the cleanest separation. `execute/2` always produces the simple `JoinFactReceived` event. `apply_runnable/2` handles the topology-dependent completion check. During replay, `apply_event/2` folds all events (including `JoinCompleted`) as a pure fold without re-deriving.

The key insight is that `apply_runnable/2` is **only called during live execution** and it already has component-awareness (it calls `emit_downstream_activations` which needs to know about the node). Adding a `maybe_complete_join` step is a natural extension.

### 3.3 Implementation

1. Add `JoinFactReceived`, `JoinCompleted`, `JoinEdgeRelabeled` event structs.
2. Join's `execute/2` produces only `JoinFactReceived` + `ActivationConsumed` (for the triggering fact's `:runnable` edge).
3. In `apply_runnable/2`, after folding events, call `maybe_finalize_coordination/2` which dispatches on node type:
   - For `%Join{}`: run completion check, produce derived events, fold them, buffer them.
   - For other nodes: no-op.
4. `apply_event/2` handles `JoinFactReceived` (draw `:joined` edge), `JoinCompleted` (log join fact, draw `:produced` edge), `JoinEdgeRelabeled` (relabel edge).

### 3.4 Validation

- Join with 2 branches, serial execution: produces `JoinFactReceived` twice, second triggers `JoinCompleted`.
- Join with 2 branches, concurrent execution (async: true): both produce `JoinFactReceived`, apply_runnable recheck triggers `JoinCompleted` on whichever is applied second.
- Deep joins, chained joins, join + condition combinations all pass.
- `from_events/1` round-trip produces identical graph.

---

## Phase 4: FanOut/FanIn — Map/Reduce Coordination

**Goal:** Migrate FanOut and FanIn to event-sourced execution. This involves the `mapped` coordination state.

### 4.1 Options for `mapped` State

The `workflow.mapped` field is a mutable accumulator tracking fan-out batch state. In the event model, we have two options:

#### Option A: `mapped` as Event-Derived Projection

Eliminate `mapped` as a first-class field. Derive it from `MapReduceTracked` and `FanOutFactEmitted` events during replay.

```elixir
def apply_event(wf, %Events.FanOutFactEmitted{} = e) do
  # Build the expected list
  key = {e.source_fact_hash, e.fan_out_hash}
  expected = Map.get(wf.mapped, key, [])
  mapped = Map.put(wf.mapped, key, [e.emitted_fact_hash | expected])
  %{wf | mapped: mapped}
  |> log_fact(Fact.new(hash: e.emitted_fact_hash, value: e.emitted_value, ancestry: e.emitted_ancestry))
  |> draw_connection(wf.graph.vertices[e.fan_out_hash], wf.graph.vertices[e.emitted_fact_hash], :fan_out, weight: e.weight)
end

def apply_event(wf, %Events.MapReduceTracked{} = e) do
  key = {e.source_fact_hash, e.step_hash}
  seen = Map.get(wf.mapped, key, %{})
  mapped = Map.put(wf.mapped, key, Map.put(seen, e.fan_out_fact_hash, e.result_fact_hash))
  # Also store the fan_out_hash for batch lookup
  batch_key = {:fan_out_for_batch, e.source_fact_hash}
  mapped = Map.put(mapped, batch_key, e.fan_out_hash)
  %{wf | mapped: mapped}
end
```

**Pros:** `mapped` is fully derived from events. Replay is correct by construction. No separate "mapped state" to persist.

**Cons:** `mapped` reconstruction requires all `FanOutFactEmitted` and `MapReduceTracked` events to be replayed. This is fine since we replay all events anyway.

#### Option B: `mapped` Mutations as Explicit Events

Keep `mapped` but make every mutation an event (`FanOutTracked`, `FanInBatchReady`, etc.).

**Pros:** Fine-grained audit of coordination state.

**Cons:** More event types for what is essentially bookkeeping. Events should describe domain-meaningful state transitions, not internal data structure mutations.

---

**Recommendation: Option A** (mapped as derived projection)

The `mapped` field is an internal coordination mechanism, not a domain concept. It should be derived from meaningful events (`FanOutFactEmitted`, `MapReduceTracked`, `FanInCompleted`). During replay, these events naturally rebuild the `mapped` state. This keeps the event vocabulary clean and domain-focused.

### 4.2 FanOut Migration

FanOut's `execute/2` produces N `FanOutFactEmitted` events (one per item in the enumerable) + `ActivationConsumed` for the source fact:

```elixir
def execute(%FanOut{} = fan_out, %Runnable{input_fact: source_fact, context: ctx} = runnable) do
  values = Enum.to_list(source_fact.value)

  fan_out_events =
    Enum.map(values, fn value ->
      fact = Fact.new(value: value, ancestry: {fan_out.hash, source_fact.hash})
      %Events.FanOutFactEmitted{
        fan_out_hash: fan_out.hash,
        source_fact_hash: source_fact.hash,
        emitted_fact_hash: fact.hash,
        emitted_value: value,
        emitted_ancestry: fact.ancestry,
        weight: ctx.ancestry_depth + 1
      }
    end)

  events = fan_out_events ++ [
    %Events.ActivationConsumed{
      fact_hash: source_fact.hash, node_hash: fan_out.hash, from_label: :runnable
    }
  ]

  Runnable.complete(runnable, values, events)
end
```

`apply_runnable/2` for FanOut: after folding events (which logs facts and draws `:fan_out` edges via `apply_event`), activate downstream nodes for each emitted fact.

### 4.3 FanIn Migration

FanIn follows the same pattern as Join — it's a coordination node where completion depends on graph state.

- `execute/2` produces events based on `ctx.fan_in_context`:
  - **Simple mode:** `FactProduced` (reduced value) + `ActivationConsumed`
  - **Fan-out-reduce mode, ready:** `FanInCompleted` + `FactProduced` (reduced value) + `ActivationConsumed` for all sister facts
  - **Fan-out-reduce mode, not ready:** `ActivationConsumed` only

- `apply_runnable/2` has a `maybe_finalize_coordination/2` that handles FanIn similarly to Join — if FanIn produces `FanInCompleted`, fold the associated events. The `cleanup_mapped` step is encoded in `apply_event(%Events.FanInCompleted{})`.

### 4.4 Validation

- Simple map/reduce: `[1,2,3] |> map(fn x -> x * 2 end) |> reduce(fn x, acc -> x + acc end, 0)` → `12`
- Nested fan-out/fan-in
- Fan-out with condition gating
- Multiple map/reduce pipelines in the same workflow
- `from_events/1` round-trip

---

## Phase 5: Store Contract Evolution

**Goal:** Evolve the Store behaviour from `save/load` to `append/stream` as the primary interface.

### 5.1 New Store Behaviour

```elixir
defmodule Runic.Runner.Store do
  @type workflow_id :: term()
  @type event :: struct()
  @type cursor :: non_neg_integer()
  @type state :: term()

  # Core (required)
  @callback init_store(opts :: keyword()) :: {:ok, state()} | {:error, term()}
  @callback append(workflow_id(), events :: [event()], state()) ::
              {:ok, cursor()} | {:error, term()}
  @callback stream(workflow_id(), state()) ::
              {:ok, Enumerable.t()} | {:error, :not_found | term()}

  # Snapshot (optional — faster recovery)
  @callback save_snapshot(workflow_id(), cursor(), snapshot :: binary(), state()) ::
              :ok | {:error, term()}
  @callback load_snapshot(workflow_id(), state()) ::
              {:ok, {cursor(), binary()}} | {:error, :not_found | term()}

  # Fact-level storage (optional — hybrid rehydration)
  @callback save_fact(fact_hash :: term(), value :: term(), state()) ::
              :ok | {:error, term()}
  @callback load_fact(fact_hash :: term(), state()) ::
              {:ok, term()} | {:error, :not_found | term()}

  # Lifecycle (optional)
  @callback delete(workflow_id(), state()) :: :ok | {:error, term()}
  @callback list(state()) :: {:ok, [workflow_id()]} | {:error, term()}
  @callback exists?(workflow_id(), state()) :: boolean()

  # Legacy (deprecated — backward compat)
  @callback save(workflow_id(), log :: [struct()], state()) :: :ok | {:error, term()}
  @callback load(workflow_id(), state()) :: {:ok, [struct()]} | {:error, :not_found | term()}

  @optional_callbacks [
    save_snapshot: 4, load_snapshot: 2,
    save_fact: 3, load_fact: 2,
    delete: 2, list: 1, exists?: 2,
    save: 3, load: 2
  ]
end
```

### 5.2 ETS Store Adapter Update

The existing ETS store (if any) gains `append/3` and `stream/2`:
- Events in an `:ordered_set` keyed by `{workflow_id, sequence}`.
- `stream/2` returns a lazy `Stream` over `:ets.select`.
- `save/load` remain as snapshot-based operations.

### 5.3 `Workflow.from_events/1`

```elixir
def from_events(events, base_workflow \\ nil) do
  {build_events, runtime_events} =
    Enum.split_with(events, &is_struct(&1, ComponentAdded))

  base = if base_workflow, do: base_workflow, else: from_log(build_events)

  Enum.reduce(runtime_events, base, fn event, wf ->
    apply_event(wf, event)
  end)
end
```

### 5.4 Worker Integration

The Worker gains event-sourced checkpoint/recovery:

```elixir
# After task completion:
defp handle_task_result(ref, %Runnable{} = executed, state) do
  workflow = apply_runnable(state.workflow, executed)

  state = %{state |
    workflow: workflow,
    uncommitted_events: state.uncommitted_events ++ workflow.uncommitted_events,
    event_cursor: state.event_cursor + length(workflow.uncommitted_events)
  }

  state = %{state | workflow: %{workflow | uncommitted_events: []}}
  state = maybe_checkpoint(state)
  dispatch_runnables(state)
end

# Checkpoint: flush uncommitted events to store
defp do_checkpoint(state) do
  {store_mod, store_state} = state.store
  unless Enum.empty?(state.uncommitted_events) do
    {:ok, _cursor} = store_mod.append(state.id, state.uncommitted_events, store_state)
  end
  %{state | uncommitted_events: []}
end

# Recovery: replay from store
def resume(runner, workflow_id, opts) do
  {store_mod, store_state} = get_store(runner)
  {:ok, event_stream} = store_mod.stream(workflow_id, store_state)
  workflow = Workflow.from_events(Enum.to_list(event_stream), base_workflow)
  start_worker(runner, workflow_id, workflow, opts)
end
```

---

## Phase 6: Remove Legacy `apply_fn` Path ✅

**Goal:** Remove the `apply_fn` field from Runnable. All Invokable implementations produce events. Delete the legacy `apply_fn` code path from `apply_runnable/2`.

**Status:** Complete. All 793 tests pass (0 failures, 13 skipped).

### 6.1 Changes (Completed)

1. **Runnable struct:** Removed `apply_fn` field from `%Runnable{}` struct, type, and defstruct. Updated moduledoc.
2. **`Runnable.complete/3`:** Removed overload that takes a function. Only the `events` list variant remains.
3. **`Runnable.skip/2`:** Now accepts a list of events (typically `[%ActivationConsumed{}]`) instead of an `apply_fn` closure.
4. **`apply_runnable/2`:** Removed legacy clauses that call `apply_fn.(workflow)`. Added skipped-with-events clause that folds events and calls `skip_downstream_subgraph/2`.
5. **PolicyDriver:** Converted `handle_fallback/3` `{:value, term}` path to produce `FactProduced` + `ActivationConsumed` events. Converted `skip_runnable/1` to produce `ActivationConsumed` events. Updated `reset_for_retry/1` to clear `events` instead of `apply_fn`.
6. **Invokable protocol docs:** Updated three-phase model docs, return type docs, and custom Invokable example to use event-sourced pattern.

### 6.2 Skip/Defer Handling

**Decision:** Keep skip/defer as closures in `prepare/3`. They're a pre-execute concern — the closure runs immediately in `prepare_for_dispatch/2`. These never enter the execute/apply cycle, so they don't interfere with event sourcing.

Post-execute skip (`Runnable.skip/2` from PolicyDriver) is now event-sourced: produces `ActivationConsumed` events, and `apply_runnable/2` for `:skipped` folds events then calls `skip_downstream_subgraph/2` to prevent downstream nodes from being stuck.

### 6.3 Breaking Changes

- `Runnable.complete/3` no longer accepts a function. External code passing `apply_fn` closures must switch to producing event structs.
- `Runnable.skip/2` now takes `[event]` instead of `apply_fn`.
- `apply_runnable/2` no longer accepts runnables with `apply_fn` (field removed).
- PolicyDriver now returns event-sourced runnables for fallback `{:value, _}` and `:skip` paths.

---

## Phase 7: Cleanup, Documentation & Serialization ✅

**Status:** Complete.

### 7.1 Cleanup (Completed)

- **`Workflow.log/1`:** Deprecated with `@deprecated` annotation directing users to `build_log/1` + `workflow.uncommitted_events` with `from_events/2`. The function remains for backward compatibility but emits compiler warnings.
- **`Workflow.build_log/1`:** Retained — it provides `%ComponentAdded{}` events needed for workflow structure reconstruction in `from_events/2`.
- **Direct graph mutation functions** (`draw_connection`, `log_fact`, `mark_runnable_as_ran`, `prepare_next_runnables`): Retained as internal implementation used by `apply_event/2`, `invoke/3`, and `emit_downstream_activations/2`. They are the primitives that events decompose into.
- **`reactions_occurred/1`:** Retained as private helper for the deprecated `log/1`. Will be removed when `log/1` is removed.
- **Worker legacy path:** `do_checkpoint/1` and `maybe_persist/1` emit deprecation warnings when using `Workflow.log/1` for non-stream stores. This is intentional — it guides store implementors to adopt `append/3` + `stream/2`.

### 7.2 Event Serialization (Completed)

Created `lib/workflow/events/serializer.ex` with:

```elixir
defmodule Runic.Workflow.Events.Serializer do
  def to_binary(events)        # → binary (ETF)
  def from_binary(binary)      # → {:ok, events} | {:error, reason}
  def event_to_binary(event)   # single event
  def event_from_binary(binary)
end
```

Uses `:erlang.term_to_binary/1` and `:erlang.binary_to_term/2` with `:safe` mode to prevent atom table exhaustion from untrusted input. JSON serialization is deferred to the Store adapter level since `FactProduced.value` contains arbitrary user data.

### 7.3 Documentation (Completed)

- Invokable protocol docs updated: three-phase model, return types, custom example all use events.
- Workflow `apply_runnable/2` docs updated to reflect event-only path.
- `prepared_runnables/1` doc updated: apply phase references `apply_runnable/2` instead of `apply_fn`.

---

## Execution Order & Dependencies

```
Phase 1 ──► Phase 2 ──► Phase 3 ──► Phase 4 ──► Phase 5 ──► Phase 6 ──► Phase 7
 (found.)    (stateful)   (Join)    (FanOut/In)   (Store)    (cleanup)    (docs)
```

Phases are sequential. Each phase must pass the full test suite before proceeding.

Phase 5 (Store) can begin in parallel with Phase 3-4 since the Store contract is independent of which Invokable implementations have been migrated. However, Worker integration (5.4) depends on all Invokable implementations producing events.

---

## Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Infinite loops from Invokable changes | Medium | High | Run tests frequently. Add loop detection in `react_until_satisfied` (max iterations). |
| Performance regression >15% | Medium | Medium | Benchmark each phase. If exceeded, batch-apply events or optimize `apply_event` dispatch. |
| Join concurrent recheck correctness | High | High | Extensive test coverage for parallel join scenarios. Property-based tests comparing legacy vs event path. |
| FanIn `mapped` state consistency during replay | Medium | High | Integration tests: react → extract events → replay → compare graphs. |
| Macro-generated code (Rules, Map, StateMachine) | Medium | Medium | These are compositions of Steps/Conditions/Joins. If primitives work correctly, macros should too. Test macro-generated workflows explicitly. |
| Content-addressability changes | Low | High | Fact hashes don't change (same `Fact.new` call). Event hashes are new concepts. Test hash stability. |

---

## Success Criteria

1. **Functional equivalence:** `react_until_satisfied(workflow, input)` produces identical `raw_productions` for all workflow patterns (linear, branching, rules, accumulators, joins, map/reduce, state machines). ✅ (793 tests, 0 failures)
2. **Event round-trip:** For any workflow execution, `from_events(workflow.uncommitted_events, base_workflow)` produces a graph identical to the one produced by live execution. ✅ (tested for linear, branching, condition, accumulator, join, map/reduce patterns)
3. **Performance:** <15% overhead on baseline benchmarks for serial execution. ✅ (benchmarked in Phase 1)
4. **Serializable execution:** `%Runnable{events: [...]}` is fully serializable via `:erlang.term_to_binary/1`. ✅ (Serializer tests pass)
5. **No `apply_fn` closures** in any Invokable implementation after Phase 6. ✅ (field removed from Runnable struct)

---

## Post-Implementation Q&A: Self-Reflection

### Compositionality

**Q: Do events compose well across nested workflow patterns (e.g., a Rule containing Conditions + Steps + Accumulators)?**

A: Yes, because events are produced at the primitive level. A Rule is a macro-generated composition of Conditions, Steps, and Accumulators — each of which produces its own events independently. The `apply_runnable/2` → `maybe_finalize_coordination/2` → `emit_downstream_activations/2` pipeline handles cross-component activation regardless of how deeply nested the composition is. The key invariant is that `apply_event/2` is always a pure fold on individual event structs, and coordination (Join, FanIn) is handled as a separate post-fold step.

However, there's a latent concern: **event ordering assumptions**. The current model assumes events from a single `execute/2` call are folded in order. Within a single runnable's event list, this is trivially true. But during replay from a journal with interleaved events from concurrent runnables, ordering must be maintained per-runnable. The current ETS/Mnesia stores use monotonic sequence numbers which naturally preserve this, but a distributed store would need causal ordering guarantees.

**Q: How well does `from_events/2` handle partial replay (e.g., replaying only up to event N)?**

A: `from_events/2` supports this directly — it's a left fold, so stopping at event N gives you the workflow state at that point. However, there's a gap: **derived events from `maybe_finalize_coordination`** (e.g., `JoinCompleted`, `FanInCompleted`) are produced during the apply phase and buffered in `uncommitted_events`. During replay, these derived events are in the journal and get folded by `apply_event/2` as normal events. But if you replay only up to the point *between* a `JoinFactReceived` and its derived `JoinCompleted`, the join will appear incomplete even though at runtime it was immediately completed. This is correct behavior (the join genuinely was incomplete at that event cursor), but it's a subtlety that could surprise users building temporal queries.

**Q: What happens when a workflow is `merge/2`'d after execution? Do uncommitted_events survive?**

A: No — `merge/2` combines graph topology via the `Transmutable` protocol, which doesn't carry `uncommitted_events`. This is the correct behavior since `merge/2` is a build-time operation on structure, not a runtime state transfer. However, it means you cannot merge two partially-executed workflows and get a unified event stream. If this use case arises, it would require an explicit event-stream merge with conflict resolution.

### Performance

**Q: What's the memory overhead of buffering events in `uncommitted_events`?**

A: Each event struct is small (5-7 fields, mostly integer hashes). The main cost is `FactProduced.value` which carries the full fact value. For a workflow producing 1000 facts with small values (integers, short strings), the overhead is negligible. For workflows producing large values (multi-MB payloads), the `uncommitted_events` list duplicates every value until the Worker flushes to the store. The checkpointing plan's hybrid rehydration (FactRef) addresses the read side of this problem, but on the write side, the values must exist in memory during execution regardless.

Mitigation for large-value workflows: the Worker's `checkpoint_strategy` should flush more aggressively (e.g., after every N events or every M bytes). The Store's `append/3` callback can extract fact values to content-addressed storage and strip them from the journal entry. This is a Store-level optimization, transparent to the Workflow.

**Q: Is the `Enum.reduce(events, workflow, &apply_event/2)` pattern in `apply_runnable/2` a bottleneck?**

A: Unlikely. A typical `execute/2` produces 2-4 events (FactProduced + ActivationConsumed, maybe ConditionSatisfied or MapReduceTracked). The fold is O(n) in events per runnable, and each `apply_event/2` clause does 1-2 graph operations. This is comparable to the old `apply_fn` which did the same graph operations directly. The overhead is the event struct allocation and pattern match dispatch, which is constant per event type. Benchmarks in Phase 1 confirmed <15% overhead.

For coordination nodes (Join with many branches, FanIn with large fan-out), the derived events from `maybe_finalize_coordination` can be numerous (N `JoinEdgeRelabeled` events for N branches, N `ActivationConsumed` events for FanIn sister facts). These are still O(N) with small constants.

**Q: How does replay performance scale with journal length?**

A: `from_events/2` is O(total events) — it replays every event from the journal. For long-running workflows with thousands of events, this can take meaningful time (hundreds of milliseconds). The checkpointing plan's snapshot strategy directly addresses this: snapshot at cursor N, replay only events since N. Without snapshots, the ETS and Mnesia stores already keep all events in memory, so the bottleneck is CPU for graph operations, not I/O.

The `uncommitted_events` list on the workflow struct is cleared after each Worker checkpoint flush (`%{wf | uncommitted_events: []}`), so it doesn't grow unbounded during live execution.

### Code Quality

**Q: Is there dead code remaining from the pre-event-sourced model?**

A: Yes, several areas:

1. **`invoke/3` implementations**: Every `Invokable` implementation still has `invoke/3` which directly mutates the workflow graph without events. This is the "fast path" used by `react/2` and `react_until_satisfied/2` for in-process execution. It's not dead code — it's the default execution path for non-Worker usage. But it means there are two ways to execute every node: `invoke/3` (direct mutation) and `execute/2` → `apply_runnable/2` (event-sourced). The two must stay in sync, which is a maintenance burden. A future phase could unify `invoke/3` to internally use `execute/2` → `apply_runnable/2`, eliminating the duplication at the cost of some performance overhead for the simple case.

2. **`Workflow.log/1` and `reactions_occurred/1`**: Deprecated but retained for backward compatibility. `log/1` scans the entire graph to derive `ReactionOccurred` events — the exact O(total edges) behavior that event sourcing was designed to replace. It persists because existing tests and the Worker's legacy (non-stream) store path depend on it. Removal is blocked until all Store adapters implement `append/3` + `stream/2`.

3. **`ReactionOccurred` struct**: Used only by `log/1` and `from_log/1`. Once `log/1` is removed, `ReactionOccurred` and its graph scanning can be deleted.

4. **`hook_apply_fns` on Runnable**: Hooks still return closures (`{:apply, fn wf -> ... end}`) that run during the apply phase. These are intentionally not event-sourced — the plan deferred hook event-sourcing as low-value complexity. But it means hook effects are not captured in the journal and not replayable. For pure logging/telemetry hooks this is fine. For hooks that mutate workflow state (e.g., injecting facts), their effects are captured in the next snapshot but not as individual events.

**Q: Are there test coverage gaps for the event-sourced path?**

A: The event-sourced test file (`test/workflow/event_sourced_test.exs`) has 58 tests covering all node types, event round-trips, ETS store integration, and serialization. However, several gaps exist:

1. **Concurrent Join/FanIn**: The tests exercise serial execution where branches arrive one at a time. The concurrent case (multiple branches completing simultaneously, both producing `JoinFactReceived`, with `maybe_finalize_coordination` resolving the race on whichever is applied second) is tested indirectly through the Worker's async tests but not as an explicit event-sourced unit test.

2. **PolicyDriver skip integration**: A new test validates `apply_runnable` with skipped events, but the end-to-end path (Worker dispatches runnable → PolicyDriver decides `:skip` → Worker calls `apply_runnable` with skipped event-sourced runnable) is tested indirectly through Worker tests, not as an explicit event-sourced integration test.

3. **Nested map/reduce with conditions**: Simple map/reduce and condition-gated workflows are tested, but deeply nested patterns (map → condition → reduce → map) haven't been tested for event round-trip fidelity.

4. **StateMachine**: StateMachine is a macro-generated composition. The individual primitives (Accumulator, StateCondition, StateReaction) are tested with events, but an explicit StateMachine event round-trip test is missing.

**Q: What about the `invoke/3` ↔ `execute/2` divergence risk?**

A: This is the biggest code quality concern. Today, `invoke/3` and `execute/2` for each node type are separate implementations that must produce identical graph effects. If someone modifies `invoke/3` (e.g., to fix a bug in Condition evaluation) but forgets to update `execute/2`, the event-sourced path will silently diverge. There's no automated check enforcing equivalence.

Mitigation strategies:
- The existing test suite exercises both paths extensively (legacy tests use `react/2` which calls `invoke/3`; event-sourced tests use `execute/2` + `apply_runnable/2`). A divergence would likely show up as a test failure.
- Long-term, `invoke/3` should be refactored to call `execute/2` → `apply_runnable/2` internally, eliminating the duplication. This would add per-invocation overhead (event struct allocation, pattern match dispatch) but ensure the two paths can never diverge.

### API Surface

**Q: Is the public API clear about when to use events vs. direct mutation?**

A: The current API has three ways to execute a workflow:
1. `react/2` / `react_until_satisfied/2` — high-level, uses `invoke/3` internally (direct mutation)
2. `prepare_for_dispatch/1` → `execute/2` → `apply_runnable/2` — three-phase, event-sourced
3. Worker/Runner — GenServer-based, event-sourced with store integration

For most users, option 1 is the right choice. Options 2 and 3 are for custom schedulers and durable execution. The Invokable protocol docs now clearly describe the event-sourced pattern. However, the `invoke/3` function's doc still says "Legacy invoke function" which may confuse users into thinking it's deprecated — it's not deprecated for in-process usage, only for the distributed/durable execution use case.

**Q: Should `uncommitted_events` be exposed as a public field, or should there be an accessor?**

A: Currently it's a direct struct field access (`workflow.uncommitted_events`). This is fine for Elixir conventions where structs are transparent data. An accessor function would add indirection without benefit. The field name clearly communicates its purpose and lifecycle (uncommitted = not yet flushed to store). The Worker clears it after checkpointing.

### Future Considerations

**Q: What's needed to enable distributed execution via the event-sourced model?**

A: The event model removes the biggest blocker — closure serialization. A remote Executor can now receive a `%Runnable{}` (serializable via ETF), call `Invokable.execute/2`, and return the completed runnable with events. The remaining pieces:

1. **DispatchIntent**: A serializable representation of work to dispatch (node + fact + context), described in the exploration doc but not yet implemented.
2. **Event transport**: The Worker needs to receive events from remote Executors. This is a messaging concern (GenServer calls, distributed Erlang, or message queues).
3. **Idempotency**: If a remote Executor retries or duplicates, the Worker needs to detect and deduplicate events. The `Runnable.id` (hash of node + fact) provides a natural idempotency key.
4. **Fact value shipping**: `FactProduced.value` carries the actual user data. For large values, the Executor should write to a content-addressed fact store and the Worker reads from it, transmitting only the hash. This is the Store-level optimization described in the checkpointing plan.

**Q: How does the event model interact with the checkpointing plan's hybrid rehydration (FactRef)?**

A: The event model is a prerequisite for hybrid rehydration. The `apply_event/2` fold function is the point where `FactRef` integration happens: during replay, `apply_event(%FactProduced{})` can construct either a full `%Fact{}` (hot, value loaded) or a `%FactRef{}` (cold, value deferred) depending on a hot/cold classifier. The event stream provides the complete causal history needed to classify facts. The checkpointing plan's Phase 2 (hot/cold classification) and Phase 3 (selective loading) build directly on top of the event model established here.

**Q: What about event schema evolution?**

A: Event structs are versioned implicitly by their module name and field set. Adding a field with a default value is backward-compatible (old events deserialized with `:safe` will have `nil` for the new field). Removing or renaming a field requires a migration function in `from_binary/1`. The Serializer currently uses ETF which ties serialization to Elixir struct shapes. For cross-version compatibility, a Store adapter could version events explicitly (e.g., wrapping each event with `{version, event}`) and running migrations during `stream/2`.
