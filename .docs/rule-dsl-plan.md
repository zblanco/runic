# Explicit Rule DSL Design

## Executive Summary

This document proposes an explicit `given/when/then` (or `given/if/do`) rule DSL that extends Runic's current pattern-matching-only rules to support meta-conditions, complex logical expressions, type predicates, and runtime workflow introspection. This design maintains pure functional semantics while enabling sophisticated rule-based expert systems and CQRS patterns.

## Problem Statement

### Current Rule Limitations

Runic's current `rule` macro is elegant but constrained:

```elixir
# Current: Pattern matching + guards only (compile-time optimized)
rule(fn %Order{status: :pending} = order when order.total > 100 -> apply_discount(order) end)

# Current: Separate condition/reaction
rule(
  condition: fn order -> order.status == :pending end,
  reaction: fn order -> apply_discount(order) end
)
```

**Limitations:**

1. **Pattern-only LHS**: Conditions are limited to pattern matching and guard clauses
2. **No meta-conditions**: Cannot reference workflow state, execution history, or other components
3. **No complex logic**: Cannot compose arbitrary boolean expressions beyond guards
4. **No type introspection**: Type checks limited to guard-compatible predicates
5. **Stateless evaluation**: Rules cannot observe accumulated state or coordination signals

### Why This Matters

Rule-based expert systems require:
- **Forward chaining**: React to derived facts from upstream computations
- **State-aware decisions**: "If cart total exceeds threshold AND user is premium tier..."
- **Coordination logic**: "Wait until validation completes before processing"
- **Type-safe bindings**: Explicit variable declarations with optional type constraints

## Proposed API

### Core Syntax: `given/when/then`

```elixir
rule do
  given order: %Order{},
        user: %User{tier: tier}

  when order.status == :pending
   and order.total > 100
   and tier == :premium
   and step_ran?(:validate_order)

  then fn %{order: order, user: user} ->
    apply_premium_discount(order, user)
  end
end
```

### Alternative Syntax: `given/if/do`

```elixir
rule do
  given order: %Order{},
        user: %User{}

  if order.status == :pending and state_of(:cart).item_count > 3

  do fn %{order: order, user: _user} ->
    apply_bulk_discount(order)
  end
end
```

### Design Principles

1. **`given`**: Declares variable bindings with optional type/pattern constraints
2. **`when`/`if`**: Boolean expression for the LHS—may include meta-conditions
3. **`then`/`do`**: RHS execution block—a pure function receiving the bound variables

## Detailed Specification

### The `given` Clause

The `given` clause declares **named bindings** that the rule will operate on. Each binding can optionally include a type constraint or pattern.

#### Syntax Variants

```elixir
# Simple binding (any type)
given order: _

# Pattern binding with struct type
given order: %Order{}

# Pattern binding with field extraction
given order: %Order{id: order_id, items: items}

# Multiple bindings
given order: %Order{},
      user: %User{tier: tier},
      config: %Config{}

# Tuple destructuring
given {status, payload}: _

# Guard-enhanced binding
given order: %Order{} when is_map(order)
```

#### Compilation Strategy

The `given` clause compiles to:

1. **Pattern match function head**: For struct/pattern checks that can be guard-optimized
2. **Binding extraction map**: For accessing values in `when` and `then` clauses

```elixir
# Source
given order: %Order{id: id}, user: %User{tier: tier}

# Compiles to condition function head:
fn %{order: %Order{id: id} = order, user: %User{tier: tier} = user} -> ...

# With bindings available:
%{order: order, user: user, id: id, tier: tier}
```

### The `when`/`if` Clause

The `when` clause is a **boolean expression** that determines whether the rule fires. It can reference:

1. **Bound variables** from `given`
2. **Meta-conditions** for workflow introspection
3. **Any boolean-returning expression**

#### Simple Expressions

```elixir
when order.status == :pending
when order.total > 100 and user.tier == :premium
when length(order.items) > 0
when MyModule.is_valid?(order)
```

#### Meta-Conditions

