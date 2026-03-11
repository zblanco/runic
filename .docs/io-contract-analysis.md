# Runic I/O Contract System: Analysis & Recommendations

## Executive Summary

Runic's current I/O contract system—`inputs/1` and `outputs/1` on the `Component` protocol backed by NimbleOptions-style schemas and a `TypeCompatibility` helper—was a successful lean spike that proved the concept. However, it has significant gaps when evaluated against the target use cases of **low-code canvas UIs**, **agential runtime composition**, and **expert systems via component knowledge bases**.

The core recommendation: **keep the lightweight type vocabulary and gradual typing philosophy**, but evolve the system into a **public port contract layer** with **connection-time enforcement**, **workflow boundary visibility**, and **optional fact metadata**—without importing a heavy type system or schema DSL.

---

## Current State Assessment

### What Exists

Components define I/O contracts via the `Component` protocol:

```elixir
# Protocol definition (lib/workflow/component.ex)
def inputs(component)   # => NimbleOptions keyword list
def outputs(component)  # => NimbleOptions keyword list
```

Schemas are keyed by internal subcomponent kind:

```elixir
# Step
inputs:  [step: [type: :any, doc: "..."]]
outputs: [step: [type: :any, doc: "..."]]

# Rule
inputs:  [condition: [type: :any, doc: "..."]]
outputs: [reaction: [type: :any, doc: "..."]]

# StateMachine
inputs:  [reactors: [type: {:list, :any}, doc: "..."]]
outputs: [accumulator: [type: :any, doc: "..."]]

# Map
inputs:  [fan_out: [type: :any, doc: "..."]]
outputs: [leaf: [type: {:custom, Runic.Components, :enumerable_type, []}, doc: "..."]]
```

Type compatibility is checked via `Runic.Component.TypeCompatibility`:

```elixir
types_compatible?(:any, :integer)                    # => true (wildcard)
types_compatible?(:string, :integer)                 # => false
types_compatible?({:list, :integer}, {:list, :any})  # => true (recursive)
schemas_compatible?(producer_outputs, consumer_inputs) # => lenient cross-key check
```

Users can override defaults:

```elixir
Runic.step(fn x -> x * 3 end,
  name: "tripler",
  inputs:  [step: [type: :integer, doc: "Integer to be tripled"]],
  outputs: [step: [type: :integer, doc: "Tripled integer value"]]
)
```

### What Works Well

1. **Gradual typing** — `:any` as default means zero burden for simple usage
2. **Lightweight vocabulary** — `:integer`, `:string`, `{:list, t}`, `{:one_of, []}`, `{:custom, m, f, a}` is minimal but expressive
3. **Protocol-based** — each component type controls its own contract shape
4. **Content-addressable hashing** — components are already identity-stable for catalogs
5. **Closure & source capture** — AST serialization via `source/1` supports reproducibility

---

## Problems Identified

### Problem 1: Internal Topology Leaks Into Public Contracts

Schema keys (`:step`, `:condition`, `:reaction`, `:fan_out`, `:fan_in`, `:accumulator`, `:reactors`) are internal graph topology names, not user-facing port identifiers.

**Impact:**
- A canvas UI user dragging a Rule node sees ports named "condition" and "reaction" instead of "in" and "out"
- An AI agent composing workflows must understand each component's internal decomposition to reason about connectivity
- Schema keys vary by component type even when the semantic contract is identical (a Step's `:step` output and a Rule's `:reaction` output both mean "the value this node produces")
- The `validate_component_schema/3` function enforces these internal keys, locking users into implementation-specific vocabulary

**Example of the problem:**

```elixir
# These two components produce compatible outputs but use different keys:
step_outputs = [step: [type: :integer]]
rule_outputs = [reaction: [type: :integer]]

# schemas_compatible?/2 works around this by ignoring key names entirely,
# but that's too lenient — it loses the ability to distinguish ports.
```

### Problem 2: Compatibility Is Not Enforced at Connection Time

`Workflow.add/3` → `do_add_component/4` → `Component.connect/3` **never calls `connectable?`**. The `Workflow.connectable?/3` utility exists but is completely opt-in.

```elixir
# lib/workflow.ex L629-668 — no connectable? check
defp do_add_component(%__MODULE__{} = workflow, component, parent, opts) do
  # ...
  workflow = Component.connect(component, parent, workflow)
  # ^ directly connects, no validation
end
```

