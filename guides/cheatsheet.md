# Runic Cheatsheet

Quick reference for Runic's core APIs.

## Setup

```elixir
# Always require before using macros
require Runic
alias Runic.Workflow

# Consider importing Runic as well
import Runic
```

## Creating Components

### Step

Steps are basic input → output transformation lambda functions:

```elixir
# Anonymous function
step = Runic.step(fn x -> x * 2 end)

# Captured module function
step = Runic.step(&String.upcase/1)

# With name (recommended for debugging and referencing in workflows)
step = Runic.step(fn x -> x + 1 end, name: :increment)

# Multi-arity (requires 2-element list input)
step = Runic.step(fn a, b -> a + b end)

# Pin runtime variables (required for serialization)
multiplier = 3
step = Runic.step(fn x -> x * ^multiplier end)
```

### Rule

Conditional logic with guards:

```elixir
# Guard-based condition (same Elixir guard clause limitations)
rule = Runic.rule(fn x when x > 0 -> :positive end)

# Separate condition/reaction
rule = Runic.rule(
  condition: fn x -> x > 10 end,
  reaction: fn x -> {:large, x} end,
  name: :size_check
)

# or
rule = Runic.rule(
  if: fn x -> x > 10 end,
  do: fn x -> {:large, x} end,
  name: :size_check
)

# Given/Where/Then DSL (for complex destructuring)
Runic.rule do
  given order: %{status: status, total: total}
  where status == :pending and total > 100
  then fn %{order: order} -> {:apply_discount, order} end
end
```

### Workflow

Compose components into a DAG:

```elixir
# Simple flat workflow (two independent steps to execute)
workflow = Runic.workflow(
  name: :simple,
  steps: [
    Runic.step(fn x -> x + 1 end),
    Runic.step(fn x -> x * 2 end)
  ]
)

# Pipeline syntax: {parent, [children]} (1 parent with two dependent steps)
workflow = Runic.workflow(
  name: :pipeline,
  steps: [
    {Runic.step(fn x -> x + 1 end, name: :add),
     [Runic.step(fn x -> x * 2 end, name: :double),
      Runic.step(fn x -> x * 3 end, name: :triple)]}
  ]
)

# With rules
workflow = Runic.workflow(
  name: :classifier,
  rules: [
    Runic.rule(fn x when x > 10 -> :large end),
    Runic.rule(fn x when x <= 10 -> :small end)
  ]
)
```

### State Machine

Stateful reducer with reactive conditions:

```elixir
counter = Runic.state_machine(
  name: :counter,
  init: 0,
  reducer: fn x, acc -> acc + x end,
  reactors: [
    fn state when state > 100 -> :threshold_exceeded end,
    fn state when state > 50 -> :warning end
  ]
)
```

### FSM (Finite State Machine)

```elixir
fsm = Runic.fsm name: :traffic_light do
  initial_state :red

  state :red do
    on :timer, to: :green
    on_entry fn -> {:notify, :stopped} end
  end

  state :green do
    on :timer, to: :yellow
  end

  state :yellow do
    on :timer, to: :red
  end
end
```

### Aggregate

```elixir
agg = Runic.aggregate name: :counter do
  state 0

  command :increment do
    emit fn _state -> {:incremented, 1} end
  end

  command :decrement do
    where fn state -> state > 0 end
    emit fn _state -> {:decremented, 1} end
  end

  event {:incremented, n}, state do
    state + n
  end

  event {:decremented, n}, state do
    state - n
  end
end
```

### Saga

```elixir
saga = Runic.saga name: :fulfillment do
  transaction :reserve do
    fn _input -> {:ok, :reserved} end
  end
  compensate :reserve do
    fn _ -> :released end
  end

  transaction :charge do
    fn %{reserve: _} -> {:ok, :charged} end
  end
  compensate :charge do
    fn _ -> :refunded end
  end

  on_complete fn results -> {:done, results} end
  on_abort fn reason, compensated -> {:failed, reason, compensated} end
end
```

### ProcessManager