```elixir
# State introspection
when state_of(:cart_accumulator).total > 100
when state_of(:order_fsm) == :confirmed

# Execution history
when step_ran?(:validate_order)
when step_ran?(:enrich_user) and step_ran?(:check_inventory)

# Fact-specific execution
when step_ran?(:process_item, order.id)

# State transitions
when state_changed?(:order_fsm, to: :shipped)

# Negation
when not step_ran?(:already_processed)
```

#### Composite Expressions

```elixir
when (order.total > 100 and user.tier == :premium)
  or (order.total > 500)
  or state_of(:promotion_engine).active_promotion?

when cond do
  order.priority == :urgent -> true
  step_ran?(:expedite_requested) -> true
  state_of(:queue).length < 10 -> true
  true -> false
end
```

#### Compilation Strategy

The `when` clause compiles to a **2-arity condition function**:

```elixir
fn bindings_map, workflow_context -> boolean
```

Where:
- `bindings_map` contains all variables from `given`
- `workflow_context` provides meta-condition resolution (component states, execution history)

```elixir
# Source
when order.total > 100 and step_ran?(:validate)

# Compiles to:
fn %{order: order}, ctx ->
  order.total > 100 and Runic.Workflow.Runtime.step_ran?(ctx, :validate)
end
```

### The `then`/`do` Clause

The RHS is a **1-arity function** that receives the bindings map and executes the rule's action.

```elixir
then fn %{order: order, user: user} ->
  %DiscountApplied{
    order_id: order.id,
    user_id: user.id,
    amount: calculate_discount(order, user)
  }
end

# Or with simpler destructuring
then fn bindings ->
  send_notification(bindings.user, bindings.order)
end

# Can also use capture syntax for simple transformations
then &process_order/1
```

#### Compilation

The `then` clause compiles to a standard `Runic.step`:

```elixir
step(
  name: :rule_rhs_#{hash},
  work: fn %{order: order, user: user} -> ... end
)
```

## Meta-Condition Primitives

### `state_of/1` — State Reference

Access the current accumulated state of any named stateful component.

```elixir
# Access reducer/accumulator state
state_of(:cart_accumulator).total
state_of(:order_aggregate)

# Use in pattern matching within when
when match?(%{status: :confirmed}, state_of(:order_fsm))

# Compare states
when state_of(:left_reducer) == state_of(:right_reducer)
```

**Semantics:**
- Returns the **last known state** of the referenced component
- If component hasn't run yet, returns its **initial state**
- Creates an **implicit graph edge** from the component to this rule
- Evaluated **lazily** during rule condition checking

**Type signature:**
```elixir
@spec state_of(component_name :: atom()) :: term()
```

### `step_ran?/1` — Execution Check

Query whether a step has executed at least once in the current workflow instance.

```elixir
when step_ran?(:validate_user)
when step_ran?(:step_a) and step_ran?(:step_b)
when not step_ran?(:already_sent_notification)
```

**Semantics:**
- Returns `true` if step has produced **at least one output fact**
- **Monotonic**: Once true, remains true
- Scope: Per workflow instance (not per input fact)

**Type signature:**
```elixir
@spec step_ran?(step_name :: atom()) :: boolean()
```

### `step_ran?/2` — Fact-Specific Execution Check

Query whether a step has executed for a **specific input** or **fact lineage**.

```elixir
# Check by correlation key
when step_ran?(:validate_item, item.id)

# Check by fact reference
when step_ran?(:transform, input_fact)
```

**Semantics:**
- Tracks execution at the **fact granularity**
- Uses fact hashing or generation-based lineage
- Enables fine-grained coordination

**Type signature:**
```elixir
@spec step_ran?(step_name :: atom(), correlation_key :: term()) :: boolean()
```

### `state_changed?/2,3` — Transition Detection

React only when state transitions match a specific pattern.

```elixir
when state_changed?(:order_fsm, to: :shipped)
when state_changed?(:order_fsm, from: :pending, to: :confirmed)
when state_changed?(:counter, fn old, new -> new > old * 2 end)
```

**Semantics:**
- Requires workflow to track **previous states**
- Only fires on the transition, not on stable state
- Useful for event-driven reactions

