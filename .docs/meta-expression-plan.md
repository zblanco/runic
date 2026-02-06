# Meta Expression Plan for Runic Component Construction

> **Status**: Draft  
> **Scope**: Phase 1 - Rule `given/where/then` DSL  
> **Related**: Invokable protocol, Component protocol, CausalContext

## Table of Contents

1. [Overview](#overview)
2. [Architecture Foundation](#architecture-foundation)
3. [Meta Expression Types](#meta-expression-types)
4. [Implementation Design](#implementation-design)
5. [Graph Edge Strategy](#graph-edge-strategy)
6. [Protocol Integration](#protocol-integration)
7. [Macro Compilation](#macro-compilation)
8. [Phased Implementation Plan](#phased-implementation-plan)
9. [Q&A / Open Questions](#qa--open-questions)

---

## Overview

### What are Meta Expressions?

Meta expressions in Runic are expressions within component construction macros that reference **Runic workflow state or runtime knowledge** rather than the user's domain logic. They are "meta" because they're coupled to Runic's runtime concerns:

- State of a component (e.g., an accumulator's current value)
- Counts of facts produced by a component
- Whether a step has executed
- How many times a step has run
- History of facts produced by a component

### Why Meta Expressions?

The three-phase execution model (`prepare → execute → apply`) now provides a clean separation:

1. **Prepare**: Extract runtime state needed for meta expressions into `CausalContext`
2. **Execute**: Evaluate the expression with prepared context (parallelizable)
3. **Apply**: Reduce results back into workflow memory

This enables meta expressions that look like regular Elixir code but transparently access workflow state during the prepare phase.

### Design Goals

1. **Transparent to user code**: `state_of(:cart).total > 100` reads naturally
2. **Compile-time detection**: Macro detects meta expressions, compiles appropriate nodes
3. **Minimal runtime cost**: Only prepare what's needed for execution
4. **Graph connectivity**: Meta expressions create edges for efficient traversal
5. **Consistent with vanilla Elixir**: Condition guards and `if/do` syntax unchanged

---

## Architecture Foundation

### Current Patterns to Follow

#### MemoryAssertion Pattern
`MemoryAssertion` already demonstrates accessing workflow state in the prepare phase:

```elixir
# From invokable.ex - MemoryAssertion
def prepare(%MemoryAssertion{} = ma, %Workflow{} = workflow, %Fact{} = fact) do
  # Execute the assertion during prepare since it needs full workflow
  assertion_result = ma.memory_assertion.(workflow, fact)
  
  context = CausalContext.new(...)
  # Store the pre-computed result in the context
  context = Map.put(context, :memory_snapshot, assertion_result)
  
  {:ok, Runnable.new(ma, fact, context)}
end

def execute(%MemoryAssertion{} = _ma, %Runnable{context: ctx} = runnable) do
  # Result was already computed in prepare phase
  satisfied = Map.get(ctx, :memory_snapshot, false)
  # ...pure execution using pre-computed value
end
```

#### StateCondition/StateReaction Pattern
These prepare the `last_known_state` into `CausalContext`:

```elixir
def prepare(%StateCondition{} = sc, %Workflow{} = workflow, %Fact{} = fact) do
  last_known_state = Workflow.last_known_state(workflow, sc)
  
  context = CausalContext.new(
    last_known_state: last_known_state,
    is_state_initialized: not is_nil(last_known_state)
    # ...
  )
  {:ok, Runnable.new(sc, fact, context)}
end
```

#### Component Edge Pattern (`:fan_in`, `:component_of`)
The Reduce component creates a `:fan_in` edge from FanOut to FanIn for efficient traversal:

```elixir
# From component.ex - Reduce.connect
|> Workflow.draw_connection(map_fan_out, reduce.fan_in, :fan_in)
```

### Key Insight

Meta expressions will compile into nodes that:
1. Store references to target components (hash or name)
2. Use special edge labels (`:meta_ref`) for graph traversal
3. Prepare needed state during the prepare phase into `CausalContext`
4. Execute pure functions with prepared context

Stored in the edge properties of `:meta_ref` connections is a `getter_fn` that takes a fact value and returns the input in a map to the variable it will assign in the downstream function.

---

## Meta Expression Types

### 1. `state_of/1`

**Purpose**: Access the current state of a stateful component (Accumulator, StateMachine)

**Syntax**:
```elixir
rule name: :high_value_order do
  given order: %{total: total}
  where state_of(:cart_accumulator).total > 100
  then fn %{order: order} -> {:discount, order} end
end

# Also in reactions:
rule name: :emit_summary do
  given _
  then fn _ -> state_of(:cart_accumulator) end
end
```

**Compile Output**:
- Creates a `%MetaCondition{}` or prepares context for reaction
- References the target component by name/hash
- During prepare: fetches `last_known_state` for the referenced component
- During execute: evaluates `fn %{total: total} -> total > 100 end`

**Field Access Support**:
- `state_of(:acc)` - returns full state
- `state_of(:acc).field` - compile-time extraction, only prepares needed field
- `state_of(:acc)[:key]` - dynamic access

---

### 2. `step_ran?/1`

**Purpose**: Check if a step has executed at least once in the current workflow run

**Syntax**:
```elixir
rule name: :after_validation do
  given event: event
  where step_ran?(:validate_input)
  then fn %{event: e} -> {:validated, e} end
end
```

**Compile Output**:
- Creates a `%MetaCondition{}` with `kind: :step_ran`
- During prepare: queries workflow for `:ran` edges from the referenced step
- During execute: evaluates as boolean in conjunction with other conditions

---

### 3. `all_facts_of/1`

**Purpose**: Get all facts produced by a component as a list

**Syntax**:
```elixir
rule name: :aggregate_results do
  given _
  then fn _ -> 
    all_facts_of(:processor) 
    |> Enum.map(& &1.value)
  end
end
```

**Compile Output**:
- Prepares list of `%Fact{}` structs into context
- Uses `:produced` edge traversal from component

---

### 4. `all_values_of/1`

**Purpose**: Get all fact values (ignoring ancestry metadata) from a component

**Syntax**:
```elixir
where length(all_values_of(:items)) > 5
```

**Compile Output**:
- Same as `all_facts_of/1` but extracts `.value` during prepare
- More efficient for conditions that only need values

---

### 5. `latest_fact_of/1`

**Purpose**: Get the most recently produced fact from a component

**Syntax**:
```elixir
where latest_fact_of(:sensor).value.temperature > 100
```

**Compile Output**:
- During prepare: finds fact with highest ancestry depth from component
- Prepares single `%Fact{}` into context

---

### 6. `latest_value_of/1`

**Purpose**: Get the most recently produced value (ignoring fact metadata)

**Syntax**:
```elixir
rule name: :check_latest do
  given event: _
  where latest_value_of(:processor) != nil
  then fn _ -> :ok end
end
```

**Compile Output**:
- During prepare: finds latest fact, extracts `.value`
- More efficient when fact metadata isn't needed

---

### 7. `fact_count/1`

**Purpose**: Count of facts produced by a component

**Syntax**:
```elixir
rule name: :batch_ready do
  given _
  where fact_count(:items) >= 10
  then fn _ -> :process_batch end
end
```

**Compile Output**:
- During prepare: counts `:produced` edges from component
- Prepares integer into context

---

## Implementation Design

### Approach: Edge-Injected Meta Context (Preferred)

Rather than creating new `MetaCondition`/`MetaReaction` structs, we enhance existing `Condition` and `Step` nodes with `:meta_ref` edges that inject context during the prepare phase. This approach:

1. **Reuses existing structs** - No new node types needed
2. **Polymorphism via edge properties** - `kind` and `getter_fn` on edge handle different meta expression types
3. **Single prepare-phase enhancement** - Existing Invokable impls check for `:meta_ref` in-edges
4. **Simpler mental model** - A condition is still a condition, just with extra context

#### Edge Structure

```elixir
%Graph.Edge{
  v1: condition_or_step,      # The node needing meta context
  v2: target_component,       # The referenced component (Accumulator, Step, etc.)
  label: :meta_ref,
  properties: %{
    kind: :state_of,          # :state_of | :step_ran | :fact_count | :all_facts | etc.
    field_path: [:total],     # Optional path for field extraction
    context_key: :cart_state, # Key in meta_context map for this value
    getter_fn: fn workflow, target_component ->
      # Knows how to traverse to the right causal fact and extract value
      state = Workflow.last_known_state(workflow, target_component)
      get_in(state, [:total])
    end
  }
}
```

#### How It Works

**1. Macro Compilation**

When the rule macro detects `state_of(:cart).total > 100`:

```elixir
# Compiles to a regular Condition with:
# - A work function that expects meta context: fn input, meta_ctx -> meta_ctx.cart_state > 100 end
# - Metadata indicating it needs meta context injection
condition = %Condition{
  work: fn _input, %{cart_state: cart_state} -> cart_state > 100 end,
  hash: ...,
  arity: 1,
  meta_refs: [  # NEW field - list of meta references needed
    %{
      kind: :state_of,
      target: :cart,
      field_path: [:total],
      context_key: :cart_state
    }
  ]
}
```

**2. Component.connect Creates Edges**

When the Rule is added to the workflow:

```elixir
defimpl Runic.Component, for: Runic.Workflow.Rule do
  def connect(rule, to, workflow) do
    workflow
    |> add_rule_workflow(rule, to)
    |> create_meta_ref_edges(rule)
  end
  
  defp create_meta_ref_edges(workflow, rule) do
    # Find all nodes in rule's workflow that have meta_refs
    rule.workflow.graph
    |> Graph.vertices()
    |> Enum.filter(&has_meta_refs?/1)
    |> Enum.reduce(workflow, fn node, wrk ->
      Enum.reduce(node.meta_refs, wrk, fn meta_ref, w ->
        target = Workflow.get_component(w, meta_ref.target)
        getter_fn = build_getter_fn(meta_ref)
        
        Workflow.draw_connection(w, node, target, :meta_ref,
          properties: %{
            kind: meta_ref.kind,
            field_path: meta_ref.field_path,
            context_key: meta_ref.context_key,
            getter_fn: getter_fn
          }
        )
      end)
    end)
  end
  
  defp build_getter_fn(%{kind: :state_of, field_path: path}) do
    fn workflow, target ->
      state = Workflow.last_known_state(workflow, target)
      get_in_path(state, path)
    end
  end
  
  defp build_getter_fn(%{kind: :step_ran}) do
    fn workflow, target ->
      workflow.graph
      |> Graph.out_edges(target, by: :ran)
      |> Enum.any?()
    end
  end
  
  defp build_getter_fn(%{kind: :fact_count}) do
    fn workflow, target ->
      workflow.graph
      |> Graph.out_edges(target, by: [:produced, :state_produced, :reduced])
      |> length()
    end
  end
  
  defp build_getter_fn(%{kind: :all_facts}) do
    fn workflow, target ->
      workflow.graph
      |> Graph.out_edges(target, by: [:produced, :state_produced, :reduced])
      |> Enum.map(& &1.v2)
    end
  end
  
  defp build_getter_fn(%{kind: :all_values}) do
    fn workflow, target ->
      workflow.graph
      |> Graph.out_edges(target, by: [:produced, :state_produced, :reduced])
      |> Enum.map(& &1.v2.value)
    end
  end
  
  defp build_getter_fn(%{kind: :latest_fact}) do
    fn workflow, target ->
      workflow.graph
      |> Graph.out_edges(target, by: [:produced, :state_produced, :reduced])
      |> Enum.max_by(fn edge -> Workflow.ancestry_depth(workflow, edge.v2) end, fn -> nil end)
      |> case do
        nil -> nil
        edge -> edge.v2
      end
    end
  end
  
  defp build_getter_fn(%{kind: :latest_value}) do
    fn workflow, target ->
      case build_getter_fn(%{kind: :latest_fact}).(workflow, target) do
        nil -> nil
        fact -> fact.value
      end
    end
  end
end
```

**3. Prepare Phase Injects Context**

The key change is in the existing `Invokable.prepare/3` implementations. They check for `:meta_ref` in-edges and prepare context:

```elixir
# In lib/workflow/invokable.ex - Condition impl
defimpl Runic.Workflow.Invokable, for: Runic.Workflow.Condition do
  def prepare(%Condition{} = cond, %Workflow{} = workflow, %Fact{} = fact) do
    # NEW: Prepare meta context from :meta_ref edges
    meta_context = prepare_meta_context(workflow, cond)
    
    context =
      CausalContext.new(
        node_hash: cond.hash,
        input_fact: fact,
        ancestry_depth: Workflow.ancestry_depth(workflow, fact),
        hooks: Workflow.get_hooks(workflow, cond.hash),
        meta_context: meta_context  # NEW field
      )

    {:ok, Runnable.new(cond, fact, context)}
  end
  
  defp prepare_meta_context(workflow, node) do
    workflow.graph
    |> Graph.out_edges(node, by: :meta_ref)
    |> Enum.reduce(%{}, fn edge, acc ->
      target = edge.v2
      %{context_key: key, getter_fn: getter} = edge.properties
      value = getter.(workflow, target)
      Map.put(acc, key, value)
    end)
  end
  
  def execute(%Condition{} = cond, %Runnable{input_fact: fact, context: ctx} = runnable) do
    # Pass meta_context to the work function if it expects it
    satisfied = 
      if has_meta_context?(ctx) do
        cond.work.(fact.value, ctx.meta_context)
      else
        cond.work.(fact.value)
      end
    
    # ... rest of execute unchanged
  end
  
  defp has_meta_context?(%{meta_context: mc}) when map_size(mc) > 0, do: true
  defp has_meta_context?(_), do: false
end
```

**4. Execute Phase Uses Prepared Context**

The work function receives the prepared meta context as a second argument:

```elixir
# User writes:
rule name: :high_value do
  given order: %{id: id}
  where state_of(:cart).total > 100
  then fn %{order: order} -> {:discount, order} end
end

# Compiles to condition with work:
fn _input, %{cart_state: cart_state} -> cart_state > 100 end
```

#### Struct Changes

Minimal changes to existing structs:

```elixir
# lib/workflow/condition.ex
defmodule Runic.Workflow.Condition do
  defstruct [
    :hash,
    :work,
    :arity,
    :ast,
    :meta_refs  # NEW: list of %{kind, target, field_path, context_key}
  ]
end

# lib/workflow/step.ex  
defmodule Runic.Workflow.Step do
  defstruct [
    # ... existing fields
    :meta_refs  # NEW: for steps that use meta expressions in their work
  ]
end
```

#### CausalContext Addition

```elixir
# lib/workflow/causal_context.ex
defstruct [
  # ... existing fields
  :meta_context  # NEW: %{context_key => prepared_value}
]

@spec with_meta_context(t(), map()) :: t()
def with_meta_context(%__MODULE__{} = ctx, meta_context) do
  %{ctx | meta_context: meta_context}
end
```

#### Advantages of This Approach

| Aspect | Edge-Injected Approach | New Struct Approach |
|--------|----------------------|---------------------|
| New structs | 0 | 2 (MetaCondition, MetaReaction) |
| Invokable impls | Modify existing | Add new |
| Component impls | Modify existing | Add new |
| Mental model | "Condition with extra context" | "New node type" |
| Serialization | Edges serialize naturally | New struct serialization |
| Composability | Works with existing patterns | Parallel pattern |

#### Edge Traversal for Dependencies

To find what a node depends on via meta expressions:

```elixir
def meta_dependencies(workflow, node) do
  workflow.graph
  |> Graph.out_edges(node, by: :meta_ref)
  |> Enum.map(fn edge -> {edge.properties.kind, edge.v2} end)
end
```

To find what depends on a component via meta expressions:

```elixir
def meta_dependents(workflow, component) do
  workflow.graph
  |> Graph.in_edges(component, by: :meta_ref)
  |> Enum.map(fn edge -> {edge.properties.kind, edge.v1} end)
end
```

---

### Alternative Approach: New Struct (For Reference)

The following section describes an alternative using dedicated `MetaCondition` structs. This is preserved for reference but the edge-injected approach above is preferred.

### New Struct: `%MetaCondition{}`

```elixir
defmodule Runic.Workflow.MetaCondition do
  @moduledoc """
  A condition that evaluates meta expressions referencing workflow state.
  
  Meta conditions extract their required context during the prepare phase,
  enabling pure evaluation during the execute phase.
  """
  
  defstruct [
    :hash,
    :kind,           # :state_of | :step_ran | :fact_count | :all_facts | :all_values | :latest_fact | :latest_value
    :target_ref,     # {component_name, :component} | {component_name, :subcomponent_kind}
    :field_path,     # [:field, :nested_field] for state_of(:acc).field.nested
    :evaluator,      # fn context -> boolean end - pure function for execute phase
    :source_ast      # Original AST for debugging/serialization
  ]
  
  @type t :: %__MODULE__{
    hash: integer(),
    kind: atom(),
    target_ref: {atom(), atom()} | atom(),
    field_path: [atom()] | nil,
    evaluator: (map() -> boolean()),
    source_ast: Macro.t()
  }
  
  def new(opts), do: struct!(__MODULE__, opts)
end
```

### New Struct: `%MetaReaction{}`

```elixir
defmodule Runic.Workflow.MetaReaction do
  @moduledoc """
  A step that produces values using meta expressions in its work function.
  
  Similar to MetaCondition but for the reaction (RHS) of rules.
  """
  
  defstruct [
    :hash,
    :meta_refs,      # List of {kind, target_ref, field_path} for all meta exprs in reaction
    :work,           # fn context, input -> output end
    :source_ast
  ]
end
```

### CausalContext Extensions

Add a new field to `CausalContext` for meta expression data:

```elixir
defstruct [
  # ... existing fields ...
  :meta_context    # %{target_ref => prepared_value} for meta expressions
]
```

With helper:

```elixir
@spec with_meta_context(t(), map()) :: t()
def with_meta_context(%__MODULE__{} = ctx, meta_context) do
  %{ctx | meta_context: meta_context}
end
```

---

## Graph Edge Strategy

### New Edge Label: `:meta_ref`

When a component containing meta expressions is added to the workflow, create edges that enable efficient traversal:

```elixir
# From the MetaCondition to the referenced component
Workflow.draw_connection(meta_condition, target_component, :meta_ref,
  properties: %{
    kind: :state_of,           # or :step_ran, :fact_count, etc.
    field_path: [:total]       # optional field extraction
  }
)
```

### Edge Direction

The edge goes **from the meta-expression node TO the referenced component** so we can:
1. Quickly find what a meta condition depends on
2. Find all meta conditions that depend on a component (via in_edges)

### Integration with Component.connect/3

When adding a Rule containing meta expressions:

```elixir
defimpl Runic.Component, for: Runic.Workflow.Rule do
  def connect(rule, to, workflow) do
    workflow
    |> add_rule_workflow(rule, to)
    |> register_meta_references(rule)  # NEW: Create :meta_ref edges
  end
  
  defp register_meta_references(workflow, rule) do
    # Walk rule's internal workflow for MetaCondition/MetaReaction nodes
    # For each, create :meta_ref edge to target component
    meta_nodes = find_meta_nodes(rule.workflow)
    
    Enum.reduce(meta_nodes, workflow, fn meta_node, wrk ->
      target = resolve_target(wrk, meta_node.target_ref)
      Workflow.draw_connection(wrk, meta_node, target, :meta_ref,
        properties: %{kind: meta_node.kind, field_path: meta_node.field_path}
      )
    end)
  end
end
```

---

## Protocol Integration

### Invokable Protocol for MetaCondition

```elixir
defimpl Runic.Workflow.Invokable, for: Runic.Workflow.MetaCondition do
  alias Runic.Workflow
  alias Runic.Workflow.{Fact, Runnable, CausalContext}

  def match_or_execute(_meta_condition), do: :match

  def prepare(%MetaCondition{} = mc, %Workflow{} = workflow, %Fact{} = fact) do
    # Prepare the meta context based on kind
    meta_value = prepare_meta_value(mc, workflow)
    
    context =
      CausalContext.new(
        node_hash: mc.hash,
        input_fact: fact,
        ancestry_depth: Workflow.ancestry_depth(workflow, fact),
        meta_context: %{mc.target_ref => meta_value}
      )
    
    {:ok, Runnable.new(mc, fact, context)}
  end

  def execute(%MetaCondition{} = mc, %Runnable{context: ctx} = runnable) do
    # Pure evaluation using prepared context
    prepared_value = ctx.meta_context[mc.target_ref]
    satisfied = mc.evaluator.(prepared_value)
    
    apply_fn = fn workflow ->
      if satisfied do
        workflow
        |> Workflow.prepare_next_runnables(mc, ctx.input_fact)
        |> Workflow.draw_connection(ctx.input_fact, mc, :satisfied, 
             weight: ctx.ancestry_depth + 1)
        |> Workflow.mark_runnable_as_ran(mc, ctx.input_fact)
      else
        Workflow.mark_runnable_as_ran(workflow, mc, ctx.input_fact)
      end
    end
    
    Runnable.complete(runnable, satisfied, apply_fn)
  end

  # Kind-specific preparation functions
  defp prepare_meta_value(%{kind: :state_of, target_ref: ref, field_path: path}, workflow) do
    component = resolve_component(workflow, ref)
    state = Workflow.last_known_state(workflow, component)
    extract_field_path(state, path)
  end
  
  defp prepare_meta_value(%{kind: :step_ran, target_ref: ref}, workflow) do
    component = resolve_component(workflow, ref)
    has_ran_edges?(workflow, component)
  end
  
  defp prepare_meta_value(%{kind: :fact_count, target_ref: ref}, workflow) do
    component = resolve_component(workflow, ref)
    count_produced_facts(workflow, component)
  end
  
  defp prepare_meta_value(%{kind: :all_facts, target_ref: ref}, workflow) do
    component = resolve_component(workflow, ref)
    get_all_produced_facts(workflow, component)
  end
  
  defp prepare_meta_value(%{kind: :all_values, target_ref: ref}, workflow) do
    component = resolve_component(workflow, ref)
    get_all_produced_facts(workflow, component) |> Enum.map(& &1.value)
  end
  
  defp prepare_meta_value(%{kind: :latest_fact, target_ref: ref}, workflow) do
    component = resolve_component(workflow, ref)
    get_latest_produced_fact(workflow, component)
  end
  
  defp prepare_meta_value(%{kind: :latest_value, target_ref: ref}, workflow) do
    component = resolve_component(workflow, ref)
    case get_latest_produced_fact(workflow, component) do
      nil -> nil
      fact -> fact.value
    end
  end
  
  defp extract_field_path(value, nil), do: value
  defp extract_field_path(value, []), do: value
  defp extract_field_path(value, [field | rest]) when is_map(value) do
    extract_field_path(Map.get(value, field), rest)
  end
  defp extract_field_path(_, _), do: nil
end
```

### Component Protocol Integration

`MetaCondition` needs Component protocol for composition:

```elixir
defimpl Runic.Component, for: Runic.Workflow.MetaCondition do
  def components(mc), do: [{mc.hash, mc}]
  def connectables(mc, _), do: components(mc)
  def connectable?(_, _), do: true
  
  def connect(mc, to, workflow) do
    workflow
    |> Workflow.add_step(to, mc)
    |> register_meta_edge(mc)
  end
  
  defp register_meta_edge(workflow, mc) do
    case Workflow.get_component(workflow, elem(mc.target_ref, 0)) do
      nil -> workflow  # Component not yet added, edge created when target is added
      target -> Workflow.draw_connection(workflow, mc, target, :meta_ref,
                  properties: %{kind: mc.kind})
    end
  end
  
  def source(mc), do: mc.source_ast
  def hash(mc), do: mc.hash
  def inputs(_), do: [meta_condition: [type: :any]]
  def outputs(_), do: [meta_condition: [type: :boolean]]
end
```

---

## Macro Compilation

### Detection in `compile_when_clause`

Modify the existing rule compilation to detect meta expressions:

```elixir
defp compile_when_clause(when_expr, pattern, top_binding, binding_vars, env) do
  # NEW: Check for meta expressions in the when clause
  {has_meta, meta_exprs} = detect_meta_expressions(when_expr)
  
  if has_meta do
    compile_meta_when_clause(when_expr, meta_exprs, pattern, top_binding, binding_vars, env)
  else
    # Existing compilation path for vanilla conditions
    compile_vanilla_when_clause(when_expr, pattern, top_binding, binding_vars, env)
  end
end
```

### Meta Expression Detection

```elixir
defp detect_meta_expressions(ast) do
  {ast, meta_exprs} = Macro.prewalk(ast, [], fn
    # state_of(:component) or state_of(:component).field
    {{:., _, [{:state_of, _, [ref]}, field]}, _, []} = node, acc ->
      {node, [{:state_of, ref, [field]} | acc]}
    
    {:state_of, _, [ref]} = node, acc ->
      {node, [{:state_of, ref, []} | acc]}
    
    {:step_ran?, _, [ref]} = node, acc ->
      {node, [{:step_ran, ref, []} | acc]}
    
    {:fact_count, _, [ref]} = node, acc ->
      {node, [{:fact_count, ref, []} | acc]}
    
    {:all_facts_of, _, [ref]} = node, acc ->
      {node, [{:all_facts, ref, []} | acc]}
    
    {:all_values_of, _, [ref]} = node, acc ->
      {node, [{:all_values, ref, []} | acc]}
    
    {:latest_fact_of, _, [ref]} = node, acc ->
      {node, [{:latest_fact, ref, []} | acc]}
    
    {:latest_value_of, _, [ref]} = node, acc ->
      {node, [{:latest_value, ref, []} | acc]}
    
    node, acc ->
      {node, acc}
  end)
  
  {length(meta_exprs) > 0, meta_exprs}
end
```

### Meta Condition Compilation

```elixir
defp compile_meta_when_clause(when_expr, meta_exprs, pattern, top_binding, binding_vars, env) do
  # Generate unique context keys for each meta expression
  meta_bindings = Enum.with_index(meta_exprs, fn {kind, ref, field_path}, idx ->
    {:"__meta_#{idx}", {kind, ref, field_path}}
  end)
  
  # Rewrite the when_expr to use context lookups
  rewritten_expr = rewrite_meta_refs(when_expr, meta_bindings)
  
  # Build MetaCondition struct
  quote do
    # Build the evaluator function that receives prepared context
    evaluator = fn meta_ctx ->
      # Bind meta values from context
      unquote_splicing(
        for {var_name, {_kind, ref, _path}} <- meta_bindings do
          quote do
            unquote(Macro.var(var_name, nil)) = Map.get(meta_ctx, unquote(ref))
          end
        end
      )
      
      # Evaluate the rewritten expression
      unquote(rewritten_expr)
    end
    
    MetaCondition.new(
      kind: unquote(determine_primary_kind(meta_exprs)),
      target_ref: unquote(build_target_ref(meta_exprs)),
      field_path: unquote(extract_field_path(meta_exprs)),
      evaluator: evaluator,
      hash: Runic.Workflow.Components.fact_hash(unquote(Macro.escape(when_expr))),
      source_ast: unquote(Macro.escape(when_expr))
    )
  end
end
```

### Compound Meta Expressions

When a `where` clause has both meta expressions AND regular pattern-based conditions:

```elixir
where order.total > 50 and state_of(:cart).discount_applied == false
```

Compilation creates a Conjunction:
1. Regular `Condition` for `order.total > 50`
2. `MetaCondition` for `state_of(:cart).discount_applied == false`
3. `Conjunction` combining both

---

## Phased Implementation Plan (Edge-Injected Approach)

This plan follows the preferred edge-injected approach where existing `Condition` and `Step` structs are enhanced with `:meta_refs` field, and `:meta_ref` edges inject context during prepare phase.

### Phase 1: Core Infrastructure

**Files to modify:**

1. **`lib/workflow/causal_context.ex`**
   - Add `:meta_context` field to struct (default `%{}`)
   - Add `with_meta_context/2` helper function

2. **`lib/workflow/condition.ex`**
   - Add `:meta_refs` field to struct (default `[]`)

3. **`lib/workflow/step.ex`**
   - Add `:meta_refs` field to struct (default `[]`)

4. **`lib/workflow.ex`**
   - Add `prepare_meta_context/2` - traverses `:meta_ref` edges and executes getter functions
   - Add `meta_dependencies/2` - query what a node depends on via meta refs
   - Add `meta_dependents/2` - query what depends on a component via meta refs

**Tests:**
- `test/workflow/meta_context_test.exs` - Unit tests for meta context preparation and edge traversal

### Phase 2: `state_of/1` in `where` Clause

**Files to modify:**

1. **`lib/runic.ex`** - Macro compilation
   - Add `detect_meta_expressions/1` - walks AST looking for `state_of`, `step_ran?`, etc.
   - Add `compile_meta_when_clause/6` - compiles condition with meta_refs populated
   - Add `rewrite_meta_refs_in_ast/2` - transforms `state_of(:x).y` → `meta_ctx.x_state`
   - Modify `compile_when_clause/5` to detect meta expressions and branch

2. **`lib/workflow/invokable.ex`** - Condition impl
   - Modify `prepare/3` to call `Workflow.prepare_meta_context/2` when node has meta_refs
   - Modify `execute/2` to pass `ctx.meta_context` as second arg when present

3. **`lib/workflow/component.ex`** - Rule impl
   - Add `create_meta_ref_edges/2` in Rule's `connect/3` implementation
   - Add `build_getter_fn/1` for `:state_of` kind - uses `Workflow.last_known_state/2`
   - Add `has_meta_refs?/1` helper

**Tests - `test/rule_meta_expressions_test.exs`:**
- Basic `state_of(:accumulator)` in where clause
- `state_of(:acc).field` with single field path extraction
- `state_of(:acc).nested.field` with deep field access
- `state_of` with Accumulator component (uses last_known_state)
- `state_of` with StateMachine component
- `state_of` before target has produced any facts (returns init value)
- Missing component reference (returns nil, doesn't crash)

### Phase 3: Simple Boolean/Numeric Meta Expressions

**For each, add `build_getter_fn/1` clause and tests:**

1. **`step_ran?/1`**
   - Getter: `Graph.out_edges(target, by: :ran) |> Enum.any?()`
   - Test: rule fires only after referenced step has run

2. **`fact_count/1`**
   - Getter: `Graph.out_edges(target, by: [:produced, :state_produced, :reduced]) |> length()`
   - Test: `where fact_count(:processor) >= 3`

3. **`latest_value_of/1`**
   - Getter: find fact with max ancestry_depth from target, extract `.value`
   - Test: rule using latest produced value in condition

4. **`latest_fact_of/1`**
   - Getter: find fact with max ancestry_depth from target
   - Test: rule accessing fact ancestry metadata

### Phase 4: Collection Meta Expressions

1. **`all_values_of/1`**
   - Getter: collect all produced facts, map to `.value`
   - Test: `where length(all_values_of(:items)) > 5`
   - Test: `where Enum.sum(all_values_of(:scores)) > 100`

2. **`all_facts_of/1`**
   - Getter: collect all produced facts as list
   - Test: rule filtering facts by ancestry or other metadata

**Performance tests:**
- 1000+ facts from a single component
- Parallel execution with meta expressions accessing same component

### Phase 5: Meta Expressions in `then` Clause

**Files to modify:**

1. **`lib/runic.ex`**
   - Modify `compile_then_clause/5` to detect meta expressions
   - Generate Step with `meta_refs` field populated
   - Rewrite reaction function to receive meta_context

2. **`lib/workflow/invokable.ex`** - Step impl
   - Modify `prepare/3` to call `prepare_meta_context/2` when step has meta_refs
   - Modify `execute/2` to pass meta_context to work function

**Tests:**
- `state_of(:acc)` in then clause returns current state value
- Multiple meta expressions in single then clause
- Combining pattern bindings (`%{order: order}`) with meta expressions
- Meta expression in then clause references component added later to workflow

### Phase 6: Compound Expressions & Edge Cases

**Implement:**

1. **Multiple meta expressions in one clause**
   ```elixir
   where state_of(:a).x > 0 and state_of(:b).y < 10
   ```
   - Multiple `:meta_ref` edges from same Condition node
   - Meta context map has multiple keys: `%{a_state: ..., b_state: ...}`

2. **Mixed pattern + meta conditions**
   ```elixir
   where order.total > 50 and state_of(:cart).discount == false
   ```
   - Condition work function: `fn input, meta_ctx -> input.total > 50 and meta_ctx.cart_state.discount == false end`

3. **Subcomponent references**
   ```elixir
   state_of({:my_rule, :condition})
   state_of({:my_map, :leaf})
   ```
   - Tuple target resolution via existing `Workflow.get_component/2`
   - Getter uses subcomponent directly

**Edge case tests:**
- Missing component returns nil (no crash)
- Circular meta references detected at connect time (raise error)
- Component referenced before it's added (deferred edge creation, or resolve at prepare time)
- Empty field path on state_of (returns full state)

### Phase 7: Serialization & Build Log

**Files to modify:**

1. **`lib/workflow/serializer.ex`**
   - Include `:meta_ref` edges in serialization
   - Serialize edge properties (kind, field_path, context_key)
   - `getter_fn` NOT serialized - rebuilt from kind + field_path during restore

2. **`lib/workflow.ex`** - `from_log/1`
   - Reconstruct `getter_fn` from edge properties using `build_getter_fn/1`

3. **`lib/workflow/component.ex`**
   - Ensure `create_meta_ref_edges/2` is idempotent for rebuild scenarios

**Tests:**
- Round-trip: workflow with meta expressions → `build_log` → `from_log` → execute
- Verify `:meta_ref` edges recreated correctly
- Verify getter functions work after restoration

---

## Q&A / Open Questions

### Q1: Component Resolution Timing

**Question**: When should we resolve the target component reference?

- **At macro compile time**: Requires component to exist, fails if added later
- **At workflow build time**: When Rule is added to workflow via Component.connect
- **At runtime prepare phase**: Most flexible, resolves by name each time

**Suggested Answer (Edge-Injected)**: 
- Create `:meta_ref` edges at **workflow build time** (Component.connect)
- If target doesn't exist yet, store `target: :component_name` on the node's `meta_refs` field and defer edge creation
- At **prepare phase**, follow the edges (already resolved) or resolve by name if edge creation was deferred
- This balances graph integrity with dynamic construction flexibility

---

### Q2: Multiple Meta Expressions in One Clause

**Question**: How to handle `where state_of(:a).x > 0 and state_of(:b).y < 10`?

**Answer (Edge-Injected)**:
- Single `Condition` node with multiple entries in `meta_refs` field
- Multiple `:meta_ref` edges from this Condition to each target
- `prepare_meta_context/2` follows all edges, builds a map: `%{a_state: ..., b_state: ...}`
- Work function receives both: `fn input, meta_ctx -> meta_ctx.a_state > 0 and meta_ctx.b_state < 10 end`

---

### Q3: Subcomponent References

**Question**: How to reference subcomponents like `state_of({:my_map, :fan_out})`?

**Answer**: Support tuple syntax matching existing `get_component/2` API:
- `state_of(:my_accumulator)` - direct component
- `state_of({:my_rule, :condition})` - subcomponent by kind
- `state_of({:my_map, :leaf})` - Map's leaf step

The edge's v2 will be the resolved subcomponent, not the parent component.

---

### Q4: Error Handling for Missing Components

**Question**: What happens if `state_of(:nonexistent)` references a component that doesn't exist?

**Answer (Edge-Injected)**:
- At **connect time**: If target not found, store reference in `meta_refs` without creating edge
- At **prepare time**: If edge doesn't exist and name lookup fails, `getter_fn` returns `nil`
- Work function receives `nil` for that context key
- Document that meta expressions should handle `nil` defensively

This matches Elixir's nil-punning philosophy and supports dynamic workflow construction.

---

### Q5: Initialization State

**Question**: What does `state_of(:accumulator)` return before the accumulator has been invoked?

**Answer**: Return the accumulator's `init` value (calling init function if needed). 

The `build_getter_fn(%{kind: :state_of, ...})` implementation delegates to `Workflow.last_known_state/2` which already has this fallback behavior.

---

### Q6: Fact Ordering for `latest_*` Functions

**Question**: How do we determine "latest" when facts may be produced in parallel?

**Answer**: Use `ancestry_depth` (causal depth) as the ordering metric:

```elixir
defp build_getter_fn(%{kind: :latest_fact}) do
  fn workflow, target ->
    workflow.graph
    |> Graph.out_edges(target, by: [:produced, :state_produced, :reduced])
    |> Enum.max_by(
      fn edge -> Workflow.ancestry_depth(workflow, edge.v2) end,
      fn -> nil end
    )
    |> case do
      nil -> nil
      edge -> edge.v2
    end
  end
end
```

Document that in parallel execution, "latest" may be non-deterministic among facts at the same causal depth.

---

### Q7: Should Meta Expressions Be Usable Outside Rules?

**Question**: Can users write `Runic.step(fn _ -> state_of(:acc) end)`?

**Answer**: For Phase 1, only support in `rule` DSL's `given/where/then`. 

The Step struct already gets `meta_refs` field in Phase 1, but macro detection only happens in rule compilation. Phase 5 extends to `then` clause (which compiles to a Step), then future work can extend to standalone `Runic.step()` calls.

---

### Q8: Interaction with Hooks

**Question**: Should before/after hooks on the target component fire when accessed via meta expression?

**Answer**: No. Meta expressions are **read-only queries** against workflow state. 

- The target component's hooks fire when that component is invoked
- The Condition/Step containing the meta expression has its own hooks (if registered) which do fire
- Meta context preparation happens in prepare phase, before any hooks run

---

### Q9: Serialization of `:meta_ref` Edges

**Question**: How do we serialize the `getter_fn` stored in edge properties?

**Answer (Edge-Injected)**:
- Edge properties `kind`, `field_path`, `context_key` are serialized as data
- `getter_fn` is **NOT serialized** - it's rebuilt during `from_log/1`
- During restoration, call `build_getter_fn(%{kind: kind, field_path: field_path})` to recreate

```elixir
# In from_log or edge restoration:
defp restore_meta_ref_edge(edge) do
  %{edge | 
    properties: Map.put(edge.properties, :getter_fn, 
      build_getter_fn(edge.properties))
  }
end
```

This mirrors how `Step.work` is rebuilt from `Closure` during restoration.

---

### Q10: Performance Considerations

**Question**: What's the cost of meta expression evaluation?

**Prepare phase costs**:
- `state_of/1`: O(1) vertex lookup + O(e) edge traversal for state_produced
- `step_ran?/1`: O(e) edge check for :ran edges
- `fact_count/1`: O(e) counting produced edges
- `all_facts_of/1`: O(e) collecting facts, O(n) memory for result
- `latest_*`: O(e) edge traversal with max-depth tracking

**Mitigation strategies**:
- Cache state lookups in workflow during a react cycle
- Use edge label indices (already in libgraph) for fast queries (do this to start)
- Document that `all_facts_of/1` on high-volume components may be expensive

---

## Implementation Checklist (Edge-Injected Approach)

### Phase 1: Core Infrastructure
- [ ] Add `:meta_context` field to `CausalContext` struct (default `%{}`)
- [ ] Add `with_meta_context/2` helper to CausalContext
- [ ] Add `:meta_refs` field to `Condition` struct (default `[]`)
- [ ] Add `:meta_refs` field to `Step` struct (default `[]`)
- [ ] Add `prepare_meta_context/2` to Workflow module
- [ ] Add `meta_dependencies/2` to Workflow module
- [ ] Add `meta_dependents/2` to Workflow module
- [ ] Add `build_getter_fn/1` with clause for `:state_of`
- [ ] Create `test/workflow/meta_context_test.exs` with unit tests

### Phase 2: state_of/1 in where Clause
- [ ] Add `detect_meta_expressions/1` in runic.ex - walks AST for meta calls
- [ ] Add `compile_meta_when_clause/6` in runic.ex - builds Condition with meta_refs
- [ ] Add `rewrite_meta_refs_in_ast/2` - transforms state_of(:x) → meta_ctx.x_state
- [ ] Modify `compile_when_clause/5` to detect and branch on meta expressions
- [ ] Modify Condition's `Invokable.prepare/3` to call `prepare_meta_context/2`
- [ ] Modify Condition's `Invokable.execute/2` to pass meta_context when present
- [ ] Add `create_meta_ref_edges/2` in Rule's Component.connect
- [ ] Add `has_meta_refs?/1` helper function
- [ ] Test: basic state_of(:accumulator) in where clause
- [ ] Test: state_of(:acc).field with single field path
- [ ] Test: state_of(:acc).nested.field with deep path
- [ ] Test: state_of with Accumulator (uses last_known_state)
- [ ] Test: state_of before target invoked (returns init)
- [ ] Test: missing component reference (returns nil)

### Phase 3: Simple Boolean/Numeric Meta Expressions
- [ ] Add `build_getter_fn/1` clause for `:step_ran`
- [ ] Test: step_ran?(:step) in where clause
- [ ] Add `build_getter_fn/1` clause for `:fact_count`
- [ ] Test: fact_count(:processor) >= 3
- [ ] Add `build_getter_fn/1` clause for `:latest_value`
- [ ] Test: latest_value_of(:sensor) in condition
- [ ] Add `build_getter_fn/1` clause for `:latest_fact`
- [ ] Test: latest_fact_of(:producer) accessing ancestry

### Phase 4: Collection Meta Expressions
- [ ] Add `build_getter_fn/1` clause for `:all_values`
- [ ] Test: length(all_values_of(:items)) > 5
- [ ] Test: Enum.sum(all_values_of(:scores)) > 100
- [ ] Add `build_getter_fn/1` clause for `:all_facts`
- [ ] Test: filtering facts by ancestry
- [ ] Performance test: 1000+ facts from single component

### Phase 5: Meta Expressions in then Clause ✅ COMPLETED
- [x] Add `compile_meta_then_clause/6` to detect and compile meta expressions in then
- [x] Generate Step with meta_refs field populated
- [x] Modify Step's `Invokable.prepare/3` to call `prepare_meta_context/2` when has_meta_refs?
- [x] Modify Step's `Invokable.execute/2` to call `run_with_meta_context` when meta_context present
- [x] Update `workflow_of_rule_with_meta/5` to pass reaction_meta_refs to Step
- [x] Update Rule's `Component.connect` to create meta_ref edges for both condition AND reaction
- [x] Test: state_of(:acc) in then clause returns current state
- [x] Test: state_of with field access in then clause
- [x] Test: multiple meta expressions in single then clause
- [x] Test: meta expressions in both where and then clauses
- [x] Test: all_values_of, latest_value_of in then clause
- [x] Test: meta_ref edges created for reaction when rule added to workflow
- [x] Test: end-to-end workflow execution with meta expressions in then clause

### Phase 6: Compound Expressions & Edge Cases ✅ COMPLETED
- [x] Test: multiple meta refs in one where clause (already existed)
- [x] Test: mixed pattern + meta conditions
- [x] Test: subcomponent references with tuple syntax (state_of({:my_sm, :accumulator}))
- [x] Test: component added after rule (deferred edge creation - documents current behavior)
- [x] Test: deeply nested field access (state_of(:config).database.connection.pool_size)
- [x] Test: guard-style comparison operators (state_of(:level) >= 10 and state_of(:level) <= 100)
- [x] Test: meta expressions in or branches
- [x] StateMachine component now registers itself and creates :component_of edge to accumulator
- [ ] Circular meta reference detection (deferred - not yet implemented)

### Phase 7: Serialization & Build Log ✅ COMPLETED
- [x] Include `:meta_ref` edges in serializer (via `reactions_occurred/1`)
- [x] Skip `getter_fn` serialization (via `strip_getter_fn_for_serialization/2`)
- [x] Add `restore_meta_ref_properties/2` in from_log restoration to rebuild getter_fn
- [x] Test: round-trip serialize → restore → execute
- [x] Test: verify edges recreated correctly with functional getter_fn
- [x] Test: log/1 output is serializable with term_to_binary
- [x] Test: restored workflow with state_of in then clause executes correctly
- [x] Test: restored workflow with multiple meta expression kinds
- [x] Test: meta_ref edges point to correct target components after restoration
- [x] Test: workflow with runtime bindings in then clause serializes correctly
- [x] Test: workflow with meta expressions and regular bindings serializes correctly

---

## Future Work: Materialized Projection Optimization

> **Status**: Proposal  
> **Priority**: Low (performance optimization)

### Problem

The current naive approach computes meta expressions at runtime during every invocation:

```elixir
# Every time this rule fires, all_values_of scans the graph for all facts
rule name: :check_total do
  given event: e
  where Enum.sum(all_values_of(:scores)) > 100
  then fn %{event: e} -> {:threshold_exceeded, e} end
end
```

For high-volume workflows or collection meta expressions (`all_values_of`, `all_facts_of`), this can become expensive as the workflow accumulates many facts.

### Proposed Solution: Compile-Time Materialized Projections

Instead of computing meta expressions at runtime, compile them into materialized view-like projections as separate workflow components. The condition/step would then depend on this projection via a regular graph edge.

#### Example Transformation

**Before (naive):**
```elixir
rule name: :check_sum do
  given x: _x
  where Enum.sum(all_values_of(:scores)) > 100
  then fn _ -> :threshold_exceeded end
end
```

**After (optimized):**
```
             ┌──────────────────────┐
             │    :scores step      │
             └──────────────────────┘
                       │
                       │ :produced
                       ▼
             ┌──────────────────────┐
             │  :scores_sum_acc     │  <-- Auto-generated accumulator
             │  init: 0             │      that incrementally sums scores
             │  reducer: acc + x    │
             └──────────────────────┘
                       │
                       │ :meta_projection (new edge type)
                       ▼
             ┌──────────────────────┐
             │  :check_sum rule     │
             │  condition: > 100    │  <-- Reads from projection, not re-scanning
             └──────────────────────┘
```

The condition's prepare phase would read the projection accumulator's state instead of scanning all facts.

### Benefits

1. **Incremental computation**: `Enum.sum(all_values_of(:scores))` becomes O(1) per invocation instead of O(n)
2. **Leverages existing primitives**: Uses Runic's existing Accumulator/Reduce components
3. **Declarative optimization**: Users write simple expressions, compiler generates efficient topology
4. **Maintains semantics**: Same behavior, just faster

### Challenges

1. **Complexity**: Detecting which expressions can be incrementalized
2. **Ordering**: Projection must update before dependent condition evaluates
3. **Reset semantics**: What happens on workflow reset?
4. **Composability**: Nested projections like `Enum.filter(all_values_of(:x), &check/1) |> Enum.count()`

### Candidate Meta Expressions for Optimization

| Expression | Projection Type |
|-----------|-----------------|
| `Enum.sum(all_values_of(:x))` | Accumulator: `fn v, acc -> acc + v end` |
| `Enum.count(all_values_of(:x))` | Accumulator: `fn _, acc -> acc + 1 end` |
| `length(all_values_of(:x))` | Same as count |
| `Enum.max(all_values_of(:x))` | Accumulator: `fn v, acc -> max(v, acc) end` |
| `Enum.min(all_values_of(:x))` | Accumulator: `fn v, acc -> min(v, acc) end` |

### Implementation Sketch

1. **Detection**: In `compile_given_when_then_rule`, detect optimizable patterns in AST
2. **Extraction**: Extract the collection meta expression and aggregation function
3. **Projection Generation**: Create an Accumulator component with appropriate init/reducer
4. **Graph Connection**: Connect projection to source component, connect rule to projection
5. **Rewrite**: Replace `Enum.sum(all_values_of(:scores))` with `state_of(:__scores_sum_projection)`

### Decision

**Start with naive approach** (current implementation) - it's simpler, correct, and sufficient for most use cases. Implement materialized projections as a targeted optimization when performance profiling shows it's needed.

The naive approach:
- ✅ Simpler to implement and maintain
- ✅ Works correctly for all cases
- ✅ Sufficient for moderate-sized workflows
- ⚠️ May become slow for very large workflows with collection meta expressions

Revisit this optimization if:
- Users report performance issues with collection meta expressions
- Benchmark shows significant overhead on realistic workflows
- Workflow sizes regularly exceed 1000+ facts from single components

## Research summary regarding query optimizers, predicate pushdown, reactive systems

### Expanded Research on Query Optimization

Query optimization is crucial for transforming high-level expressions (like your meta expressions) into efficient execution plans in dataflow systems. In Runic's context, this involves parsing expressions into an abstract syntax tree (AST), rewriting them for efficiency, and compiling to graph nodes with dependencies that enable lazy evaluation—computing aggregates like `sum` or `count` only when downstream nodes demand results. This avoids eager computation, reducing overhead in reactive workflows.

#### Key Concepts and Techniques
- **Rule-Based vs. Cost-Based Optimization**: Rule-based applies transformations (e.g., predicate pushdown, join reordering) heuristically, while cost-based estimates execution costs (e.g., via cardinality, I/O) to select the best plan. For Runic, a hybrid could optimize meta expressions: rewrite `sum(all_values_of(:scores))` to push filters early, then cost plans based on graph size.
- **Lazy Evaluation in Dataflow Graphs**: Systems delay computation until an action (e.g., result consumption) triggers it, building a DAG first for global optimizations like common subexpression elimination (CSE) or dead code removal. This aligns with compiling your expressions to lazy nodes: dependencies ensure `all_values_of(:scores)` is collected incrementally, and aggregates like `max/min` are computed on-demand.
- **Volcano-Style Optimizers**: Extend the classic Volcano model for graphs by enumerating equivalent plans via rules (e.g., commuting joins) and pruning via costs. In Runic, adapt for reactive dataflows: optimize subgraphs for expressions, ensuring lazy propagation of facts.

#### Applications to Meta Expressions in Runic
- Compile expressions to nodes: Parse to AST, transform aggregates into specialized nodes (e.g., a `SumNode` depending on a `CollectNode` for `all_values_of`). Define edges for dataflow, using lazy invocation via demand signals—similar to demand-driven evaluation where upstream computations activate only on downstream needs.
- Efficiency: Use incremental view maintenance for updates; recompute only changed parts of aggregates during fact propagation, avoiding full re-evaluations.
- Challenges: Handle cycles or infinite data with timestamps; optimize for parallelism in Elixir (e.g., via Flow).

#### Recommended Reading and Resources
- **Papers**:
  - "Query Optimization in Relational Systems" by Philip A. Bernstein et al. (1981): Foundational on cost-based techniques; apply to graph-based queries.
  - "Spark SQL: Relational Data Processing in Spark" by Michael Armbrust et al. (2015): Details Catalyst optimizer for DAGs; study for lazy transformations in expressions.
  - "Toward Lazy Evaluation in a Graph Database" (2019): Explores in-graph batching for throughput; relevant for lazy meta expression eval in DAGs.
- **Books**:
  - "Database System Implementation" by Hector Garcia-Molina et al. (2000): In-depth on optimizers; chapters on algebraic rewriting for expressions.
- **Projects to Study**:
  - Apache Spark (GitHub: apache/spark): Analyze Catalyst for compiling queries to DAGs with lazy eval.
  - Polars (Rust/Python library): Its query optimizer uses lazy frames for efficient aggregates; port ideas to Elixir for Runic's runtime.
  - DataFusion (Apache Arrow): Rust-based query engine; examine CASE expression optimizations for conditional meta exprs like your `where`.

### Expanded Research on "Out of the Tar Pit"

This 2006 paper by Ben Moseley and Peter Marks identifies complexity as the root of software crises, attributing most to accidental sources like mutable state and explicit control flow. It proposes Functional Relational Programming (FRP—not to be confused with reactive FRP) to minimize these, using relations for data and pure functions for logic. For reactive systems like Runic, FRP inspires declarative, state-minimal designs where expressions compile to composable, lazy graphs.

#### Key Concepts
- **State and Control as Complexity Sources**: Mutable state explodes possible configurations, complicating testing/reasoning. Control over-specifies execution order. FRP separates essential state (user-required) into base relations, derives others functionally, and lets infrastructure handle control lazily.
- **FRP Architecture**: Essential logic uses relational algebra (e.g., join, project) and pure functions for derived relations (views). Accidental state/control are isolated hints (e.g., "store this view" for caching). This enables data independence: logical simplicity without physical performance trade-offs.
- **Lazy Evaluation in FRP**: Derived relations compute on-demand (lazy) or eagerly via hints, avoiding unnecessary state. Composable expressions build via operators, ensuring closure—outputs are relations, inputs to further exprs.

#### Applications to Reactive Systems
- In reactive dataflows, FRP reduces "contamination" from state: pure functions process facts without side effects, propagating via relational updates. Dynamic modifications (e.g., adding rules) become declarative assignments, not imperative changes.
- For Runic: Treat workflows as relational graphs; meta expressions as derived views (e.g., `sum(all_values_of(:scores))` as a summarize operator). Infrastructure optimizes eval order, enabling lazy computation without explicit user control.

#### Applications to Meta Expressions in Runic
- Compile expressions declaratively: Parse to relational ops (e.g., `all_values_of` as project, `sum` as summarize), defining nodes/edges implicitly. Lazy eval via demand: infrastructure propagates needs backward, computing aggregates only when queried.
- Benefits: Composability allows nesting (e.g., `where count(...) > N` inside another expr); constraints ensure validity without state checks.
- Challenges: Handle real-world accidents (e.g., performance hints for eager aggregates in hot paths).

#### Recommended Reading and Resources
- **Papers**:
  - The original "Out of the Tar Pit" (PDF available online): Core reading; focus on Sections 7-9 for FRP details.
  - "A Summary of Out of the Tar Pit" by Jacob Beers (2024 talk): Concise overview with examples for developers.
- **Books**:
  - "An Introduction to Relational Database Theory" by C.J. Date (2010): Complements FRP with relational algebra; useful for expression compilation.
- **Projects to Study**:
  - Rel (RelationalAI): Modern FRP-inspired database; examine how it compiles declarative queries to graphs for incremental/lazy eval.
  - Datomic (Clojure DB): Uses immutable facts and queries; inspires Runic's fact propagation without mutable state.

### Expanded Research on Differential Dataflow

Differential Dataflow (DD) is an incremental computation framework from the Naiad project, enabling efficient updates to aggregates over changing data. It uses timestamps and differences (deltas) to recompute only affected parts, supporting lazy, on-demand evaluation in streaming/reactive contexts. For Runic, DD inspires handling meta expressions incrementally: track changes to `:scores`, update `sum` deltas lazily when the expression is invoked.

#### Key Concepts
- **Timely Dataflow**: Builds on Naiad's model, using logical timestamps for coordination in distributed graphs. Computations are data-driven but support cycles via epochs.
- **Incremental Aggregates**: For ops like sum/count/max/min, DD maintains collections as multisets with counts; updates apply deltas (add/remove). This enables O(1) or logarithmic recomputes vs. full scans.
- **Lazy Computation**: Integrates with demand-driven modes; computations activate via frontiers (pending timestamps), deferring work until results are needed.

#### Applications to Reactive Systems
- In reactive dataflows, DD handles streaming updates efficiently, propagating changes through graphs. It supports infinite data via lazy frontiers, avoiding eager materialization.
- For Runic: Extend forward chaining with differentials; facts as input changes trigger delta propagations for aggregates.

#### Applications to Meta Expressions in Runic
- Compile to DD operators: `all_values_of(:scores)` as a collection, `sum` as a reduce with delta tracking. Dependencies via timestamps ensure lazy eval—compute deltas only on invocation or change.
- Efficiency: For `where sum(...) > 100`, maintain incremental state; lazy updates avoid re-summing entire collections.
- Challenges: Implement in Elixir (e.g., via ETS for multisets); handle retractions for deletions.

#### Recommended Reading and Resources
- **Papers**:
  - "Naiad: A Timely Dataflow System" by Murray et al. (2013): Introduces DD; focus on incremental joins/aggregates.
  - "Differential Dataflow" by McSherry et al. (ongoing series): Details algorithms for lazy/incremental ops.
  - "Adapton: Composable, Demand-Driven Incremental Computation" (2014): Complements DD with lazy caching for expressions.
- **Books**:
  - "Streaming Systems" by Tyler Akidau et al. (2018): Covers incremental processing; apply to reactive workflows.
- **Projects to Study**:
  - Timely Dataflow (Rust: timely-dataflow/timely-dataflow): Core lib; prototype aggregates for Runic.
  - Materialize (materializeinc/materialize): SQL on DD; study query compilation to incremental views.
  - idf (Emacs lib): Simple lazy/incremental dataflow; lightweight inspiration for Elixir.