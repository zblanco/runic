# Runic Documentation Coverage Audit

An actionable checklist of every public function in `Runic` and `Runic.Workflow`, their current documentation status, and recommendations for documenting, moving, or deprecating.

**Legend:**
- ✅ = Has @doc with example
- 📝 = Has @doc but missing example
- ❌ = No @doc at all
- ✔ = Done / Completed

---

## `Runic` Module (Macros / Constructor API)

All functions in `Runic` are the primary user-facing macro API. They are all documented well.

- [x] `step/1` — ✅ Comprehensive docs with multiple examples
- [x] `step/2` — ❌ No separate doc, but covered by `step/1` default args. **No action needed** (Elixir convention for default-arg delegation).
- [x] `rule/1` — ✅ Comprehensive docs with examples (basic, guards, pattern matching, given/where/then DSL)
- [x] `rule/2` — ❌ No separate doc, covered by `rule/1` default args. **No action needed.**
- [x] `condition/1` — ✅ Docs with examples
- [x] `map/1`, `map/2` — ✅ Comprehensive docs with map-reduce examples
- [x] `reduce/2`, `reduce/3` — ✅ Comprehensive docs with map-reduce examples
- [x] `accumulator/2`, `accumulator/3` — ✅ Comprehensive docs with examples
- [x] `state_machine/1` — ✅ Comprehensive docs with lock/unlock example
- [x] `workflow/0`, `workflow/1` — ✅ Comprehensive docs with pipeline, rules, hooks examples
- [x] `transmute/1` — ✅ Docs with examples
- [x] `state_of/1` — ✔ Example added showing `state_of` inside a rule condition referencing an accumulator
- [x] `step_ran?/1` — ✔ Example added showing a rule that gates on whether a prior step executed
- [x] `step_ran?/2` — ✔ Example added showing the fact-scoped variant
- [ ] **Note** Add other meta reference expressions supported and document them this way

### Runic Macro Internals (compile-time helpers, public but internal)

These are exported because they're called by macro-generated code. They should **not** be documented for end-users but should be marked `@doc false`.

- [x] `compile_meta_then_clause/6` — ✔ Marked `@doc false`
- [x] `compile_meta_when_clause/6` — ✔ Marked `@doc false`
- [x] `detect_meta_expressions/1` — ✔ Marked `@doc false`
- [x] `has_meta_expressions?/1` — ✔ Marked `@doc false`
- [x] `rewrite_meta_refs_in_ast/2` — ✔ Marked `@doc false`

---

## `Runic.Workflow` Module

### Well-Documented Public API (has docs + examples) ✅

These are in good shape. No action needed unless you want to expand coverage.

- [x] `add/2`, `add/3` — ✔ Example added
- [x] `add_step/2` — ✔ Moved to `Runic.Workflow.Private`, delegate with `@doc false`
- [x] `add_step/3` — ✔ Moved to `Runic.Workflow.Private`, delegate with `@doc false`
- [x] `add_rule/2` — ✔ Moved to `Runic.Workflow.Private`, delegate with `@doc false`
- [x] `ancestry_depth/2` — ✅ Has doc with examples
- [x] `apply_hook_fns/2` — ✅ Has doc with example (scheduler/internal use)
- [x] `apply_runnable/2` — ✅ Has doc with example (scheduler API)
- [x] `attach_after_hook/3` — ✅ Has doc with example
- [x] `build_getter_fn/1` — ✔ Moved to `Runic.Workflow.Private`, delegate with `@doc false`
- [x] `build_log/1` — ✅ Has doc with full serialize/deserialize example
- [x] `causal_depth/2` — ✅ Has doc with examples
- [x] `components/1` — ✔ Example added
- [x] `conditions/1` — ✅ Has doc with example
- [x] `draw_meta_ref_edge/4` — ✔ Moved to `Runic.Workflow.Private`, delegate with `@doc false`
- [x] `events_produced_since/2` — ✔ Example added
- [x] `execute_runnable/1` — ✔ Example added
- [x] `facts/1` — ✅ Has doc with runnable iex examples
- [x] `from_log/1` — ✔ Example added (cross-references `build_log/1`)
- [x] `get_component/2` — ✅ Has doc with iex examples and subcomponent access
- [x] `get_component!/2` — ✅ Has doc with example
- [x] `get_hooks/2` — ✔ Moved to `Runic.Workflow.Private`, delegate with `@doc false`
- [x] `invoke/3` — ✔ Example added showing three-phase invocation
- [x] `invoke_with_events/3` — ✔ Example added showing event capture
- [x] `is_runnable?/1` — ✅ Has doc with runnable iex example
- [x] `merge/2` — ✅ Has doc with runnable iex examples
- [x] `meta_dependencies/2` — ✅ Has doc with example
- [x] `meta_dependents/2` — ✅ Has doc with example
- [x] `new/1` — ✔ Example added
- [x] `next_runnables/1` — ✅ Has doc with example
- [x] `next_steps/2` — ✅ Has doc with full example
- [x] `plan/1` — ✔ Example added
- [x] `plan/2` — ✔ Example added
- [x] `plan_eagerly/1` — ✔ Example added
- [x] `plan_eagerly/2` — ✔ Example added
- [x] `prepare_for_dispatch/1` — ✅ Has doc with full scheduler example
- [x] `prepare_meta_context/2` — ✔ Moved to `Runic.Workflow.Private`, delegate with `@doc false`
- [x] `prepared_runnables/1` — ✅ Has doc with full three-phase example
- [x] `productions/1` — ✅ Has doc with iex example
- [x] `productions/2` — ✔ Example added
- [x] `productions_by_component/1` — ✔ Example added
- [x] `raw_productions/1` — ✅ Has doc with iex examples (including by-name variant)
- [x] `raw_reactions/1` — ✔ Example added
- [x] `react/1`, `react/2`, `react/3` — ✅ Has doc with examples and options
- [x] `react_until_satisfied/1`, `/2`, `/3` — ✅ Has doc with examples, options, and warnings
- [x] `reactions/1` — ✔ Example added
- [x] `root_ancestor_hash/2` — ✅ Has doc with examples
- [x] `steps/1` — ✅ Has doc with iex examples
- [x] `sub_components/2` — ✔ Example added
- [x] `to_cytoscape/1`, `/2` — ✅ Has doc with Livebook example
- [x] `to_dot/1`, `/2` — ✅ Has doc with example
- [x] `to_edgelist/1`, `/2` — ✅ Has doc with examples and options
- [x] `to_mermaid/1`, `/2` — ✅ Has doc with examples and options
- [x] `to_mermaid_sequence/1`, `/2` — ✅ Has doc with example

