# Port Contracts Implementation Plan

**Status:** Draft  
**References:** [I/O Contract Analysis](io-contract-analysis.md)  
**Goal:** Replace internal-key-based I/O schemas with a user-facing port contract system, enforce compatibility at connection time, and lay groundwork for typed workflow boundaries.

---

## Scope & Priorities

This plan covers the **core port contract system** needed for low-code canvas UIs and runtime workflow composition. Per the analysis, the following are **deferred**:

- **Expert system fact-kind indexing and working-memory semantics** — deferred to a future effort when Runic is used in production KB scenarios
- **Component catalogs, searchable registries, contract diffing** — these are external consumer concerns; Runic provides the contract data, consumers build the catalog
- **Serialization format** — deferred; the port contract is a simple keyword/map structure that is trivially serializable by consumers today; a canonical JSON format can be specified later without breaking changes
- **Semantic type identifiers (`{:ref, "type.v1"}`)** — deferred until concrete domain-typing use cases arise
- **Adapter/coercion systems, cross-language interop** — out of scope

**Fact metadata** (`meta` field on `%Fact{}`) is included as a lightweight addition but scoped carefully. It adds optional provenance data useful for debugging, UI inspection, and future storage optimization. Its interaction with checkpointing, rehydration, and content-addressed hashing is analyzed below and must not increase per-fact memory cost in the default case.

---

## Design Principles

1. **Ports are the public interface.** Users see named input/output ports. Internal subcomponent topology (`:condition`, `:reaction`, `:fan_out`, `:fan_in`, etc.) is hidden behind the port layer.

2. **Direct, not incremental.** Runic is pre-alpha — we change `inputs/1` and `outputs/1` to return port-format directly. No wrapper layer, no two-layer migration. One format, one source of truth.

3. **Gradual typing preserved.** Untyped components default all ports to `type: :any`. No burden on simple usage.

4. **Arity = count of input ports.** Multi-arity steps declare multiple named input ports. The Join mechanism remains internal. Port order (keyword list position) maps to Join collection order / `apply` argument position.

5. **Enforce by default.** `Workflow.add/3` validates port compatibility. A `validate: :off` escape hatch exists for prototyping.

6. **Minimal Fact metadata.** The `meta` field is an empty map by default (zero allocation in most BEAM implementations for `%{}`). It is **excluded** from the fact hash. It does not affect content-addressing, deduplication, or existing event replay.

---

## Affected Modules & Files

### Structs with `:inputs` / `:outputs` fields (port format changes)

| Struct | File | Current Schema Keys |
|--------|------|-------------------|
| `Step` | `lib/workflow/step.ex` | `:step` |
| `Rule` | `lib/workflow/rule.ex` | `:condition` / `:reaction` |
| `Accumulator` | `lib/workflow/accumulator.ex` | `:accumulator` |
| `Map` | `lib/workflow/map.ex` | `:fan_out` / `:leaf` |
| `Reduce` | `lib/workflow/reduce.ex` | `:fan_in` |
| `StateMachine` | `lib/workflow/state_machine.ex` | `:reactors` / `:accumulator` |
| `Aggregate` | `lib/workflow/aggregate.ex` | `:commands` / `:accumulator`, `:events` |
| `FSM` | `lib/workflow/fsm.ex` | `:events` / `:accumulator`, `:transition` |
| `Saga` | `lib/workflow/saga.ex` | `:trigger` / `:accumulator`, `:result` |
| `ProcessManager` | `lib/workflow/process_manager.ex` | `:events` / `:accumulator`, `:commands` |

### Protocol & helpers

| Module | File | Changes |
|--------|------|---------|
| `Runic.Component` protocol | `lib/workflow/component.ex` | Update `inputs/1` / `outputs/1` docs & all impls |
| `Runic.Component.TypeCompatibility` | `lib/workflow/component.ex` | Rewrite `schemas_compatible?/2` for port-name matching |
| `Runic.Component.FlowPath` | `lib/workflow/component.ex` | No changes |