## Compilation Architecture

### Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        rule do ... end                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────┐ │
│  │   given     │───▶│    when     │───▶│       then          │ │
│  │  (bindings) │    │  (LHS cond) │    │   (RHS step)        │ │
│  └─────────────┘    └─────────────┘    └─────────────────────┘ │
│         │                  │                     │              │
│         ▼                  ▼                     ▼              │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────┐ │
│  │  Pattern    │    │ Condition   │    │     Step.new()      │ │
│  │  Extractor  │    │  Function   │    │                     │ │
│  │  Function   │    │ (2-arity)   │    │                     │ │
│  └─────────────┘    └─────────────┘    └─────────────────────┘ │
│                            │                                    │
│                            ▼                                    │
│                   ┌─────────────────┐                          │
│                   │ Meta-Condition  │                          │
│                   │   Extraction    │                          │
│                   │  (AST walking)  │                          │
│                   └─────────────────┘                          │
│                            │                                    │
│                            ▼                                    │
│                   ┌─────────────────┐                          │
│                   │ Graph Edges     │                          │
│                   │ (dependencies)  │                          │
│                   └─────────────────┘                          │
└─────────────────────────────────────────────────────────────────┘
```

### Phase 1: Parse and Extract

The macro parses the DSL blocks and extracts:

```elixir
defmacro rule(do: block) do
  {given_clause, when_clause, then_clause} = parse_rule_block(block)
  
  bindings = extract_bindings(given_clause)
  meta_conditions = extract_meta_conditions(when_clause)
  dependencies = resolve_dependencies(meta_conditions)
  
  # ...
end
```

### Phase 2: Compile Pattern Extractor

Generate a function that extracts and validates bindings from input:

```elixir
# given order: %Order{id: id}, user: %User{}
# Compiles to:

fn input ->
  case input do
    %{order: %Order{id: id} = order, user: %User{} = user} ->
      {:ok, %{order: order, user: user, id: id}}
    _ ->
      :no_match
  end
end
```

### Phase 3: Compile Condition Function

Generate a 2-arity condition that evaluates the `when` clause:

```elixir
# when order.total > 100 and step_ran?(:validate)
# Compiles to:

fn %{order: order} = _bindings, workflow_ctx ->
  order.total > 100 and 
    Runic.Workflow.Runtime.step_ran?(workflow_ctx, :validate)
end
```

### Phase 4: Compile RHS Step

Wrap the `then` clause as a standard Runic step:

```elixir
# then fn %{order: order} -> apply_discount(order) end
# Compiles to:

Step.new(
  name: :rule_rhs_#{hash},
  work: fn %{order: order} -> apply_discount(order) end
)
```

### Phase 5: Assemble Rule Component

```elixir
%Rule{
  name: rule_name,
  pattern_extractor: pattern_fn,
  condition: condition_fn,
  reaction: step,
  dependencies: [:cart_accumulator, :validate],  # from meta-conditions
  hash: rule_hash
}
```

## Integration with Workflow Runtime

### Extended Workflow Struct

```elixir
defmodule Runic.Workflow do
  defstruct [
    :graph,
    :component_index,
    :pending_facts,
    # Meta-condition support:
    :component_states,      # %{component_name => current_state}
    :executed_components,   # MapSet.t(component_name)
    :execution_history,     # %{component_name => MapSet.t(fact_key)}
    :state_history          # [{component_name, prev_state, new_state}]
  ]
end
```

### Runtime Context

When evaluating rule conditions, the runtime provides a context:

```elixir
defmodule Runic.Workflow.RuntimeContext do
  defstruct [
    :workflow,
    :current_fact,
    :component_states,
    :executed_components,
    :execution_history
  ]
  
  def state_of(%__MODULE__{component_states: states}, name) do
    Map.get(states, name)
  end
  
  def step_ran?(%__MODULE__{executed_components: executed}, name) do
    MapSet.member?(executed, name)
  end
  
  def step_ran?(%__MODULE__{execution_history: history}, name, key) do
    case Map.get(history, name) do
      nil -> false
      keys -> MapSet.member?(keys, key)
    end
  end
