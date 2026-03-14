# Workflow Results API: Implementation Plan

**Status:** Draft  
**References:** [Output Extraction Concept](workflow-output-extraction.md), [Port Contracts Plan](port-contracts-implementation-plan.md)  
**Goal:** Implement `Workflow.results/1,2,3` for structured, port-driven result extraction, and propagate through the Runner layer with backward-compatible options.

---

## Scope

**In scope:**
- `Workflow.results/1` — port-driven extraction using `output_ports`
- `Workflow.results/2` — explicit component name selection
- `Workflow.results/3` — options for `:facts` mode and `:all` cardinality override
- `Runner.get_results/2,3` updated to use `Workflow.results`
- `Runner.Worker` `:get_results` handler updated
- Tests for all arities and Runner integration

**Out of scope (deferred):**
- `on_complete` callback signature change
- Runtime type validation (`:strict` option)
- Streaming/incremental result extraction

---

## API Specification

### `Workflow.results/1`

Uses the workflow's `output_ports` to determine extraction shape. When no output ports are declared, falls back to `raw_productions_by_component/1`.

```elixir
@doc """
Extracts structured results from a workflow using its output port contract.

When the workflow declares `output_ports`, returns a map keyed by port name
with the last produced value for each port. When no ports are declared,
falls back to `raw_productions_by_component/1`.

## Examples

    # With output ports
    workflow = Runic.workflow(
      name: :pipeline,
      steps: [{Runic.step(&parse/1, name: :parse),
               [Runic.step(&price/1, name: :price)]}],
      output_ports: [total: [type: :float, from: :price]]
    )

    %{total: 42.50} =
      workflow
      |> Workflow.react_until_satisfied(order)
      |> Workflow.results()

    # Without output ports — falls back to by-component map
    workflow = Runic.workflow(steps: [Runic.step(fn x -> x * 2 end, name: :double)])

    %{double: [10]} =
      workflow
      |> Workflow.react_until_satisfied(5)
      |> Workflow.results()
"""
@spec results(t()) :: map()
```

**Behavior:**

| Workflow state | Return value |
|---|---|
| Has `output_ports`, ports have `:from` | `%{port_name => last_value_from_component}` |
| Has `output_ports`, no `:from` binding | Port name used as component name |
| Port with `cardinality: :many` | `%{port_name => [all_values]}` |
| Port with `cardinality: :one` (default) | `%{port_name => last_value}` |
| No `output_ports` declared | `raw_productions_by_component(workflow)` — `%{component_name => [values]}` |
| Component has no productions yet | `nil` for `:one`, `[]` for `:many` |

The fallback returns `raw_productions_by_component` which is `%{name => [values]}` — a list per component. This differs from the port-driven path which returns unwrapped single values for `:one` cardinality. This is intentional: without declared ports, the system can't know which value is "the" result, so it returns all of them.

### `Workflow.results/2`

Explicit component selection, independent of `output_ports`:

```elixir
@doc """
Extracts results for specific components by name.

Returns the last produced value for each named component. Ignores the
workflow's output port declarations — this is for ad-hoc extraction.

## Example

    %{add: 6, mult: 10} =
      workflow
      |> Workflow.react_until_satisfied(5)
      |> Workflow.results([:add, :mult])
"""
@spec results(t(), [atom() | binary()]) :: map()
```

### `Workflow.results/3`

Full control with options:

```elixir
@doc """
Extracts results with options for fine-grained control.

The first argument is the workflow. The second is a list of component
names to extract from, or `nil` to use the output port contract. The
third is a keyword list of options.

## Options

  - `:facts` — when `true`, returns `%Fact{}` structs instead of raw values.
    Default `false`.
  - `:all` — when `true`, returns all produced values as a list instead of
    just the last one, regardless of port cardinality. Default `false`.

## Examples

    # Get all produced values
    %{price: [first_price, final_price]} =
      Workflow.results(workflow, [:price], all: true)

    # Get full Fact structs for tracing
    %{price: %Fact{value: 42.50, ancestry: {_, _}}} =
      Workflow.results(workflow, [:price], facts: true)

    # Both: all facts
    %{price: [%Fact{}, %Fact{}]} =
      Workflow.results(workflow, [:price], facts: true, all: true)

    # Use output ports with options
    %{total: [42.50, 43.00]} =
      Workflow.results(workflow, nil, all: true)
"""
@spec results(t(), [atom() | binary()] | nil, keyword()) :: map()
```

**Option semantics:**

| `:facts` | `:all` | `:one` port | `:many` port |
|---|---|---|---|
| `false` (default) | `false` (default) | `List.last(values)` | `values` |
| `false` | `true` | `values` (list) | `values` |
| `true` | `false` | `List.last(facts)` | `facts` |
| `true` | `true` | `facts` (list) | `facts` |

