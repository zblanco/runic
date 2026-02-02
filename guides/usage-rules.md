# Runic Usage Rules

Guidelines for when and how to use Runic effectively.

## Core Concepts

### What is Runic?

Runic is a **purely functional workflow composition tool** for building:

- **Dataflow parallel pipelines** - DAG-based execution with automatic dependency resolution
- **Rule-based expert systems** - Forward-chaining conditional logic
- **Low-code workflow engines** - Runtime-modifiable workflow definitions

Runic workflows are **data structures** (decorated directed acyclic graphs) that can be composed, serialized, and executed lazily across any process topology.

### Key Design Principles

1. **Lazy evaluation** - Components only execute when their inputs are satisfied
2. **Process-agnostic** - No assumed runtime topology; integrate with GenServer, GenStage, Flow, etc.
3. **Content-addressable** - Components are hashed for deduplication and caching
4. **Serializable** - Workflows can be persisted and recovered via `build_log`/`from_log`

## When to Use Runic

### ✅ Good Use Cases

| Scenario | Why Runic Helps |
|----------|-----------------|
| **User-defined workflows** | Runtime modification of logic that can't be compiled ahead of time |
| **Expert systems** | Forward-chaining rule evaluation with pattern matching |
| **Complex data pipelines** | DAG-based execution with automatic parallelization |
| **Workflow persistence** | Serialize workflow state, pause/resume execution |
| **Low-code platforms** | Users define logic via UI that becomes Runic workflows |
| **Dynamic ETL** | Runtime-composed transformation pipelines |

### ❌ When NOT to Use Runic

| Scenario | Better Alternative |
|----------|-------------------|
| **Static, known-at-compile-time logic** | Plain compiled Elixir functions and pattern matching will be faster|
| **Simple linear pipelines** | Elixir's `|>` operator |
| **High-performance hot paths** | Compiled Elixir code (Runic has runtime overhead) |
| **Simple async tasks** | `Task.async/await` or `Task.async_stream` |
| **Message passing** | GenServer, GenStage, Broadway |

> **Rule of thumb**: If your workflow structure is known at compile time, doesn't need parallel dataflow execution, and won't change, use vanilla Elixir. Runic adds value when workflows are built or modified at runtime and dataflow parallelism is inherent.

## API Selection Guide

### Which Component to Use?

| Need | Component | Example |
|------|-----------|---------|
| Transform input to output | `Runic.step/1` | `Runic.step(fn x -> x * 2 end)` |
| Conditional logic with guards | `Runic.rule/1` | `Runic.rule(fn x when x > 0 -> :positive end)` |
| Stateful transitions | `Runic.state_machine/1` | Counter, lock/unlock, FSM |
| Running total/counter | `Runic.accumulator/3` | `Runic.accumulator(0, fn x, acc -> acc + x end)` |
| Transform each element | `Runic.map/1` | `Runic.map(fn x -> x * 2 end)` |
| Aggregate collection | `Runic.reduce/3` | `Runic.reduce(0, fn x, acc -> x + acc end)` |

### Which Evaluation API to Use?

| Scenario | API | Notes |
|----------|-----|-------|
| **REPL/Testing/Scripts** | `react_until_satisfied/2` | Runs to completion; simple but blocks |
| **Evaluating LHS of rules / match phase** | `plan_eagerly/2` | Eagerly evaluates conditions against an input
| **Production with simple needs** | `react/2` in a loop | More control over iterations |
| **Custom scheduler/GenServer** | Three-phase APIs | Full control over dispatch |
| **Parallel I/O-bound work** | `async: true` option | Uses `Task.async_stream` |
| **Distributed execution** | `prepare_for_dispatch/1` | Extract runnables for remote execution |

### Three-Phase Execution APIs

For custom schedulers, GenServers, or distributed execution:

```elixir
# Phase 1: Planning - Match rules, prepare agenda
workflow = Workflow.plan_eagerly(workflow, input)
{workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

# Phase 2: Execution - Can be parallelized/distributed
executed = Enum.map(runnables, fn runnable ->
  Invokable.execute(runnable.node, runnable)
end)

# Phase 3: Application - Reduce results back
workflow = Enum.reduce(executed, workflow, &Workflow.apply_runnable(&2, &1))
```

