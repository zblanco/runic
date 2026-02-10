# Runic Protocols

Runic uses three core protocols to enable extensibility and customization of workflow behavior:

1. **`Runic.Workflow.Invokable`** - Defines how nodes execute within a workflow
2. **`Runic.Component`** - Defines how components connect and compose together
3. **`Runic.Transmutable`** - Defines how data converts into workflows or components

Understanding these protocols enables you to:
- Create custom execution behavior for specialized node types
- Build new component types that integrate with existing workflows
- Convert domain-specific data structures into Runic workflows

---

## Runic.Workflow.Invokable

The `Invokable` protocol is the runtime heart of Runic. It defines how each node type (Step, Condition, Rule, etc.) executes within the context of a workflow.

### Three-Phase Execution Model

All workflow execution uses a three-phase model that enables parallel execution and external scheduler integration:

```
┌─────────────┐      ┌─────────────┐      ┌─────────────┐
│   PREPARE   │ ───► │   EXECUTE   │ ───► │    APPLY    │
│  (Phase 1)  │      │  (Phase 2)  │      │  (Phase 3)  │
└─────────────┘      └─────────────┘      └─────────────┘
      │                    │                    │
      ▼                    ▼                    ▼
 Extract context      Run work fn         Reduce results
 from workflow        in isolation         into workflow
 → %Runnable{}        (parallelizable)     (sequential)
```

1. **Prepare** (`prepare/3`) - Extract minimal context from workflow into a `%Runnable{}` struct
2. **Execute** (`execute/2`) - Run the node's work function in isolation (can be parallelized)
3. **Apply** - The `apply_fn` on the Runnable reduces results back into the workflow

### Protocol Functions

```elixir
defprotocol Runic.Workflow.Invokable do
  @spec match_or_execute(node :: struct()) :: :match | :execute
  def match_or_execute(node)

  @spec invoke(node :: struct(), workflow :: Workflow.t(), fact :: Fact.t()) :: Workflow.t()
  def invoke(node, workflow, fact)

  @spec prepare(node :: struct(), workflow :: Workflow.t(), fact :: Fact.t()) ::
          {:ok, Runnable.t()} | {:skip, reducer_fn} | {:defer, reducer_fn}
  def prepare(node, workflow, fact)

  @spec execute(node :: struct(), runnable :: Runnable.t()) :: Runnable.t()
  def execute(node, runnable)
end
```

### Function Descriptions

| Function | Purpose |
|----------|---------|
| `match_or_execute/1` | Declares whether this node is a `:match` (predicate/gate) or `:execute` (produces facts) node |
| `invoke/3` | Legacy high-level API that runs all three phases internally |
| `prepare/3` | Phase 1: Extracts context from workflow, returns `{:ok, %Runnable{}}`, `{:skip, fn}`, or `{:defer, fn}` |
| `execute/2` | Phase 2: Runs the work function using only Runnable context (no workflow access) |

### Built-in Implementations

Runic provides `Invokable` implementations for all core node types:

| Node Type | Match/Execute | Description |
|-----------|---------------|-------------|
| `Runic.Workflow.Root` | `:match` | Entry point for facts into the workflow |
| `Runic.Workflow.Condition` | `:match` | Boolean predicate check |
| `Runic.Workflow.Step` | `:execute` | Transform input fact to output fact |
| `Runic.Workflow.Conjunction` | `:match` | Logical AND of multiple conditions |
| `Runic.Workflow.MemoryAssertion` | `:match` | Check for facts in workflow memory |
| `Runic.Workflow.StateCondition` | `:match` | Check accumulator state |
| `Runic.Workflow.StateReaction` | `:execute` | Produce facts based on accumulator state |
| `Runic.Workflow.Accumulator` | `:execute` | Stateful reducer across invocations |
| `Runic.Workflow.Join` | `:execute` | Wait for multiple parent facts before firing |
| `Runic.Workflow.FanOut` | `:execute` | Spread enumerable into parallel branches |
| `Runic.Workflow.FanIn` | `:execute` | Collect parallel results back together |

### Implementing Custom Invokable

To create a custom node type, implement the protocol:

```elixir
defmodule MyApp.CustomNode do
  defstruct [:hash, :name, :work]
end

defimpl Runic.Workflow.Invokable, for: MyApp.CustomNode do
  alias Runic.Workflow
  alias Runic.Workflow.{Fact, Runnable, CausalContext}

  def match_or_execute(_node), do: :execute

  def invoke(%MyApp.CustomNode{} = node, workflow, fact) do
    # Execute the work and produce a result
    result = node.work.(fact.value)
    result_fact = Fact.new(value: result, ancestry: {node.hash, fact.hash})

    workflow
    |> Workflow.log_fact(result_fact)
    |> Workflow.draw_connection(node, result_fact, :produced)
    |> Workflow.mark_runnable_as_ran(node, fact)
    |> Workflow.prepare_next_runnables(node, result_fact)
  end

  def prepare(%MyApp.CustomNode{} = node, workflow, fact) do
    context = CausalContext.new(
      node_hash: node.hash,
      input_fact: fact,
      ancestry_depth: Workflow.ancestry_depth(workflow, fact)
    )

    {:ok, Runnable.new(node, fact, context)}
  end

  def execute(%MyApp.CustomNode{} = node, %Runnable{input_fact: fact} = runnable) do
    result = node.work.(fact.value)
    result_fact = Fact.new(value: result, ancestry: {node.hash, fact.hash})

    apply_fn = fn workflow ->
      workflow
      |> Workflow.log_fact(result_fact)
      |> Workflow.draw_connection(node, result_fact, :produced)
      |> Workflow.mark_runnable_as_ran(node, fact)
      |> Workflow.prepare_next_runnables(node, result_fact)
    end

    Runnable.complete(runnable, result_fact, apply_fn)
  end
end
```

### External Scheduler Integration

The three-phase model enables integration with custom schedulers, worker pools, or distributed systems:

```elixir
# Phase 1: Prepare runnables for dispatch
workflow = Workflow.plan_eagerly(workflow, input)
{workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

# Phase 2: Execute (dispatch to worker pool, external service, etc.)
executed = Task.async_stream(runnables, fn runnable ->
  Runic.Workflow.Invokable.execute(runnable.node, runnable)
end, timeout: :infinity)

# Phase 3: Apply results back to workflow
workflow = Enum.reduce(executed, workflow, fn {:ok, runnable}, wrk ->
  Workflow.apply_runnable(wrk, runnable)
end)

# Continue if more work is available
if Workflow.is_runnable?(workflow), do: # repeat...
```

---

## Runic.Component

The `Component` protocol defines how Runic components can be composed together and connected within workflows. It provides introspection capabilities and connection semantics for workflow composition.

### Protocol Functions

```elixir
defprotocol Runic.Component do
  @spec components(component) :: keyword()
  def components(component)

  @spec connectables(component, other_component) :: keyword()
  def connectables(component, other_component)

  @spec connectable?(component, other_component) :: boolean()
  def connectable?(component, other_component)

  @spec connect(component, to :: term(), workflow :: Workflow.t()) :: Workflow.t()
  def connect(component, to, workflow)

  @spec source(component) :: Macro.t()
  def source(component)

  @spec hash(component) :: integer()
  def hash(component)

  @spec inputs(component) :: keyword()
  def inputs(component)

  @spec outputs(component) :: keyword()
  def outputs(component)
end
```

### Function Descriptions

| Function | Purpose |
|----------|---------|
| `components/1` | List all connectable sub-components of a component |
| `connectables/2` | List compatible sub-components with another component |
| `connectable?/2` | Check if a component can be connected to another |
| `connect/3` | Connect this component to a parent in a workflow |
| `source/1` | Returns the source AST for building/serializing the component |
| `hash/1` | Returns the content-addressable hash of the component |
| `inputs/1` | Returns the nimble_options schema for component inputs |
| `outputs/1` | Returns the nimble_options schema for component outputs |

### Built-in Implementations

| Component Type | Description |
|----------------|-------------|
| `Runic.Workflow.Step` | Single transformation function |
| `Runic.Workflow.Rule` | Conditional logic with condition and reaction |
| `Runic.Workflow.Map` | Fan-out transformation over enumerables |
| `Runic.Workflow.Reduce` | Fan-in aggregation |
| `Runic.Workflow.Accumulator` | Stateful reducer across invocations |
| `Runic.Workflow.StateMachine` | Stateful reducer with reactive conditions |
| `Runic.Workflow` | Workflows themselves are components |
| `Tuple` | Pipeline syntax `{parent, [children]}` |