```elixir
pm = Runic.process_manager name: :order_flow do
  state %{paid: false, shipped: false}

  on :payment_received do
    update %{paid: true}
    emit {:ship_order, 123}
  end

  on :shipment_created do
    update %{shipped: true}
  end

  complete? fn state -> state.shipped end
end
```

### Map

Fan-out transformation over enumerables:

```elixir
map_op = Runic.map(fn x -> x * 2 end, name: :double)
```

### Reduce

Fan-in aggregation:

```elixir
# With `:map` option for lazy map-reduce
reduce_op = Runic.reduce(0, fn x, acc -> x + acc end, name: :sum, map: :double)

# Usage: add reduce after map
workflow = Workflow.new()
  |> Workflow.add(map_op)
  |> Workflow.add(reduce_op, to: :double)
```

### Accumulator

Cumulative state across invocations:

```elixir
acc = Runic.accumulator(0, fn x, state -> state + x end, name: :running_sum)
```

## Adding Components to Workflows

```elixir
workflow = Workflow.new()
  |> Workflow.add(step1)                       # Add to root
  |> Workflow.add(step2, to: :step1_name)      # Add as child of named component
  |> Workflow.add(step3, to: step2)            # Add as child of component struct
  |> Workflow.add(join_step, to: [:a, :b])     # Join multiple parents
```

## Evaluating Workflows

### Basic Execution

```elixir
# Single cycle
workflow = Workflow.react(workflow, input)

# Run to completion (recommended for simple use)
workflow = Workflow.react_until_satisfied(workflow, input)
```

### Async/Parallel Execution

```elixir
# Parallel execution
workflow = Workflow.react_until_satisfied(workflow, input, 
  async: true, 
  max_concurrency: 8,
  timeout: :infinity
)
```

### Runtime Context

Inject external values (secrets, config, feature flags) into components:

```elixir
# Declare context dependencies with context/1
step = Runic.step(fn _x -> context(:api_key) end, name: :call_llm)

# With defaults — used when run_context doesn't provide the key
step = Runic.step(fn _x -> context(:api_key, default: "test-key") end, name: :call_llm)

# Default function — called lazily when key is missing
step = Runic.step(fn _x -> context(:api_key, default: fn -> System.get_env("KEY") end) end, name: :call_llm)

# In rules
rule = Runic.rule name: :gated do
  given(val: v)
  where(v > context(:threshold, default: 100))
  then(fn %{val: v} -> {:ok, v} end)
end

# In accumulators
acc = Runic.accumulator(0, fn x, s -> s + x * context(:factor, default: 1) end, name: :scaled)

# In map pipelines
map = Runic.map(fn x -> x * context(:multiplier) end, name: :mult_map)

# In reduce
red = Runic.reduce(0, fn x, acc -> acc + x * context(:weight) end, name: :weighted_sum)

# Provide at runtime
workflow
|> Workflow.put_run_context(%{
  call_llm: %{api_key: "sk-..."},
  _global: %{workspace_id: "ws1"}
})
|> Workflow.react_until_satisfied(input)

# Or via options
Workflow.react_until_satisfied(workflow, input,
  run_context: %{call_llm: %{api_key: "sk-..."}}
)

# Introspect and validate
Workflow.required_context_keys(workflow)
# => %{call_llm: [api_key: :required, model: {:optional, "gpt-4"}]}

Workflow.validate_run_context(workflow, %{call_llm: %{api_key: "sk-..."}})
# => :ok (keys with defaults are not reported as missing)
```

### Three-Phase Execution (Custom Schedulers)

```elixir
# Phase 1: Plan and prepare
workflow = Workflow.plan_eagerly(workflow, input)
{workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

# Phase 2: Execute (can be distributed/parallel)
executed = Enum.map(runnables, fn runnable ->
  Runic.Workflow.Invokable.execute(runnable.node, runnable)
end)

# Phase 3: Apply results
workflow = Enum.reduce(executed, workflow, fn runnable, wrk ->
  Workflow.apply_runnable(wrk, runnable)
end)

# Continue if more work
if Workflow.is_runnable?(workflow), do: # repeat...
```