### Previously Undocumented Functions — Now Documented ✅

#### Public API (Documented)

- [x] `new/0` — ✔ Documented with example
- [x] `add_steps/2` — ✔ Documented with pipeline syntax explanation
- [x] `add_rules/2` — ✔ Documented with example
- [x] `attach_before_hook/3` — ✔ Documented mirroring `attach_after_hook/3`
- [x] `purge_memory/1` — ✔ Documented explaining memory cleanup
- [x] `connectable?/2`, `connectable?/3` — ✔ Documented with graph connectivity explanation
- [x] `connectables/2` — ✔ Documented explaining arity-matching component filtering
- [x] `raw_productions/2` — ✔ Covered by `raw_productions/1` doc's "By Component Name" section
- [x] `raw_productions_by_component/1` — ✔ Documented with example
- [x] `fetch_component/2` — ✔ Documented with ok/error tuple returns

#### Event Sourcing / Advanced API (Documented)

- [x] `apply_event/2` — ✔ Documented as part of event sourcing system
- [x] `apply_events/2` — ✔ Documented with event replay example
- [x] `log/1` — ✔ Documented explaining build_log + reactions combination
- [x] `add_with_events/2`, `add_with_events/3` — ✔ Documented for event-sourced construction
- [x] `log_fact/2` — ✔ Marked `@doc false` (internal, delegates to Private)

#### Moved to `Runic.Workflow.Private` (with `@doc false` delegates)

All internal graph/engine mechanics moved to `Runic.Workflow.Private` with `@doc false` delegating wrappers in `Runic.Workflow` for backwards compatibility.

- [x] `add_after_hooks/2` — ✔ Moved to Private
- [x] `add_before_hooks/2` — ✔ Moved to Private
- [x] `add_dependent_steps/2` — ✔ Moved to Private
- [x] `causal_generation/2` — ✔ Moved to Private (deprecated)
- [x] `draw_connection/4`, `draw_connection/5` — ✔ Moved to Private
- [x] `mark_runnable_as_ran/3` — ✔ Moved to Private
- [x] `matches/1` — ✔ Moved to Private
- [x] `maybe_put_component/2` — ✔ Moved to Private
- [x] `next_runnables/2` — ✔ Moved to Private
- [x] `prepare_next_generation/2` — ✔ Moved to Private (deprecated)
- [x] `prepare_next_runnables/3` — ✔ Moved to Private
- [x] `register_component/2` — ✔ Moved to Private
- [x] `root/0` — ✔ Moved to Private
- [x] `run_after_hooks/3` — ✔ Moved to Private
- [x] `run_before_hooks/3` — ✔ Moved to Private
- [x] `satisfied_condition_hashes/2` — ✔ Moved to Private
- [x] `last_known_state/2` — ✔ Moved to Private

---

## Summary

| Category | Status |
|----------|--------|
| Fully documented with examples | ✅ All done |
| Previously missing examples | ✅ Added to ~20 functions |
| Previously undocumented public API | ✅ Documented ~16 functions |
| Internal functions moved to `Runic.Workflow.Private` | ✅ ~24 functions moved |
| Runic macro internals hidden | ✅ 5 functions marked `@doc false` |

### Remaining Work

- [ ] **Document other meta reference expressions** supported beyond `state_of/1` and `step_ran?/1,2`
- [ ] **Clarify/deprecate redundancies**: `reactions/1` vs `raw_reactions/1` vs `raw_productions/1` — these overlap. Consider consolidating to `productions/1` and `raw_productions/1` only.