end
```

### Evaluation Flow

```
Input Fact
    │
    ▼
┌───────────────────┐
│ Pattern Extractor │──────▶ {:ok, bindings} or :no_match
└───────────────────┘
    │
    ▼ (if :ok)
┌───────────────────┐
│ Build Runtime Ctx │──────▶ Snapshot component states
└───────────────────┘
    │
    ▼
┌───────────────────┐
│ Condition Check   │──────▶ condition_fn.(bindings, ctx)
└───────────────────┘
    │
    ▼ (if true)
┌───────────────────┐
│ Execute RHS Step  │──────▶ step.work.(bindings)
└───────────────────┘
    │
    ▼
┌───────────────────┐
│ Produce Fact      │──────▶ Update workflow state
└───────────────────┘
```

## Examples

### Simple Discount Rule

```elixir
rule do
  given order: %Order{total: total}
  
  when total > 100
  
  then fn %{order: order} ->
    %Order{order | discount: total * 0.1}
  end
end
```

### State-Aware Rule

```elixir
rule do
  given item: %CartItem{}
  
  when state_of(:cart_accumulator).item_count < 10
   and item.in_stock?
  
  then fn %{item: item} ->
    {:add_to_cart, item}
  end
end
```

### Coordination Rule (Join Pattern)

```elixir
rule do
  given order: %Order{id: order_id}
  
  when step_ran?(:validate_payment, order_id)
   and step_ran?(:reserve_inventory, order_id)
   and step_ran?(:verify_address, order_id)
  
  then fn %{order: order} ->
    {:ready_to_ship, order}
  end
end
```

### State Transition Rule

```elixir
rule do
  given event: %Event{type: :status_update}
  
  when state_changed?(:order_fsm, from: :pending, to: :confirmed)
  
  then fn %{event: _event} ->
    order_state = state_of(:order_fsm)
    send_confirmation_email(order_state)
  end
end
```

### Complex Business Logic

```elixir
rule do
  given order: %Order{},
        user: %User{tier: tier, created_at: signup_date}
  
  when tier in [:gold, :platinum]
   and Date.diff(Date.utc_today(), signup_date) > 365
   and order.total > state_of(:user_stats).avg_order_value
   and not step_ran?(:loyalty_bonus_applied, order.id)
  
  then fn %{order: order, user: user} ->
    %LoyaltyBonusApplied{
      user_id: user.id,
      order_id: order.id,
      bonus_points: calculate_bonus(order, user)
    }
  end
end
```

## Advanced Features

### Type Predicates in Given

Support explicit type predicates for runtime validation:

```elixir
rule do
  given order: %Order{} when is_struct(order, Order),
        amount: amount when is_number(amount) and amount > 0
  
  when order.status == :pending
  
  then fn %{order: order, amount: amount} ->
    apply_payment(order, amount)
  end
end
```

### Multiple Clause Rules (Disjunction)

Support multiple `when` clauses as OR branches:

```elixir
rule do
  given order: %Order{}
  
  when order.priority == :urgent
  or   when order.total > 10_000
  or   when state_of(:vip_list) |> MapSet.member?(order.user_id)
  
  then fn %{order: order} ->
    expedite_processing(order)
  end
end
```

### Named Rules with Options

```elixir
rule name: :premium_discount_rule,
     priority: :high,
     salience: 100 do
  given order: %Order{}, user: %User{}
  when user.tier == :premium and order.total > 50
  then fn %{order: order} -> apply_discount(order, 0.15) end
end
```

### Rule Groups / Modules

```elixir
defmodule OrderRules do
  use Runic.Rules
  
  rule :validate_order do
    given order: %Order{}
    when order.items != [] and order.total > 0
    then fn %{order: order} -> {:validated, order} end
  end
  
  rule :apply_tax do
    given order: %Order{validated: true}
    when step_ran?(:validate_order)
    then fn %{order: order} -> calculate_tax(order) end
  end
