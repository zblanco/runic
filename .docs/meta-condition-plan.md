# Meta-Condition Implementation Plan

## Executive Summary

This document explores extending Runic's `rule` macro to support meta-conditions—runtime introspection primitives that enable rules to conditionally operate on workflow execution state, component state, and fact history. This capability is essential for implementing CQRS patterns, stateful aggregates, and dynamic workflow composition.

## Problem Space

### Current Limitations

1. **Rules are stateless**: Current rules can only evaluate incoming facts, not the accumulated state of other components
2. **No execution history awareness**: Rules cannot determine if/when other steps have executed
3. **CQRS impedance mismatch**: Command handlers need state context, process managers need event history
4. **Dynamic composition gap**: Cannot express "wait until reducer accumulates N items" or "react when state transitions to X"

### Core Requirements

- Reference accumulated state of named components (reducers, accumulators, state machines)
- Query workflow execution history (has step X run? for which facts?)
- Compose meta-conditions with normal fact pattern matching
- Maintain pure functional semantics despite apparent statefulness
- Support CQRS patterns: event handlers, aggregates, process managers

## Proposed Meta-Conditions

### 1. `state_of/1` - State Reference

**Purpose**: Access the current accumulated state of a stateful component.

```elixir
# Check if cart total exceeds threshold
rule condition: state_of(:cart_accumulator).total > 100,
     reaction: &send_discount_offer/1

# Pattern match on aggregate state
rule condition: match?(%{status: :pending}, state_of(:order_aggregate)),
     reaction: &process_payment/1
```

**Semantics**:
- Returns the last accumulated value (or initial state if not yet run)
- Type: Returns the state type of the referenced component
- Lazy evaluation: State lookup happens during rule evaluation phase
- Graph dependency: Creates implicit edge from referenced component to this rule

**Implementation considerations**:
- Compile-time: Validate component exists and is stateful
- Runtime: Index component states in Workflow struct (e.g., `%{component_states: %{name => value}}`)
- Graph: Add hidden dependency edge so rule only evaluates after referenced component

### 2. `step_ran?/1` - Execution Check

**Purpose**: Determine if a step has executed at least once.

```elixir
# Only validate after enrichment
rule condition: step_ran?(:enrich_user_data) and valid_email?(fact.email),
     reaction: &create_account/1

# Coordination: wait for multiple upstream steps
rule condition: step_ran?(:fetch_prices) and step_ran?(:fetch_inventory),
     reaction: &calculate_availability/1
```

**Semantics**:
- Boolean: true if step has produced at least one fact
- Monotonic: Once true, remains true for workflow lifetime
- Scope: Per workflow instance

**Implementation**:
- Workflow execution tracker: `%{executed_steps: MapSet.t(component_id)}`
- Updated when step produces output
- Meta-condition compiles to state check function

### 3. `step_ran?/2` - Fact-Specific Execution Check

**Purpose**: Determine if a step has executed for a specific input fact or generation.

```elixir
# Process each item only after its validation completes
rule condition: fn %{item_id: id} = fact ->
       step_ran?(:validate_item, id)
     end,
     reaction: &ship_item/1

# Generational processing: wait for fact's lineage
rule condition: step_ran?(:transform, fact),
     reaction: &downstream_process/1
```

**Semantics**:
- Checks execution history for specific fact hash or generation marker
- Enables fine-grained data dependencies beyond graph topology
- Supports both fact value matching and generation/lineage tracking

**Implementation options**:

**A. Hash-based tracking**:
```elixir
%{execution_history: %{
  step_id => MapSet.new([fact_hash1, fact_hash2, ...])
}}
```

**B. Generation-based tracking** (preferred for lineage):
```elixir
# Facts carry generation/lineage metadata
%Fact{value: ..., generation: %{
  origin_fact_id: uuid,
  step_path: [:step_a, :step_b]
}}

# Workflow tracks generations processed per step
%{step_generations: %{
  step_id => MapSet.new([generation_key, ...])
}}
```

### 4. `all_facts_of/1` - Fact History Query

**Purpose**: Access all facts produced by a component (for reduce-like operations in rules).