When `component_names` is an explicit list (not `nil`), there are no port schemas to read cardinality from. In that case, `:one` cardinality is assumed unless `:all` is `true`.

---

## Implementation

### Phase 1: `Workflow.results/1,2,3`

All implementation in `lib/workflow.ex`.

```elixir
@spec results(t(), [atom() | binary()] | nil, keyword()) :: map()
def results(workflow, component_names \\ nil, opts \\ [])

# Explicit component selection
def results(%__MODULE__{} = workflow, component_names, opts)
    when is_list(component_names) do
  return_facts = Keyword.get(opts, :facts, false)
  return_all = Keyword.get(opts, :all, false)

  Map.new(component_names, fn name ->
    values = extract_productions(workflow, name, return_facts)
    {name, select_value(values, :one, return_all)}
  end)
end

# Port-driven extraction
def results(%__MODULE__{output_ports: ports} = workflow, nil, opts)
    when is_list(ports) do
  return_facts = Keyword.get(opts, :facts, false)
  return_all = Keyword.get(opts, :all, false)

  Map.new(ports, fn {port_name, port_opts} ->
    component_name = Keyword.get(port_opts, :from, port_name)
    cardinality = Keyword.get(port_opts, :cardinality, :one)
    values = extract_productions(workflow, component_name, return_facts)
    {port_name, select_value(values, cardinality, return_all)}
  end)
end

# Fallback: no ports, no explicit names
def results(%__MODULE__{} = workflow, nil, opts) do
  return_facts = Keyword.get(opts, :facts, false)

  if return_facts do
    productions_by_component(workflow)
  else
    raw_productions_by_component(workflow)
  end
end
```

Helper functions:

```elixir
# Extracts productions for a component, as facts or raw values
defp extract_productions(workflow, component_name, true = _facts) do
  productions(workflow, component_name)
end

defp extract_productions(workflow, component_name, false = _facts) do
  raw_productions(workflow, component_name)
end

# Selects the final value based on cardinality and :all option
defp select_value(values, _cardinality, true = _return_all), do: values
defp select_value(values, :many, false = _return_all), do: values
defp select_value([], :one, false = _return_all), do: nil
defp select_value(values, :one, false = _return_all), do: List.last(values)
```

**Why `List.last/1`:** Stateful components (Accumulator, StateMachine, Aggregate, FSM) produce new state facts on each reaction cycle. The last produced value is the final state. For stateless Step chains, there's typically one production per input, so `last` and `first` are equivalent.

### Phase 2: Runner Integration

**Approach:** The Runner's `get_results` should delegate to `Workflow.results`, but since `get_results` has ~70 existing call sites in tests that expect a flat list (`assert 6 in results`), we need a backward-compatible path. The `results/3` options solve this cleanly — existing tests continue to work via `get_workflow` + `raw_productions`, while the new API provides structured results.

However, since none of the existing Runner test workflows declare `output_ports`, calling `Workflow.results/1` on them falls back to `raw_productions_by_component/1` which returns `%{name => [values]}` — a map, not a list. This **would break** existing test assertions like `assert 6 in results`.

**Decision:** Keep `Runner.get_results/2` behavior unchanged (returns `raw_productions`). Add `Runner.get_results/3` with options to opt into the new structured API. This avoids a breaking change while making the new API available.

#### Worker changes

```elixir
# Existing — unchanged
def handle_call(:get_results, _from, state) do
  {:reply, {:ok, Workflow.raw_productions(state.workflow)}, state}
end

# New — structured results with options
def handle_call({:get_results, opts}, _from, state) do
  component_names = Keyword.get(opts, :components)
  {:reply, {:ok, Workflow.results(state.workflow, component_names, opts)}, state}
end
```

#### Runner public API changes

```elixir
@doc """
Returns the raw productions from a running workflow.

For structured results using port contracts, use `get_results/3`.
"""
def get_results(runner, workflow_id) do
  case lookup(runner, workflow_id) do
    nil -> {:error, :not_found}
    pid -> GenServer.call(pid, :get_results)
  end
end

@doc """
Returns structured results from a running workflow.

## Options

  - `:components` — list of component names to extract. When `nil` (default),
    uses the workflow's output port contract.
  - `:facts` — when `true`, returns `%Fact{}` structs. Default `false`.
  - `:all` — when `true`, returns all produced values as lists. Default `false`.

## Examples

    # Use output port contract
    {:ok, %{total: 42.50}} = Runner.get_results(runner, :order_pipeline, [])

    # Explicit component selection
    {:ok, %{price: 42.50}} = Runner.get_results(runner, :order_pipeline, components: [:price])

    # All values as facts
    {:ok, %{total: [%Fact{}, ...]}} = Runner.get_results(runner, :id, facts: true, all: true)
"""
def get_results(runner, workflow_id, opts) when is_list(opts) do
  case lookup(runner, workflow_id) do
    nil -> {:error, :not_found}
    pid -> GenServer.call(pid, {:get_results, opts})
  end
end
```

