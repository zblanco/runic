# Workflow Output Extraction: Port-Driven Results API

**Status:** Conceptual  
**References:** [Port Contracts Implementation Plan](port-contracts-implementation-plan.md)  
**Goal:** Design a single, ergonomic API for extracting structured results from workflow execution, leveraging output port contracts as the default extraction shape.

---

## The Problem

Today, getting results out of a workflow is manual and noisy:

```elixir
workflow =
  Runic.workflow(
    name: :order_pipeline,
    steps: [
      {Runic.step(&parse_order/1, name: :parse),
       [Runic.step(&calculate_total/1, name: :total),
        Runic.step(&validate_stock/1, name: :stock)]}
    ]
  )

workflow = Workflow.react_until_satisfied(workflow, order)

# Now what? The user must know the extraction API vocabulary:
total = Workflow.raw_productions(workflow, :total) |> List.first()
stock = Workflow.raw_productions(workflow, :stock) |> List.first()
```

This has several friction points:

1. **The user must name-chase.** They need to know internal component names to extract results. This is the same "internal topology leaks" problem that port contracts solved for connection semantics — but now on the output side.

2. **Boilerplate per-extraction.** Every consumer of the workflow writes `raw_productions(wf, :name) |> List.first()` or similar. This is ceremony that obscures intent.

3. **No single "result shape" concept.** There's no standard answer to "what does this workflow produce?" The output port contract system gives us that answer — but the execution API doesn't use it yet.

4. **The workflow struct carries everything.** `react_until_satisfied/3` returns the full workflow struct. For simple call-and-get-result usage, the user doesn't want a workflow — they want the answer.

---

## Design Principles

Following the philosophy of minimal need-to-knows for maximum utility:

1. **One concept, not many.** The user already knows output ports exist. The extraction API should be "get me what the output ports say" — not a new concept to learn.

2. **Zero-config for the common case.** If a workflow has output ports, results should be extractable without naming components.

3. **Progressive disclosure.** Simple workflows → simple results. Complex workflows → structured results. Expert users → full control.

4. **Don't break the return type.** `react_until_satisfied` currently returns `%Workflow{}`. Changing that is a breaking API change. Instead, offer an opt-in that returns `{workflow, outputs}` or provide a separate extraction function that's trivially composable.

---

## Option Analysis

### Option A: `Workflow.outputs/1` extraction function

Add a single function that reads the workflow's output port contract and extracts the matching productions:

```elixir
# After execution
workflow = Workflow.react_until_satisfied(workflow, order)

# Extract using output port contract
%{total: 42.50, stock: :in_stock} = Workflow.outputs(workflow)
```

**How it works:**
- Reads `workflow.output_ports` for the declared output shape
- For each port with a `:from` binding, calls `raw_productions(workflow, from_component)`
- For ports without `:from`, uses the port name as the component name
- Single-value ports unwrap `List.first()` automatically; `:many` cardinality ports return the list
- Returns a map keyed by port name

**Without output ports declared:**
- Falls back to `raw_productions_by_component(workflow)` — same behavior as today but behind a consistent API

**Pros:**
- Single new function, trivially discoverable
- Uses output ports as the default extraction shape — connects the contract system to runtime utility
- Non-breaking — additive API
- Works identically whether called on the `Workflow` struct or as a Runner result

**Cons:**
- Name collision risk: `Workflow.outputs/1` could be confused with `Component.outputs/1` (which returns the port contract, not produced values). Possible alternative names: `results/1`, `output_values/1`, `collect_outputs/1`

### Option B: `:return` option on `react_until_satisfied`

```elixir
# Default behavior — returns workflow
workflow = Workflow.react_until_satisfied(workflow, order)

# Opt-in structured results
{workflow, %{total: 42.50}} =
  Workflow.react_until_satisfied(workflow, order, return: :outputs)
```

**Pros:**
- Single call to run and extract
- Explicit opt-in, no surprise return type changes
- Natural place for the option since the user is already passing opts

**Cons:**
- Changes the return type shape conditionally — `react |> react_until_satisfied` pipelines would break if `:return` is passed, since downstream expects a `%Workflow{}`
- Mixes execution concerns with extraction concerns

### Option C: `Workflow.collect/2` with explicit selectors

```elixir
# Collect specific component outputs
%{total: 42.50} = Workflow.collect(workflow, [:total])

# Collect using output port contract (default when no selectors given)
%{total: 42.50, stock: :in_stock} = Workflow.collect(workflow)

# Collect with full facts (not just values)
%{total: [%Fact{value: 42.50, ...}]} = Workflow.collect(workflow, [:total], raw: false)
```