```elixir
# Aggregation in rule condition
rule condition: fn fact ->
       events = all_facts_of(:event_stream)
       length(events) > 10 and match?(%{type: :critical}, fact)
     end,
     reaction: &trigger_alert/1
```

**Semantics**:
- Returns list of all facts produced by component
- Ordered by production time
- Immutable snapshot at evaluation time

**Alternative**: Consider memory implications—might need `recent_facts_of/2` with limit.

### 5. `state_changed?/2` - State Transition Detector

**Purpose**: React only when state transitions match a pattern.

```elixir
# Trigger on specific state transitions
rule condition: state_changed?(:order_fsm, from: :pending, to: :confirmed),
     reaction: &send_confirmation_email/1
```

**Implementation**: Requires workflow to track state diffs or previous states.

## API Design Alternatives

### Alternative 1: Implicit Context Binding (Current Proposal)

```elixir
rule condition: state_of(:cart).total > 100,
     reaction: &apply_discount/1
```

**Pros**: Natural, minimal syntax
**Cons**: Implicit dependencies, harder to track graph edges

### Alternative 2: Explicit Context Parameter

```elixir
rule condition: fn fact, %{state: state} ->
       state[:cart].total > 100
     end,
     reaction: &apply_discount/1
```

**Pros**: Explicit, FP-friendly, easier to test
**Cons**: More verbose, breaks current DSL aesthetics

### Alternative 3: Macro-Based Query DSL

```elixir
rule do
  condition do
    state(:cart).total > 100 and
    step_ran?(:validate_cart) and
    fact.user_tier == :premium
  end
  
  reaction &apply_discount/1
end
```

**Pros**: Most expressive, clear intent
**Cons**: Most complex implementation, new DSL to learn

**Recommendation**: Start with Alternative 1, provide Alternative 2 as escape hatch for complex scenarios.

## Meta-Runtime APIs

### `Workflow.react_until/3`

**Purpose**: Execute workflow until a condition becomes true.

```elixir
# Run until aggregate reaches specific state
Workflow.react_until(workflow, fn wrk ->
  match?(%{status: :completed}, Workflow.get_state(wrk, :order_aggregate))
end)

# Run until N facts processed
Workflow.react_until(workflow, fn wrk ->
  Workflow.fact_count(wrk) >= 100
end, timeout: 5000)
```

**Implementation**:
```elixir
def react_until(workflow, condition_fn, opts \\ []) do
  timeout = Keyword.get(opts, :timeout, :infinity)
  max_iterations = Keyword.get(opts, :max_iterations, 10_000)
  
  do_react_until(workflow, condition_fn, timeout, max_iterations, 0)
end

defp do_react_until(wrk, condition_fn, timeout, max, iteration) do
  if condition_fn.(wrk) or iteration >= max do
    wrk
  else
    case react_once(wrk, timeout) do
      {:ok, new_wrk} -> do_react_until(new_wrk, condition_fn, timeout, max, iteration + 1)
      {:idle, wrk} -> wrk  # No more reactions possible
      {:error, reason} -> {:error, reason}
    end
  end
end
```

### `Workflow.await_state/3`

**Purpose**: Block until a component reaches specific state.

```elixir
# In test or synchronous context
workflow
|> Workflow.inject_fact(:order_created, order)
|> Workflow.await_state(:order_aggregate, fn state -> 
     state.status == :confirmed 
   end)
```

### `Workflow.get_state/2`

**Purpose**: Query current state of any stateful component.

```elixir
current_cart = Workflow.get_state(workflow, :shopping_cart)
```

### `Workflow.rewind/2` (Advanced)

**Purpose**: Fork workflow at previous state for "what-if" analysis.

```elixir
# Speculative execution for saga compensation
original_workflow
|> Workflow.rewind(to: :before_payment)
|> Workflow.inject_fact(:payment_failed, reason)
|> Workflow.react_until(&compensated?/1)
```

## CQRS Pattern Support

### Event Handlers

**Pattern**: Rule that pattern matches events and triggers steps.