### Macro construction

| Macro | File | Changes |
|-------|------|---------|
| `step/1`, `step/2` | `lib/runic.ex` | Add port key validation |
| `rule/1` | `lib/runic.ex` | Add port key validation |
| `state_machine/1` | `lib/runic.ex` | Update `validate_component_schema` keys |
| `map/1`, `map/2` | `lib/runic.ex` | Add port key validation |
| `reduce/3` | `lib/runic.ex` | Add port key validation |
| `validate_component_schema/3` | `lib/runic.ex` | Update known keys per component |

### Workflow runtime

| Module | File | Changes |
|--------|------|---------|
| `Runic.Workflow` | `lib/workflow.ex` | Enforce `connectable?` in `add/3`; add `:validate` opt |
| `Runic.Workflow.Fact` | `lib/workflow/fact.ex` | Add `meta: %{}` field |

### Tests

| File | Changes |
|------|---------|
| `test/component_protocol_test.exs` | Update all schema key assertions to port names |
| New: `test/port_compatibility_test.exs` | Port matching, multi-port, enforcement tests |

---

## Phase 1: Port Contract Format & Protocol Changes

**Can be developed as a single focused effort. All changes here are tightly coupled.**

### 1.1 Define the port contract format

The canonical format returned by `inputs/1` and `outputs/1`:

```elixir
# Single-port component (most components)
[in: [type: :any, doc: "Input value"]]
[out: [type: :any, doc: "Output value"]]

# Multi-port component (multi-arity step)
[
  order: [type: :map, doc: "Order data"],
  customer: [type: :map, doc: "Customer data"]
]

# Component with cardinality
[items: [type: :any, cardinality: :many, doc: "Collection to process"]]
```

Port schemas are keyword lists (ordered, lightweight, idiomatic Elixir). Each port entry is a keyword list of options:

| Option | Type | Default | Purpose |
|--------|------|---------|---------|
| `:type` | atom or tuple | `:any` | Type constraint |
| `:doc` | string | `nil` | Human-readable description |
| `:cardinality` | `:one \| :many` | `:one` | Whether port expects single value or collection |
| `:required` | boolean | `true` | Whether the port must be connected (for multi-port consumers) |

### 1.2 Update all `Component` protocol implementations

Replace internal subcomponent keys with user-facing port names.

**Default port name mapping:**

| Component | Input Ports | Output Ports | Notes |
|-----------|------------|-------------|-------|
| `Step` (arity 1) | `[in: ...]` | `[out: ...]` | |
| `Step` (arity N) | User-named or `[in_0: ..., in_1: ...]` | `[out: ...]` | Multi-arity |
| `Rule` | `[in: ...]` | `[out: ...]` | Hides condition/reaction split |
| `Map` | `[items: [cardinality: :many, ...]]` | `[out: [cardinality: :many, ...]]` | |
| `Reduce` | `[items: [cardinality: :many, ...]]` | `[result: ...]` | |
| `Accumulator` | `[in: ...]` | `[state: ...]` | |
| `StateMachine` | `[in: ...]` | `[state: ...]` | |
| `Aggregate` | `[command: ...]` | `[state: ...]` | |
| `FSM` | `[event: ...]` | `[state: ...]` | |
| `Saga` | `[in: ...]` | `[result: ...]` | |
| `ProcessManager` | `[event: ...]` | `[state: ...]` | |
| `Condition` | `[in: ...]` | `[out: ...]` | Internal, but consistent |
| `Workflow` | `[]` (Phase 2) | `[]` (Phase 2) | Boundaries added in Phase 2 |
| `Tuple` | `[]` | `[]` | Pipeline syntax, no introspection |

**Implementation pattern** (same for all component types):

```elixir
# Step example — default when user provides no schema
def inputs(%Step{inputs: nil}) do
  [in: [type: :any, doc: "Input value to be processed by the step function"]]
end

# User-provided schema passed through directly
def inputs(%Step{inputs: user_inputs}), do: user_inputs

# Same pattern for outputs
def outputs(%Step{outputs: nil}) do
  [out: [type: :any, doc: "Output value produced by the step function"]]
end

def outputs(%Step{outputs: user_outputs}), do: user_outputs
```