**Impact:**
- Invalid graphs can be constructed silently
- A canvas UI cannot rely on the runtime to prevent incompatible connections
- Agents can compose workflows that look valid but fail at execution time
- The entire I/O contract system is advisory documentation, not a safety net

### Problem 3: `schemas_compatible?/2` Is Too Lenient

The current implementation succeeds if **any** producer key type-matches **any** consumer key:

```elixir
def schemas_compatible?(producer_outputs, consumer_inputs) do
  Enum.any?(producer_keys, fn p_key ->
    Enum.any?(consumer_keys, fn c_key ->
      # Keys don't need to match — any pair passing is sufficient
      types_compatible?(p_type, c_type)
    end)
  end)
end
```

Combined with `:any` matching everything and `{:custom, _, _, _}` always returning `true`, this means almost everything is "compatible." The check provides false confidence—it rarely rejects anything.

### Problem 4: `connectable?` Has Structural Fallbacks That Bypass Schema Checks

Several implementations (Rule, Reduce) add hard-coded fallbacks:

```elixir
# Rule's connectable? — always true for Steps, Maps, Reduces, Workflows
structural_compatible =
  case other_component do
    %Step{} -> true
    %Runic.Workflow.Map{} -> true
    %Reduce{} -> true
    %Workflow{} -> true
    _otherwise -> false
  end

schema_compatible or structural_compatible
```

This means type annotations on Rules are never actually enforced.

### Problem 5: Workflows Are Opaque Containers

The Workflow implementation returns empty contracts:

```elixir
defimpl Runic.Component, for: Runic.Workflow do
  def inputs(%Workflow{}), do: []
  def outputs(%Workflow{}), do: []
end
```

**Impact:**
- A composed workflow cannot be used as a reusable component in a canvas UI
- An agent cannot query what a workflow accepts or produces
- Knowledge bases cannot catalog workflows alongside primitive components
- Workflow-of-workflows composition has no type safety

### Problem 6: Facts Carry No Type/Kind Metadata

```elixir
defstruct [:hash, :value, :ancestry]
```

Facts are completely untyped at runtime—no `type`, `kind`, or provenance information.

**Impact:**
- Expert systems cannot index working memory by fact class/kind
- Runtime validation of flowing data is impossible without inspecting `value` directly
- Debugging workflows requires examining opaque `term()` values
- Agent orchestration cannot reason about what's in the workflow's fact log

### Problem 7: Inconsistent Validation Coverage

Only `state_machine` validates schema keys at macro expansion time. `step`, `rule`, `map`, `reduce`, `accumulator`, `aggregate`, `fsm`, `saga` all accept arbitrary schema keys silently.

```elixir
# Only state_machine does this:
inputs = validate_component_schema(rewritten_opts[:inputs], "state_machine", [:reactors])
outputs = validate_component_schema(rewritten_opts[:outputs], "state_machine", [:accumulator])

# Step just passes through unvalidated:
inputs: unquote(rewritten_opts[:inputs]),
outputs: unquote(rewritten_opts[:outputs]),
```

### Problem 8: No Multi-Port / Named Port Concept

Components with multiple logically distinct inputs or outputs (e.g., a Join that waits on N parents, a StateMachine with command input vs. query input) have no way to express distinct ports with different type contracts. Everything is flattened into a single keyword list.

---

## Fitness Assessment by Target Use Case

### Low-Code Canvas / Node-Builder UIs: **Weak**

| Requirement | Status |
|-------------|--------|
| Visible named ports for drag-connect | ❌ Internal keys leak |
| Safe connection validation | ❌ Not enforced |
| Reusable workflow nodes | ❌ Workflows opaque |
| Port compatibility drives UI affordances | ❌ Too lenient |
| Serializable contracts for persistence | ⚠️ Keywords work but fragile |

The system provides docs/introspection but cannot **drive** a canvas UX safely.

### Agential Runtime Composition: **Weak-to-Moderate**

| Requirement | Status |
|-------------|--------|
| Simple type vocabulary | ✅ Lightweight |
| Gradual typing | ✅ `:any` default |
| Trustworthy compatibility | ❌ Advisory only |
| Stable type identifiers for planning | ❌ No semantic type IDs |
| Workflow boundary visibility | ❌ Empty contracts |
| Serializable for agent reasoning | ⚠️ Keywords, not maps |

Agents can read contracts but cannot trust compatibility checks for safe composition.

### Expert Systems / Knowledge Bases: **Weak**