## Do's and Don'ts

### ✅ Always Do

1. **Always `require Runic`** before using macros:
   ```elixir
   require Runic
   ```

2. **Use `^variable` syntax** to capture runtime values for serialization:
   ```elixir
   # ✅ Correct - survives serialization
   multiplier = 3
   Runic.step(fn x -> x * ^multiplier end)
   
   # ❌ Wrong - fails after serialization
   Runic.step(fn x -> x * multiplier end)
   ```

3. **Name your components** for debugging, hooks, and referencing:
   ```elixir
   Runic.step(fn x -> x * 2 end, name: :double)
   ```

4. **Use `raw_productions/1`** or similar apis to extract results, not direct graph access:
   ```elixir
   Workflow.raw_productions(workflow)
   ```

5. **Check `is_runnable?/1`** before calling `react/2` in loops:
   ```elixir
   if Workflow.is_runnable?(workflow) do
     Workflow.react(workflow)
   end
   ```

6. **Use `plan_eagerly/2`** before `react_until_satisfied/1` when passing input with rules:
   ```elixir
   # ✅ Correct for workflows with rules
   workflow
   |> Workflow.plan_eagerly(input)
   |> Workflow.react_until_satisfied()
   
   # Also works (plan_eagerly is called internally):
   Workflow.react_until_satisfied(workflow, input)
   ```

### ❌ Never Do

1. **Never use `else if` or `elsif`** - Elixir doesn't support this syntax:
   ```elixir
   # ❌ Invalid Elixir
   if condition1 do
     ...
   else if condition2 do  # WRONG
     ...
   end
   
   # ✅ Use cond instead
   cond do
     condition1 -> ...
     condition2 -> ...
     true -> ...
   end
   ```

2. **Never assume list index access** works with `[]`:
   ```elixir
   # ❌ Invalid - lists don't support Access
   mylist[0]
   
   # ✅ Use Enum.at/2
   Enum.at(mylist, 0)
   ```

3. **Never modify workflow state directly** - use the APIs:
   ```elixir
   # ❌ Don't do this
   workflow.graph = modified_graph
   
   # ✅ Use APIs
   Workflow.add(workflow, component)
   ```

4. **Never create infinite loops** with `react_until_satisfied/2`:
   ```elixir
   # ❌ Danger - hooks that add steps infinitely
   Runic.workflow(
     after_hooks: %{:some_step => fn step, workflow, fact ->
       Workflow.add(workflow, another_step)  # Infinite!
     end}
   )
   ```

5. **Never use unpinned variables** in components that will be serialized:
   ```elixir
   # ❌ Will fail after build_log/from_log round-trip
   config = load_config()
   Runic.step(fn x -> x * config.multiplier end)
   
   # ✅ Pin the variable
   Runic.step(fn x -> x * ^config.multiplier end)
   ```

6. **Never use `String.to_atom/1`** on user input - memory leak risk:
   ```elixir
   # ❌ Atoms are never garbage collected
   Runic.step(fn x -> x end, name: String.to_atom(user_input))
   
   # ✅ Use strings for dynamic names
   Runic.step(fn x -> x end, name: user_input)
   ```

## Workflow Construction Patterns

### Prefer: Declarative `workflow/1` Macro

For static structures known at definition time:

```elixir
workflow = Runic.workflow(
  name: :text_processor,
  steps: [
    {Runic.step(&tokenize/1, name: :tokenize),
     [Runic.step(&count_words/1, name: :count),
      Runic.step(&first_word/1, name: :first)]}
  ]
)
```

### Prefer: Imperative `add/3` for Dynamic Construction

For runtime-built workflows:

```elixir
workflow = Workflow.new(name: :dynamic)
  |> Workflow.add(Runic.step(&step_a/1, name: :a))
  |> Workflow.add(Runic.step(&step_b/1, name: :b), to: :a)

# Conditionally add components
workflow = if needs_validation? do
  Workflow.add(workflow, Runic.step(&validate/1, name: :validate), to: :b)
else
  workflow
end
```