This way:
- `Runner.get_results(runner, id)` — returns `{:ok, [values]}` (unchanged, backward-compatible)
- `Runner.get_results(runner, id, [])` — returns `{:ok, %{port => value}}` using output ports
- `Runner.get_results(runner, id, components: [:total])` — returns `{:ok, %{total: value}}`
- `Runner.get_results(runner, id, all: true)` — returns all values as lists

---

## Affected Modules & Files

| Module | File | Changes |
|--------|------|---------|
| `Runic.Workflow` | `lib/workflow.ex` | Add `results/1,2,3`, `extract_productions/3`, `select_value/3` |
| `Runic.Runner` | `lib/runic/runner.ex` | Add `get_results/3` |
| `Runic.Runner.Worker` | `lib/runic/runner/worker.ex` | Add `{:get_results, opts}` handler |
| New: test | `test/workflow_results_test.exs` | Unit tests for `results/1,2,3` |
| New: test | `test/runner/results_test.exs` | Runner integration tests |

---

## Testing Strategy

### `Workflow.results/1` — port-driven

```
- Workflow with output_ports and :from bindings extracts correct values
- Workflow with output_ports, no :from, uses port name as component name
- Workflow without output_ports falls back to raw_productions_by_component
- Port with cardinality: :many returns full list
- Port with cardinality: :one returns last value
- Component with no productions returns nil for :one, [] for :many
- Multiple output ports each extract independently
- Stateful component (Accumulator/StateMachine) returns final state
```

### `Workflow.results/2` — explicit selection

```
- Extracts named components regardless of output_ports
- Returns last value per component
- Works with components not referenced by output_ports
- Missing component name returns nil
```

### `Workflow.results/3` — options

```
- facts: true returns %Fact{} structs instead of raw values
- all: true returns list of all values for :one cardinality ports
- all: true with :many cardinality still returns list (no change)
- facts: true, all: true returns list of facts
- Default opts (facts: false, all: false) matches results/1 behavior
- nil component_names with opts uses output port contract
- Explicit component_names with opts uses component selection
```

### Runner integration

```
- Runner.get_results/2 (no opts) returns flat list (backward-compatible)
- Runner.get_results/3 with empty opts uses Workflow.results/1
- Runner.get_results/3 with components: [...] selects specific components
- Runner.get_results/3 with facts: true returns Fact structs
- Runner.get_results/3 with all: true returns all values
- All existing Runner tests continue to pass without modification
```

---

## Implementation Sequence

### Step 1: Core `Workflow.results/3`

1. Add `results/3` with default args to `lib/workflow.ex`
2. Add `extract_productions/3` and `select_value/3` private helpers
3. Add `@doc` with examples
4. Add `test/workflow_results_test.exs` with all unit tests
5. Run `mix test` — verify existing tests unaffected

### Step 2: Runner integration

1. Add `{:get_results, opts}` handler to `Runner.Worker`
2. Add `get_results/3` to `Runner` public API
3. Add `test/runner/results_test.exs` with Runner-level tests
4. Run full `mix test` — verify no existing Runner tests break

### Step 3: Documentation

1. Update `Workflow` moduledoc to mention `results` in the quick start
2. Add `results` to the cheatsheet
3. Update `Runner` moduledoc to mention `get_results/3`

---

## Design Decisions

| Decision | Chosen | Rationale |
|----------|--------|-----------|
| Function name | `results` | Avoids `Component.outputs/1` collision; clear intent |
| Default value selection | `List.last/1` | Matches stateful component semantics (final state is last) |
| No-ports fallback | `raw_productions_by_component` | Graceful degradation; don't force port declarations |
| Runner backward compat | Keep `get_results/2` unchanged | ~70 test call sites; pre-alpha but no need to churn |
| `results/3` instead of separate functions | Single entry point with opts | Progressive disclosure; one concept to learn |
| `:all` option | Override cardinality to return lists | Covers "give me everything" without per-port configuration |
| `:facts` option | Return `%Fact{}` structs | Enables tracing, debugging, and advanced extraction without a separate API |
| Nil component produces `nil` for `:one` | `nil` not an empty list | `nil` means "no result yet"; `[]` means "empty collection" |