User-provided schemas use port names directly:

```elixir
Runic.step(fn x -> x * 3 end,
  name: "tripler",
  inputs: [in: [type: :integer, doc: "Integer to triple"]],
  outputs: [out: [type: :integer, doc: "Tripled value"]]
)

# Multi-arity
Runic.step(fn a, b -> a + b end,
  name: "sum",
  inputs: [
    left: [type: :integer, doc: "Left operand"],
    right: [type: :integer, doc: "Right operand"]
  ],
  outputs: [out: [type: :integer, doc: "Sum"]]
)
```

### 1.3 Rewrite `TypeCompatibility`

Replace the current cross-product matching with port-aware compatibility:

```elixir
defmodule Runic.Component.TypeCompatibility do
  @moduledoc false

  @doc """
  Check if a producer's output ports are compatible with a consumer's input ports.

  Matching rules:
  1. If both sides have exactly one port, match them regardless of name
  2. Otherwise, match by port name
  3. All required consumer ports must have a compatible producer

  Returns `{:ok, port_mapping}` or `{:error, reasons}`.
  """
  def ports_compatible?(producer_outputs, consumer_inputs) do
    case {length(producer_outputs), length(consumer_inputs)} do
      # Single port on each side — infer connection regardless of names
      {1, 1} ->
        [{_p_name, p_schema}] = producer_outputs
        [{_c_name, c_schema}] = consumer_inputs
        p_type = Keyword.get(p_schema, :type, :any)
        c_type = Keyword.get(c_schema, :type, :any)

        if types_compatible?(p_type, c_type) do
          {:ok, :inferred}
        else
          {:error, [{:type_mismatch, p_type, c_type}]}
        end

      # Multi-port — match by name
      _ ->
        errors =
          consumer_inputs
          |> Enum.filter(fn {_name, schema} ->
            Keyword.get(schema, :required, true)
          end)
          |> Enum.reject(fn {c_name, c_schema} ->
            case Keyword.fetch(producer_outputs, c_name) do
              {:ok, p_schema} ->
                types_compatible?(
                  Keyword.get(p_schema, :type, :any),
                  Keyword.get(c_schema, :type, :any)
                )

              :error ->
                false
            end
          end)
          |> Enum.map(fn {c_name, c_schema} ->
            {:unmatched_port, c_name, Keyword.get(c_schema, :type, :any)}
          end)

        if Enum.empty?(errors), do: {:ok, :matched}, else: {:error, errors}
    end
  end

  # types_compatible?/2 stays largely the same but:
  # - {:custom, _, _, _} no longer universally matches
  # - exact match and :any wildcard preserved
  def types_compatible?(producer_type, consumer_type) do
    case {producer_type, consumer_type} do
      {:any, _} -> true
      {_, :any} -> true
      {same, same} -> true
      {{:list, p}, {:list, c}} -> types_compatible?(p, c)
      {{:one_of, p_opts}, {:one_of, c_opts}} ->
        Enum.any?(p_opts, fn p -> Enum.any?(c_opts, &types_compatible?(p, &1)) end)
      {{:one_of, p_opts}, c} ->
        Enum.any?(p_opts, &types_compatible?(&1, c))
      {p, {:one_of, c_opts}} ->
        Enum.any?(c_opts, &types_compatible?(p, &1))
      _ -> false
    end
  end
end
```

### 1.4 Update `connectable?` implementations

All `connectable?` implementations should use `ports_compatible?/2` and **remove structural fallbacks**:

```elixir
# Replace all variations of this pattern:
def connectable?(component, other) do
  producer_outputs = outputs(component)
  consumer_inputs = Runic.Component.inputs(other)

  case Runic.Component.TypeCompatibility.ports_compatible?(producer_outputs, consumer_inputs) do
    {:ok, _} -> true
    {:error, _} -> false
  end
end
```