**Pros:**
- Clear name that implies "gather results"
- Supports both port-driven defaults and explicit component selection
- Extensible via options

**Cons:**
- Yet another extraction function alongside `productions`, `raw_productions`, `reactions`, etc.

### Recommendation: Option A as primary, with Option C's flexibility

The cleanest interface is a single `Workflow.results/1,2` function (using `results` to avoid confusion with `Component.outputs`):

```elixir
# Uses output_ports contract to determine shape
%{total: 42.50, stock: :in_stock} = Workflow.results(workflow)

# Explicit component selection (overrides output_ports)
%{total: 42.50} = Workflow.results(workflow, [:total])

# Returns full Fact structs
%{total: %Fact{value: 42.50}} = Workflow.results(workflow, [:total], facts: true)
```

The function name `results` communicates intent unambiguously and doesn't collide with any existing API.

---

## Proposed API

### `Workflow.results/1`

Extract results using the workflow's output port contract:

```elixir
@spec results(t()) :: map()
def results(%__MODULE__{output_ports: ports} = workflow) when is_list(ports) do
  Map.new(ports, fn {port_name, port_opts} ->
    component_name = Keyword.get(port_opts, :from, port_name)
    cardinality = Keyword.get(port_opts, :cardinality, :one)
    values = raw_productions(workflow, component_name)

    case cardinality do
      :one -> {port_name, List.last(values)}
      :many -> {port_name, values}
    end
  end)
end

# Fallback when no output ports are declared
def results(%__MODULE__{} = workflow) do
  raw_productions_by_component(workflow)
end
```

### `Workflow.results/2`

Extract results for specific component names:

```elixir
@spec results(t(), list(atom() | binary())) :: map()
def results(%__MODULE__{} = workflow, component_names) when is_list(component_names) do
  Map.new(component_names, fn name ->
    values = raw_productions(workflow, name)
    {name, List.last(values)}
  end)
end
```

### `Workflow.results/3`

Full control with options:

```elixir
@spec results(t(), list(atom() | binary()) | nil, keyword()) :: map()
def results(workflow, component_names \\ nil, opts \\ [])

# opts:
#   facts: true  — return %Fact{} structs instead of raw values
#   cardinality: :many  — return all values as lists (override per-port cardinality)
```

---

## Extraction Semantics: Which Value?

For ports with cardinality `:one`, multiple executions may produce multiple facts from the same component. The extraction must choose which value represents "the output":

| Strategy | Behavior | When |
|----------|----------|------|
| **Last produced** | `List.last(productions)` | Default — matches imperative intuition. Stateful components (Accumulator, StateMachine) naturally produce the final state last |
| **First produced** | `List.first(productions)` | Rarely useful |
| **All** | Full list | When `cardinality: :many` |

**Stateful components** (Accumulator, StateMachine, Aggregate, FSM) produce a new state fact on every reaction cycle. The last produced value is the final state — exactly what a caller wants. This makes `List.last/1` the right default.

For **stateless pipelines** (Step chains), there's typically one production per component per input. `List.last/1` and `List.first/1` are equivalent.

---

## Runner Integration

The Runner's `get_results/2` currently returns `raw_productions/1` — a flat list of all produced values. This should evolve to use `Workflow.results/1`:

### Current

```elixir
# Runner.Worker handle_call
def handle_call(:get_results, _from, state) do
  {:reply, {:ok, Workflow.raw_productions(state.workflow)}, state}
end

# Runner public API
def get_results(runner, workflow_id) do
  case lookup(runner, workflow_id) do
    nil -> {:error, :not_found}
    pid -> GenServer.call(pid, :get_results)
  end
end
```

### Proposed

```elixir
# Worker now delegates to Workflow.results
def handle_call(:get_results, _from, state) do
  {:reply, {:ok, Workflow.results(state.workflow)}, state}
end

# Explicit component selection
def handle_call({:get_results, component_names}, _from, state) do
  {:reply, {:ok, Workflow.results(state.workflow, component_names)}, state}
end
```

The Runner public API gains the same shape:

```elixir
# Default: use output ports
{:ok, %{total: 42.50}} = Runner.get_results(runner, workflow_id)

# Explicit selection
{:ok, %{total: 42.50}} = Runner.get_results(runner, workflow_id, [:total])
```

This is a behavior change for `get_results` — the return value changes from `{:ok, [values]}` to `{:ok, %{port_name => value}}` when output ports are declared. For workflows without output ports, the fallback to `raw_productions_by_component` returns a map keyed by component name — which is already a map, just more informative than a flat list.