## Extracting Results

```elixir
# All leaf productions (most common)
Workflow.raw_productions(workflow)
# => [result1, result2, ...]

# Productions from specific component
Workflow.raw_productions(workflow, :component_name)

# All facts (includes inputs and intermediates)
Workflow.facts(workflow)
# => [%Fact{value: input, ancestry: nil}, %Fact{value: output, ancestry: {...}}, ...]

# Productions with full Fact structs
Workflow.productions(workflow)
```

## Serialization & Persistence

```elixir
# Get build log for serialization
log = Workflow.build_log(workflow)
serialized = :erlang.term_to_binary(log)

# Store in database, file, etc...

# Later: rebuild from log
restored_log = :erlang.binary_to_term(serialized)
workflow = Workflow.from_log(restored_log)
```

> **Important**: Use `^variable` syntax for captured variables to survive serialization.

## Visualization

```elixir
# Mermaid diagram
Workflow.to_mermaid(workflow)

# DOT format (Graphviz)
Workflow.to_dot(workflow)

# Cytoscape JSON (for Kino.Cytoscape in Livebook)
Workflow.to_cytoscape(workflow)

# Edge list
Workflow.to_edgelist(workflow)
```

## Common Patterns

### Linear Pipeline

```elixir
Runic.workflow(
  steps: [
    {Runic.step(&parse/1, name: :parse),
     [{Runic.step(&validate/1, name: :validate),
       [Runic.step(&transform/1, name: :transform)]}]}
  ]
)
```

### Conditional Branching

```elixir
Runic.workflow(
  rules: [
    Runic.rule(fn x when x > 100 -> process_large(x) end),
    Runic.rule(fn x when x <= 100 -> process_small(x) end)
  ]
)
```

### Map-Reduce

```elixir
map_op = Runic.map(fn x -> x * 2 end, name: :double)
reduce_op = Runic.reduce(0, fn x, acc -> x + acc end, map: :double)

Workflow.new()
  |> Workflow.add(map_op)
  |> Workflow.add(reduce_op, to: :double)
```

### Fan-Out / Fan-In

```elixir
# Fan-out: one input -> multiple outputs
Runic.workflow(
  steps: [
    {Runic.step(&parse/1, name: :parse),
     [Runic.step(&extract_a/1, name: :a),
      Runic.step(&extract_b/1, name: :b),
      Runic.step(&extract_c/1, name: :c)]}
  ]
)

# Fan-in: join results (add step with list of parents)
Workflow.add(workflow, merge_step, to: [:a, :b, :c])
```

## Quick Reference Table

| Task | API |
|------|-----|
| Create step | `Runic.step(fn x -> ... end)` |
| Create rule | `Runic.rule(fn x when guard -> result end)` |
| Create workflow | `Runic.workflow(steps: [...], rules: [...])` |
| Add component | `Workflow.add(workflow, component, to: parent)` |
| Run one cycle | `Workflow.react(workflow, input)` |
| Run to completion | `Workflow.react_until_satisfied(workflow, input)` |
| Get results | `Workflow.raw_productions(workflow)` |
| Check if runnable | `Workflow.is_runnable?(workflow)` |
| Serialize | `Workflow.build_log(workflow)` |
| Deserialize | `Workflow.from_log(log)` |
| Visualize | `Workflow.to_mermaid(workflow)` |
| Set runtime context | `Workflow.put_run_context(workflow, %{name: %{key: val}})` |
| Validate context | `Workflow.validate_run_context(workflow, context)` |
| Context with default | `context(:key, default: "fallback")` |
| Create FSM | `Runic.fsm name: :name do ... end` |
| Create aggregate | `Runic.aggregate name: :name do ... end` |
| Create saga | `Runic.saga name: :name do ... end` |
| Create process manager | `Runic.process_manager name: :name do ... end` |
| Access sub-component | `Workflow.get_component(wf, {:name, :kind})` |