Remove from Rule, Reduce, and any other impl:
```elixir
# DELETE these structural fallbacks:
structural_compatible =
  case other_component do
    %Step{} -> true
    %Runic.Workflow.Map{} -> true
    # ...
  end
```

### 1.5 Update `validate_component_schema/3` for all macros

Extend validation to all component macros. The known port keys are now public port names:

```elixir
# In each macro, validate schema keys against allowed port names.
# For multi-arity steps, any user-chosen port names are valid for inputs.

# step — single arity
validate_component_schema(rewritten_opts[:inputs], "step", :input)
validate_component_schema(rewritten_opts[:outputs], "step", :output)

# rule
validate_component_schema(rewritten_opts[:inputs], "rule", :input)
validate_component_schema(rewritten_opts[:outputs], "rule", :output)

# state_machine — update existing calls
validate_component_schema(rewritten_opts[:inputs], "state_machine", :input)
validate_component_schema(rewritten_opts[:outputs], "state_machine", :output)

# map, reduce, accumulator — same pattern
```

The validation function needs updating. With user-defined port names, the validator should check:
- Schema is a keyword list
- Each entry is a keyword list with valid option keys (`:type`, `:doc`, `:cardinality`, `:required`)
- No duplicate port names
- Type values are from the known type vocabulary

```elixir
defp validate_component_schema(nil, _component_type, _direction), do: nil

defp validate_component_schema(schema, component_type, direction) when is_list(schema) do
  valid_port_opts = [:type, :doc, :cardinality, :required]

  Enum.each(schema, fn
    {port_name, port_opts} when is_atom(port_name) and is_list(port_opts) ->
      invalid_opts = Keyword.keys(port_opts) -- valid_port_opts

      unless Enum.empty?(invalid_opts) do
        raise ArgumentError,
          "Invalid port options #{inspect(invalid_opts)} for #{direction} port " <>
          "#{inspect(port_name)} on #{component_type}. " <>
          "Valid options: #{inspect(valid_port_opts)}"
      end

    {port_name, _} ->
      raise ArgumentError,
        "Port #{inspect(port_name)} on #{component_type} must have a keyword list of options"
  end)

  # Check for duplicate port names
  port_names = Keyword.keys(schema)
  dupes = port_names -- Enum.uniq(port_names)

  unless Enum.empty?(dupes) do
    raise ArgumentError,
      "Duplicate port names #{inspect(Enum.uniq(dupes))} in #{direction} schema for #{component_type}"
  end

  schema
end
```

### 1.6 Update `Component` protocol docs

Update the `@moduledoc` to reference ports instead of NimbleOptions/subcomponent keys. Update the custom component example to use port names.

---

## Phase 2: Connection-Time Enforcement

**Can begin immediately after Phase 1 merges, or developed in parallel on a branch.**

### 2.1 Add validation to `Workflow.add/3`

Insert a compatibility check before `do_add_component/4`:

```elixir
def add(%__MODULE__{} = workflow, component, opts \\ []) do
  validate_mode = Keyword.get(opts, :validate, :error)

  parent = resolve_parent(workflow, opts)

  case validate_mode do
    :off ->
      do_add_component(workflow, component, parent, opts)

    mode when mode in [:warn, :error] ->
      case validate_connection(component, parent) do
        :ok ->
          do_add_component(workflow, component, parent, opts)

        {:error, reasons} when mode == :warn ->
          Logger.warning(
            "Runic port compatibility warning connecting " <>
            "#{inspect_component_name(component)} to " <>
            "#{inspect_component_name(parent)}: #{inspect(reasons)}"
          )
          do_add_component(workflow, component, parent, opts)

        {:error, reasons} when mode == :error ->
          raise Runic.IncompatiblePortError,
            component: component,
            parent: parent,
            reasons: reasons
      end
  end
end
```

The `validate_connection/2` function:

```elixir
defp validate_connection(_component, %Root{}), do: :ok
defp validate_connection(_component, nil), do: :ok

defp validate_connection(component, parents) when is_list(parents) do
  # Multi-parent (Join) — validate each parent's output against consumer's ports
  # This is the multi-arity case
  consumer_inputs = Component.inputs(component)

  if length(consumer_inputs) == 1 do
    # Single input port, multiple parents → each parent just needs compatible type
    [{_port_name, port_schema}] = consumer_inputs
    c_type = Keyword.get(port_schema, :type, :any)

    errors =
      parents
      |> Enum.reject(fn parent ->
        parent
        |> Component.outputs()
        |> Enum.any?(fn {_name, schema} ->
          TypeCompatibility.types_compatible?(Keyword.get(schema, :type, :any), c_type)
        end)
      end)
      |> Enum.map(&{:incompatible_parent, Component.hash(&1)})

    if Enum.empty?(errors), do: :ok, else: {:error, errors}
  else
    # Multi-port consumer, multi-parent → validate port-by-port by position
    if length(parents) != length(consumer_inputs) do
      {:error, [{:arity_mismatch, length(parents), length(consumer_inputs)}]}
    else
      errors =
        parents
        |> Enum.zip(consumer_inputs)
        |> Enum.reject(fn {parent, {_c_name, c_schema}} ->
          c_type = Keyword.get(c_schema, :type, :any)

          parent
          |> Component.outputs()
          |> Enum.any?(fn {_name, schema} ->
            TypeCompatibility.types_compatible?(Keyword.get(schema, :type, :any), c_type)
          end)
        end)
        |> Enum.map(fn {_parent, {c_name, _}} -> {:unmatched_port, c_name} end)

      if Enum.empty?(errors), do: :ok, else: {:error, errors}
    end
  end
end

defp validate_connection(component, parent) do
  producer_outputs = Component.outputs(parent)
  consumer_inputs = Component.inputs(component)

  case TypeCompatibility.ports_compatible?(producer_outputs, consumer_inputs) do
    {:ok, _} -> :ok
    {:error, _} = err -> err
  end
end
```

### 2.2 Define `Runic.IncompatiblePortError`

A clear error for connection failures:

```elixir
defmodule Runic.IncompatiblePortError do
  defexception [:component, :parent, :reasons]

  def message(%{component: component, parent: parent, reasons: reasons}) do
    comp_name = name_of(component)
    parent_name = name_of(parent)

    "Cannot connect #{comp_name} to #{parent_name}: " <>
      Enum.map_join(reasons, "; ", &format_reason/1)
  end

  defp name_of(%{name: name}) when not is_nil(name), do: inspect(name)
  defp name_of(%{hash: hash}), do: "component(#{hash})"
  defp name_of(other), do: inspect(other)

  defp format_reason({:type_mismatch, p, c}),
    do: "type mismatch: producer #{inspect(p)} vs consumer #{inspect(c)}"
  defp format_reason({:unmatched_port, name, type}),
    do: "required port #{inspect(name)} (#{inspect(type)}) has no compatible producer"
  defp format_reason({:unmatched_port, name}),
    do: "required port #{inspect(name)} has no compatible producer"
  defp format_reason({:arity_mismatch, got, expected}),
    do: "parent count #{got} does not match input port count #{expected}"
  defp format_reason({:incompatible_parent, hash}),
    do: "parent #{hash} output is incompatible"
  defp format_reason(other), do: inspect(other)
end
```

Place in `lib/workflow/errors.ex` or alongside existing error modules.

### 2.3 Update `Workflow.connectable?/3`

The existing `connectable?/3` utility should use `ports_compatible?/2` and return structured results:

```elixir
def connectable?(wrk, component, to: component_name) do
  with {:ok, added_to} <- fetch_component(wrk, component_name),
       :ok <- arity_match(component, added_to) do
    producer_outputs = Component.outputs(added_to)
    consumer_inputs = Component.inputs(component)
    TypeCompatibility.ports_compatible?(producer_outputs, consumer_inputs)
  end
end
```

