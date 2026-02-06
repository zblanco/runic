# Meta-Expression Follow-Up Plan

> **Status**: Draft  
> **Scope**: Post-Phase 7 improvements and outstanding work  
> **Related**: [meta-expression-plan.md](meta-expression-plan.md)

## Table of Contents

1. [Rule Macro API Pain Points](#rule-macro-api-pain-points)
2. [Execution Timing Semantics](#execution-timing-semantics)
3. [Graph & Component Issues](#graph--component-issues)
4. [Outstanding Safety Work](#outstanding-safety-work)
5. [Performance Optimizations](#performance-optimizations)
6. [Open Questions](#open-questions)
7. [Prioritized Action Items](#prioritized-action-items)

---

## Rule Macro API Pain Points

### 1. DSL vs Keyword Options Confusion

**Problem**: Two incompatible syntaxes exist with non-obvious differences:

| Style | Syntax | Keys |
|-------|--------|------|
| DSL | `rule do given/where/then end` | `given`, `where`, `then` |
| Keyword | `rule(condition: ..., reaction: ...)` | `:condition`/`:if`, `:reaction`/`:do` |

Users attempting the intuitive but incorrect form get cryptic errors:

```elixir
# ❌ INVALID - causes compilation errors
Runic.rule(
  name: :threshold_check,
  given: event,
  where: state_of(:counter) > 10,
  then: fn %{event: e} -> {:threshold_exceeded, e} end
)

# ✅ VALID - DSL form
Runic.rule name: :threshold_check do
  given(event: e)
  where(state_of(:counter) > 10)
  then(fn %{event: e} -> {:threshold_exceeded, e} end)
end

# ✅ VALID - Keyword form
Runic.rule(
  name: :threshold_check,
  condition: fn event -> is_map(event) end,
  reaction: fn event -> {:threshold_exceeded, event} end
)
```

**Potential Solutions**:

- [ ] **Option A**: Detect `given/where/then` keys in keyword form and transform internally
- [ ] **Option B**: Improve error messages to explain the two forms clearly
- [ ] **Option C**: Deprecate keyword form in favor of DSL-only
- [x] **Option D**: Extend keyword form to accept `given/where/then` as aliases

**Recommended**: Option A or D - unify the API transparently.

I like option D since I personally prefer the keyword form and use of parens over the do/end block but we should support both transparently.

---

### 2. Pin Operator (`^`) Limitations in `where`

**Problem**: The pin operator works in `then` clauses (function bodies) but fails in `where` clauses because they're compiled as guard-style expressions.

```elixir
threshold = 100

# ❌ Fails - where clause processed as guard
rule do
  given(event: e)
  where(e.value > ^threshold)  # CompileError
  then(fn %{event: e} -> {:exceeded, e} end)
end

# ✅ Works - then is a function body
rule do
  given(event: e)
  where(e.value > 100)
  then(fn %{event: e} -> {:exceeded, e, ^threshold} end)
end
```

**Potential Solutions**:

- [x] Compile `where` clauses to function bodies when pins are detected
- [ ] Pre-evaluate pinned values and inline them into the guard AST
- [ ] Document limitation clearly and suggest workarounds
- [x] Our where clauses should not be guard clauses but functions that evaluate a boolean in their body

**Investigation Needed**: What's the full scope of expressions allowed in `where`? Guards only, or extended?

Answer: `where` clauses should support anything a function body or an if statement can rather than guard clauses which are limited to function inlining compiler checks. Here our resulting Condition should be rewritten and depend on the variable using our Closure setup as any other invokable does already.

---

### 3. Pattern Matching in `given` Clauses

**Problem**: Direct map pattern matching is unsupported - only keyword bindings work.

```elixir
# ❌ Unsupported
rule do
  given(%{item: i, quantity: q})
  where(q > 0)
  then(fn _ -> {:valid, i} end)
end

# ✅ Supported
rule do
  given(item: %{item: i, quantity: q})
  where(q > 0)
  then(fn %{item: _} -> {:valid, i} end)
end
```

**Potential Solutions**:

- [x] Extend `compile_given_clause/1` to detect and handle map patterns
- [x] Support tuple patterns for multi-input matching
- [ ] Document current limitations

`given` is a pattern declaration to similar to a function head where they might bind variables as with elixir pattern matching so it should support anything a pattern match / guard clause might in the `given` clause. Note that the `where` clause **is not a guard** it is compiled to a function that takes the pattern of the given and evaluates a boolean.

---

## Execution Timing Semantics

### The "Off-by-One" Effect

**Problem**: `state_of(:accumulator)` evaluates during the **prepare phase**, reflecting state *before* the triggering fact updates the accumulator.

```elixir
# Given: counter accumulator starts at 0
# Input: fact with value 5

rule do
  given(event: e)
  where(state_of(:counter) >= 5)  # Sees 0, not 5!
  then(fn _ -> :threshold_reached end)
end
```

The rule won't fire on the input that brings the counter to 5 - it fires on the *next* input.

**Root Cause**: In Runic's dataflow model, the prepare phase runs before apply. The accumulator hasn't processed the current fact yet.

**User Expectations**: Often users expect conditions to see the *result* of processing the current fact.

**Potential Solutions**:

- [ ] **Document clearly**: This is semantically correct for causal dataflow
- [ ] **Add `state_after/1`**: New meta expression for post-update state (requires speculative execution)
- [ ] **Topology hints**: Allow users to declare ordering constraints
- [ ] **Two-phase rules**: Separate "update" rules from "check" rules

**Questions**:
- Is speculative execution worth the complexity?
- How do Differential Dataflow / Naiad handle this?

**Answer**: Its okay that this rule fires twice (for the initial state setup of the accumulator then the reaction to the accumulators next state). 

---

## Graph & Component Issues

### 1. Deferred Edge Creation

**Problem**: If a rule referencing `state_of(:target)` is added before the target component exists, `:meta_ref` edges aren't created. The graph topology is incomplete.

```elixir
workflow = Workflow.new()

# Rule added first - references :counter which doesn't exist yet
|> Workflow.add(rule_using_state_of_counter)

# Accumulator added later - edge NOT created
|> Workflow.add(counter_accumulator)
```

**Current Behavior**: `prepare_meta_context` can still resolve at runtime using stored `meta_refs`, but graph traversal (introspection, serialization) is incomplete.

**Potential Solutions**:

- [ ] **Lazy edge creation**: Patch edges during first `react/2` call
- [ ] **Explicit finalize**: Add `Workflow.finalize/1` that validates and patches topology
- [ ] **Forward declaration**: Allow `Workflow.declare(:counter, :accumulator)` before adding
- [ ] **Strict ordering**: Error if target doesn't exist at rule addition time

**Recommended**: Explicit finalize pass - keeps construction flexible, validates before execution.

**Answer**: We should throw an exception if a component is added that depends on an unnamed component or sub-component in the workflow - this includes meta references. Be sure the exception includes context of why its erroring and for what reference.

---

### 2. Composite Component Registration

**Fixed in Phase 6**: StateMachine now registers subcomponents and creates `:component_of` edges.

**Remaining Question**: Are there other composite components with similar gaps?

**Action Items**:

- [ ] Audit `Map`, `Reduce`, `Join` for proper subcomponent registration
- [ ] Document the pattern for custom composite components
- [ ] Consider a `CompositeComponent` behaviour/protocol

**Answer**: We're going to reimplement state machines now that our meta-reference system is in place so don't worry about its lacking state for now.

---

### 3. Vertex Lookup Inconsistency

**Problem**: Edge `v2` sometimes contains the full struct, but `workflow.graph.vertices` is keyed by hash. Causes lookup failures.

```elixir
# Sometimes edge.v2 is a hash
Map.get(workflow.graph.vertices, edge.v2)  # Works

# Sometimes edge.v2 is a struct
Map.get(workflow.graph.vertices, edge.v2)  # Returns nil
```

**Current Fix**: Lookups now check and resolve by hash when struct is encountered.

**Root Cause**: Inconsistent edge storage - not addressed.

**Action Items**:

- [ ] Audit all `Workflow.draw_connection` calls for consistency
- [ ] Normalize edge storage to always use hashes
- [ ] Add assertions in edge creation to catch inconsistencies early

---

## Outstanding Safety Work

### Circular Meta Reference Detection

**Status**: Deferred - no implementation exists.

**Risk**: Infinite loops when components mutually reference each other's state:

```
Rule A: where state_of(:B) > 10 → produces fact → updates :B
Rule B: where state_of(:A) > 10 → produces fact → updates :A
```

**Detection Strategies**:

- [ ] **Compile-time**: Graph cycle detection in `Component.connect`
- [ ] **Runtime**: Track activation chain, error on depth limit
- [ ] **Hybrid**: Warn at compile-time, hard limit at runtime

**Implementation Sketch**:

```elixir
# In Component.connect or Workflow.add
def detect_meta_cycles(workflow, component) do
  meta_deps = get_meta_dependencies(component)
  
  for dep <- meta_deps do
    if creates_cycle?(workflow, component, dep) do
      raise Runic.CyclicMetaReferenceError, 
        "#{component.name} -> #{dep} creates a cycle"
    end
  end
end
```

**Questions**:
- Are all cycles bad? Some might be intentional feedback loops
- Should we allow cycles with explicit opt-in (`allow_cycle: true`)?

---

## Performance Optimizations

### Materialized Projections for Collection Meta Expressions

**Problem**: `Enum.sum(all_values_of(:scores))` scans O(n) facts every invocation.

**Current Approach**: Naive - acceptable for moderate workflows.

**Proposed Optimization**: Auto-generate hidden Accumulators that maintain aggregates incrementally.

**Before (naive)**:
```elixir
rule do
  given(x: _)
  where(Enum.sum(all_values_of(:scores)) > 100)
  then(fn _ -> :threshold end)
end
```

**After (optimized topology)**:
```
:scores step
    │
    │ :produced
    ▼
:__scores_sum_projection (auto-generated accumulator)
    │                     init: 0
    │                     reducer: acc + x
    │ :meta_projection
    ▼
:rule condition
    reads state_of(:__scores_sum_projection)
```

**Candidate Patterns**:

Support explicit common query aggregates like sum, count, max, min and compile them into various other nodes like map/reduce/accumulator/step to compute the value in parlance with predicate pushdown and other query engine optimizer techniques.

| Expression | Projection |
|-----------|------------|
| `sum(all_values_of(:x))` | `fn v, acc -> acc + v end` |
| `count(all_values_of(:x))` | `fn _, acc -> acc + 1 end` |
| `length(all_values_of(:x))` | Same as count |
| `max(all_values_of(:x))` | `fn v, acc -> max(v, acc) end` |
| `min(all_values_of(:x))` | `fn v, acc -> min(v, acc) end` |

**Implementation Phases**:

1. [ ] Benchmark current approach - when does it become a bottleneck?
2. [ ] Detect optimizable patterns in AST during compilation
3. [ ] Generate projection accumulators with `:meta_projection` edges
4. [ ] Rewrite expression to use `state_of(:__projection)`

**Research References** (from meta-expression-plan.md:1436+):
- Differential Dataflow: Incremental computation with deltas
- Adapton: Demand-driven incremental caching
- Spark Catalyst / Polars: Lazy DAG optimization

---

## Open Questions

### API Design

1. **Unification**: Can we merge keyword and DSL forms without breaking changes?
2. **Guard semantics**: Should `where` support full Elixir or stay guard-like?
3. **Expressiveness vs Safety**: How much power in conditions before they become footguns?

### Semantics

4. **Eager vs Lazy**: Should meta expressions resolve at prepare time or support lazy evaluation?
5. **Causal ordering**: Is the "off-by-one" effect correct, or should we provide alternatives?
6. **Cycle handling**: Are all meta-cycles errors, or are some valid feedback loops?

### Architecture

7. **Composite pattern**: Should we formalize how complex components register subcomponents?
8. **Edge consistency**: Hash-only edges, or allow struct references with normalization?
9. **Projection scope**: Auto-optimize all patterns, or require explicit hints?

---

## Prioritized Action Items

### High Priority (Correctness/Safety)

- [ ] **Circular reference detection**: Implement at least runtime detection with depth limits
- [ ] **Deferred edge patching**: Add `Workflow.finalize/1` or lazy edge creation
- [ ] **Vertex lookup normalization**: Audit and fix edge storage inconsistency

Also:

- [ ] **Pin operator in `where`**: Investigate compilation to function body
- [ ] **Map pattern in `given`**: Extend `compile_given_clause/1`

### Medium Priority (Developer Experience)

- [ ] **API unification**: Support `given/where/then` in keyword form
- [ ] **Better error messages**: Explain DSL vs keyword syntax on compilation errors
- [ ] **Documentation**: Document timing semantics, limitations, patterns

### Lower Priority (Performance)

- [ ] **Benchmark collection meta expressions**: Establish when optimization is needed
- [ ] **Materialized projections prototype**: Implement for `Enum.sum` as proof of concept

### Exploratory

- [ ] **`state_after/1`**: Explore post-update state access semantics

---

## Implementation Notes

### Testing Strategy

Each fix should include:
1. Unit test for the specific case
2. Integration test with full workflow execution
3. Serialization round-trip test if graph topology changes

### Compatibility

- Maintain backward compatibility with existing working code
- New features should be opt-in where possible
- Deprecation warnings before removal (if any)

### Files Likely to Change

- `lib/runic.ex` - Macro compilation, API surface
- `lib/workflow.ex` - Edge creation, finalization
- `lib/workflow/component.ex` - `connect` implementations, cycle detection
- `lib/workflow/rule.ex` - Rule struct, meta_refs handling

---

## Implementation Phases

### Phase 1: `where` Clause Function Body Compilation

**Goal**: Compile `where` clauses as function bodies instead of guards, enabling full Elixir expressions and pin operators.

**Current Behavior**: `where` compiles to guard-style expressions with limitations.

**Target Behavior**: `where` compiles to a `Condition` with a function body that returns a boolean.

#### Tasks

- [x] 1.1 Audit `compile_meta_when_clause/3` and `compile_when_clause/1` in `lib/runic.ex`
- [x] 1.2 Refactor to generate function body: `fn bindings -> expression end` returning boolean
- [x] 1.3 Support pin operator (`^var`) via existing `traverse_expression/2` for Closure bindings
- [x] 1.4 Update Condition struct to use function-based evaluation (may already work)
- [x] 1.5 Tests:
  - [x] `where(^threshold > 10)` with pinned variable
  - [x] `where(String.starts_with?(name, "prefix"))` - non-guard function call
  - [x] `where(Enum.any?(items, &(&1 > 0)))` - higher-order function
  - [x] Existing guard-style expressions still work
- [x] 1.6 Serialization: Ensure Closure captures bindings for round-trip

**Files**: `lib/runic.ex`, `lib/workflow/condition.ex`

---

### Phase 2: Extended `given` Pattern Matching

**Goal**: Support full pattern matching in `given` clauses like function heads.

**Current Behavior**: Only keyword bindings supported (`given(event: e)`).

**Target Behavior**: Support map patterns, tuple patterns, and nested destructuring.

#### Syntax Support

```elixir
# Map pattern (direct)
given(%{item: i, quantity: q})

# Tuple pattern (multi-input)
given({:ok, value})

# Nested destructuring
given(%{user: %{name: name, age: age}})

# Keyword (existing - keep working)
given(event: e, context: ctx)
```

#### Tasks

- [x] 2.1 Audit `compile_given_clause/1` in `lib/runic.ex`
- [x] 2.2 Add clause for map pattern AST: `{:%{}, _, pairs}`
- [x] 2.3 Add clause for tuple pattern AST: `{:{}, _, elements}` or `{a, b}`
- [x] 2.4 Extract bound variables from patterns for use in `where`/`then`
- [x] 2.5 Generate appropriate match expression for Condition/Step
- [x] 2.6 Tests:
  - [x] `given(%{item: i})` binds `i`
  - [x] `given({:event, type, payload})` binds `type`, `payload`
  - [x] `given(%{nested: %{value: v}})` binds `v`
  - [x] Pattern match failure produces `nil` fact (rule doesn't fire)
- [ ] 2.7 Documentation: Update rule macro docs with new patterns

**Files**: `lib/runic.ex`

---

### Phase 3: Keyword API Unification

**Goal**: Accept `given/where/then` keys in keyword form, transform to DSL internally.

**Current Behavior**: Keyword form only accepts `:condition`/`:if` and `:reaction`/`:do`.

**Target Behavior**: Both forms work transparently.

```elixir
# Both produce identical Rule structs
Runic.rule(
  name: :check,
  given: %{value: v},
  where: v > 10,
  then: fn %{value: v} -> {:big, v} end
)

Runic.rule name: :check do
  given(%{value: v})
  where(v > 10)
  then(fn %{value: v} -> {:big, v} end)
end
```

#### Tasks

- [x] 3.1 In `defmacro rule(opts) when is_list(opts)`, detect `given/where/then` keys
- [x] 3.2 Transform keyword opts to synthetic DSL block AST
- [x] 3.3 Delegate to `compile_given_when_then_rule/3`
- [x] 3.4 Preserve `:name`, `:inputs`, `:outputs` options
- [x] 3.5 Error if mixing styles (e.g., `given:` with `condition:`)
- [x] 3.6 Tests:
  - [x] Keyword form with `given/where/then` produces correct Rule
  - [x] Keyword form with meta expressions works
  - [x] Pin operators in keyword form work
  - [x] Error message for mixed styles is clear
- [ ] 3.7 Update macro docs with unified examples

**Files**: `lib/runic.ex`

---

### Phase 4: Strict Meta Reference Validation

**Goal**: Throw descriptive exceptions when adding components with unresolvable references.

**Current Behavior**: Missing references silently produce incomplete graph topology.

**Target Behavior**: Fail fast with helpful error messages.

```elixir
workflow = Workflow.new()
|> Workflow.add(rule_using_state_of_counter)  # Raises!

# ** (Runic.UnresolvedReferenceError) Cannot add rule :my_rule - 
#    meta reference state_of(:counter) targets component :counter 
#    which does not exist in the workflow.
#    
#    Hint: Add the :counter component before adding this rule, or
#    use a forward declaration.
```

#### Tasks

- [x] 4.1 Define `Runic.UnresolvedReferenceError` exception
- [x] 4.2 In `Component.connect/2` for Rule, validate all `meta_refs` targets exist
- [x] 4.3 Include context in error: rule name, reference kind, target name
- [x] 4.4 Handle subcomponent references `{:parent, :child}` - both must exist
- [x] 4.5 Tests:
  - [x] Adding rule with missing target raises with clear message
  - [x] Adding rule after target works (no regression)
  - [x] Subcomponent reference to missing parent raises
  - [x] Subcomponent reference to missing child raises
- [ ] 4.6 Consider: Optional `Workflow.add(component, validate: false)` for advanced use?

**Files**: `lib/workflow/component.ex`, `lib/runic/exceptions.ex` (new?)

---

### Phase 5: Edge Storage Normalization ** NOT APPLICABLE **

**Goal**: Ensure all edges use hashes consistently, eliminating lookup failures.

**Current Behavior**: `edge.v2` sometimes contains struct, sometimes hash.

**Target Behavior**: Edges always store hashes; lookups are predictable.

#### Tasks

<!-- - [ ] 5.1 Audit all `Workflow.draw_connection/4` call sites
- [ ] 5.2 Ensure `draw_connection` normalizes to hash: `component.hash` not `component`
- [ ] 5.3 Add assertion in `draw_connection`: raise if vertex is struct, not hash
- [ ] 5.4 Update any code that passes full structs to pass hashes
- [ ] 5.5 Review `meta_dependencies/2` and `meta_dependents/2` - remove hash resolution workarounds
- [ ] 5.6 Tests:
  - [ ] All edge `v1`/`v2` fields are integers (hashes)
  - [ ] `Workflow.get_component` works without special casing -->

**Files**: `lib/workflow.ex`, `lib/workflow/component.ex`

**Investigated** found as a non-issue with no changes needed

---

### Phase 6: Circular Reference Detection (Runtime)

**Goal**: Prevent infinite loops from mutual meta references with runtime depth limiting.

**Current Behavior**: No protection - infinite loops possible.

**Target Behavior**: Runtime detection with configurable depth limit.

#### Tasks

- [ ] 6.1 Add `:meta_activation_depth` to `CausalContext` or Workflow state
- [ ] 6.2 In `prepare_meta_context/2`, increment depth counter
- [ ] 6.3 Check against limit (default: 100?), raise `Runic.CyclicActivationError`
- [ ] 6.4 Include activation chain in error for debugging
- [ ] 6.5 Optional: Configurable limit via `Workflow.new(max_meta_depth: 50)`
- [ ] 6.6 Tests:
  - [ ] Simple A→B→A cycle detected and raises
  - [ ] Deep but non-cyclic chain works up to limit
  - [ ] Custom limit respected
- [ ] 6.7 Future: Consider compile-time detection as enhancement

**Files**: `lib/workflow.ex`, `lib/workflow/invokable.ex`

---

### Phase 7: Materialized Projections (Exploratory)

**Goal**: Prototype automatic optimization for collection aggregates.

**Scope**: `sum(all_values_of(:x))` only - prove the pattern works.

#### Tasks

- [ ] 7.1 Benchmark naive `all_values_of` with 100, 1000, 10000 facts
- [ ] 7.2 Define `sum/1`, `count/1`, `max/1`, `min/1` as recognized meta-aggregate functions
- [ ] 7.3 In `detect_meta_expressions/1`, detect pattern `agg_fn(all_values_of(:target))`
- [ ] 7.4 Generate hidden accumulator with appropriate reducer
- [ ] 7.5 Rewrite expression to `state_of(:__target_sum_projection)`
- [ ] 7.6 Create `:meta_projection` edge type
- [ ] 7.7 Ensure projection updates before dependent rule evaluates
- [ ] 7.8 Tests:
  - [ ] `sum(all_values_of(:scores))` produces correct results
  - [ ] Performance improved vs naive (benchmark)
  - [ ] Serialization handles projection accumulators
- [ ] 7.9 Document pattern and limitations

**Files**: `lib/runic.ex`, `lib/workflow.ex`

---

## Phase Dependencies

```
Phase 1 (where as function) ──┐
                              ├──► Phase 3 (API unification)
Phase 2 (given patterns) ─────┘

Phase 4 (strict validation) ──► Independent

Phase 5 (edge normalization) ──► Phase 6 (cycle detection)

Phase 7 (projections) ──► Requires Phases 1-5 stable
```

**Recommended Order**: 1 → 2 → 3 → 4 → 5 → 6 → 7

Phases 1-3 can be done as a unit (rule macro improvements).
Phases 4-6 can be done as a unit (graph safety).
Phase 7 is optional/exploratory.