### Type Compatibility

The `Component` protocol includes type compatibility checking via an internal `TypeCompatibility` helper module. This enables schema-based validation when connecting components:

```elixir
# Type compatibility checks
TypeCompatibility.types_compatible?(:any, :integer)  # => true
TypeCompatibility.types_compatible?(:string, :integer)  # => false
TypeCompatibility.types_compatible?({:list, :integer}, {:list, :any})  # => true

# Schema compatibility for connecting components
producer_outputs = [step: [type: {:list, :integer}]]
consumer_inputs = [step: [type: {:list, :any}]]
TypeCompatibility.schemas_compatible?(producer_outputs, consumer_inputs)  # => true
```

### Using Component Protocol

```elixir
require Runic

step = Runic.step(fn x -> x * 2 end, name: :double)
rule = Runic.rule(fn x when x > 10 -> :large end, name: :classify)

# Introspection
Runic.Component.hash(step)  # => 1234567890
Runic.Component.source(step)  # => AST representation
Runic.Component.components(step)  # => [step: step]

# Compatibility checking
Runic.Component.connectable?(step, rule)  # => true

# Connection (typically done via Workflow.add/3)
workflow = Runic.Workflow.new()
  |> Runic.Workflow.add(step)
  |> Runic.Workflow.add(rule, to: :double)
```

### Implementing Custom Component

```elixir
defmodule MyApp.CustomComponent do
  defstruct [:hash, :name, :config]

  def new(opts) do
    %__MODULE__{
      name: Keyword.fetch!(opts, :name),
      config: Keyword.get(opts, :config, %{}),
      hash: :erlang.phash2(opts)
    }
  end
end

defimpl Runic.Component, for: MyApp.CustomComponent do
  alias Runic.Workflow

  def components(component) do
    [{component.name, component}]
  end

  def connectables(component, _other) do
    components(component)
  end

  def connectable?(_component, _other), do: true

  def connect(component, to, workflow) do
    # Add internal nodes to workflow, connected to 'to'
    workflow
    |> Workflow.add_step(to, some_internal_step(component))
    |> Workflow.register_component(component)
  end

  def source(component) do
    quote do
      MyApp.CustomComponent.new(
        name: unquote(component.name),
        config: unquote(Macro.escape(component.config))
      )
    end
  end

  def hash(component), do: component.hash

  def inputs(_component) do
    [custom: [type: :any, doc: "Input value"]]
  end

  def outputs(_component) do
    [custom: [type: :any, doc: "Output value"]]
  end

  defp some_internal_step(component) do
    Runic.Workflow.Step.new(
      work: fn x -> transform(x, component.config) end,
      name: :"#{component.name}_step"
    )
  end
end
```

---

## Runic.Transmutable

The `Transmutable` protocol defines how data structures can be converted into Runic workflows or components. This enables natural integration of domain-specific data and easy workflow construction from functions.

### Protocol Functions

```elixir
defprotocol Runic.Transmutable do
  @fallback_to_any true

  @spec transmute(component) :: Workflow.t()
  def transmute(component)  # Deprecated: use to_workflow/1

  @spec to_workflow(component) :: Workflow.t()
  def to_workflow(component)

  @spec to_component(component) :: struct()
  def to_component(component)
end
```

### Function Descriptions

| Function | Purpose |
|----------|---------|
| `transmute/1` | *Deprecated* - use `to_workflow/1` instead |
| `to_workflow/1` | Converts data to a `%Runic.Workflow{}` |
| `to_component/1` | Converts data to a Runic component (Step, Rule, etc.) |

### Built-in Implementations

| Type | `to_workflow/1` Behavior | `to_component/1` Behavior |
|------|-------------------------|--------------------------|
| `Runic.Workflow` | Returns itself | Extracts first component or raises |
| `Runic.Workflow.Rule` | Wraps rule in workflow with components | Returns the rule |
| `Runic.Workflow.Step` | Wraps step in workflow | Returns the step |
| `Runic.Workflow.StateMachine` | Wraps FSM in workflow with components | Returns the FSM |
| `Function` | Creates workflow with function as step | Creates a Step wrapping the function |
| `List` | Merges transmuted elements into one workflow | Recursively converts elements |
| `Tuple` (AST) | Creates Rule from quoted anonymous function | Creates Rule from AST |
| `Any` | Creates workflow with constant-producing step | Creates Step returning the value |