```elixir
# Simple event handler
rule condition: match?(%Event{type: :user_registered}, fact),
     reaction: &send_welcome_email/1

# With state awareness
rule condition: fn %Event{type: :item_added} = event ->
       cart_state = state_of(:cart_accumulator)
       cart_state.item_count < cart_state.max_items
     end,
     reaction: &add_to_cart/1
```

**Implementation**: Already supported by current rule system, enhanced by meta-conditions.

### Aggregates (Command → Events in State Context)

**Challenge**: Aggregates need to evaluate commands in context of current state, then emit events.

**Proposed Component**: `Aggregate`

```elixir
aggregate :order_aggregate do
  initial_state %Order{status: :draft, items: [], total: 0}
  
  # Command handler: state + command → events
  handle_command :add_item, fn state, %{item: item} = cmd ->
    cond do
      state.status != :draft -> 
        {:error, :order_not_editable}
      
      item.quantity > inventory_check(item.sku) ->
        {:error, :insufficient_inventory}
      
      true ->
        {:ok, [%Event{type: :item_added, data: item}]}
    end
  end
  
  # Event handler: state + event → new state
  apply_event :item_added, fn state, %{data: item} ->
    %{state | 
      items: [item | state.items],
      total: state.total + item.price * item.quantity
    }
  end
end
```

**How it integrates with rules**:

```elixir
# Rules can trigger commands on aggregates
rule condition: valid_add_item_request?(fact),
     reaction: fn fact ->
       Aggregate.command(:order_aggregate, :add_item, fact)
     end

# Rules can react to aggregate events
rule condition: fn %Event{type: :item_added, aggregate: :order_aggregate} = event ->
       state_of(:order_aggregate).total > 100
     end,
     reaction: &apply_bulk_discount/1
```

**Implementation Strategy**:

1. `Aggregate` wraps a state machine + command handler rules + event handler rules
2. Commands flow in as facts labeled with `{:command, aggregate_id, command_name}`
3. Aggregate evaluates command in state context, emits event facts
4. Event facts trigger event handler rules (which might be internal Apply or external reactions)
5. State updates flow through normal accumulator/reduce mechanisms

### Process Managers (Events → State → Commands)

**Pattern**: Saga/orchestrator that accumulates events and issues commands based on state.

```elixir
process_manager :order_fulfillment_saga do
  initial_state %{
    order_id: nil,
    payment_confirmed: false,
    inventory_reserved: false,
    shipment_created: false
  }
  
  # Accumulate events into state
  on_event :payment_confirmed, fn state, event ->
    %{state | payment_confirmed: true, order_id: event.order_id}
  end
  
  on_event :inventory_reserved, fn state, event ->
    %{state | inventory_reserved: true}
  end
  
  # Conditional command emission based on state
  rule condition: fn _fact ->
       state = state_of(:order_fulfillment_saga)
       state.payment_confirmed and state.inventory_reserved and 
         not state.shipment_created
     end,
     reaction: fn fact ->
       state = state_of(:order_fulfillment_saga)
       create_shipment_command(state.order_id)
     end
end
```

**Alternative: Pure Rule-Based Approach**:

```elixir
# State accumulator
reduce :saga_state, 
  initial: %{payment: false, inventory: false},
  accumulator: &update_saga_state/2

# Coordination rule using meta-conditions
rule condition: fn _fact ->
       state = state_of(:saga_state)
       state.payment and state.inventory and not step_ran?(:create_shipment)
     end,
     reaction: &create_shipment_command/1
```

## Compilation & Graph Implications

### Implicit Dependencies

Meta-conditions create implicit graph edges:

```elixir
rule condition: state_of(:accumulator_a).count > 5,
     reaction: &trigger_b/1
```

Creates edge: `accumulator_a -> this_rule`

**Compile-time analysis**:
1. Parse rule condition AST
2. Extract meta-condition calls (`state_of`, `step_ran?`, etc.)
3. Validate referenced components exist
4. Add dependency edges to graph
5. Verify no cycles introduced

### StateCondition Component

Introduce `StateCondition` component to encapsulate state queries:

```elixir
defmodule Runic.Workflow.StateCondition do
  @moduledoc """
  A condition that evaluates against workflow runtime state.
  """
  
  defstruct [
    :id,
    :target_component,  # component to query
    :query_type,        # :state_of | :step_ran | :all_facts_of
    :predicate          # function to evaluate
  ]
  
  def state_of(component_name, predicate_fn) do
    %__MODULE__{
      id: generate_id(),
      target_component: component_name,
      query_type: :state_of,
      predicate: predicate_fn
    }
  end
end

# Protocol implementation
defimpl Runic.Component, for: Runic.Workflow.StateCondition do
  def invoke(%{target_component: target, predicate: pred}, %Fact{} = fact, workflow) do
    state = Workflow.Runtime.get_component_state(workflow, target)
    
    if pred.(state, fact) do
      {:ok, %Fact{value: true, metadata: %{state_condition: true}}}
    else
      {:skip, nil}
    end
  end
end
```

### Conjunction Composition

Combine state conditions with normal conditions using `Conjunction`:

```elixir
rule condition: state_of(:cart).total > 100 and fact.user.vip?,
     reaction: &apply_vip_discount/1

# Compiles to:
Conjunction.new([
  StateCondition.state_of(:cart, fn state, _fact -> state.total > 100 end),
  Condition.new(fn fact -> fact.user.vip? end)
])
```

## Runtime State Management

### Workflow State Tracking

Extend `%Workflow{}` struct:

```elixir
defmodule Runic.Workflow do
  defstruct [
    :graph,
    :component_index,
    :pending_facts,
    # New fields for meta-condition support:
    :component_states,      # %{component_id => current_state}
    :execution_history,     # %{component_id => [fact_hash | generation_key]}
    :executed_components,   # MapSet.t(component_id)
    :state_history          # Optional: [{component_id, old_state, new_state}]
  ]
end
```

### State Update Protocol

```elixir
defmodule Runic.Workflow.Runtime do
  def update_component_state(workflow, component_id, new_state) do
    %{workflow | 
      component_states: Map.put(workflow.component_states, component_id, new_state),
      executed_components: MapSet.put(workflow.executed_components, component_id)
    }
  end
  
  def record_execution(workflow, component_id, fact) do
    history = Map.get(workflow.execution_history, component_id, MapSet.new())
    key = fact_execution_key(fact)  # hash or generation
    
    %{workflow |
      execution_history: Map.put(workflow.execution_history, component_id, 
                                MapSet.put(history, key))
    }
  end
end
```

## Extended Meta-Conditions (Future)

### `state_changed?/2,3` - Transition Detection

```elixir
rule condition: state_changed?(:order_fsm, to: :shipped),
     reaction: &send_tracking_notification/1
```

### `fact_count/1` - Component Output Counter

```elixir
rule condition: fact_count(:event_stream) > 1000,
     reaction: &archive_old_events/1
```

### `upstream_of?/2` - Lineage Query

```elixir
rule condition: upstream_of?(fact, :validated_input),
     reaction: &safe_to_persist/1
```

### `await/1` - Synchronization Primitive

```elixir
rule condition: await(all_of([:step_a, :step_b, :step_c])),
     reaction: &combine_results/1
```

### `rate_limit/2` - Temporal Constraint

```elixir
rule condition: rate_limit(:send_email, max: 100, window: :per_minute),
     reaction: &send_notification_email/1
```

## Testing Strategy

### Unit Tests for Meta-Conditions

```elixir
describe "state_of meta-condition" do
  test "accesses current accumulator state" do
    workflow = 
      Workflow.new()
      |> Workflow.add_component(Accumulator.new(:counter, 0, &(&1 + &2)))
      |> Workflow.add_component(
           Rule.new(
             condition: fn _fact -> state_of(:counter) > 5 end,
             reaction: fn fact -> %{triggered: true, count: state_of(:counter)} end,
             id: :threshold_rule
           )
         )
    
    # Inject facts to increment counter
    workflow = Enum.reduce(1..3, workflow, fn i, wrk ->
      Workflow.inject_fact(wrk, :counter, i) |> Workflow.react()
    end)
    
    # Counter = 6, rule should not trigger yet
    refute state_of(:counter) > 5  # TODO: How to assert from outside workflow?
    
    # Inject more
    workflow = 
      workflow
      |> Workflow.inject_fact(:counter, 4)
      |> Workflow.react()
    
    # Now counter = 10, rule should trigger
    assert_received {:fact_produced, :threshold_rule, %{triggered: true, count: 10}}
  end
end
```