### Map-Reduce Pattern

```elixir
# Define map and reduce with linked names
map_op = Runic.map(fn x -> expensive_transform(x) end, name: :transform)
reduce_op = Runic.reduce([], fn x, acc -> [x | acc] end, name: :collect, map: :transform)

# Add reduce as child of map
workflow = Workflow.new()
  |> Workflow.add(map_op)
  |> Workflow.add(reduce_op, to: :transform)

# Execute - map runs lazily, reduce waits for all elements
workflow
|> Workflow.plan_eagerly([1, 2, 3, 4, 5])
|> Workflow.react_until_satisfied()
|> Workflow.raw_productions(:collect)
```

## Performance Considerations

### Runic Adds Runtime Overhead

Runic workflows are essentially a **dataflow virtual machine** running within Elixir:

- Graph traversal and fact matching on each cycle
- Hash computation for content-addressability
- Closure evaluation for serialization support

For hot paths where performance is critical, consider:

1. **Compile static parts** - Move invariant logic to regular Elixir functions
2. **Batch inputs** - Process collections rather than individual items
3. **Use async mode** - Parallelize I/O-bound work with `async: true`
4. **Profile with Benchee** - Measure actual overhead in your use case

### When Parallel Execution Helps

```elixir
# ✅ Good for parallel: I/O-bound independent operations
workflow = Runic.workflow(
  steps: [
    {Runic.step(&parse/1),
     [Runic.step(&fetch_from_api_a/1),
      Runic.step(&fetch_from_api_b/1),
      Runic.step(&fetch_from_api_c/1)]}
  ]
)
Workflow.react_until_satisfied(workflow, input, async: true)

# ❌ No benefit: CPU-bound sequential work
# Just use regular Elixir functions instead
```

## Integration Patterns

### GenServer Scheduler

```elixir
defmodule MyApp.WorkflowRunner do
  use GenServer
  alias Runic.Workflow

  def init(workflow) do
    {:ok, %{workflow: workflow}}
  end

  def handle_cast({:process, input}, state) do
    workflow = state.workflow
      |> Workflow.plan_eagerly(input)
      |> Workflow.react_until_satisfied()
    
    results = Workflow.raw_productions(workflow)
    # Handle results...
    
    {:noreply, %{state | workflow: workflow}}
  end
end
```

### Persistence Pattern

```elixir
# Save workflow state
def save_workflow(workflow, id) do
  log = Workflow.build_log(workflow)
  serialized = :erlang.term_to_binary(log)
  MyRepo.insert(%WorkflowState{id: id, data: serialized})
end

# Restore workflow state
def load_workflow(id) do
  case MyRepo.get(WorkflowState, id) do
    nil -> Workflow.new()
    %{data: serialized} ->
      log = :erlang.binary_to_term(serialized)
      Workflow.from_log(log)
  end
end
```

## Debugging Tips

1. **Visualize with Mermaid**:
   ```elixir
   workflow |> Workflow.to_mermaid() |> IO.puts()
   ```

2. **Inspect facts for tracing**:
   ```elixir
   Workflow.facts(workflow)
   |> Enum.map(fn fact -> {fact.value, fact.ancestry} end)
   ```

3. **Use named components**:
   ```elixir
   Workflow.raw_productions(workflow, :specific_step)
   ```

4. **Add debug hooks**:
   ```elixir
   Runic.workflow(
     after_hooks: %{
       :suspicious_step => fn step, workflow, fact ->
         IO.inspect({step.name, fact.value}, label: "DEBUG")
         workflow
       end
     }
   )
   ```

## Summary

| Principle | Guidance |
|-----------|----------|
| **Use Runic when** | Workflows are built/modified at runtime |
| **Don't use when** | Logic is static and compile-time |
| **Always require** | `require Runic` before macros |
| **Always pin** | `^variable` for runtime values |
| **Always name** | Components for debugging |
| **Extract with** | `raw_productions/1`, not graph access |
| **Serialize with** | `build_log/1` and `from_log/1` |
| **Parallelize with** | `async: true` for I/O-bound work |