| Requirement | Status |
|-------------|--------|
| Typed facts in working memory | ❌ Facts untyped |
| Semantic type/kind matching | ❌ Structural types only |
| Component catalog with searchable contracts | ⚠️ Partial |
| Rule matching on fact classes | ❌ No fact metadata |
| Composable knowledge bases | ❌ Workflows opaque |

Expert systems need **semantic identity** of facts (e.g., `"order.created.v1"`), not just structural types (`:map`).

---

## Recommendations

### R1: Introduce a Public Port Contract Layer

**What:** Decouple the public-facing I/O contract from internal subcomponent topology. Users and UIs see named **ports**; the runtime maps ports to internal graph nodes.

**Port contract shape** (canonical normalized form):

```elixir
%{
  version: 1,
  inputs: %{
    in: %{type: :integer, doc: "...", required: true, cardinality: :one}
  },
  outputs: %{
    out: %{type: :string, doc: "...", cardinality: :one}
  }
}
```

**Default port mappings by component kind:**

| Component | Input Port(s) | Output Port(s) | Internal Binding |
|-----------|---------------|-----------------|------------------|
| Step | `in` | `out` | `in → :step`, `out → :step` |
| Rule | `in` | `out` | `in → :condition`, `out → :reaction` |
| Map | `items` (`:many`) | `out` (`:many`) | `items → :fan_out`, `out → :leaf` |
| Reduce | `items` (`:many`) | `result` | `items → :fan_in`, `result → :fan_in` |
| Accumulator | `event` | `state` | `event → :accumulator`, `state → :accumulator` |
| StateMachine | `event` | `state` | `event → :reactors`, `state → :accumulator` |
| Workflow | explicit | explicit | user-declared bindings |

**Authoring stays simple:**

```elixir
# Minimal — just override types
Runic.step(fn x -> x * 2 end,
  name: :double,
  inputs: [in: [type: :integer]],
  outputs: [out: [type: :integer]]
)

# Or stay with defaults (gradual typing preserved)
Runic.step(fn x -> x * 2 end, name: :double)
# => ports default to in: :any, out: :any
```

**Multi-arity steps and named input ports:**

Runic already supports multi-arity steps via `Join` nodes. When a step is connected to multiple parents (`add(step, to: [:a, :b])`), a `Join` is inserted that collects one fact per parent, produces a single fact whose value is a **list** of all parent values (in declaration order), and `Components.run/3` spreads that list as arguments via `apply(work, fact_value)`.

The port contract model makes this mechanism explicit: **arity is the count of input ports**. Multiple input ports on a step signal that a Join is needed, and port order maps to the Join's collection order. This is the user-facing abstraction over the internal Join wiring.

```elixir
# Multi-arity step with named input ports:
Runic.step(fn order, customer -> calculate_price(order, customer) end,
  name: :price,
  inputs: [
    order:    [type: {:ref, "order.v1"}, doc: "The order to price"],
    customer: [type: {:ref, "customer.v1"}, doc: "The customer for discounts"]
  ],
  outputs: [
    result: [type: :float, doc: "Calculated price"]
  ]
)
```

A canvas UI renders two distinct input sockets; the user connects different upstream nodes to each named port. At build time, port names establish which upstream output maps to which argument position in the Join.

For untyped multi-arity steps (no explicit port declarations), the system falls back to positional ports derived from `arity_of(work)` — e.g., `in_0`, `in_1` for a 2-arity function. This preserves backward compatibility while giving typed components explicit, nameable connection points.

**Port matching with Joins:**
- When connecting `producer_output → consumer_input_port`, the port name identifies which Join slot receives the value
- Port order in the `inputs:` keyword list defines argument position (keyword lists are ordered)
- A single-input-port step needs no Join (current behavior unchanged)
- The Join remains an internal runtime node — ports abstract over it entirely

**Migration path:** Add a `contract/1` function that normalizes current `inputs/outputs` into the port contract format. Existing protocol remains, new layer wraps it.

### R2: Enforce Compatibility at Connection Time

**What:** Make `Workflow.add/3` validate port compatibility by default, with escape hatches.

```elixir
def add(workflow, component, opts \\ []) do
  validation = Keyword.get(opts, :validate, :warn)  # start with :warn, move to :error

  case validation do
    :off   -> do_add_component(workflow, component, parent, opts)
    :warn  -> validate_then_add(workflow, component, parent, opts, :warn)
    :error -> validate_then_add(workflow, component, parent, opts, :error)
  end
end
```

**Validation modes:**
- `:off` — current behavior, prototyping-friendly
- `:warn` — logs warnings but allows connection (transition period)
- `:error` — raises on incompatible connections (production default)