**Migration consideration:** This is a breaking change to `get_results`. Since Runic is pre-alpha, this is acceptable. The old behavior is recoverable via `get_workflow` + `raw_productions`.

### `on_complete` callback

The Worker's `on_complete` callback currently receives `workflow_id`. It could also receive extracted results:

```elixir
# Current
on_complete: fn workflow_id -> ... end

# Proposed — results included
on_complete: fn workflow_id, results -> ... end
```

This eliminates a `get_results` round-trip in the common pattern where `on_complete` needs to forward results to another system.

---

## Interaction with Fact Metadata

Phase 4 added `meta` to Facts. When output ports have typed schemas, the extraction layer could optionally validate that produced values match declared port types:

```elixir
# Strict mode — raises if produced value doesn't match port type
Workflow.results(workflow, strict: true)
```

This is deferred. The metadata is there for future use, but runtime type checking adds overhead and complexity. The port contracts are primarily a build-time and introspection concern.

---

## Usage Patterns

### Simple workflow — zero config needed

```elixir
workflow = Runic.workflow(
  name: :doubler,
  steps: [Runic.step(fn x -> x * 2 end, name: :double)],
  output_ports: [result: [type: :integer, from: :double]]
)

%{result: 10} =
  workflow
  |> Workflow.react_until_satisfied(5)
  |> Workflow.results()
```

### Multi-output workflow

```elixir
workflow = Runic.workflow(
  name: :order_pipeline,
  steps: [
    {Runic.step(&parse/1, name: :parse),
     [Runic.step(&price/1, name: :price),
      Runic.step(&validate/1, name: :validate)]}
  ],
  output_ports: [
    total: [type: :float, from: :price],
    valid: [type: :boolean, from: :validate]
  ]
)

%{total: 42.50, valid: true} =
  workflow
  |> Workflow.react_until_satisfied(order)
  |> Workflow.results()
```

### Ad-hoc extraction (no output ports declared)

```elixir
workflow = Runic.workflow(
  name: :ad_hoc,
  steps: [
    Runic.step(fn x -> x + 1 end, name: :add),
    Runic.step(fn x -> x * 2 end, name: :mult)
  ]
)

# Extract specific components by name
%{add: 6, mult: 10} =
  workflow
  |> Workflow.react_until_satisfied(5)
  |> Workflow.results([:add, :mult])
```

### Runner integration

```elixir
{:ok, _} = Runner.start_workflow(runner, :order_pipeline, workflow)
Runner.run(runner, :order_pipeline, order)

# Later...
{:ok, %{total: 42.50, valid: true}} = Runner.get_results(runner, :order_pipeline)
```

### Pipe-friendly composition

```elixir
# results/1 is the terminal operation in a pipeline
order
|> then(&Workflow.react_until_satisfied(workflow, &1))
|> Workflow.results()
|> Map.fetch!(:total)
```

---

## What This Enables

1. **Canvas UIs** can show output port values in real-time without knowing component internals.

2. **Agent orchestration** can compose workflows as black-box functions: "call this workflow with this input, get these named outputs."

3. **Testing** becomes declarative:
   ```elixir
   assert %{total: total} = Workflow.results(workflow)
   assert total > 0
   ```

4. **Workflow-of-workflows** composition gets a clean data-passing interface — the outer workflow can route inner workflow results by port name.

5. **The Runner** gets a structured result API that scales from simple "give me the answer" to fine-grained component selection.

---

## Implementation Scope

**Core (small, high-value):**
- `Workflow.results/1` — port-driven extraction (~20 lines)
- `Workflow.results/2` — explicit component selection (~10 lines)
- Update `Runner.Worker` `get_results` to use `Workflow.results/1`
- Update `Runner.get_results/2,3` public API

**Deferred:**
- `results/3` with options (`:facts`, `:strict`, `:cardinality` override)
- `on_complete` callback signature change
- Runtime type validation against port contracts
- Streaming/incremental result extraction for long-running workflows

---

## Trade-offs

| Decision | Chosen | Alternative | Rationale |
|----------|--------|-------------|-----------|
| Function name | `results` | `outputs`, `collect` | Avoids collision with `Component.outputs/1`; clear intent |
| Default extraction shape | Output ports | All productions | Ports are the public contract; this is the point |
| Value selection | `List.last/1` | `List.first/1`, all | Matches stateful component semantics (final state) |
| No-ports fallback | `raw_productions_by_component` | Empty map, raise | Graceful degradation; gradual typing philosophy |
| Runner breaking change | Accept it | Wrapper function | Pre-alpha; cleaner long-term API |
| Return type on `react_until_satisfied` | Keep `%Workflow{}` | `{workflow, results}` | Don't break pipeline composition |