### Usage Examples

```elixir
require Runic
alias Runic.Transmutable

# Convert a function to workflow
fn_workflow = Transmutable.to_workflow(fn x -> x * 2 end)

# Convert a rule to workflow
rule = Runic.rule(fn x when x > 0 -> :positive end)
rule_workflow = Transmutable.to_workflow(rule)

# Convert a list of components to merged workflow
components = [
  Runic.step(fn x -> x + 1 end),
  Runic.step(fn x -> x * 2 end)
]
merged_workflow = Transmutable.to_workflow(components)

# Convert arbitrary data to a component
data_step = Transmutable.to_component(%{type: :custom, value: 42})
# => %Step{work: fn _anything -> %{type: :custom, value: 42} end}

# Use transmute/1 macro for convenient conversion
workflow = Runic.transmute(fn x -> x * 2 end)
```

### The `Runic.transmute/1` Macro

The `Runic.transmute/1` macro provides a convenient wrapper around the `Transmutable` protocol:

```elixir
require Runic

# Convert any transmutable to a workflow
workflow = Runic.transmute(fn x -> x + 1 end)

# Equivalent to:
workflow = Runic.Transmutable.to_workflow(fn x -> x + 1 end)
```

### Implementing Custom Transmutable

```elixir
defmodule MyApp.DataProcessor do
  defstruct [:name, :transform_fn, :validate_fn]
end

defimpl Runic.Transmutable, for: MyApp.DataProcessor do
  alias Runic.Workflow

  def transmute(processor), do: to_workflow(processor)

  def to_workflow(%MyApp.DataProcessor{} = processor) do
    validate_step = Runic.Workflow.Step.new(
      work: processor.validate_fn,
      name: :"#{processor.name}_validate"
    )

    transform_step = Runic.Workflow.Step.new(
      work: processor.transform_fn,
      name: :"#{processor.name}_transform"
    )

    Workflow.new(name: processor.name)
    |> Workflow.add_step(validate_step)
    |> Workflow.add_step(validate_step, transform_step)
    |> Map.put(:components, %{processor.name => processor})
  end

  def to_component(%MyApp.DataProcessor{} = processor) do
    # Return a representative step for this processor
    Runic.Workflow.Step.new(
      work: fn input ->
        if processor.validate_fn.(input) do
          processor.transform_fn.(input)
        else
          {:error, :validation_failed}
        end
      end,
      name: processor.name
    )
  end
end
```

### Integration with Workflow.merge/2

The `Transmutable` protocol integrates with `Workflow.merge/2` to allow merging any transmutable into a workflow:

```elixir
workflow = Runic.Workflow.new()

# Merge a rule (transmuted to workflow first)
rule = Runic.rule(fn x when x > 0 -> :positive end)
workflow = Workflow.merge(workflow, rule)

# Merge a function directly
workflow = Workflow.merge(workflow, fn x -> x * 2 end)

# Merge a list of components
workflow = Workflow.merge(workflow, [
  Runic.step(fn x -> x + 1 end),
  Runic.step(fn x -> x - 1 end)
])
```

---

## Protocol Summary

| Protocol | Purpose | Key Use Case |
|----------|---------|--------------|
| `Invokable` | Runtime execution | Custom node types, external schedulers |
| `Component` | Composition & introspection | Custom components, schema validation |
| `Transmutable` | Data conversion | Domain integration, DSL building |

### When to Implement Each Protocol

- **Implement `Invokable`** when you need a new node type with custom execution semantics (e.g., async I/O, retries, timeouts, external service calls)

- **Implement `Component`** when you need a new composite component that bundles multiple nodes together (e.g., a validation pipeline, a saga pattern)

- **Implement `Transmutable`** when you want to convert domain-specific data structures into workflows (e.g., YAML configs, database records, external DSLs)

---

## See Also

- [Cheatsheet](cheatsheet.html) - Quick reference for all core APIs
- [Usage Rules](usage-rules.html) - Core concepts, when to use, do's/don'ts
- `Runic.Workflow` module docs - Three-phase execution model in detail