**Remove structural fallbacks** — the `case other_component do %Step{} -> true` patterns in Rule/Reduce `connectable?` implementations should be removed once port contracts are in place.

### R3: Tighten Type Compatibility Rules

**Port matching rules:**
1. Explicit source port → target port mapping takes precedence
2. If both sides have exactly one port, infer the connection
3. Otherwise, require port names (canvas UIs do this naturally via drag-connect)

**Type matching refinements:**
- `:any` remains the universal wildcard
- Exact match remains valid
- `{:list, t}` checks recursively
- `{:one_of, [...]}` checks for overlap
- `{:custom, m, f, a}` should **not** universally match — treat as opaque type identity, require exact match or explicit compatibility declaration
- Add `{:ref, "type.name.v1"}` for semantic type identifiers (domain types without MFA coupling)

**`schemas_compatible?/2` must change:**
- Match by port name, not cross-product of all keys
- Require all `required: true` consumer ports to have a compatible producer port
- Return `{:ok, port_mapping}` or `{:error, mismatches}` instead of boolean

### R4: Expose Workflow Boundary Ports

**What:** Let workflows declare their public interface.

```elixir
Runic.workflow(
  name: :price_calculator,
  inputs: [
    order: [type: {:ref, "order.v1"}, to: :parse_order]
  ],
  outputs: [
    total: [type: :float, from: :calculate_total]
  ],
  steps: [...]
)
```

- `to:` maps the workflow input port to an internal component
- `from:` maps an internal component's output to the workflow output port

**Benefits:**
- Composed workflows become reusable catalog components with visible ports
- Canvas UIs can render workflow nodes identically to primitive nodes
- Agents can compose workflows-of-workflows with type safety
- Knowledge bases can index workflows by their contracts

### R5: Add Optional Fact Metadata

**What:** Extend `Fact` with an optional `meta` field for type/kind/provenance without changing core semantics.

```elixir
defstruct [:hash, :value, :ancestry, meta: %{}]
```

**Usage patterns:**

```elixir
# Runtime decoration (opt-in, producer-side)
meta: %{
  source_port: :out,
  type: :map,
  kind: "order.created.v1"
}
```

**Guardrails:**
- `meta` is **not** included in the fact hash by default (facts with same value/ancestry remain deduplicated regardless of metadata)
- Fact metadata is populated when a step produces a fact and the step has typed output ports
- Expert system conditions can pattern-match on `meta.kind` for working-memory indexing

### R6: Consistent Schema Validation Across All Components

**What:** Apply `validate_component_schema/3` (or its port-contract successor) to all component macros, not just `state_machine`.

Components to add validation to:
- `step` — valid keys: `[:in]` / `[:out]` (or `[:step]` during migration)
- `rule` — valid keys: `[:in]` / `[:out]`
- `map` — valid keys: `[:items]` / `[:out]`
- `reduce` — valid keys: `[:items]` / `[:result]`
- `accumulator` — valid keys: `[:event]` / `[:state]`
- `aggregate`, `fsm`, `saga`, `process_manager` — respective valid keys
- `workflow` — validate boundary port declarations

### R7: Serializable Contract Format for Catalogs & Transport

**What:** Normalize contracts to plain maps with a version for storage and transport.

```elixir
# Serialized form (JSON-friendly)
%{
  "version" => 1,
  "component_type" => "step",
  "name" => "tripler",
  "hash" => 1234567890,
  "inputs" => %{
    "in" => %{"type" => "integer", "doc" => "Integer to be tripled", "required" => true}
  },
  "outputs" => %{
    "out" => %{"type" => "integer", "doc" => "Tripled integer value"}
  }
}
```

**Benefits:**
- Persist in databases, ship over APIs
- Feed to LLM agents as structured context
- Diff contracts between versions
- Build searchable component catalogs
- Canvas UIs can hydrate node palettes from serialized catalogs

---

## Approach Options

### Option A: Incremental Port Contract Wrapper (Recommended)

**Approach:** Add a `Runic.Component.Contract` module that wraps existing `inputs/1`/`outputs/1` with port normalization. Keep the current protocol, add the new layer on top.

**Pros:** Non-breaking, can ship incrementally, existing tests pass
**Cons:** Two layers temporarily, some duplication during migration
**Effort:** M (1-2 days for contract layer + enforcement)

### Option B: Direct Protocol Evolution