---

## Phase 3: Workflow Boundary Ports

**Depends on Phase 1 (port format). Can run in parallel with Phase 2.**

### 3.1 Add port fields to `Workflow` struct

The `Workflow` struct currently has an `:inputs` field used for tracking input fact hashes. Add separate `:input_ports` and `:output_ports` for boundary contracts:

```elixir
defstruct name: nil,
          hash: nil,
          graph: nil,
          components: %{},
          # ... existing fields ...
          input_ports: nil,   # keyword list of port schemas, or nil
          output_ports: nil   # keyword list of port schemas, or nil
```

### 3.2 Accept ports in `Runic.workflow/1`

```elixir
def workflow(opts \\ []) do
  name = opts[:name]
  steps = opts[:steps]
  rules = opts[:rules]
  input_ports = opts[:inputs]
  output_ports = opts[:outputs]

  Workflow.new(name)
  |> Workflow.add_steps(steps)
  |> Workflow.add_rules(rules)
  |> maybe_set_ports(input_ports, output_ports)
end
```

Port declarations can include a `:to` / `:from` binding to name the internal component:

```elixir
Runic.workflow(
  name: :price_calculator,
  inputs: [
    order: [type: :map, doc: "Order to price", to: :parse_order]
  ],
  outputs: [
    total: [type: :float, doc: "Calculated total", from: :calculate_total]
  ],
  steps: [...]
)
```

The `:to` / `:from` keys are metadata for the boundary mapping — they tell the system which internal component a workflow input feeds into and which internal component's output surfaces as a workflow output. These are validated at build time to ensure the named components exist.

### 3.3 Update `Workflow` Component implementation

```elixir
defimpl Runic.Component, for: Runic.Workflow do
  def inputs(%Workflow{input_ports: nil}), do: []
  def inputs(%Workflow{input_ports: ports}), do: ports

  def outputs(%Workflow{output_ports: nil}), do: []
  def outputs(%Workflow{output_ports: ports}), do: ports

  # connectable? now works for workflows with declared ports
  def connectable?(%Workflow{output_ports: nil}, _), do: true
  def connectable?(%Workflow{} = wf, other) do
    producer_outputs = outputs(wf)
    consumer_inputs = Runic.Component.inputs(other)

    case Runic.Component.TypeCompatibility.ports_compatible?(producer_outputs, consumer_inputs) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end
end
```

---

## Phase 4: Fact Metadata (Lightweight)

**Independent of Phases 1–3. Can be developed in parallel.**

### 4.1 Design considerations

The `%Fact{}` struct is central to Runic's runtime. Every fact produced flows through the graph, is stored in graph edges as vertices, and in durable execution scenarios is persisted via events and potentially stored separately by hash. Changes here have consequences:

**Memory weight:**
- `meta: %{}` adds one field to the struct. Empty maps in BEAM are a single word (8 bytes on 64-bit). This is negligible for workflows with typical fact counts.
- Populated metadata (e.g., `%{source_port: :out, type: :integer}`) is a small map — ~3 words per key. For workflows producing thousands of facts, this is bounded and proportional to information content.
- **Decision:** Default to `%{}` — zero meaningful overhead. Populate only when the producing component has typed output ports.

**Content-addressed hashing:**
- Facts are hashed via `Components.fact_hash({value, ancestry})`.
- **Decision:** `meta` is **excluded** from the hash. Two facts with the same value and ancestry but different metadata are the same fact. This preserves deduplication semantics and means adding metadata never changes workflow behavior.

**Checkpointing & rehydration:**
- Events like `FactProduced` carry `hash`, `value`, `ancestry`. Adding `meta` to `FactProduced` is additive — older event streams without `meta` deserialize with the default `%{}`.
- Snapshot serialization via `:erlang.term_to_binary` captures the full struct — the `meta` field serializes naturally.
- For fact-level storage (`save_fact/3` / `load_fact/2` on `Runic.Runner.Store`), `meta` would be stored alongside the fact. Since these callbacks aren't implemented yet, we can design them to include metadata from the start.
- **Hot/cold fact classification** during rehydration (the `FactRef` approach from the checkpointing plan) is unaffected — `meta` travels with the fact regardless of hot/cold status.

