## Implementation Plan: First-Class Named Conditions

### Phase 1 — Upgrade the Condition Struct & `Runic.condition` Macro

**Files:** [lib/workflow/condition.ex](file:///home/doops/wrk/runic/lib/workflow/condition.ex), [lib/runic.ex](file:///home/doops/wrk/runic/lib/runic.ex#L358-L396)

1. **Add `:name` and `:closure` fields** to the `Condition` struct (alongside existing `:hash`, `:work`, `:arity`, `:meta_refs`).

2. **Convert `Runic.condition/1` and `Runic.condition/2` from `def` to `defmacro`**, following the Step macro pattern:
   - `condition(fn x -> x > 10 end)` — anonymous function form
   - `condition(fn x -> x > 10 end, name: :ham)` — with options
   - `condition({M, F, A})` — captured function form (can remain a def or dispatch to `Condition.new`)
   - Traverse the AST with `traverse_expression/2` to handle `^` pin bindings.
   - Build a `%Closure{}` via `build_closure/3`.
   - Compute `hash` from `closure.hash` (with bindings) or `Components.fact_hash(source)` (without), mirroring Step's dual-path pattern.
   - Compute `work_hash` from normalized work AST + bindings for content-addressability.
   - Generate a default name via `default_component_name("condition", hash)` when no name is provided.

3. **Keep `Condition.new/1` as the runtime struct constructor** for internal use (e.g., inside `workflow_of_rule/2` which builds conditions from AST at macro expansion time). Callers that currently build `Condition.new(work: ..., hash: ..., arity: ...)` continue to work unchanged — they just won't have closures or names unless explicitly provided.

4. **Breaking change audit:** Search all call-sites of `Runic.condition(fun)` (the current `def`). Since it's being promoted to a macro, any call from non-macro contexts (e.g., passing a runtime variable function) needs to use `Condition.new(fun)` directly instead. Document this.

---

### Phase 2 — Component Protocol for Condition

**Files:** [lib/workflow/component.ex](file:///home/doops/wrk/runic/lib/workflow/component.ex)

Implement `Runic.Component` for `Runic.Workflow.Condition`:

- **`connect/3`**: Add the condition node to the workflow graph, register it as a component, draw a `:component_of` edge. When `to` is `Root`, connect from root; otherwise connect from the specified parent. Handle `meta_refs` edge creation (reuse the same pattern from the Rule implementation).
- **`connectable?/2`**: Permissive — conditions gate flow, so most connections are valid.
- **`hash/1`**: Return `condition.hash`.
- **`source/1`**: Return `condition.closure.source` (nil if no closure).
- **`inputs/1`**: `[condition: [type: :any, doc: "Input value to evaluate"]]`.
- **`outputs/1`**: `[condition: [type: :any, doc: "Passthrough value when satisfied"]]` — a condition gates, it doesn't transform, so output type matches input.

This enables: `Workflow.new() |> Workflow.add(condition)`.

---

### Phase 3 — Transmutable Protocol for Condition

**Files:** [lib/workflow/transmutable.ex](file:///home/doops/wrk/runic/lib/workflow/transmutable.ex)

Implement `Runic.Transmutable` for `Runic.Workflow.Condition`:

- **`to_workflow/1`**: Wrap the condition in a new workflow via `Workflow.new() |> Workflow.add_step(condition)`.
- **`to_component/1`**: Return the condition itself.
- **`transmute/1`**: Delegate to `to_workflow/1`.

---

### Phase 4 — Condition Reference Markers & Boolean Expression Compilation

**Files:** [lib/runic.ex](file:///home/doops/wrk/runic/lib/runic.ex) (rule DSL compilation), new file `lib/workflow/condition_ref.ex`

This is the core of the feature. Scope to **`and`-only** in v1; reject `or` with a clear error.

1. **Create `%Runic.Workflow.ConditionRef{name: atom()}`** — a lightweight compile-time placeholder struct. This is *not* a graph vertex; it exists only during macro expansion to represent `condition(:ham)` inside a `where` clause before the condition is resolved at connect-time.

2. **Add `condition(:name)` detection to the `where` clause compiler** in `compile_given_when_then_rule/3`:
   - Add `:condition` to the meta-expression-like detection, but handle it distinctly. When the `where` clause is walked, `condition(:ham)` is recognized as a condition reference — not expanded into a `%Condition{}` struct.
   - Plain sub-expressions like `x >= 2` without `condition(...)` calls compile as inline `Condition.new(...)` nodes (the existing behavior).

3. **Boolean `and` decomposition**:
   - When the `where` clause is `condition(:ham) and x >= 2`:
     - The top-level `{:and, _, [lhs, rhs]}` AST is detected.
     - `lhs` resolves to `ConditionRef{name: :ham}`.
     - `rhs` compiles to an inline `Condition.new(work: fn input -> ... end, hash: ..., arity: 1)`.
     - A `Conjunction` is created referencing both (the ref's hash is deferred — use a placeholder or the ref name for now).
   - The rule's internal workflow stores: the inline condition node, a `ConditionRef` marker for `:ham`, and the `Conjunction` node pointing downstream to the reaction `Step`.
   - `rule.condition_hash` points to the Conjunction's hash.

4. **Conjunction hash with unresolved refs**: Extend `Conjunction` to store `condition_refs: [ConditionRef.t()]` alongside `condition_hashes`. The conjunction hash is computed from a sorted list of `{:hash, int} | {:ref, atom}` tuples — stable at compile-time. At connect-time (Phase 5), refs are resolved to hashes and `condition_hashes` is populated for runtime evaluation.

5. **Error on `or`**: If the `where` clause contains `{:or, _, _}`, raise `ArgumentError` with a message like "or expressions in where clauses with condition references are not yet supported." *(Lifted in Phase 4b.)*

---

### Phase 4b — `or` Expression Support in Boolean Where Clauses

**Files:** [lib/runic.ex](file:///home/doops/wrk/runic/lib/runic.ex) (rule DSL compilation), [lib/workflow/conjunction.ex](file:///home/doops/wrk/runic/lib/workflow/conjunction.ex)

In dataflow pattern-matching evaluation, an `or` is simply **another path to the reaction**. Unlike `and` (which requires a `Conjunction` gate that waits for all conditions), `or` means whichever condition is satisfied first can activate the downstream step. The runtime already deduplicates via `mark_runnable_as_ran` — a reaction won't execute twice for the same input fact.

#### Dataflow Model

```
# and: condition_a ──┐
#                     ├─ Conjunction ── reaction
#      condition_b ──┘
#
# or:  condition_a ──┬── reaction
#      condition_b ──┘
```

An `and` converges through a `Conjunction` gate. An `or` is just multiple independent flow edges into the same reaction step — no gate needed.

#### Implementation

1. **Remove the `or` rejection** from `compile_given_when_then_rule_with_condition_refs`. Instead, handle `or`/`||` as a first-class boolean operator alongside `and`/`&&`.

2. **Extend `flatten_and_chain` → `flatten_boolean_tree`**: Walk the where clause AST and produce a boolean IR rather than a flat list:
   - `{:and, [part, ...]}` — all parts must be satisfied (existing Conjunction behavior)
   - `{:or, [part, ...]}` — any part may activate the reaction
   - `{:inline, expr}` — an inline condition expression
   - `{:ref, atom()}` — a condition reference

   For Phase 4b, support **top-level `or`** and **`or` of `and` groups** (CNF-like). Nested mixed expressions like `(a and b) or (c and d)` decompose naturally:
   - Two `and` groups, each producing a Conjunction
   - Both Conjunctions independently flow to the reaction

3. **Workflow construction for `or`**:
   - Each top-level `or` branch compiles independently:
     - A bare inline expression → a single `Condition` node flowing to the reaction
     - A bare `condition(:name)` ref → a `ConditionRef` stored on the rule, wired at connect-time to flow directly to the reaction
     - An `and` group → a `Conjunction` node (same as Phase 4) flowing to the reaction
   - All branches share the same reaction `Step` vertex — multiple flow edges in, one step out
   - `rule.condition_hash` can point to a new lightweight **`Disjunction`** node (or simply to the first branch; see design choice below)

4. **Design choice — `Disjunction` struct vs. multi-parent reaction**:

   **Option A (simpler, recommended for v1):** No `Disjunction` struct. The rule's internal workflow wires each `or` branch directly to the reaction step. `rule.condition_hash` is set to a synthetic hash derived from the sorted hashes of all branches. The runtime doesn't need a new node type — it just sees multiple conditions/conjunctions independently flowing to the reaction, and `mark_runnable_as_ran` prevents double execution.

   **Option B (richer, for future):** Create `%Disjunction{branch_hashes: MapSet.t()}` as a logical marker. Its `Invokable` implementation activates the reaction when *any* branch hash appears in `satisfied_conditions`, then marks itself as ran to prevent re-activation. This provides a single `condition_hash` for the rule and cleaner graph introspection, at the cost of a new struct + Invokable impl.

   **Recommendation:** Start with Option A. The runtime already handles multiple parents naturally — `prepare_next_runnables` will schedule the reaction when any upstream condition is satisfied, and `mark_runnable_as_ran` prevents it from running again for the same fact.

5. **`condition_refs` on branches**: When `or` branches contain `condition(:name)` refs, each ref is stored alongside the branch it belongs to. At connect-time (Phase 5), resolution wires the referenced condition's output to the appropriate target:
   - If the ref is in a standalone `or` branch → wire to the reaction directly
   - If the ref is in an `and` group → wire to that group's `Conjunction`

6. **Hash stability**: The rule's `condition_hash` is computed from a sorted representation of all branches — `[{:or, [{:and, [hash1, {:ref, :ham}]}, {:inline, hash2}]}]` — so it's deterministic at compile-time regardless of branch order.

#### Examples

```elixir
# Simple or: either condition activates the reaction
Runic.rule do
  given(value: x)
  where(x > 100 or x < 0)
  then(fn %{value: v} -> {:out_of_range, v} end)
end
# Produces: condition(x>100) ──┬── reaction
#           condition(x<0)  ──┘

# Or with condition refs
Runic.rule do
  given(value: x)
  where(condition(:premium) or x > 1000)
  then(fn %{value: v} -> {:apply_discount, v} end)
end
# Produces: ref(:premium)      ──┬── reaction  (ref wired at connect-time)
#           condition(x>1000)  ──┘

# Mixed and/or
Runic.rule do
  given(value: x)
  where((condition(:ham) and x >= 2) or condition(:vip))
  then(fn %{value: v} -> {:result, v} end)
end
# Produces: condition(x>=2) ── Conjunction(:ham + inline) ──┬── reaction
#           ref(:vip)                                       ──┘
```

#### Tests

1. Simple `or` of two inline conditions — verify both paths activate reaction independently
2. `or` with condition refs — verify ref resolution wires to reaction
3. `and` inside `or` — verify conjunction gates within each `or` branch
4. Deduplication — verify reaction runs only once when multiple `or` branches are satisfied for the same fact
5. Backward compatibility — existing `and`-only and no-ref rules unaffected

---

### Phase 5 — Connect-Time Resolution of Condition References

**Files:** [lib/workflow/component.ex](file:///home/doops/wrk/runic/lib/workflow/component.ex) (Rule's `connect/3`)

When a Rule with condition references is added to a workflow:

1. **Resolve `ConditionRef` names to existing workflow vertices**:
   - In `Component.connect/3` for Rule, after merging the rule's internal workflow, walk the graph for any `ConditionRef` nodes.
   - Look up each ref by name via `Workflow.get_component(workflow, ref_name)`.
   - If not found, raise `Runic.UnresolvedReferenceError` (reuse existing exception pattern from meta_ref resolution).

2. **Wire flow edges**:
   - The referenced condition must receive the same input fact as the rule. Connect the rule's upstream parent to the referenced condition via a `:flow` edge (if not already connected).
   - Connect the referenced condition to the Conjunction via a `:flow` edge.
   - Update the Conjunction's `condition_hashes` MapSet to include the resolved hash.

3. **Graph vertex reuse**: When resolving, reuse the *existing vertex instance* from the workflow graph — do not create a new `%Condition{}` with the same hash, as libgraph uses structural equality for vertex identity.

4. **Remove `ConditionRef` placeholder vertices** from the graph after resolution (they served their purpose as compile-time markers).

---

### Phase 6 — Tests & Documentation

**Files:** new test file `test/condition_component_test.exs`

1. **Standalone condition tests**: Create named conditions, add to workflow, verify they appear as components, verify they gate downstream steps.
2. **Condition reference in rules**: `condition(:ham) and x >= 2` — verify correct subgraph (two conditions + conjunction + reaction), verify runtime behavior.
3. **Shared condition across rules**: Two rules referencing `condition(:ham)` — verify the condition is evaluated once, both rules' conjunctions observe the same satisfaction.
4. **Content-addressable hashing**: Same condition source + bindings → same hash. Different bindings → different hash.
5. **Pinned variables**: `threshold = 10; Runic.condition(fn x -> x > ^threshold end)` — verify hash changes with threshold value.
6. **Error cases**: referencing a condition not in the workflow raises `UnresolvedReferenceError`; using `or` raises `ArgumentError`.

---

### Breaking Changes Summary

| Change | Migration |
|--------|-----------|
| `Runic.condition/1` becomes a macro | Call-sites passing runtime function variables switch to `Condition.new(fun)` |
| `Condition` struct gains `:name`, `:closure` fields | Non-breaking (new optional fields default to nil) |

### Dependency Order

Phase 1 → Phase 2 → Phase 3 (these three can be landed incrementally). Phase 4 depends on Phase 1. Phase 5 depends on Phases 2 and 4. Phase 6 spans all phases (write tests as each phase lands).