# State-Based Component Exploration

> **Status**: Draft  
> **Related**: [Meta Expression Plan](./meta-expression-plan.md), Accumulator, StateMachine, Invokable protocol  
> **Goal**: Redesign state machine components using meta expressions and composable primitives

## Table of Contents

1. [Overview](#overview)
2. [Current State Machine Analysis](#current-state-machine-analysis)
3. [First Principles: State in Dataflow Systems](#first-principles-state-in-dataflow-systems)
4. [State Models Taxonomy](#state-models-taxonomy)
5. [Redesign: Composable State Primitives](#redesign-composable-state-primitives)
6. [Finite State Machines](#finite-state-machines)
7. [Unbounded State Machines](#unbounded-state-machines)
8. [Rule Rewriting Systems](#rule-rewriting-systems)
9. [Event Sourced CQRS Models](#event-sourced-cqrs-models)
10. [Component Composition Patterns](#component-composition-patterns)
11. [API Alternatives](#api-alternatives)
12. [Concerns and Trade-offs](#concerns-and-trade-offs)
13. [Open Questions](#open-questions)

---

## Overview

### Why Redesign?

The current `StateMachine` component is tightly coupled, building a specialized internal workflow with `StateCondition`, `StateReaction`, and `MemoryAssertion` nodes. This approach:

1. **Duplicates concepts** - `StateCondition` and `MemoryAssertion` overlap with what `state_of()` meta expressions can achieve
2. **Limited composability** - Cannot easily combine state machines with other components
3. **Hard to extend** - Adding new state patterns requires new node types
4. **Opaque internals** - Users can't easily understand or modify the generated workflow

### Design Goals

1. **Composable primitives** - Build state machines from Accumulators + Rules + meta expressions
2. **Unified mental model** - `state_of(:component)` works the same everywhere
3. **Extensible patterns** - FSM, unbounded state, CQRS aggregates share common building blocks
4. **Transparent construction** - Users can see and modify how state machines work

### Meta Expressions as Foundation

With meta expressions (see [meta-expression-plan.md](./meta-expression-plan.md)), we can reference workflow state directly in rule conditions and reactions:

```elixir
rule do
  given command: %{type: :add_item, item: item}
  where state_of(:cart_state).status == :open
  then fn %{command: cmd} -> 
    {:item_added, cmd.item}
  end
end
```

This enables building state machines from composable parts rather than specialized structs.

---

## Current State Machine Analysis

### Current Structure

```elixir
%StateMachine{
  name: :counter,
  init: fn -> 0 end,
  reducer: fn x, acc -> acc + x end,
  reactors: [fn state when state > 100 -> :threshold_exceeded end],
  workflow: %Workflow{...},  # Pre-built internal workflow
  ...
}
```

### Current Internal Workflow

When a `StateMachine` is constructed, it builds an internal workflow with:

1. **`StateCondition` nodes** - Pattern match on `(input, last_known_state)` to gate the reducer
2. **`Accumulator` node** - The actual stateful reducer
3. **`MemoryAssertion` nodes** - For each reactor, checks `last_known_state` against a pattern
4. **`StateReaction` nodes** - Produces output when memory assertion is satisfied

```
                    ┌─────────────────┐
                    │ StateCondition  │──── Pattern match input + state
                    │  (fn x, acc)    │
                    └────────┬────────┘
                             │
                             ▼
                    ┌─────────────────┐
                    │   Accumulator   │──── Stateful reducer
                    │  (init, reduce) │
                    └────────┬────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
              ▼              ▼              ▼
     ┌────────────────┐ ┌────────────────┐ ┌────────────────┐
     │MemoryAssertion │ │MemoryAssertion │ │MemoryAssertion │
     │  (reactor 1)   │ │  (reactor 2)   │ │  (reactor N)   │
     └───────┬────────┘ └───────┬────────┘ └───────┬────────┘
             │                  │                  │
             ▼                  ▼                  ▼
     ┌────────────────┐ ┌────────────────┐ ┌────────────────┐
     │ StateReaction  │ │ StateReaction  │ │ StateReaction  │
     │   (output 1)   │ │   (output 2)   │ │   (output N)   │
     └────────────────┘ └────────────────┘ └────────────────┘
```

### Problems with Current Approach

1. **`MemoryAssertion` executes during prepare** - Breaks the pure execute phase model
2. **Tight coupling to Accumulator** - `state_hash` references create implicit dependencies
3. **No reuse** - Each reactor creates duplicate MemoryAssertion + StateReaction pairs
4. **Limited expressiveness** - Can't compose with external state sources

---

## First Principles: State in Dataflow Systems

### What is "State" in Runic?

State in a dataflow system is **accumulated knowledge derived from facts**. In Runic:

- **Facts** are immutable values with causal ancestry
- **Accumulators** fold facts into state, producing new state facts
- **State facts** are like any other fact, but with `:state_produced` edges

### The State Reference Problem

To make decisions based on state, a node needs to:

1. **Identify** which component's state to reference
2. **Retrieve** the current state value (latest by causal depth)
3. **Incorporate** that value into its execution

The three-phase model constrains this:
- **Prepare**: Can access workflow, fetch state
- **Execute**: No workflow access, only `CausalContext`
- **Apply**: Reduce results back

**Solution**: Meta expressions inject state into `CausalContext` during prepare.

### State as Edges, Not Special Nodes

Rather than specialized `StateCondition`/`StateReaction` nodes, we can use:

- **`:meta_ref` edges** connect any node to a state source
- **Prepare phase** traverses these edges to populate `meta_context`
- **Regular `Condition`/`Step` nodes** receive state as input

This unifies state handling across all components.

---

## State Models Taxonomy

### 1. Finite State Machines (FSM)

**Characteristics**:
- Bounded set of discrete states (`:idle`, `:processing`, `:complete`)
- Events/inputs trigger transitions between states
- Guards can prevent invalid transitions
- Actions fire on entry, exit, or transitions

**Example domains**: Protocol implementations, UI flows, order lifecycles

### 2. Unbounded State Machines

**Characteristics**:
- State is any arbitrary value (counter, list, map)
- No predefined state set - state space is infinite
- State evolves through reducer functions
- Runic's current `Accumulator` is already this model

**Example domains**: Counters, shopping carts, running aggregations

### 3. Rule Rewriting Systems (Wolfram-style)

**Characteristics**:
- State is a graph or pattern structure
- Rules match sub-patterns and rewrite them
- Non-deterministic - multiple rules may apply
- Emergent behavior from simple local rules

**Example domains**: Cellular automata, graph transformations, symbolic computation

### 4. Event Sourced CQRS

**Characteristics**:
- Commands express intent
- Aggregates validate commands against current state
- Events are produced (immutable facts)
- State is derived by folding events
- Process managers react to events across aggregates

**Example domains**: Domain-driven design, distributed systems, audit logs

---

## Redesign: Composable State Primitives

### Core Insight

All state models can be built from three primitives:

1. **Accumulator** - Folds facts into state
2. **Rule with `state_of()`** - Conditional logic referencing state
3. **Step with `state_of()`** - Transforms that read state

### The New Model

```elixir
# Instead of a monolithic StateMachine, compose from primitives:

# 1. State holder
cart_state = Runic.accumulator(
  name: :cart_state,
  init: %{items: [], status: :open, total: 0},
  reducer: fn event, state ->
    case event do
      {:item_added, item} -> 
        %{state | items: [item | state.items], total: state.total + item.price}
      {:cart_closed} -> 
        %{state | status: :closed}
      _ -> state
    end
  end
)

# 2. Command validation rules (reference state via meta expression)
add_item_rule = Runic.rule name: :validate_add_item do
  given command: %{type: :add_item, item: item}
  where state_of(:cart_state).status == :open
  then fn %{command: cmd} -> {:item_added, cmd.item} end
end

# 3. Compose into workflow
workflow = Workflow.new()
  |> Workflow.add(cart_state)
  |> Workflow.add(add_item_rule, to: :cart_state)  # Events feed back to accumulator
```

### Edge-Injected Meta Context Flow

```
      Input Fact
          │
          ▼
    ┌───────────┐
    │   Rule    │
    │ Condition │◄─────────────────┐
    └─────┬─────┘                  │
          │                        │
          │  :meta_ref edge        │ (prepare phase fetches state)
          │  kind: :state_of       │
          │                        │
          ▼                        │
    ┌───────────────┐              │
    │  Accumulator  │──────────────┘
    │  :cart_state  │
    └───────────────┘
```

During prepare:
```elixir
# Invokable.prepare for Condition traverses :meta_ref edges
def prepare(%Condition{meta_refs: refs} = cond, workflow, fact) when refs != [] do
  meta_context = prepare_meta_context(workflow, cond)
  
  context = CausalContext.new(
    node_hash: cond.hash,
    input_fact: fact,
    meta_context: meta_context  # <- Injected state values
  )
  
  {:ok, Runnable.new(cond, fact, context)}
end
```

---

## Finite State Machines

### FSM as Rule + Accumulator Composition

A finite state machine is just an accumulator with:
- State constrained to discrete values
- Transition rules that check current state + event

```elixir
# Define the FSM state type (for documentation/validation)
defmodule TrafficLight do
  @states [:red, :yellow, :green]
  @events [:timer, :emergency]
  
  def transitions do
    %{
      {:red, :timer} => :green,
      {:green, :timer} => :yellow,
      {:yellow, :timer} => :red,
      {_, :emergency} => :red
    }
  end
end

# Build FSM from primitives
fsm_state = Runic.accumulator(
  name: :traffic_light,
  init: :red,
  reducer: fn event, current_state ->
    TrafficLight.transitions()
    |> Map.get({current_state, event}, current_state)
  end
)

# Transition rules with guards
timer_transition = Runic.rule name: :timer_transition do
  given event: :timer
  where state_of(:traffic_light) in [:red, :green, :yellow]
  then fn _ -> :timer end  # Pass event to accumulator
end

emergency_rule = Runic.rule name: :emergency do
  given event: :emergency
  then fn _ -> :emergency end
end

# Side effects on state changes
notify_on_red = Runic.rule name: :notify_red do
  given _
  where state_of(:traffic_light) == :red and 
        latest_value_of(:traffic_light) != :red  # State just changed
  then fn _ -> {:notification, :traffic_stopped} end
end
```

### FSM DSL Option (Sugar over primitives)

```elixir
# High-level DSL that compiles to Accumulator + Rules
fsm = Runic.fsm name: :traffic_light do
  initial_state :red
  
  state :red do
    on :timer, to: :green
    on :emergency, to: :red  # Stay red
    on_entry fn -> broadcast(:traffic_stopped) end
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

This would compile to:

```elixir
# Expands to:
accumulator = Runic.accumulator(
  name: :traffic_light,
  init: :red,
  reducer: &transition_reducer/2
)

transition_rules = [
  Runic.rule(name: :red_timer, do: ...),
  Runic.rule(name: :red_emergency, do: ...),
  # ...
]

entry_actions = [
  Runic.rule(name: :red_entry, do: ...)
]
```

### FSM Variation: Hierarchical States (HSM)

```elixir
# Nested states - the state value becomes a path
hsm = Runic.fsm name: :media_player do
  initial_state [:stopped]
  
  state :stopped do
    on :play, to: [:playing, :normal]
  end
  
  state :playing do
    on :stop, to: [:stopped]
    
    state :normal do
      on :fast_forward, to: [:playing, :fast]
    end
    
    state :fast do
      on :normal, to: [:playing, :normal]
    end
  end
end

# State becomes: [:stopped] | [:playing, :normal] | [:playing, :fast]
# Allows: state_of(:media_player) |> hd() == :playing
```

---

## Unbounded State Machines

### Already Supported: Accumulator

The `Accumulator` component is already an unbounded state machine:

```elixir
counter = Runic.accumulator(
  name: :counter,
  init: 0,
  reducer: fn x, acc -> acc + x end
)
```

### Enhanced with Meta Expressions

With meta expressions, unbounded state becomes more useful:

```elixir
# Accumulator for user session
session_state = Runic.accumulator(
  name: :user_session,
  init: %{
    user_id: nil,
    login_time: nil,
    action_count: 0,
    last_action: nil
  },
  reducer: fn 
    {:login, user_id}, state -> 
      %{state | user_id: user_id, login_time: DateTime.utc_now(), action_count: 0}
    {:action, action}, state ->
      %{state | action_count: state.action_count + 1, last_action: action}
    :logout, state ->
      %{state | user_id: nil, login_time: nil}
  end
)

# Rules that reference session state
rate_limit_rule = Runic.rule name: :rate_limit do
  given action: _
  where state_of(:user_session).action_count > 100
  then fn _ -> {:error, :rate_limited} end
end

session_timeout_rule = Runic.rule name: :session_timeout do
  given _
  where not is_nil(state_of(:user_session).login_time) and
        DateTime.diff(DateTime.utc_now(), state_of(:user_session).login_time, :minute) > 30
  then fn _ -> :logout end
end
```

### Windowed/Temporal State

```elixir
# Sliding window accumulator
windowed_avg = Runic.accumulator(
  name: :windowed_avg,
  init: %{window: [], window_size: 100},
  reducer: fn value, %{window: w, window_size: size} = state ->
    new_window = Enum.take([value | w], size)
    avg = Enum.sum(new_window) / length(new_window)
    %{state | window: new_window, current_avg: avg}
  end
)

# Alert when average exceeds threshold
alert_rule = Runic.rule name: :high_avg_alert do
  given _
  where state_of(:windowed_avg).current_avg > 95.0
  then fn _ -> {:alert, :high_average} end
end
```

---

## Rule Rewriting Systems

### Wolfram-Style Graph Rewriting

In rule rewriting systems, the "state" is a graph structure, and rules match sub-patterns to rewrite them.

**Challenge**: Runic's current model assumes facts flow forward. Rule rewriting requires:
1. Pattern matching on graph structure
2. Destructive rewriting (remove + add nodes)
3. Non-deterministic rule selection

### Modeling with Accumulators

We can model graph state as an accumulator where:
- State is a graph structure (using libgraph)
- Events are rewrite operations
- Rules match on graph patterns via `state_of()`

```elixir
# Graph state accumulator
graph_state = Runic.accumulator(
  name: :graph,
  init: Graph.new() |> Graph.add_vertex(:A) |> Graph.add_vertex(:B),
  reducer: fn
    {:add_vertex, v}, graph -> Graph.add_vertex(graph, v)
    {:add_edge, v1, v2}, graph -> Graph.add_edge(graph, v1, v2)
    {:remove_vertex, v}, graph -> Graph.delete_vertex(graph, v)
    {:rewrite, old_pattern, new_pattern}, graph -> 
      apply_rewrite(graph, old_pattern, new_pattern)
  end
)

# Rewrite rules (match pattern, produce rewrite event)
rule_a = Runic.rule name: :wolfram_rule_110 do
  given _
  where pattern_exists?(state_of(:graph), [:black, :white, :white])
  then fn _ -> 
    {:rewrite, [:black, :white, :white], [:black, :black, :white]}
  end
end
```

### Cellular Automata Variation

```elixir
# 1D cellular automaton as accumulator
ca_state = Runic.accumulator(
  name: :cellular_automaton,
  init: %{cells: [0,0,0,1,0,0,0], rule: 110, generation: 0},
  reducer: fn :tick, state ->
    new_cells = apply_rule(state.cells, state.rule)
    %{state | cells: new_cells, generation: state.generation + 1}
  end
)

# Termination condition
stable_pattern = Runic.rule name: :detect_stable do
  given _
  where state_of(:cellular_automaton).cells == latest_value_of(:cellular_automaton)
  then fn _ -> :stable_pattern_detected end
end
```

### Concerns with Rewriting Systems

1. **Non-determinism** - Multiple rules may match; need conflict resolution strategy
2. **Termination** - No guarantee rewriting terminates
3. **Performance** - Pattern matching on graphs is expensive
4. **Causality** - Rewriting breaks simple causal chains

**Potential solution**: A `RewriteSystem` component that:
- Maintains rule priority/salience
- Limits iterations per cycle
- Tracks rewrite history as facts

---

## Event Sourced CQRS Models

### Aggregates

An **Aggregate** in CQRS/Event Sourcing:
1. Receives commands
2. Validates against current state (derived from past events)
3. Produces events if valid
4. State is rebuilt by folding events

This maps naturally to Runic:

```elixir
# Aggregate state from events
order_state = Runic.accumulator(
  name: :order_aggregate,
  init: %{
    id: nil,
    status: :draft,
    items: [],
    total: 0
  },
  reducer: fn
    # Events update state
    {:order_created, id}, state -> 
      %{state | id: id, status: :created}
    {:item_added, item}, state -> 
      %{state | items: [item | state.items], total: state.total + item.price}
    {:order_submitted}, state -> 
      %{state | status: :submitted}
    {:order_cancelled}, state -> 
      %{state | status: :cancelled}
  end
)

# Command handlers (validate + produce events)
create_order = Runic.rule name: :create_order do
  given command: %{type: :create_order, id: id}
  where state_of(:order_aggregate).status == :draft
  then fn %{command: cmd} -> {:order_created, cmd.id} end
end

add_item = Runic.rule name: :add_item do
  given command: %{type: :add_item, item: item}
  where state_of(:order_aggregate).status == :created
  then fn %{command: cmd} -> {:item_added, cmd.item} end
end

submit_order = Runic.rule name: :submit_order do
  given command: %{type: :submit_order}
  where state_of(:order_aggregate).status == :created and
        length(state_of(:order_aggregate).items) > 0
  then fn _ -> {:order_submitted} end
end

cancel_order = Runic.rule name: :cancel_order do
  given command: %{type: :cancel_order}
  where state_of(:order_aggregate).status in [:created, :submitted]
  then fn _ -> {:order_cancelled} end
end
```

### Process Managers (Sagas)

A **Process Manager** reacts to events from multiple aggregates, potentially issuing commands:

```elixir
# Process manager state
fulfillment_saga = Runic.accumulator(
  name: :fulfillment_saga,
  init: %{
    order_id: nil,
    order_submitted: false,
    payment_received: false,
    inventory_reserved: false,
    shipped: false
  },
  reducer: fn
    {:order_submitted, order_id}, state ->
      %{state | order_id: order_id, order_submitted: true}
    {:payment_received, _}, state ->
      %{state | payment_received: true}
    {:inventory_reserved, _}, state ->
      %{state | inventory_reserved: true}
    {:shipment_created, _}, state ->
      %{state | shipped: true}
  end
)

# React to order submission - request payment
request_payment = Runic.rule name: :request_payment do
  given event: {:order_submitted, order_id}
  then fn %{event: {_, order_id}} -> 
    {:command, :payment, %{type: :charge, order_id: order_id}}
  end
end

# React to payment - reserve inventory
reserve_inventory = Runic.rule name: :reserve_inventory do
  given event: {:payment_received, _}
  where state_of(:fulfillment_saga).order_submitted == true
  then fn _ -> 
    {:command, :inventory, %{type: :reserve, order_id: state_of(:fulfillment_saga).order_id}}
  end
end

# Compensation on timeout
compensation_timeout = Runic.rule name: :payment_timeout do
  given event: {:timeout, :payment}
  where state_of(:fulfillment_saga).order_submitted == true and
        state_of(:fulfillment_saga).payment_received == false
  then fn _ -> 
    {:command, :order, %{type: :cancel_order, reason: :payment_timeout}}
  end
end
```

### CQRS DSL Option

```elixir
# High-level DSL for aggregates
aggregate = Runic.aggregate name: :order do
  state %{
    id: nil,
    status: :draft,
    items: [],
    total: 0
  }
  
  # Command handlers
  command :create_order do
    given %{id: id}
    when status == :draft
    emit {:order_created, id}
  end
  
  command :add_item do
    given %{item: item}
    when status == :created
    emit {:item_added, item}
  end
  
  command :submit_order do
    when status == :created and length(items) > 0
    emit {:order_submitted}
  end
  
  # Event handlers (state transitions)
  event {:order_created, id} do
    %{state | id: id, status: :created}
  end
  
  event {:item_added, item} do
    %{state | items: [item | state.items], total: state.total + item.price}
  end
  
  event {:order_submitted} do
    %{state | status: :submitted}
  end
end
```

---

## Component Composition Patterns

### Pattern 1: State + Rules Fan-Out

Multiple rules reference the same accumulator:

```elixir
Workflow.new()
|> Workflow.add(my_accumulator)
|> Workflow.add(rule_a, to: :my_accumulator)  # rule_a uses state_of(:my_accumulator)
|> Workflow.add(rule_b, to: :my_accumulator)  # rule_b uses state_of(:my_accumulator)
|> Workflow.add(rule_c, to: :my_accumulator)  # rule_c uses state_of(:my_accumulator)
```

### Pattern 2: Feedback Loops

Rules produce events that feed back to the accumulator:

```elixir
#     ┌──────────────────────────────────────┐
#     │                                      │
#     ▼                                      │
# ┌────────────┐    ┌─────────┐    ┌─────────┴─────┐
# │Accumulator │◄───│  Join   │◄───│ Rule (events) │
# └────────────┘    └─────────┘    └───────────────┘
#     │                                      ▲
#     │           ┌─────────┐                │
#     └──────────►│  Rule   │────────────────┘
#                 └─────────┘

workflow = Workflow.new()
  |> Workflow.add(accumulator)
  |> Workflow.add(command_rule, to: :root)       # Commands from outside
  |> Workflow.add(reaction_rule, to: :accumulator)  # Reactions produce events
  |> Workflow.add(join, to: [:command_rule, :reaction_rule])
  |> Workflow.connect(:accumulator, from: :join)  # Feedback loop
```

### Pattern 3: Cross-Accumulator References

Rules can reference multiple state sources:

```elixir
rule = Runic.rule name: :cross_state_check do
  given event: _
  where state_of(:user_state).active == true and
        state_of(:system_state).maintenance_mode == false
  then fn event -> process(event) end
end
```

### Pattern 4: State Machine Composition

Compose multiple FSMs:

```elixir
# Two independent state machines
auth_fsm = Runic.fsm(name: :auth, ...)
session_fsm = Runic.fsm(name: :session, ...)

# Rule that coordinates them
coordination_rule = Runic.rule name: :coordinate do
  given event: :user_action
  where state_of(:auth) == :authenticated and
        state_of(:session) == :active
  then fn event -> allow(event) end
end

Workflow.new()
|> Workflow.add(auth_fsm)
|> Workflow.add(session_fsm)
|> Workflow.add(coordination_rule, to: [:auth, :session])
```

---

## API Alternatives

### Alternative 1: Explicit State References (Chosen Approach)

```elixir
rule do
  given command: cmd
  where state_of(:my_state).field > 10
  then fn %{command: c} -> process(c) end
end
```

**Pros**: Clear, composable, works with existing rules
**Cons**: Verbose, requires naming components

### Alternative 2: Implicit State Binding

```elixir
# State is automatically bound to a variable
stateful_rule :my_state, name: :check do
  given command: cmd, state: state  # state is magically bound
  where state.field > 10
  then fn %{command: c, state: s} -> process(c, s) end
end
```

**Pros**: Less verbose, familiar pattern
**Cons**: Magic binding, harder to compose, new macro

### Alternative 3: State as First-Class Input

```elixir
# State is a required input to the rule
rule name: :check, requires_state: [:my_state] do
  given command: cmd
  where fn cmd, %{my_state: state} -> state.field > 10 end  # State passed to where
  then fn %{command: c}, %{my_state: s} -> process(c, s) end
end
```

**Pros**: Explicit dependencies, testable
**Cons**: Different function signature, breaks uniformity

### Alternative 4: Monadic State

```elixir
# Pure functional state handling
rule do
  given command: cmd
  where 
    with_state(:my_state, fn state -> state.field > 10 end)
  then fn %{command: c} -> 
    update_state(:my_state, fn s -> %{s | processed: true} end)
    process(c)
  end
end
```

**Pros**: Familiar to FP practitioners
**Cons**: Complex, requires runtime support

### Alternative 5: Lens-Based Access

```elixir
# Define lenses for state access
field_lens = lens(:my_state, [:nested, :field])

rule do
  given cmd: cmd
  where view(field_lens) > 10
  then fn %{cmd: c} -> 
    over(field_lens, & &1 + 1)
    process(c)
  end
end
```

**Pros**: Composable accessors, elegant for nested state
**Cons**: Learning curve, requires lens infrastructure

---

## Concerns and Trade-offs

### Performance Concerns

1. **Prepare phase overhead** - Each meta expression requires graph traversal during prepare
   - *Mitigation*: Cache getter results, batch edge traversals

2. **State fetching latency** - `last_known_state` walks `:state_produced` edges
   - *Mitigation*: Index latest state fact per accumulator

3. **Large state values** - Copying full state into CausalContext
   - *Mitigation*: Field path extraction, lazy loading for collections

### Correctness Concerns

1. **Stale state reads** - Multiple rules reading state concurrently may see stale values
   - *Mitigation*: Document eventual consistency, provide `mergeable: true` for safe parallelism

2. **State mutation ordering** - When multiple rules modify same state, order matters
   - *Mitigation*: Sequential apply phase, deterministic ordering by causal depth

3. **Circular dependencies** - `state_of(:a)` in rule that produces to `:a`
   - *Mitigation*: Detect cycles at connect time, or document as "reads previous state"

### Composability Concerns

1. **Hidden dependencies** - `state_of(:x)` creates implicit coupling
   - *Mitigation*: `:meta_ref` edges make dependencies visible in graph

2. **Component removal** - Removing a state source breaks dependent rules
   - *Mitigation*: Validate `:meta_ref` targets exist, provide helpful errors

3. **Serialization** - `getter_fn` cannot be serialized
   - *Mitigation*: Rebuild from edge properties during `from_log/1`

### Migration Concerns

1. **Breaking existing StateMachine users** - Current API will change
   - *Mitigation*: There are no existing users of state machines because Runic is unreleased and in development so breaking changes are fine.

2. **Learning curve** - New mental model for state handling
   - *Mitigation*: Good documentation, examples, guides

---

## Open Questions

### Q1: Should `state_of()` in `then` clause read or write?

**Option A**: Read-only - `state_of()` always returns current state
```elixir
then fn _ -> state_of(:counter)  # Returns current counter value
end
```

**Option B**: Allow state modification
```elixir
then fn _ -> 
  update_state(:counter, & &1 + 1)  # Modifies state
  :ok
end
```

**Recommendation**: Read-only in `then`. State modification happens by producing events that feed to accumulators. This maintains event sourcing semantics.

### Q2: How to handle `state_of()` for non-existent components?

**Option A**: Compile error - Component must exist when rule is added
**Option B**: Runtime nil - Returns nil if component not found
**Option C**: Deferred resolution - Edge created when component is added later

**Recommendation**: Option C with warning. Allow forward references but warn at workflow finalization if unresolved.

### Q3: Should we support `state_of()` across workflow boundaries?

```elixir
# Reference state from merged child workflow
rule do
  where state_of({:child_workflow, :counter}) > 10
  ...
end
```

**Recommendation**: Yes, using tuple syntax for namespaced references. This enables composing independent workflows with shared state awareness.

### Q4: What about `previous_state_of()` for change detection?

```elixir
# Detect state transitions
rule do
  where state_of(:status) == :active and
        previous_state_of(:status) == :pending  # State just changed
  ...
end
```

**Recommendation**: Support `previous_state_of()` or use `latest_value_of()` for detecting changes. This is valuable for entry/exit actions in FSMs.

### Q5: Should meta expressions be allowed in guards (not just where)?

```elixir
# In pattern guard position
given event: %{type: type} when type == state_of(:expected_type)
```

**Recommendation**: No. Guards are compile-time in Elixir. Keep meta expressions in `where` clause only.

### Q6: How to handle concurrent state updates in parallel execution?

When two rules run in parallel and both produce events for the same accumulator:

**Option A**: Serialize at apply phase (current approach)
**Option B**: CRDT-style merge for `mergeable: true` accumulators
**Option C**: Conflict detection and retry

**Recommendation**: Option B for explicitly marked mergeable accumulators, Option A as default.

### Q7: New component types to consider?

1. **`Runic.fsm/1`** - High-level FSM DSL that compiles to Accumulator + Rules
2. **`Runic.aggregate/1`** - CQRS aggregate DSL with command handlers
3. **`Runic.saga/1`** - Process manager / saga DSL
4. **`Runic.projection/1`** - Read-model builder from event stream
5. **`Runic.rewrite_system/1`** - Rule-based graph rewriting

---

## Implementation Roadmap

### Phase 1: Meta Expression Foundation
(See [meta-expression-plan.md](./meta-expression-plan.md))
- Add `meta_context` to CausalContext
- Implement `state_of()` detection and edge injection
- Update Condition/Step Invokable impls

### Phase 2: Deprecate Special State Nodes
- Mark `StateCondition`, `StateReaction`, `MemoryAssertion` as deprecated
- Create migration path for existing StateMachine users
- Add compatibility shim

### Phase 3: Rebuild StateMachine from Primitives
- Rewrite `Runic.state_machine/1` to emit Accumulator + Rules
- Remove internal workflow construction
- Simplify Component implementation

### Phase 4: New DSL Components
- Implement `Runic.fsm/1` for finite state machines
- Implement `Runic.aggregate/1` for CQRS aggregates
- Document patterns and best practices

### Phase 5: Advanced Patterns
- Process manager support
- Cross-accumulator transactions
- Rewrite system exploration

---

## Summary

The redesign transforms state handling in Runic from specialized node types (`StateCondition`, `StateReaction`, `MemoryAssertion`) to composable primitives:

1. **Accumulators** hold state
2. **Rules with `state_of()`** make decisions based on state
3. **`:meta_ref` edges** connect nodes to their state dependencies
4. **Prepare phase** injects state into `CausalContext`

This enables building finite state machines, unbounded state machines, CQRS aggregates, and process managers from the same building blocks, with clear semantics and transparent composition.