**Decision:** `meta` is safe to add now with these constraints:
- Excluded from `fact_hash`
- Default `%{}`
- Added to `FactProduced` event as an optional field
- No behavioral changes to existing workflows

### 4.2 Implementation

```elixir
# lib/workflow/fact.ex
defmodule Runic.Workflow.Fact do
  alias Runic.Workflow.Components
  defstruct [:hash, :value, :ancestry, meta: %{}]

  @type t() :: %__MODULE__{
          value: term(),
          hash: hash(),
          ancestry: {hash(), hash()},
          meta: map()
        }

  def new(params) do
    struct!(__MODULE__, params)
    |> maybe_set_hash()
  end

  # Hash excludes meta — intentionally
  defp maybe_set_hash(%__MODULE__{value: value, hash: nil} = fact) do
    %__MODULE__{fact | hash: Components.fact_hash({value, fact.ancestry})}
  end

  defp maybe_set_hash(%__MODULE__{hash: hash} = fact)
       when not is_nil(hash),
       do: fact
end
```

Update `FactProduced` event to carry optional metadata:

```elixir
# In lib/workflow/events/fact_produced.ex
defstruct [:hash, :value, :ancestry, :producer_label, :weight, meta: %{}]
```

Update `apply_event/2` for `FactProduced` to pass `meta` through to `Fact.new/1`.

### 4.3 Metadata population

In `Invokable.execute/2` for Step (and similar), when producing the result fact and FactProduced event, populate metadata from the step's output port schema if present:

```elixir
# Only when step has typed outputs
meta =
  case Component.outputs(node) do
    [{port_name, schema} | _] ->
      port_type = Keyword.get(schema, :type, :any)
      if port_type != :any, do: %{source_port: port_name, type: port_type}, else: %{}
    _ ->
      %{}
  end

result_fact = Fact.new(value: result, ancestry: {node.hash, fact.hash}, meta: meta)
```

This is opt-in by nature — untyped components produce facts with empty metadata.

---

## Workstream Summary

```
Phase 1: Port Format          Phase 2: Enforcement         Phase 3: Boundaries
─────────────────────         ──────────────────────        ───────────────────
1.1 Define format             2.1 add/3 validation         3.1 Workflow struct fields
1.2 All Component impls       2.2 IncompatiblePortError     3.2 workflow/1 accepts ports
1.3 Rewrite TypeCompat        2.3 Update connectable?/3     3.3 Workflow Component impl
1.4 Update connectable?
1.5 Macro validation
1.6 Protocol docs

Phase 4: Fact Meta (parallel)
─────────────────────────────
4.1 Add meta to Fact struct
4.2 Update FactProduced event
4.3 Optional metadata population
```

**Dependency graph:**

```
Phase 1 ──→ Phase 2
     │
     └────→ Phase 3

Phase 4 (independent, parallel with any phase)
```

Phases 1 and 4 can be developed concurrently. Phase 2 requires Phase 1. Phase 3 requires Phase 1 but is independent of Phase 2.

---

## Implementation Sequence

### Step 1: Phase 1 + Phase 4 in parallel

**Phase 1 workstream:**
1. Update `validate_component_schema/3` to validate port option keys instead of subcomponent keys
2. Update all `inputs/1` default clauses across all Component impls (Step, Rule, Map, Reduce, Accumulator, StateMachine, Aggregate, FSM, Saga, ProcessManager, Condition)
3. Update all `outputs/1` default clauses
4. Rewrite `TypeCompatibility.schemas_compatible?/2` → `ports_compatible?/2`
5. Update all `connectable?/2` impls to use `ports_compatible?/2`, remove structural fallbacks
6. Add port validation calls to `step`, `rule`, `map`, `reduce` macros (matching existing `state_machine` pattern)
7. Update `state_machine` macro's validation to use new port key names
8. Update all tests in `component_protocol_test.exs`
9. Update protocol `@moduledoc`