### Integration Tests for CQRS Patterns

```elixir
describe "aggregate pattern" do
  test "command handling with state context" do
    workflow = build_order_aggregate_workflow()
    
    # Issue add_item command
    workflow = 
      workflow
      |> inject_command(:order_aggregate, :add_item, %{item: %{sku: "ABC", qty: 2}})
      |> react_until(fn wrk -> 
           Workflow.get_state(wrk, :order_aggregate).item_count == 1 
         end)
    
    state = Workflow.get_state(workflow, :order_aggregate)
    assert length(state.items) == 1
  end
end
```

## Migration Path

### Phase 1: Core Meta-Conditions (MVP)
- Implement `state_of/1` 
- Implement `step_ran?/1`
- Add `component_states` and `executed_components` to Workflow
- Update rule compiler to detect and handle meta-conditions
- Add graph dependency edges for state references

### Phase 2: Fact-Level Tracking
- Implement `step_ran?/2` with generation tracking
- Add `execution_history` to Workflow
- Enhance `%Fact{}` with generation/lineage metadata

### Phase 3: Runtime APIs
- Implement `Workflow.react_until/3`
- Implement `Workflow.get_state/2`
- Implement `Workflow.await_state/3`

### Phase 4: CQRS Components
- Design and implement `Aggregate` component
- Design and implement `ProcessManager` component
- Build example applications (e-commerce, saga patterns)

### Phase 5: Advanced Meta-Conditions
- `state_changed?/2,3` with state diff tracking
- `all_facts_of/1` with memory management
- Temporal and rate-limiting meta-conditions

## Open Questions

1. **Memory Management**: How do we prevent unbounded growth of `execution_history` and `component_states`? 
   - Sliding window per component?
   - Explicit garbage collection API?
   - Component-level retention policies?

2. **Distributed Workflows**: Do meta-conditions work across distributed workflow instances?
   - State synchronization requirements?
   - Eventual consistency implications?

3. **Time Travel**: Should we support workflow rewind/replay?
   - Event sourcing integration?
   - State snapshot/restore?

4. **Performance**: What's the overhead of state tracking?
   - Benchmark state lookup vs. graph traversal
   - Consider lazy state materialization

5. **Type Safety**: How do we type-check `state_of(:component_name)`?
   - Compile-time state type registry?
   - Runtime type validation?
   - Dialyzer specs?

6. **Cycle Detection**: Can meta-conditions create cycles?
   - Rule A depends on state of Accumulator B
   - Accumulator B accumulates facts from Rule A
   - Is this a cycle or valid feedback loop?

## Alternative Approaches Considered

### 1. Event Sourcing All The Way
Instead of explicit state tracking, reconstruct state by replaying fact history.

**Pros**: Pure functional, time-travel for free
**Cons**: Performance overhead, complexity

### 2. External State Store
Keep workflow pure, reference external ETS/Agent for state queries.

**Pros**: Separates concerns
**Cons**: Breaks workflow immutability, harder to test/reason about

### 3. Monadic Workflow Context
Thread state through workflow using Reader/State monad.

**Pros**: Principled FP approach
**Cons**: Steep learning curve, doesn't fit current architecture

## Conclusion

Meta-conditions enable Runic to elegantly express stateful coordination patterns essential for CQRS, sagas, and complex event processing while maintaining its pure functional workflow semantics. The proposed `state_of/1` and `step_ran?/1,2` primitives, combined with `StateCondition` components and Conjunction composition, provide the foundation for powerful aggregate and process manager patterns.

The key insight is that workflow execution state (component states, execution history) is itself an immutable value that evolves with each reaction—meta-conditions simply provide syntax to query this state during rule evaluation.

Recommended starting point: Implement Phase 1 MVP with `state_of/1`, validate with concrete CQRS examples, then iterate based on real-world usage patterns.
