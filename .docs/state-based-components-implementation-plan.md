# State-Based Components — Implementation Plan

> **Status**: Active
> **Supersedes**: [state-based-component-exploration.md](./state-based-component-exploration.md) (exploration)  
> **Builds on**: [invokable-three-phase-refactor.md](./invokable-three-phase-refactor.md), [runtime-context-implementation-plan.md](./runtime-context-implementation-plan.md), [eventsourced-aggregate-exploration.md](./eventsourced-aggregate-exploration.md)  
> **Goal**: Deliver composable state-based components — FSM, Aggregate, ProcessManager, Saga — built from existing primitives (Accumulators, Rules, meta_refs), replacing the legacy StateMachine internals.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Assessment: Legacy State Nodes](#assessment-legacy-state-nodes)
3. [Phase 1: Legacy Internals Removal & FSM Foundation](#phase-1-legacy-internals-removal--fsm-foundation)
4. [Phase 2: FSM Component](#phase-2-fsm-component)
5. [Phase 3: Aggregate Component](#phase-3-aggregate-component)
6. [Phase 4: Saga Component](#phase-4-saga-component)
7. [Phase 5: ProcessManager Component](#phase-5-processmanager-component)
8. [Phase 6: Documentation & Guides](#phase-6-documentation--guides)
9. [Phase Dependencies & Parallel Work Streams](#phase-dependencies--parallel-work-streams)
10. [Saga API Exploration](#saga-api-exploration)
11. [Files Modified Summary](#files-modified-summary)
12. [Risk Areas & Testing Strategy](#risk-areas--testing-strategy)

---

## Architecture Overview

### Layering Principle

All state-based components are **compositional sugar** over Runic's existing primitives. No new Invokable node types are introduced unless a fundamentally different dataflow interaction is required. The layering is:

```
┌───────────────────────────────────────────────────────┐
│          User-facing Component DSL (Runic.*)          │   ← macros, constructors
│   FSM · Aggregate · Saga · ProcessManager             │
├───────────────────────────────────────────────────────┤
│          Component Protocol (connect/compose)         │   ← graph wiring, :component_of edges
├───────────────────────────────────────────────────────┤
│          Primitives (existing Invokable nodes)        │   ← Accumulator, Condition, Step, Rule,
│          + meta_ref edges + state_of() resolution     │      Join, FanOut/FanIn, Conjunction
├───────────────────────────────────────────────────────┤
│          Three-Phase Invokable Protocol               │   ← prepare → execute → apply (events)
├───────────────────────────────────────────────────────┤
│          Workflow Graph (libgraph multigraph DAG)      │   ← vertices, labeled edges, edge_index
├───────────────────────────────────────────────────────┤
│          Runner / Scheduler / Store                   │   ← scheduling, persistence, replay
└───────────────────────────────────────────────────────┘
```

Each new component:

1. Has a **struct** in `lib/workflow/<component>.ex` (data only, no runtime logic)
2. Has a **macro** in `lib/runic.ex` (construction, AST rewriting, meta_ref detection)
3. Implements **`Runic.Component`** (connect, hash, source, inputs, outputs)
4. Implements **`Runic.Transmutable`** (to_workflow, to_component)
5. Does **NOT** implement `Runic.Workflow.Invokable` — it compiles down to existing Invokable nodes

### Building Blocks

| Primitive | Role in State Components |
|-----------|-------------------------|
| `Accumulator` | Holds state; folds events/values via reducer |
| `Rule` (Condition + Step) | Command validation / event guards via `state_of()` meta_refs |
| `Condition` | Standalone predicate gates, transition guards |
| `Step` | Side-effect-free transformations, event emission |
| `Join` | Multi-branch synchronization |
| `:meta_ref` edges | `state_of()` and `context()` compile to these; resolved in prepare phase |
| `:component_of` edges | Sub-component ownership tracking |

### Named Sub-Component Referencing

All state-based components expose their internal parts via `:component_of` edges for composition with external components. The existing `Workflow.get_component/2` tuple form already resolves sub-components by matching on `edge.properties[:kind]` OR `edge.v2.name`:

```elixir
# Access by kind (always available)
Workflow.get_component(workflow, {:my_fsm, :accumulator})

# Access by name (when the sub-component was given an explicit name)
Workflow.get_component(workflow, {:my_state_machine, :threshold_exceeded})
```

This enables attaching downstream components to specific internal parts:

```elixir
# Add a step after a named state machine reaction
Workflow.add(workflow, my_logger_step, to: {:my_state_machine, :threshold_exceeded})
```

**Naming convention for generated sub-components:**

Each state-based component generates rules for its transitions/reactions/handlers. These rules receive names derived from the parent component name:

| Component | Sub-component | Generated name (default) | User-overridable |
|-----------|---------------|--------------------------|------------------|
| StateMachine | accumulator | `:"#{sm_name}_accumulator"` | No (one per SM) |
| StateMachine | handler rule | `:"#{sm_name}_#{event_pattern}"` (Form 2) or `:"#{sm_name}_handler_#{idx}"` (Form 1) | Yes, via `name:` option on `handle` |
| StateMachine | reactor rule | keyword key (Form 1) or atom after `react` (Form 2) | Yes (always named) |
| FSM | transition rule | `:"#{fsm_name}_#{from}_on_#{event}"` | No (derived from spec) |
| FSM | entry action | `:"#{fsm_name}_#{state}_entry"` | No |
| Aggregate | command rule | `:"#{agg_name}_#{command_name}"` | Yes, via `:name` in command block |
| Saga | transaction rule | `:"#{saga_name}_#{step_name}"` | Yes (step_name is required) |
| ProcessManager | event rule | `:"#{pm_name}_on_#{idx}"` | Yes, via `:name` in on block |

All generated sub-components get `:component_of` edges from the parent, making them discoverable via `Workflow.get_component/2`.

**Accessing sub-component parts recursively:**

Since each generated rule is itself a component with `:condition` and `:reaction` sub-parts, you can drill down further:

```elixir
# Get the reaction step of a named state machine reactor
Workflow.get_component(workflow, {:my_state_machine, :threshold_exceeded})
# → [%Rule{name: :threshold_exceeded, ...}]

# Then the rule's own sub-components are addressable:
Workflow.get_component(workflow, {:threshold_exceeded, :reaction})
# → [%Step{...}]

# Or connect directly to the rule's reaction output:
Workflow.add(workflow, my_alert_step, to: {:threshold_exceeded, :reaction})
```

---

## Assessment: Legacy State Nodes

### StateCondition, StateReaction, MemoryAssertion

These three node types were created for the original StateMachine spike. With the evolved model they have varying degrees of redundancy:

#### StateCondition

**Verdict: Deprecate and replace with Condition + `state_of()` meta_refs.**

`StateCondition` is a 2-arity predicate `(input_value, last_known_state) → boolean`. Its prepare phase fetches `last_known_state` from the accumulator's `:state_produced` edges and passes it as a second argument.

This is exactly what a `Condition` with `state_of(:accumulator_name)` achieves via the meta_ref mechanism — the prepare phase resolves the meta_ref, injects the state into `meta_context`, and the rewritten condition function accesses it. The only difference is the calling convention: `StateCondition` uses a hardcoded `state_hash` reference to find its accumulator, while `Condition` with `state_of()` uses named meta_ref edges.

The meta_ref approach is strictly more general:
- Supports referencing multiple state sources
- Uses the same resolution path as `context()` and any future meta expressions
- Works with the three-phase model naturally (state resolved in prepare, available in execute)
- Compatible with the event-sourced invokable model

#### StateReaction

**Verdict: Deprecate and replace with Step + `state_of()` meta_refs.**

`StateReaction` fetches `last_known_state` during prepare and passes it to a work function. This is equivalent to a `Step` whose work function uses `state_of()` to read the accumulator state. The step produces a fact; the accumulator consumes it — standard dataflow.

The special `:no_match_of_lhs_in_reactor_fn` sentinel is a pattern-match guard that should instead be expressed as a proper `Condition` gate upstream of the step.

#### MemoryAssertion

**Verdict: Deprecate and replace with Condition + `state_of()` meta_refs.**

`MemoryAssertion` takes `(workflow, fact) → boolean` — it needs full workflow access. This was a workaround before meta_refs existed. The prepare phase now runs the assertion eagerly (pre-computing the result), which means it's already effectively a condition that reads state during prepare.

With `state_of()`, the condition can reference any accumulator's state without needing raw workflow access. The meta_ref resolution in prepare provides the same data. For cases needing multiple state sources, multiple `state_of()` refs compose cleanly.

### Migration Impact

- **No external users** — Runic is unreleased, so no backward compatibility concern
- **Internal usage** — Only `StateMachine` constructs these nodes via `build_reducer_workflow_ast/3` and `maybe_add_reactors/3`
- **Tests** — Existing StateMachine tests exercise these nodes transitively; they will be rewritten to test the new primitives-based construction

### Migration Path

1. Rebuild `StateMachine` to emit Accumulator + Rules + Conditions (Phase 1)
2. Remove `StateCondition`, `StateReaction`, `MemoryAssertion` structs
3. Remove their `Invokable`, `Activator`, and related protocol implementations
4. Remove construction code in `Runic` macros (`build_reducer_workflow_ast`, `maybe_add_reactors`, `reactor_ast_of`)

---

## Phase 1: Legacy Internals Removal & FSM Foundation

**Goal:** Remove `StateCondition`, `StateReaction`, and `MemoryAssertion` from the codebase. Rebuild `StateMachine` to compile down to Accumulator + Rules with `state_of()` meta_refs. This establishes the pattern all subsequent components follow.

**Estimated scope:** Medium — focused refactor of StateMachine internals with well-defined boundaries.

### 1A: Rebuild StateMachine macro compilation

**File:** `lib/runic.ex`

Replace `workflow_of_state_machine/4`, `build_reducer_workflow_ast/3`, `maybe_add_reactors/3`, and `reactor_ast_of/4` with new compilation that emits:

1. An `Accumulator` (unchanged — already works)
2. For each handler clause: a named `Rule` with:
   - **Condition** using `state_of(:sm_name)` to gate on current state + input pattern
   - **Step** (reaction) that computes the next state to feed back to the accumulator
3. For each reactor: a named `Rule` with:
   - **Condition** using `state_of(:sm_name)` to check the state pattern
   - **Step** that runs the reactor function with `state_of()` for state access

In practice the macro will construct the condition and step ASTs directly (as `Condition.new` and `Step.new` with meta_refs) rather than going through the rule DSL, since we're generating from the handler/reducer clause AST.

**Implementation detail:** Each handler clause's LHS has two parts — an input pattern and a state guard. Split these:
- Input pattern → Condition predicate (match on fact value)
- State guard → `state_of()` reference in the condition's `where` (via meta_ref)
- Body → Step work function that receives input and state via meta_context

The StateMachine macro supports **two API forms** that compile to the same `%StateMachine{}` struct:

#### Form 1: Keyword-list constructor (data-driven)

The minimal, programmatic form. `init` accepts literals directly (wrapped to `fn -> val end` internally). Reactors are a keyword list for naming:

```elixir
Runic.state_machine(
  name: :counter,
  init: 0,
  reducer: fn x, acc -> acc + x end,
  reactors: [
    threshold_exceeded: fn state when state > 100 -> :over_limit end,
    reset_detected: fn 0 -> :was_reset end
  ]
)
```

Unnamed reactors (bare functions in a list) still work and receive auto-generated names `:"#{sm_name}_reactor_#{idx}"`. This form is best for simple state machines, programmatic construction, and backward compatibility with the existing API shape.

#### Form 2: `handle`/`react` block DSL (expressive)

For unbounded state machines with complex state, each `handle` clause bundles the event match, state guard, and state transformation together. Each handler becomes a named, addressable sub-component:

```elixir
Runic.state_machine name: :cart, init: %{items: [], total: 0} do
  handle :add_item, %{item: item}, state do
    %{state | items: [item | state.items], total: state.total + item.price}
  end

  handle :checkout, _, state when state.items != [] do
    %{state | status: :checked_out}
  end

  handle :apply_discount, %{percent: pct}, state when state.total > 0 do
    %{state | total: state.total * (1 - pct / 100)}
  end

  react :high_value do
    fn %{total: t} when t > 1000 -> {:vip_alert, t} end
  end

  react :empty_cart do
    fn %{items: []} -> :cart_empty end
  end
end
```

**`handle` clause semantics:**

```elixir
handle event_pattern, input_match, state_var [when state_guard] do
  body  # must return next state
end
```

- `event_pattern` — atom or pattern matched against the incoming fact's "event type" discriminator. When the fact value is a tuple like `{:add_item, payload}`, this matches the tag. When it's a bare value, it matches the value itself.
- `input_match` — pattern match on the event payload / fact value
- `state_var` — binds the current state via `state_of(:sm_name)` meta_ref
- `when state_guard` — optional guard on current state
- `body` — returns the next state value, fed to the accumulator

Each `handle` compiles to a named Rule:
- Name: `:"#{sm_name}_#{event_pattern}"` (e.g., `:cart_add_item`). Explicit `name:` option overrides.
- Condition: input pattern match + state_of() guard
- Step: body function receiving input and state via meta_context, producing next state

**`react` clause semantics:**

```elixir
react name do
  fn state_pattern -> output end
end
```

- Name: explicitly required (the atom after `react`)
- Compiles to a Rule with a `state_of()` condition and a step that produces the output fact
- Does NOT modify state — observation only

**Compilation equivalence:**

Both forms produce identical `%StateMachine{}` structs. The `handle` block is sugar for splitting a multi-clause reducer into individually named rules. A `handle` form:

```elixir
handle :add_item, %{item: item}, state do
  %{state | items: [item | state.items]}
end
```

Is equivalent to this in Form 1:

```elixir
reducer: fn
  {:add_item, %{item: item}}, state -> %{state | items: [item | state.items]}
  # ... other clauses
end
```

The difference is that `handle` gives each clause its own name and `:component_of` edge, making it individually addressable and composable.

### 1B: Remove legacy node types

**Files to modify:**

| File | Action |
|------|--------|
| `lib/workflow/state_condition.ex` | Delete entirely |
| `lib/workflow/state_reaction.ex` | Delete entirely |
| `lib/workflow/memory_assertion.ex` | Delete entirely |
| `lib/workflow/invokable.ex` | Remove `StateCondition`, `StateReaction`, `MemoryAssertion` Invokable impls (L738-L1056) |
| `lib/workflow/component.ex` | Remove StateMachine's references to `StateReaction`/`MemoryAssertion` in connect |
| `lib/runic.ex` | Remove `StateCondition`/`StateReaction`/`MemoryAssertion` aliases; remove `build_reducer_workflow_ast`, `maybe_add_reactors`, `reactor_ast_of` |
| `lib/workflow/serializer.ex` | Remove any serialization handling for these types |
| `lib/workflow/transmutable.ex` | No change needed (StateMachine impl stays, just builds differently) |

### 1C: Update StateMachine Component protocol

**File:** `lib/workflow/component.ex`

The `Runic.Component` impl for `StateMachine` currently splices the internal workflow's edges (including `StateReaction`/`MemoryAssertion` edges). Update to:
- Connect the accumulator to the parent `to` node
- Connect each handler rule to root (they receive input facts) with output feeding to the accumulator
- Connect each reactor rule to the accumulator (they observe state changes)
- Draw `:component_of` edges from the StateMachine to each sub-component:
  - `{sm, accumulator, :component_of, properties: %{kind: :accumulator}}`
  - `{sm, rule, :component_of, properties: %{kind: :handler}}` for each handler rule
  - `{sm, rule, :component_of, properties: %{kind: :reactor}}` for each reactor rule
- Each rule is registered as a component so its name is resolvable via `get_component`
- Meta_ref edges (`state_of`) are drawn automatically by Rule's `Component.connect` — no special handling needed

This means `get_component(workflow, {:my_sm, :accumulator})` resolves by kind, while `get_component(workflow, {:my_sm, :alert_high})` resolves by the rule's name. Both work through the existing `get_component/2` tuple matching logic.

### 1D: Update StateMachine struct

**File:** `lib/workflow/state_machine.ex`

- Remove `last_known_state/2` — this was a helper for the old `MemoryAssertion` path. State access now goes through `Workflow.last_known_state/2` or `state_of()` meta_refs
- Remove `workflow` field — the old approach stored a pre-built internal workflow. The new model stores the compiled sub-components directly for transparency. The `connect` impl wires them into the parent workflow.
- Add `handlers` field to hold compiled handler rules (from both `reducer` clauses and `handle` blocks)

```elixir
defstruct [
  :name,
  :init,
  :reducer,          # original reducer fn (Form 1) or nil (Form 2)
  :accumulator,      # compiled %Accumulator{} — the state holder
  :handlers,         # [%Rule{}, ...] — handler rules (from reducer clauses or handle blocks)
  :reactors,         # [%Rule{}, ...] — reactor rules (from react blocks or reactors: keyword)
  :source,
  :hash,
  :bindings,
  :inputs,
  :outputs
]
```

### 1E: Sub-component naming and addressability

Both API forms produce named sub-components. The naming rules:

**Handlers** (state transition rules):
- Form 1 (`reducer:`): each clause gets `:"#{sm_name}_handler_#{idx}"` (auto-generated, not user-overridable since clauses are positional)
- Form 2 (`handle`): each handler gets `:"#{sm_name}_#{event_pattern}"` by default, overridable with `name:` option:
  ```elixir
  handle :add_item, %{item: item}, state, name: :custom_add do
    %{state | items: [item | state.items]}
  end
  ```

**Reactors** (state observation rules):
- Form 1 (`reactors:` keyword list): the keyword key IS the name (e.g., `threshold_exceeded: fn ... end` → `:threshold_exceeded`)
- Form 1 (`reactors:` bare function list): auto-generated `:"#{sm_name}_reactor_#{idx}"`
- Form 2 (`react`): the atom after `react` IS the name (e.g., `react :high_value do ... end` → `:high_value`)

**Component.connect draws `:component_of` edges for all sub-components:**

```elixir
# From the SM to each handler rule
{sm, handler_rule, :component_of, properties: %{kind: :handler}}
# From the SM to each reactor rule
{sm, reactor_rule, :component_of, properties: %{kind: :reactor}}
# From the SM to the accumulator
{sm, accumulator, :component_of, properties: %{kind: :accumulator}}
```

**Downstream composition via named sub-components:**

```elixir
sm = Runic.state_machine name: :cart, init: %{items: [], total: 0} do
  handle :add_item, %{item: item}, state do
    %{state | items: [item | state.items], total: state.total + item.price}
  end

  react :high_value do
    fn %{total: t} when t > 1000 -> {:vip_alert, t} end
  end
end

workflow
|> Workflow.add(sm)
# Attach a logger after the :add_item handler
|> Workflow.add(audit_step, to: {:cart, :cart_add_item})
# Attach a notifier after the :high_value reactor
|> Workflow.add(notifier_step, to: {:cart, :high_value})
# Drill into a reactor's rule internals
# get_component(workflow, {:high_value, :reaction}) → the Step node
```

### 1F: Tests for Phase 1

**File:** `test/runic_test.exs` (update existing `"Runic.state_machine/1"` describe block)  
**File:** `test/workflow_test.exs` (update existing state machine tests)  
**File:** `test/workflow/event_sourced_test.exs` (update state machine event sourced tests)

```
Core (both forms):
- state_machine compiles to accumulator + rules (no StateCondition/StateReaction/MemoryAssertion in graph)
- state machine works with react_until_satisfied
- state machine works with runner (event sourcing, replay)
- state machine composes with other components via Workflow.add
- state machine preserves content addressability (same inputs → same hash)
- state machine works with run_context (context/1 in handler/reducer)

Form 1 (keyword-list):
- reducer clauses gate correctly via state_of() conditions
- init accepts literal values (not just fn -> val end)
- reactors keyword list: key becomes reactor rule name
- unnamed reactors (bare fn in list) get auto-generated names
- reactors fire based on state_of() conditions

Form 2 (handle/react block):
- handle clauses compile to named handler rules
- handle clause matches event pattern + input pattern + state guard
- handle body receives state via state_of() meta_ref
- handle name defaults to :"#{sm_name}_#{event_pattern}", overridable with name: option
- react clauses compile to named reactor rules (observation only, no state modification)
- react name is explicitly required

Named sub-component access (both forms):
- get_component(wf, {:sm_name, :accumulator}) returns the accumulator
- get_component(wf, {:sm_name, :handler_name}) returns a handler rule by name
- get_component(wf, {:sm_name, :reactor_name}) returns a reactor rule by name
- handler/reactor sub-parts accessible: get_component(wf, {:handler_name, :reaction})
- downstream component connectable to handler: Workflow.add(step, to: {:sm_name, :handler_name})
- downstream component connectable to reactor: Workflow.add(step, to: {:sm_name, :reactor_name})
- :component_of edges drawn for all handlers, reactors, and accumulator
```

**Verification:** `mix test`

---

## Phase 2: FSM Component

**Goal:** Introduce `Runic.fsm/2` — a high-level DSL for finite state machines with discrete states, transitions, guards, and entry/exit actions. Compiles to Accumulator + Rules.

**Depends on:** Phase 1 (clean StateMachine primitives-based compilation pattern established)

### 2A: FSM struct

**File:** `lib/workflow/fsm.ex` (new)

```elixir
defmodule Runic.Workflow.FSM do
  @moduledoc """
  Finite state machine component with discrete states and guarded transitions.

  FSMs compile to an Accumulator (holding current state atom) plus Rules
  (one per transition, using state_of() to gate on current state).
  Entry/exit actions are additional rules that fire on state changes.
  """

  defstruct [
    :name,
    :initial_state,
    :states,         # %{state_name => %{transitions: [...], on_entry: fn, on_exit: fn}}
    :accumulator,    # compiled %Accumulator{}
    :rules,          # compiled [%Rule{}, ...]
    :source,
    :hash,
    :bindings,
    :inputs,
    :outputs
  ]
end
```

### 2B: FSM macro

**File:** `lib/runic.ex`

```elixir
defmacro fsm(opts \\ [], do: block) do
  # Parse the block for state/2 declarations
  # Each state declaration contains:
  #   on event, to: target_state [, guard: fn -> bool]
  #   on_entry fn -> side_effect end
  #   on_exit fn -> side_effect end
  #
  # Compile to:
  #   1. Accumulator with init: initial_state, reducer that accepts {event, target} tuples
  #   2. For each transition: Rule with
  #      - Condition: matches event pattern AND state_of(:fsm_name) == source_state [AND guard]
  #      - Step: produces {event, target_state} to feed the accumulator
  #   3. For each on_entry: Rule with
  #      - Condition: state_of(:fsm_name) == state AND previous value != state
  #      - Step: runs the entry action
  #   4. For each on_exit: similar to on_entry but for exit
end
```

**DSL syntax:**

```elixir
fsm = Runic.fsm name: :traffic_light do
  initial_state :red

  state :red do
    on :timer, to: :green
    on :emergency, to: :red
    on_entry fn -> {:notify, :traffic_stopped} end
  end

  state :green do
    on :timer, to: :yellow
    on :emergency, to: :red
  end

  state :yellow do
    on :timer, to: :red, guard: fn ctx -> ctx.duration > 3 end
    on :emergency, to: :red
  end
end
```

### 2C: FSM Component protocol

**File:** `lib/workflow/component.ex`

Implement `Runic.Component` for `Runic.Workflow.FSM`:
- `connect/3`: wire accumulator to `to` node, wire each transition rule, draw `:component_of` edges:
  - `{fsm, accumulator, :component_of, properties: %{kind: :accumulator}}`
  - `{fsm, rule, :component_of, properties: %{kind: :transition}}` for each transition rule
  - `{fsm, rule, :component_of, properties: %{kind: :entry_action}}` for on_entry rules
  - `{fsm, rule, :component_of, properties: %{kind: :exit_action}}` for on_exit rules
- Each transition rule is named `:"#{fsm_name}_#{from}_on_#{event}"`, enabling:
  ```elixir
  Workflow.get_component(workflow, {:traffic_light, :red_on_timer})
  # → [%Rule{name: :traffic_light_red_on_timer, ...}]
  
  # Connect a logging step after a specific transition
  Workflow.add(workflow, audit_step, to: {:traffic_light, :red_on_timer})
  ```
- `hash/1`: content-addressable from `{initial_state, states_map}`
- `source/1`: return the quoted macro call
- `inputs/1`, `outputs/1`: schema for events in, state atom + action outputs out

### 2D: FSM Transmutable protocol

**File:** `lib/workflow/transmutable.ex`

Implement `Runic.Transmutable` for `Runic.Workflow.FSM`:
- `to_workflow/1`: build workflow, add accumulator, add all transition rules, wire with component_of edges
- `to_component/1`: return the FSM struct

### 2E: FSM validation

The FSM should validate at construction time:
- All `to:` targets reference declared states
- No duplicate `{state, event}` transition pairs (deterministic FSM)
- `initial_state` is a declared state
- Guards are arity-0 or arity-1 functions

Compile-time validation via the macro, raising `ArgumentError` with clear messages.

### 2F: Tests for Phase 2

**File:** `test/fsm_test.exs` (new)

```
describe "Runic.fsm/2 construction"
  - creates FSM struct with correct fields
  - compiles to accumulator + rules (no legacy node types)
  - validates initial_state exists in declared states
  - validates transition targets reference declared states
  - raises on duplicate {state, event} transitions
  - content hash is deterministic

describe "FSM execution"
  - basic state transitions via react
  - guard-gated transitions
  - transition to same state (self-loop)
  - invalid event for current state (no transition, state unchanged)
  - on_entry fires when state changes
  - on_entry does not fire when state stays same
  - on_exit fires when leaving state
  - works with react_until_satisfied
  - works with Runner

describe "FSM composition"
  - FSM composes with other components via Workflow.add
  - multiple FSMs in same workflow with cross-references
  - FSM + accumulator coordination via state_of()

describe "FSM sub-component access"
  - get_component(wf, {:fsm_name, :accumulator}) returns the state accumulator
  - get_component(wf, {:fsm_name, :red_on_timer}) returns the transition rule by name
  - transition rule's sub-parts accessible: {:red_on_timer, :reaction}
  - downstream step connectable to specific transition: add(step, to: {:fsm_name, :red_on_timer})
  - entry/exit actions accessible by kind: {:fsm_name, :entry_action} returns all entry rules

describe "FSM with run_context"
  - context/1 in guard functions
  - context/1 in entry/exit actions
```

**Verification:** `mix test test/fsm_test.exs && mix test`

---

## Phase 3: Aggregate Component

**Goal:** Introduce `Runic.aggregate/2` — a CQRS/Event Sourcing aggregate with command handlers, event handlers, and state projection. Compiles to Accumulator (state from events) + Rules (command → event).

**Depends on:** Phase 1

### 3A: Aggregate struct

**File:** `lib/workflow/aggregate.ex` (new)

```elixir
defmodule Runic.Workflow.Aggregate do
  @moduledoc """
  CQRS/ES aggregate component: validates commands against current state,
  produces domain events, and projects state by folding events.

  Compiles to an Accumulator (event fold) plus Rules (command handlers
  that check state via state_of() and emit events).

  This is a domain-level abstraction. Runic's internal event sourcing
  (workflow events, replay) operates at a different layer — the aggregate's
  "events" are domain facts flowing through the workflow graph.
  """

  defstruct [
    :name,
    :initial_state,
    :command_handlers,  # [{command_pattern, guard, event_producer}]
    :event_handlers,    # [{event_pattern, state_reducer}]
    :accumulator,       # compiled %Accumulator{} (folds domain events into state)
    :rules,             # compiled [%Rule{}, ...] (command handlers as rules)
    :source,
    :hash,
    :bindings,
    :inputs,
    :outputs
  ]
end
```

### 3B: Aggregate macro

**File:** `lib/runic.ex`

```elixir
defmacro aggregate(opts \\ [], do: block) do
  # Parse block for:
  #   state %{...}                        → initial state
  #   command :name do ... end             → command handler
  #   event pattern do ... end             → event handler (state reducer clause)
  #
  # Compile to:
  #   1. Accumulator: init from state/1, reducer from all event/2 handlers
  #   2. For each command handler: Rule with
  #      - Condition: matches command pattern AND state_of(:agg_name) satisfies guard
  #      - Step: produces domain event(s)
  #   3. Command handler output feeds back to accumulator (event → state fold)
end
```

**DSL syntax:**

```elixir
aggregate = Runic.aggregate name: :order do
  state %{id: nil, status: :draft, items: [], total: 0}

  command :create_order do
    given %{id: id}
    where status == :draft
    emit {:order_created, id}
  end

  command :add_item do
    given %{item: item}
    where status == :created
    emit {:item_added, item}
  end

  command :submit_order do
    where status == :created and length(items) > 0
    emit :order_submitted
  end

  event {:order_created, id}, state do
    %{state | id: id, status: :created}
  end

  event {:item_added, item}, state do
    %{state | items: [item | state.items], total: state.total + item.price}
  end

  event :order_submitted, state do
    %{state | status: :submitted}
  end
end
```

**Macro internals:**

Within `command` blocks, bare references to state fields (e.g., `status`, `items`) are rewritten to `state_of(:agg_name).status` etc. This provides a clean DSL where the command handler reads as if the state fields are in scope, but compiles to explicit meta_ref lookups. The `emit` form becomes the rule's reaction step output.

### 3C: Aggregate Component & Transmutable protocols

Same pattern as FSM (Phase 2C/2D). The `connect/3` wires:
- Accumulator to parent
- Command handler rules with meta_ref edges to the accumulator
- Feedback connections: rule output → accumulator input (events feed back to state)
- `:component_of` edges for all sub-components:
  - `{agg, accumulator, :component_of, properties: %{kind: :accumulator}}`
  - `{agg, rule, :component_of, properties: %{kind: :command_handler}}` per command
- Command handler rules are named `:"#{agg_name}_#{command_name}"` by default, but overridable with `:name` in the command block:
  ```elixir
  command :add_item, name: :custom_add do
    # ...
  end
  
  # Addressable as:
  Workflow.get_component(workflow, {:order, :custom_add})
  # Or by the default:
  Workflow.get_component(workflow, {:order, :order_add_item})
  ```

### 3D: Tests for Phase 3

**File:** `test/aggregate_test.exs` (new)

```
describe "Runic.aggregate/2 construction"
  - creates Aggregate struct with command + event handlers
  - compiles to accumulator + rules
  - validates command handlers reference valid state fields
  - content hash is deterministic

describe "Aggregate execution"
  - command accepted when state satisfies guard
  - command rejected when state doesn't satisfy guard (no event produced)
  - event folds into state correctly
  - sequence: create → add_item → submit (full lifecycle)
  - multiple commands against same aggregate

describe "Aggregate composition"
  - aggregate composes with downstream steps
  - aggregate output (events) feeds to other components
  - multiple aggregates in same workflow

describe "Aggregate sub-component access"
  - get_component(wf, {:order, :accumulator}) returns state accumulator
  - get_component(wf, {:order, :order_add_item}) returns command handler rule by name
  - named command handler: get_component(wf, {:order, :custom_name})
  - connect downstream to command handler output: add(step, to: {:order, :order_add_item})

describe "Aggregate with run_context"
  - context/1 in command handlers
  - context/1 in event handlers
```

**Verification:** `mix test test/aggregate_test.exs && mix test`

---

## Phase 4: Saga Component

**Goal:** Introduce `Runic.saga/2` — a compensating-action control flow component for non-CQRS models. Provides a `with`-like API where each step has an explicit compensation, and failure at any point triggers compensations in reverse order.

**Depends on:** Phase 1

### 4A: Saga struct

**File:** `lib/workflow/saga.ex` (new)

```elixir
defmodule Runic.Workflow.Saga do
  @moduledoc """
  Saga component: a sequence of steps with compensating actions.

  Unlike ProcessManager (Phase 5), Sagas are explicit forward-then-compensate
  pipelines without CQRS semantics. Think of them as a more powerful `with`
  statement where each step has a paired undo.

  Compiles to an Accumulator (tracking saga state: step results + status)
  plus Rules for forward steps, compensation triggers, and compensation steps.
  """

  defstruct [
    :name,
    :steps,            # [{step_name, forward_fn, compensate_fn}]
    :on_complete,      # optional final success handler
    :on_abort,         # optional final abort handler
    :accumulator,      # compiled — tracks saga progress
    :rules,            # compiled — forward + compensation rules
    :source,
    :hash,
    :bindings,
    :inputs,
    :outputs
  ]
end
```

### 4B: Saga macro — API options

(See [Saga API Exploration](#saga-api-exploration) below for detailed API alternatives)

**Chosen approach: `transaction`/`compensate` block pairs** — idiomatic to both Elixir's `with` pattern and Runic's declarative style.

**File:** `lib/runic.ex`

```elixir
defmacro saga(opts \\ [], do: block) do
  # Parse block for transaction/compensate pairs
  # Compile to Accumulator + Rules
end
```

**DSL syntax:**

```elixir
saga = Runic.saga name: :fulfillment do
  transaction :reserve_inventory do
    fn %{order: order} -> InventoryService.reserve(order.items) end
  end
  compensate :reserve_inventory do
    fn %{reserve_inventory: reservation} -> InventoryService.release(reservation) end
  end

  transaction :charge_payment do
    fn %{order: order, reserve_inventory: _reservation} ->
      PaymentService.charge(order.payment_method, order.total)
    end
  end
  compensate :charge_payment do
    fn %{charge_payment: charge} -> PaymentService.refund(charge) end
  end

  transaction :create_shipment do
    fn %{order: order, reserve_inventory: reservation} ->
      ShippingService.create(order.address, reservation)
    end
  end
  compensate :create_shipment do
    fn %{create_shipment: shipment} -> ShippingService.cancel(shipment) end
  end

  on_complete fn results -> {:saga_completed, results} end
  on_abort fn reason, compensated -> {:saga_aborted, reason, compensated} end
end
```

### 4C: Saga internal compilation

The saga compiles to:

1. **Accumulator** (`:{saga_name}_state`) — tracks:
   - `status`: `:pending | :running | :compensating | :completed | :aborted`
   - `completed_steps`: `[{step_name, result}]` (in execution order)
   - `current_step`: atom
   - `failure_reason`: term | nil

2. **Forward rules** — one per transaction step, chained sequentially:
   - Condition: `state_of(:saga_state).status == :running and state_of(:saga_state).current_step == :step_name`
   - Step: executes the forward function with accumulated results
   - On success: produces `{:step_completed, step_name, result}` → feeds accumulator
   - On error/exception: produces `{:step_failed, step_name, reason}` → feeds accumulator, triggers compensation

3. **Compensation rules** — one per compensate block, triggered in reverse:
   - Condition: `state_of(:saga_state).status == :compensating and :step_name in completed_steps`
   - Step: executes the compensation function with the step's original result
   - Produces `{:compensated, step_name}` → feeds accumulator

4. **Terminal rules** — `on_complete` and `on_abort` handlers fire when saga reaches terminal state

### 4D: Saga Component & Transmutable protocols

Same pattern as FSM/Aggregate.

### 4E: Tests for Phase 4

**File:** `test/saga_test.exs` (new)

```
describe "Runic.saga/2 construction"
  - creates Saga struct with transaction/compensate pairs
  - compiles to accumulator + rules
  - validates each transaction has a corresponding compensate
  - raises on orphaned compensate (no matching transaction)

describe "Saga execution — happy path"
  - all steps execute in order
  - each step receives prior results
  - on_complete fires with all results
  - saga state ends as :completed

describe "Saga execution — compensation"
  - failure at step N triggers compensation of steps N-1...1 in reverse
  - compensation functions receive original step results
  - on_abort fires with reason and compensated steps
  - saga state ends as :aborted
  - first step fails — no compensations needed (empty completed_steps)

describe "Saga composition"
  - saga composes with upstream/downstream components
  - saga output feeds to other workflow components

describe "Saga with run_context"
  - context/1 in transaction functions (e.g., API keys)
  - context/1 in compensation functions
```

**Verification:** `mix test test/saga_test.exs && mix test`

---

## Phase 5: ProcessManager Component

**Goal:** Introduce `Runic.process_manager/2` — a CQRS-oriented process manager (orchestration saga) that reacts to domain events from multiple sources, maintains coordination state, and emits commands.

**Depends on:** Phase 1, Phase 3 (uses similar patterns as Aggregate)

### 5A: ProcessManager struct

**File:** `lib/workflow/process_manager.ex` (new)

```elixir
defmodule Runic.Workflow.ProcessManager do
  @moduledoc """
  Process manager (orchestration saga): reacts to events across aggregates,
  maintains coordination state, and issues commands to drive a business process.

  Unlike Saga (Phase 4), ProcessManagers are event-driven and reactive rather
  than sequential. They subscribe to event patterns from multiple sources and
  decide what commands to issue based on accumulated state.

  Compiles to an Accumulator (coordination state) plus Rules (event → command).
  """

  defstruct [
    :name,
    :initial_state,
    :event_handlers,    # [{event_pattern, state_update, commands_to_emit}]
    :timeout_handlers,  # [{timeout_name, duration, handler}]
    :completion_check,  # fn state -> boolean (when is process complete?)
    :accumulator,
    :rules,
    :source,
    :hash,
    :bindings,
    :inputs,
    :outputs
  ]
end
```

### 5B: ProcessManager macro

**File:** `lib/runic.ex`

```elixir
defmacro process_manager(opts \\ [], do: block) do
  # Parse block for:
  #   state %{...}
  #   on event_pattern do ... end    → event handler that updates state + emits commands
  #   timeout :name, duration do ... end
  #   complete? fn state -> bool end
end
```

**DSL syntax:**

```elixir
pm = Runic.process_manager name: :fulfillment do
  state %{
    order_id: nil,
    order_submitted: false,
    payment_received: false,
    inventory_reserved: false,
    shipped: false
  }

  on {:order_submitted, order_id} do
    update %{order_id: order_id, order_submitted: true}
    emit {:command, :payment, %{type: :charge, order_id: order_id}}
  end

  on {:payment_received, _} do
    update %{payment_received: true}
    emit {:command, :inventory, %{type: :reserve, order_id: state.order_id}}
  end

  on {:inventory_reserved, _} do
    update %{inventory_reserved: true}
    emit {:command, :shipping, %{type: :ship, order_id: state.order_id}}
  end

  on {:shipment_created, _} do
    update %{shipped: true}
  end

  timeout :payment, :timer.minutes(5) do
    when not state.payment_received
    emit {:command, :order, %{type: :cancel, reason: :payment_timeout}}
  end

  complete? fn state ->
    state.shipped or (state.order_submitted and not state.payment_received)
  end
end
```

### 5C: ProcessManager compilation

Compiles to:

1. **Accumulator** — holds coordination state, reducer built from `update` clauses
2. **Event handler rules** — one per `on` block:
   - Condition: matches event pattern, optionally checks `state_of()` guard
   - Step: produces command tuple(s) as output facts
   - State update: feeds the update map to the accumulator
3. **Timeout rules** — compiled as rules that match timeout events with `state_of()` guards
4. **Completion rule** — fires `complete?` check after each state update, produces completion fact

**Note on timeouts:** Runic is a pure functional core. Timeout scheduling is the Runner's responsibility. The ProcessManager declares timeout specifications; the Runner creates timer events. The `timeout` block compiles to a rule that matches `{:timeout, :name}` events with a `state_of()` guard.

### 5D: ProcessManager Component & Transmutable protocols

Same pattern as prior components.

### 5E: Tests for Phase 5

**File:** `test/process_manager_test.exs` (new)

```
describe "Runic.process_manager/2 construction"
  - creates ProcessManager struct
  - compiles to accumulator + event handler rules
  - validates event handler patterns

describe "ProcessManager execution"
  - event triggers state update + command emission
  - multiple events drive process through stages
  - completion check fires at correct state
  - timeout event triggers compensation when guard satisfied
  - timeout event ignored when guard not satisfied

describe "ProcessManager composition"
  - PM reacts to events from an Aggregate in same workflow
  - PM commands feed to Aggregate command handlers (full loop)
  - multiple PMs in same workflow
```

**Verification:** `mix test test/process_manager_test.exs && mix test`

---

## Phase 6: Documentation & Guides

**Goal:** Document all new components with guides and module docs.

**Depends on:** Phases 1–5

### 6A: Module documentation

Each new component module (`fsm.ex`, `aggregate.ex`, `saga.ex`, `process_manager.ex`) gets `@moduledoc` with:
- Conceptual overview
- Relationship to Runic primitives
- DSL syntax reference
- Examples

### 6B: Guide

**File:** `guides/state-based-components.md` (new)

- When to use FSM vs Aggregate vs Saga vs ProcessManager
- How they compile to primitives (architecture transparency)
- Composition patterns (cross-component state_of references)
- Interaction with Runner (durability, replay, timeouts)
- Migration from legacy StateMachine

### 6C: Update existing docs

- **`guides/cheatsheet.md`**: Add all new component constructor examples
- **`README.md`**: Update component list, add state component examples

---

## Phase Dependencies & Parallel Work Streams

```
Phase 1 ─── Legacy Removal & StateMachine Rebuild (foundation)
  │
  ├──────────────────┬──────────────────┐
  │                  │                  │
  ▼                  ▼                  ▼
Phase 2            Phase 3            Phase 4
  FSM              Aggregate           Saga
  │                  │                  │
  │                  ├──────────────────┘
  │                  │
  │                  ▼
  │              Phase 5
  │              ProcessManager
  │                  │
  ├──────────────────┘
  │
  ▼
Phase 6 ─── Documentation
```

**Parallel streams after Phase 1:**
- **Stream A**: Phase 2 (FSM) — independent, no dependency on Aggregate/Saga
- **Stream B**: Phase 3 (Aggregate) + Phase 5 (ProcessManager) — PM uses patterns from Aggregate
- **Stream C**: Phase 4 (Saga) — independent, but can run parallel with Stream A/B

Phase 6 depends on all prior phases.

---

## Saga API Exploration

Three API styles were considered for the Saga component. All compile to the same internal representation.

### Option A: `transaction`/`compensate` blocks (chosen)

```elixir
Runic.saga name: :fulfillment do
  transaction :reserve_inventory do
    fn %{order: order} -> InventoryService.reserve(order.items) end
  end
  compensate :reserve_inventory do
    fn %{reserve_inventory: reservation} -> InventoryService.release(reservation) end
  end

  transaction :charge_payment do
    fn %{order: order} -> PaymentService.charge(order) end
  end
  compensate :charge_payment do
    fn %{charge_payment: charge} -> PaymentService.refund(charge) end
  end
end
```

**Pros:** Explicit pairing, reads like a spec, each step is independently named  
**Cons:** Verbose, compensate can be far from its transaction

### Option B: `step` with inline `:compensate` option (with-like)

```elixir
Runic.saga name: :fulfillment do
  step :reserve_inventory,
    do: fn %{order: order} -> InventoryService.reserve(order.items) end,
    compensate: fn %{reserve_inventory: res} -> InventoryService.release(res) end

  step :charge_payment,
    do: fn %{order: order} -> PaymentService.charge(order) end,
    compensate: fn %{charge_payment: ch} -> PaymentService.refund(ch) end

  step :create_shipment,
    do: fn %{order: order} -> ShippingService.create(order) end,
    compensate: fn %{create_shipment: sh} -> ShippingService.cancel(sh) end
end
```

**Pros:** Compact, forward+compensate colocated, visually similar to `with` clauses  
**Cons:** Long lines, harder to add metadata per step

### Option C: Keyword-list constructor (no block DSL)

```elixir
Runic.saga(
  name: :fulfillment,
  steps: [
    {:reserve_inventory,
      &InventoryService.reserve/1,
      &InventoryService.release/1},
    {:charge_payment,
      &PaymentService.charge/1,
      &PaymentService.refund/1},
    {:create_shipment,
      &ShippingService.create/1,
      &ShippingService.cancel/1}
  ]
)
```

**Pros:** No macro magic, works as data, easy to generate programmatically  
**Cons:** No access to prior step results in the type signature, less expressive

### Recommendation

**Option A** as the primary DSL for expressiveness and clarity. **Option C** as an alternative constructor `Runic.saga/1` (keyword-list form) for programmatic construction. Both compile to the same `%Saga{}` struct.

---

## Files Modified Summary

### New Files

| File | Purpose |
|------|---------|
| `lib/workflow/fsm.ex` | FSM struct |
| `lib/workflow/aggregate.ex` | Aggregate struct |
| `lib/workflow/saga.ex` | Saga struct |
| `lib/workflow/process_manager.ex` | ProcessManager struct |
| `test/fsm_test.exs` | FSM tests |
| `test/aggregate_test.exs` | Aggregate tests |
| `test/saga_test.exs` | Saga tests |
| `test/process_manager_test.exs` | ProcessManager tests |
| `guides/state-based-components.md` | Guide |

### Deleted Files

| File | Reason |
|------|--------|
| `lib/workflow/state_condition.ex` | Replaced by Condition + state_of() |
| `lib/workflow/state_reaction.ex` | Replaced by Step + state_of() |
| `lib/workflow/memory_assertion.ex` | Replaced by Condition + state_of() |

### Modified Files

| File | Changes |
|------|---------|
| `lib/runic.ex` | Remove legacy SM compilation; add `fsm/2`, `aggregate/2`, `saga/2`, `process_manager/2` macros; remove `StateCondition`/`StateReaction`/`MemoryAssertion` aliases |
| `lib/workflow/state_machine.ex` | Remove `last_known_state/2`; update struct fields |
| `lib/workflow/component.ex` | Update StateMachine connect; add FSM, Aggregate, Saga, ProcessManager Component impls |
| `lib/workflow/transmutable.ex` | Add FSM, Aggregate, Saga, ProcessManager Transmutable impls |
| `lib/workflow/invokable.ex` | Remove StateCondition, StateReaction, MemoryAssertion impls |
| `lib/workflow/serializer.ex` | Remove legacy node serialization; add new component serialization |
| `test/runic_test.exs` | Update state_machine tests |
| `test/workflow_test.exs` | Update state_machine integration tests |
| `test/workflow/event_sourced_test.exs` | Update state_machine event sourced tests |
| `test/component_protocol_test.exs` | Update SM tests, add new component tests |
| `test/transmutable_protocol_test.exs` | Update SM tests, add new component tests |
| `test/content_addressability_test.exs` | Update SM tests, add new component tests |
| `guides/cheatsheet.md` | Add new component examples |
| `README.md` | Update component list |

---

## Risk Areas & Testing Strategy

### 1. StateMachine backward compatibility

The rebuilt StateMachine must produce identical runtime behavior: same state transitions, same fact production, same event stream. The existing test suite is the regression gate.

**Mitigation:** Run existing StateMachine tests after Phase 1. Compare workflow graph structure before/after — vertex/edge counts, edge labels, fact values.

* Note that Runic is not yet published to hex and breaking changes are OK as long as the core concept of a state machine is maintained. We CAN break apis on this state machine if it enables a better experience long term. Some of the state machine tests were commented out for example because I planned to rework it. So we can be flexible in this regard.

### 2. Meta_ref resolution for generated rules

When the FSM/Aggregate/Saga macros generate rules with `state_of()`, the meta_ref detection must work correctly on the generated AST. The existing `detect_meta_expressions` function operates on AST — generated code must include the `state_of()` calls in a form the detector recognizes.

**Mitigation:** Unit test that each component's compiled rules have the expected `meta_refs` on their conditions/steps. Verify `:meta_ref` edges appear in the workflow graph after `connect`.

### 3. Feedback loops (event → accumulator → rule → event)

Aggregates and ProcessManagers create feedback loops: command → event → state update → next rule. These must terminate. The `react_until_satisfied` function already handles convergence (no new runnables), so this is safe as long as the domain logic converges.

**Mitigation:** Test with known-convergent scenarios. Document that non-converging command sequences will loop. Consider an optional `:max_iterations` on the component for safety.

### 4. Saga compensation ordering

Compensation must execute in reverse order of completed steps. Since Runic's dataflow is parallel by default, the compensation rules must be explicitly sequenced — each compensation rule's condition checks that the *next* compensation (in reverse order) has already completed or is not needed.

**Mitigation:** The saga accumulator tracks compensation progress. Each compensation rule gates on `state_of(:saga_state).next_to_compensate == :my_step`. The accumulator advances `next_to_compensate` as each compensation completes.

### 5. Interaction with Runner eventsourcing

The new components must produce event streams that are replayable via `from_log/from_events`. Since they compile to standard primitives (Accumulator, Rule, Condition, Step), and those primitives already have event-sourced Invokable implementations, this should work by construction.

**Mitigation:** Add replay round-trip tests for each component type: build workflow → execute → `build_log` → `from_log` → verify state matches.

### 6. No new Invokable nodes

This plan explicitly avoids new Invokable implementations. If during implementation a component requires a fundamentally different dataflow interaction (not expressible as Accumulator + Rule + Step), that signals a design issue to re-evaluate before proceeding. The bar for a new Invokable is: "no existing node can model this execution/data pattern or is too complicated with existing nodes and benefits from a new one to reduce complexity."