**Phase 4 workstream:**
1. Add `meta: %{}` to `Fact` struct and typespec
2. Add `meta: %{}` to `FactProduced` event struct
3. Update `apply_event/2` for `FactProduced` to pass meta through
4. Verify existing tests pass (meta defaults to `%{}`, hash unchanged)
5. Add metadata population to `Step` execute path
6. Add tests for fact metadata round-trip

### Step 2: Phase 2

1. Add `Runic.IncompatiblePortError` exception module
2. Add `validate_connection/2` private function to `Workflow`
3. Insert validation into `Workflow.add/3` with `:validate` option
4. Update `Workflow.connectable?/3` to use `ports_compatible?/2`
5. Add tests for enforcement: valid connections pass, invalid raise, `:validate :off` bypasses
6. Add tests for multi-parent (Join) validation with named ports

### Step 3: Phase 3

1. Add `:input_ports` and `:output_ports` fields to `Workflow` struct
2. Update `Runic.workflow/1` to accept and store port declarations
3. Validate `:to` / `:from` bindings against registered components
4. Update `Workflow` Component impl for `inputs/1`, `outputs/1`, `connectable?/2`
5. Add tests for workflow-as-component with boundary ports

---

## Testing Strategy

### Unit tests (per phase)

**Phase 1:**
- Each component type returns correct default port names and types
- User-provided schemas are returned as-is
- `ports_compatible?/2` correctly handles: single-to-single inference, multi-port name matching, type mismatches, `:any` wildcards, `{:list, t}` recursion, `{:one_of, [...]}` overlap
- Macro validation rejects invalid port option keys, duplicate port names
- Multi-arity steps with named input ports

**Phase 2:**
- `Workflow.add/3` raises `IncompatiblePortError` for type mismatches
- `Workflow.add/3` succeeds for compatible connections
- `validate: :off` bypasses all checks
- `validate: :warn` logs but succeeds
- Multi-parent connections validate per-port
- `:any` typed components connect to anything (gradual typing preserved)

**Phase 3:**
- Workflow with declared ports surfaces them via `Component.inputs/1` / `Component.outputs/1`
- Workflow without ports returns `[]` (backward compatible)
- Workflow-to-workflow composition validates boundary ports
- `:to` / `:from` bindings validated against component registry

**Phase 4:**
- Facts default to `meta: %{}`
- Fact hash is unchanged by metadata
- `FactProduced` event round-trips metadata through `apply_event/2`
- Typed step populates metadata on produced facts
- Untyped step leaves metadata empty
- `from_events/2` handles events with and without `meta` field

### Existing test compatibility

All existing tests that use default schemas will need schema key updates (`:step` → `:in` / `:out`, etc.) in `component_protocol_test.exs`. The runtime tests (workflow execution, reactions, productions) should be unaffected since they don't inspect I/O schemas.

Run `mix test` after each phase to verify no regressions.

---

## Deferred Work

The following items from the [analysis](io-contract-analysis.md) are explicitly **not** in scope for this plan:

| Item | Reason |
|------|--------|
| Expert system fact-kind indexing | Requires production KB use case to drive design |
| Working-memory semantic matching | Same — needs concrete expert system integration |
| Component catalog / registry | External consumer concern; Runic provides contract data |
| Searchable component databases | External concern |
| Contract diffing utilities | Nice-to-have, not blocking alpha |
| Canonical JSON serialization format | Keyword lists / maps are trivially serializable; formal spec can wait |
| `{:ref, "type.v1"}` semantic type IDs | Requires domain-typing use cases |
| Adapter/coercion graphs | Over-engineering for alpha |
| Cross-language interop | Out of scope |
| Field-level structural schemas | Out of scope |

These can be revisited post-alpha as usage patterns emerge.