**Approach:** Change `inputs/1`/`outputs/1` to return the new port-based format directly. Update all implementations at once.

**Pros:** Clean, single source of truth
**Cons:** Breaking change, large diff, all tests need updating simultaneously
**Effort:** L (2-3 days including test migration)

### Option C: Separate Type System Module

**Approach:** Build a standalone `Runic.Types` module with its own type algebra, validators, and compatibility engine. Wire it into Component protocol.

**Pros:** Clean separation of concerns, testable in isolation, extensible
**Cons:** Risk of over-engineering, more concepts for users to learn
**Effort:** L-XL (3-5 days)

### Recommendation: Option A first, evolve toward B

Start with a contract wrapper that normalizes existing schemas into port contracts. This lets the canvas UI, agent, and expert system use cases start building on a stable abstraction immediately. Over time, migrate the protocol itself to return the normalized form directly (Option B), deprecating the wrapper.

---

## Phased Implementation Roadmap

### Phase 1: Port Contract Layer + Enforcement (Priority: High)

1. Add `Runic.Component.Contract` with `contract/1` that normalizes `inputs/outputs` → port map
2. Define default port mappings per component type
3. Add `validate: :warn | :error | :off` to `Workflow.add/3`
4. Tighten `schemas_compatible?/2` to match by port name
5. Remove structural fallbacks from `connectable?` implementations
6. Add validation to all component macros

### Phase 2: Workflow Boundaries + Fact Metadata (Priority: High)

1. Implement workflow boundary port declarations (`inputs:` with `to:`, `outputs:` with `from:`)
2. Update `Workflow` Component impl to return boundary ports
3. Add `meta` field to `Fact` struct
4. Propagate port type info into fact metadata when available
5. Add `{:ref, "type.id"}` to the type vocabulary

### Phase 3: Serialization + Catalogs (Priority: Deferred)

> **Deferred.** Component catalogs and searchable registries are external consumer concerns — Runic provides the contract data, consumers build the catalog infrastructure. A canonical JSON format can be specified later without breaking changes to the port contract model.

1. Define canonical JSON-serializable contract format
2. Add `Contract.to_map/1` and `Contract.from_map/1`
3. Add contract diffing utilities
4. Build component catalog helpers (search by type, filter by compatibility)

### Phase 4: Advanced Type Features (Priority: Deferred)

> **Deferred.** Expert system semantics (fact-kind indexing, working-memory typed matching, semantic type identifiers) require concrete production use cases to drive design decisions. These should be revisited post-alpha when KB and expert system integration patterns emerge.

1. Field-level structural schemas for map/struct types
2. Semantic tags/capabilities on ports
3. Adapter/coercion registration between compatible types
4. Working-memory indexing by fact kind for expert systems
5. Cross-language contract interop (JSON Schema, Protobuf, etc.)

---

## Category-Theoretic Alignment Note

Runic's dataflow model naturally maps to **symmetric monoidal categories** where:
- Components are **morphisms** (arrows from input type to output type)
- Ports are **objects** (types/wires)
- Sequential composition is function composition along the DAG
- Parallel composition (fan-out/fan-in) is the monoidal product

The port contract system should respect this structure:
- **Identity:** a passthrough component has `in: T → out: T`
- **Composition:** connecting `A → B` and `B → C` requires `B`'s output port type ≤ `C`'s input port type
- **Product:** fan-out creates parallel wires, fan-in (Join/Reduce) merges them

The current system accidentally supports this via `:any` being the terminal object, but making it explicit through port contracts would give Runic a principled foundation for arbitrarily complex compositions without needing users to understand the theory.

The key insight: **ports are the minimal user-facing concept that bridges category-theoretic compositionality with practical UX**. Users think in terms of "this output connects to that input" — that's exactly a morphism composition. The type system on ports is just ensuring the composition is well-typed.

---

## Summary

| Gap | Severity | Fix |
|-----|----------|-----|
| Internal keys as public contract | High | Port contract layer (R1) |
| No connection-time enforcement | High | Validate in `add/3` (R2) |
| Overly lenient compatibility | High | Tighten matching (R3) |
| Workflows are opaque | High | Boundary ports (R4) |
| Facts have no type metadata | Medium | Optional `meta` field (R5) |
| Inconsistent validation | Medium | All macros validate (R6) |
| No serializable format | Medium | Normalized maps (R7) |

The path forward preserves Runic's core strengths — simplicity, composability, gradual typing, functional purity — while closing the gaps that block production use in low-code platforms, agent orchestration, and expert systems.