end
```

## Error Handling & Diagnostics

### Compile-Time Validation

1. **Undefined bindings**: Error if `when`/`then` reference variables not in `given`
2. **Invalid meta-conditions**: Error if `state_of(:unknown)` references non-existent component
3. **Type mismatches**: Warning if pattern in `given` is incompatible with usage

### Runtime Diagnostics

```elixir
# Attach diagnostic metadata to rules
%Rule{
  # ...
  diagnostics: %{
    source_location: {__ENV__.file, __ENV__.line},
    binding_names: [:order, :user],
    meta_conditions: [:state_of, :step_ran?],
    dependencies: [:cart_accumulator, :validate_order]
  }
}
```

### Tracing Support

```elixir
Workflow.with_tracing(workflow, fn trace ->
  IO.puts("Rule #{trace.rule_name} evaluated:")
  IO.puts("  Bindings: #{inspect(trace.bindings)}")
  IO.puts("  Condition result: #{trace.condition_result}")
  IO.puts("  Meta-condition values: #{inspect(trace.meta_values)}")
end)
```

## Implementation Phases

### Phase 1: Core DSL (MVP)

- [ ] Implement `given/when/then` macro parsing
- [ ] Compile `given` to pattern extractor function
- [ ] Compile `when` to 2-arity condition (without meta-conditions)
- [ ] Compile `then` to standard Runic step
- [ ] Assemble into `%Rule{}` struct
- [ ] Integration with existing `Workflow.add_rules/2`

### Phase 2: Meta-Conditions

- [ ] Implement `state_of/1` AST detection and rewriting
- [ ] Implement `step_ran?/1` AST detection and rewriting
- [ ] Extend `Workflow` struct with runtime state tracking
- [ ] Build `RuntimeContext` for condition evaluation
- [ ] Add implicit dependency edges to workflow graph

### Phase 3: Advanced Meta-Conditions

- [ ] Implement `step_ran?/2` with fact-level tracking
- [ ] Implement `state_changed?/2,3` with state history
- [ ] Memory management for execution history

### Phase 4: Developer Experience

- [ ] Compile-time validation and error messages
- [ ] Runtime tracing and diagnostics
- [ ] Documentation and examples

### Phase 5: Performance Optimization

- [ ] Condition indexing (Rete-style alpha network)
- [ ] Lazy state materialization
- [ ] Incremental condition evaluation

## Design Decisions & Rationale

### Why `given/when/then` over Function Syntax?

| Aspect | Function Syntax | Explicit DSL |
|--------|----------------|--------------|
| Clarity | Implicit bindings | Explicit declarations |
| Meta-conditions | Awkward integration | Natural placement |
| Composability | Limited | High (separate clauses) |
| Learnability | Familiar but limited | New but powerful |
| Tooling | Standard Elixir | Custom but richer |

### Why 2-Arity Condition Function?

Passing workflow context as second argument:
1. **Pure**: Condition remains a pure function
2. **Testable**: Easy to unit test with mock context
3. **Flexible**: Context can be extended without changing signature

### Why Single Bindings Map for RHS?

The RHS receives `%{order: order, user: user, ...}` rather than positional args:
1. **Self-documenting**: Clear what's available
2. **Extensible**: Can add metadata without breaking signatures
3. **Consistent**: Same shape as condition receives

## Open Questions

1. **Salience/Priority**: Should rules have explicit priority ordering?
2. **Conflict Resolution**: When multiple rules match, what strategy?
3. **Negation-as-Failure**: Should `not step_ran?(:x)` block indefinitely or fail-fast?
4. **Transactions**: Can rule evaluation be transactional (all-or-nothing)?
5. **Async Support**: How do async operations in `then` interact with workflow state?

## Conclusion

This explicit rule DSL provides a clean separation of concerns:
- **`given`**: What data the rule operates on (declaration)
- **`when`**: Under what conditions (boolean logic + meta-conditions)
- **`then`**: What action to take (pure transformation)

This design enables sophisticated rule-based systems while maintaining Runic's core principles of pure functional semantics and composable workflows. The meta-condition primitives (`state_of`, `step_ran?`) bridge the gap between stateless rule evaluation and stateful workflow coordination, making Runic suitable for CQRS, saga patterns, and complex event processing.
