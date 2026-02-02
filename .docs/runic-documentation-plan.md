# Runic Documentation Plan

## Overview

This document outlines a comprehensive documentation improvement plan for Runic, prioritized by anticipated user interaction frequency. The goal is to make Runic approachable and useful to developers wanting to understand and use it for workflow composition.

---

## Progress Tracking

### ✅ Phase 1: Core API Docs (COMPLETED)

**Runic Module:**
- [x] `Runic.step/1`, `Runic.step/2` - Full doctests added with examples for arities, pinned variables, captured functions, options, and workflow integration
- [x] `Runic.rule/1`, `Runic.rule/2` - Full doctests with guard clauses, pattern matching, separated condition/reaction, multi-arity, and workflow integration
- [x] `Runic.workflow/1` - Doctests with pipeline syntax, rules integration, and hooks examples
- [x] `Runic.state_machine/1` - Doctests with basic usage, options documentation, reactor patterns
- [x] `Runic.map/1`, `Runic.map/2` - Doctests with map-reduce pattern, pipeline integration
- [x] `Runic.reduce/3` - Doctests with map-reduce pattern and documentation of `:map` option
- [x] `Runic.accumulator/3` - Doctests with comparison to reduce, captured variables
- [x] `Runic.transmute/1` - Doctests showing conversion to workflow
- [x] `Runic.condition/1` - Doctests with MFA syntax and use cases

**Workflow Module:**
- [x] `Workflow.react/2`, `Workflow.react/3` - Doctests with options documentation
- [x] `Workflow.react_until_satisfied/3` - Full doctests with warnings about infinite loops
- [x] `Workflow.productions/1` - Doctests with ancestry explanation
- [x] `Workflow.raw_productions/1` - Doctests with by-component retrieval
- [x] `Workflow.facts/1` - Doctests with ancestry documentation
- [x] `Workflow.build_log/1` - Non-doctest example for serialization
- [x] Fixed broken doctests in serialization APIs

**Doctests Enabled:**
- `doctest Runic` in `test/runic_test.exs`
- `doctest Runic.Workflow` in `test/workflow_test.exs`

### ✅ Phase 2: Usage Artifacts (COMPLETED)
- [x] Create `guides/cheatsheet.md` - Quick reference for all core APIs
- [x] Create `guides/usage-rules.md` - Core concepts, when to use, do's/don'ts, patterns
- [x] Configure ExDocs in `mix.exs` with guides and module groupings
- [x] Add `ex_doc` dependency

### ✅ Phase 3: Advanced API Docs (COMPLETED)
- [x] Three-phase execution APIs - Comprehensive moduledoc in `Runic.Workflow` with examples
- [x] Workflow composition APIs - `merge/2`, `add/3` docs with doctests
- [x] Introspection APIs - `get_component/2`, `steps/1`, `conditions/1`, `is_runnable?/1`, `next_runnables/1`, `next_steps/2` all documented with examples

### 🔲 Phase 4: Protocol Docs (PENDING)
- [ ] Invokable protocol
- [ ] Component protocol
- [ ] Transmutable protocol

### 🔲 Phase 5: Guides (PENDING)
- [ ] Scheduler GenServer guide
- [ ] Error handling guide

---

## Notes on APIs Mentioned That Don't Exist Yet

The following features were mentioned in the documentation plan but **do not currently exist** and would need TDD implementation:

1. **`:inputs` / `:outputs` schema validation** - These options exist on component structs but are not currently used for runtime type checking. They are documented as "reserved for future schema-based type compatibility".

2. **`:async_only` option for `react/3`** - Mentioned in Guide 2 plan but not implemented. Would allow specifying which components to execute async.

3. **`:supervisor` option for `react/3`** - Mentioned in Priority 2 options but not implemented.

4. **Conflict resolution for rules** - Mentioned in Guide 5. Currently all matching rules fire; no priority/conflict resolution mechanism exists.

5. **`Runic.join/1` macro** - The `Join` module exists but isn't exposed via a macro. Users create joins implicitly via `add/3` with a list of parents.

---

## Priority 1: Core Construction API (`Runic` module)

These macros are the primary entry point for users and should have the most thorough documentation.

### 1.1 `Runic.step/1`, `Runic.step/2` (Lines ~26-310)

**Current State:** Has a good `@doc` with examples but missing coverage of all options.

**Improvements Needed:**
- Add doctests for basic usage
- Document `:inputs` and `:outputs` options (schema-based type compatibility)
- Show captured function syntax (`&Mod.fun/arity`)
- Example of multi-arity steps (2-arity with two inputs)
- Example of pinned variables (`^outer_value` syntax)
- Example of connecting named steps in workflows

**Proposed Doctest Example:**
```elixir
iex> require Runic
iex> step = Runic.step(fn x -> x * 2 end)
iex> Step.run(5)
10
```

### 1.2 `Runic.rule/1`, `Runic.rule/2` (Lines ~437-726)

**Current State:** Has extensive docs with multiple syntax examples.

**Improvements Needed:**
- Add doctests for `Rule.check/2` and `Rule.run/2`
- Document the given/where/then DSL more explicitly
- Show guard-based pattern matching examples
- Example combining rules with other components
- Document `:inputs` / `:outputs` options

**Proposed Doctest Example:**
```elixir
iex> require Runic
iex> import Runic
iex> r = rule(fn x when is_integer(x) and x > 0 -> :positive end)
iex> Runic.Workflow.Rule.check(r, 5)
true
iex> Runic.Workflow.Rule.check(r, -1)
false
```

### 1.3 `Runic.workflow/1` (Lines ~335-435)

**Current State:** Has good docs with examples.

**Improvements Needed:**
- Add doctest for basic workflow creation
- Document all options exhaustively:
  - `:name` - workflow identifier
  - `:steps` - list of steps (flat and nested/pipeline syntax)
  - `:rules` - list of rules
  - `:before_hooks` / `:after_hooks` - debugging and dynamic modification
- Show pipeline tree syntax: `{parent, [child1, child2]}` and `{parent, [{grandchild, [...]}]}`
- Example of merging workflows

### 1.4 `Runic.state_machine/1` (Lines ~788-878)

**Current State:** Has good `@doc` with example.

**Improvements Needed:**
- Add doctest for basic state machine
- Document all options:
  - `:name` - identifier
  - `:init` - initial state (literal, function, or `{M, F, A}`)
  - `:reducer` - state transition function
  - `:reactors` - conditional reactions to state changes
  - `:inputs` / `:outputs` - schema options
- Example showing reactor patterns
- Example of accessing accumulated state from rules

### 1.5 `Runic.map/1`, `Runic.map/2` (Lines ~880-992)

**Current State:** Has `@doc` with examples.

**Improvements Needed:**
- Add doctest
- Document all options:
  - `:name` - identifier
  - `:inputs` / `:outputs` - schema options
- Show nested pipeline syntax inside map
- Show how map integrates with reduce
- Show how a map + reduce should be added to a workflow with add/3 and reduce :map option

### 1.6 `Runic.reduce/3` (Lines ~994-1133)

**Current State:** Has extensive `@doc`.

**Improvements Needed:**
- Add doctest for simple reduce
- Document all options:
  - `:map` - reference to upstream map component for fan-in/fan-out
  - `:name` - identifier
  - `:inputs` / `:outputs` - schema options
- Example of `Enum.reduce/3` style usage
- Example of map-reduce pattern with lazy evaluation
- Mention how reduce operations are inherently not parallelizeable unless CRDT properties are inherent.

### 1.7 `Runic.accumulator/3` (Lines ~1137-1226)

**Current State:** Has `@doc` with examples.

**Improvements Needed:**
- Add doctest
- Document options: `:name`, `:inputs`, `:outputs`
- Explain difference from `reduce/3` (single invocation vs. enumerable)
- Example of stateful accumulation over multiple invocations
- How connecting rules to accumulators can make a state machine

### 1.8 `Runic.transmute/1` (Lines ~323-333)

**Current State:** Brief `@doc`.

**Improvements Needed:**
- Explain the Transmutable protocol
- Show examples converting Rule -> Workflow, Step -> Workflow
- Explain use case: converting natural representations into Runic workflows and their correllating components

### 1.9 `Runic.condition/1` (Lines ~312-321)

**Current State:** Brief `@doc`.

**Improvements Needed:**
- Document creating standalone conditions
- Example with `{M, F, A}` tuple syntax
- Use case: reusing conditions across rules
- Stateful conditions using `state_of`
- Referencing a named condition in a rule
- When to use separated conditions (compute / time intensive checks)
- Marking a condition runtime guarantees (durability, retries)
- Conditions are meant to be pure and deterministic and never execute side effects

---

## Priority 2: Core Evaluation API (`Runic.Workflow` module)

These are the primary runtime functions users will call.

### 2.1 `Workflow.react/2`, `Workflow.react/3` (Lines ~1272-1364)

**Current State:** Has `@doc` with options.

**Improvements Needed:**
- Add doctest for basic reaction
- Document all options:
  - `:async` - parallel execution (default: `false`)
  - `:max_concurrency` - parallel tasks limit
  - `:timeout` - task timeout
  - `:supervisor`
- Example of serial vs. async execution
- Explain single cycle behavior

### 2.2 `Workflow.react_until_satisfied/3` (Lines ~1366-1416)

**Current State:** Has `@doc` with options.

**Improvements Needed:**
- Add doctest
- Document all options (same as `react/3`)
- Warn about infinite loops in non-terminating workflows (if hooks add steps continually)
- Example of pipeline completion
- Use case: iex, scripts, livebooks, testing - for prod you probably want to use prepare_for_dispatch, next_runnables, with a scheduler process / runner etc

### 2.3 `Workflow.plan/1`, `Workflow.plan/2` (Lines ~1435-1466)

**Current State:** Has `@doc`.

**Improvements Needed:**
- Explain match phase vs. execute phase
- Example of forward chaining behavior
- Use case: preparing workflow for manual runnable execution

### 2.4 `Workflow.plan_eagerly/1`, `Workflow.plan_eagerly/2` (Lines ~1477-1514)

**Current State:** Has `@doc`.

**Improvements Needed:**
- Explain eager match phase traversal
- Example of continuing from produced facts
- Use case: preparing for external scheduler dispatch
- Commonly used anytime there are match nodes like w/ rules

### 2.5 `Workflow.invoke/3` (Lines ~1544-1570)

**Current State:** Has `@doc` explaining three-phase model.

**Improvements Needed:**
- Add doctest
- Explain prepare -> execute -> apply flow
- Use case: process-based scheduling

### 2.6 `Workflow.invoke_with_events/3` (Lines ~1586-1597)

**Current State:** Has `@doc`.

**Improvements Needed:**
- Document return format: `{workflow, events}`
- Explain durable execution use case
- Example of persisting events for recovery
- Use case: durable workflow execution with streaming/eventstore persistence semantics

---

## Priority 3: Result Extraction API (`Runic.Workflow` module)

### 3.1 `Workflow.raw_productions/1` (Lines ~1203-1219)

**Current State:** Has `@doc` with example.

**Improvements Needed:**
- Add doctest
- Explain difference from `productions/1` (raw values vs. Fact structs)

### 3.2 `Workflow.productions/1`, `Workflow.productions/2` (Lines ~1147-1188)

**Current State:** Has `@doc`.

**Improvements Needed:**
- Add doctest
- Document by-component retrieval

### 3.2 `Workflow.productions_by_component/1`, `Workflow.productions_by_component/2` (Lines ~1190-1227)

**Current State:** Has `@doc`.

**Improvements Needed:**
- Add doctest
- Document by-component retrieval

### 3.3 `Workflow.facts/1` (Lines ~1249-1263)

**Current State:** Has `@doc` with example.

**Improvements Needed:**
- Add doctest
- Explain ancestry: `nil` for inputs vs. `{producer_hash, parent_fact_hash}` for produced facts

### 3.4 `Workflow.reactions/1`, `Workflow.raw_reactions/1` (Lines ~1121-1145)

**Current State:** Has `@doc` but sparse.

**Improvements Needed:**
- Clarify difference from productions (side effects vs. all outputs)
- Add doctest

---

## Priority 4: Three-Phase Execution API (`Runic.Workflow` module)

### 4.1 `Workflow.prepare_for_dispatch/1` (Lines ~1978-2017)

**Current State:** Has `@doc` with example.

**Improvements Needed:**
- Add doctest
- Explain use case: external scheduler integration
- Show GenServer example pattern (link to "Building a workflow runner guide")

### 4.2 `Workflow.apply_runnable/2` (Lines ~2039-2066)

**Current State:** Has `@doc`.

**Improvements Needed:**
- Explain statuses: `:completed`, `:failed`, `:skipped`, `:pending`
- Example of handling failed runnables

### 4.3 `Workflow.prepared_runnables/1` (Lines ~1936-1968)

**Current State:** Has `@doc` with example.

**Improvements Needed:**
- Explain simpler alternative to `prepare_for_dispatch/1`
- Use case: read-only runnable extraction

---

## Priority 5: Workflow Composition API

### 5.1 `Workflow.add/2`, `Workflow.add/3` (Lines ~108-147)

**Current State:** Has `@doc`.

**Improvements Needed:**
- Document `:to` option exhaustively:
  - `nil` - add to root
  - component name (atom/string)
  - `{name, kind}` tuple for sub-components
  - hash (integer)
  - component struct
  - list of parents (creates join)
- Add doctest
- Example of adding a DAG workflow to another workflow's step

### 5.2 `Workflow.merge/2` (Lines ~1000-1098)

**Current State:** Has `@doc`.

**Improvements Needed:**
- Explain workflow merging behavior
- Example of combining two workflows
- A workflow can be ran in two separate execution contexts and its memory/state merged
  - Useful to schedule independent aspects of a workflow

### 5.3 `Workflow.add_step/2`, `Workflow.add_step/3` (Lines ~727-807)

**Current State:** Has `@doc`.

**Improvements Needed:**
- Mark as `@doc false` 
- Meant to be used internally
- Put code comment above to recommend `add/3` for all public use

---

## Priority 6: Introspection API

### 6.1 `Workflow.components/1` (Lines ~481-488)

**Current State:** Has `@doc`.

**Improvements Needed:**
- Add doctest
- Example of iterating registered components

### 6.2 `Workflow.get_component/2`, `Workflow.get_component!/2` (Lines ~908-951)

**Current State:** Minimal docs.

**Improvements Needed:**
- Document lookup by name, `{name, kind}` tuple, hash
- Add doctest

### 6.3 `Workflow.steps/1`, `Workflow.conditions/1` (Lines ~1103-1113)

**Current State:** Has `@doc`.

**Improvements Needed:**
- Add doctest
- Example of filtering workflow vertices

### 6.4 `Workflow.is_runnable?/1` (Lines ~1657-1660)

**Current State:** No `@doc`.

**Improvements Needed:**
- Add `@doc` explaining runnable check
- Add doctest

### 6.5 `Workflow.next_runnables/1` (Lines ~1662-1702)

**Current State:** Has `@doc`.

**Improvements Needed:**
- Explain return format: `[{node, fact}]`
- Example of manual scheduling
- Mark for deprecation: replaced by `prepared_runnables/1`

---

## Priority 7: Hooks API

### 7.1 `Workflow.attach_before_hook/3`, `Workflow.attach_after_hook/3` (Lines ~608-654)

**Current State:** Has `@doc` with example for after_hook.

**Improvements Needed:**
- Add docs for before_hook
- Document hook signature: `fn step, workflow, fact -> workflow end`
- Example of debugging/logging hooks
- Example of dynamic workflow modification
- Example of causal context + reducer hook function contract

---

## Priority 8: Serialization API

### 8.1 `Workflow.to_mermaid/2` (Lines ~2071-2093)

**Current State:** Has `@doc` with options.

**Improvements Needed:**
- Add doctest
- Show all options:
  - `:direction` - `:TB`, `:LR`, `:BT`, `:RL`
  - `:include_memory` - causal edges
  - `:title` - comment title

### 8.2 `Workflow.to_mermaid_sequence/2` (Lines ~2095-2108)

**Current State:** Has `@doc` with example.

**Improvements Needed:**
- Add doctest
- Explain causal sequence visualization

### 8.3 `Workflow.to_dot/2` (Lines ~2110-2121)

**Current State:** Has `@doc`.

**Improvements Needed:**
- Add doctest
- Example of exporting to Graphviz

### 8.4 `Workflow.to_cytoscape/2` (Lines ~2123-2136)

**Current State:** Has `@doc` with example.

**Improvements Needed:**
- Add doctest
- Example with Kino.Cytoscape

### 8.5 `Workflow.to_edgelist/2` (Lines ~2138-2159)

**Current State:** Has `@doc` with options.

**Improvements Needed:**
- Add doctest for both `:tuples` and `:string` formats

---

## Priority 9: Persistence/Replay API

### 9.1 `Workflow.build_log/1` (Lines ~288-304)

**Current State:** Has `@doc` with example.

**Improvements Needed:**
- Explain `%ComponentAdded{}` events
- Example of extracting for persistence

### 9.2 `Workflow.from_log/1` (Lines ~377-407)

**Current State:** Has `@doc`.

**Improvements Needed:**
- Add doctest
- Example of rebuilding workflow from persisted events

### 9.3 `Workflow.log/1` (Lines ~416-418)

**Current State:** No `@doc`.

**Improvements Needed:**
- Add `@doc` explaining combined build_log + reactions_occurred
- Use case: full workflow state serialization

---

## Priority 10: Protocols

### 10.1 `Runic.Workflow.Invokable` protocol (lib/workflow/invokable.ex)

**Current State:** Has comprehensive `@moduledoc`.

**Improvements Needed:**
- Add examples of implementing for custom structs
- Document `prepare/3`, `execute/2`, `invoke/3` callbacks with examples
- Explain `match_or_execute/1` callback

### 10.2 `Runic.Component` protocol (lib/workflow/component.ex)

**Current State:** Has `@moduledoc` and callback docs.

**Improvements Needed:**
- Add examples of implementing for custom components
- Document all callbacks: `connect/3`, `components/1`, `connectables/2`, `connectable?/2`, `source/1`, `hash/1`, `inputs/1`, `outputs/1`

### 10.3 `Runic.Transmutable` protocol (lib/workflow/transmutable.ex)

**Current State:** Has `@moduledoc`.

**Improvements Needed:**
- Add examples for `to_workflow/1`, `to_component/1`
- Document implementations for common types

---

## Clarifying Questions for the Architect

To ensure comprehensive documentation, I need clarity on:

1. **Variable Pinning (`^var`)**: ✅ ANSWERED - See detailed analysis below.

2. **Schema Compatibility (`:inputs`/`:outputs`)**: How should users define type schemas? What are the supported types (`{:list, :any}`, `:integer`, custom types)? Is NimbleOptions being used?

    * **Answer**: NimbleOptions is not being used directly but Runic supports the same [type options](https://hexdocs.pm/nimble_options/NimbleOptions.html#module-schema-options). This may extend or change in the future towards Elixir's new type system API.

3. **Hooks Use Cases**: Beyond debugging, what are the intended use cases for hooks? Dynamic workflow modification? Metrics/telemetry? Side effects?

    * **Answer**: Hooks are meant for debugging, logging, telemetry, or reactively modifying the workflow at runtime. Can be used to pubsub or send messages to a consumer process to collect outputs in real time.

4. **Content Addressability**: The Closure system provides content-addressable hashing. When should users care about this? Is it for deduplication, caching, or distributed execution?

    * **Answer**: Content addressability is important in many ways including: deterministic uniqueness of components and their nodes by the AST. This prevents overwriting and duplication in the workflow graph. It will also prove useful in coordinating distributed execution and caching values. Finally it is going to be important in workflow versioning in drafting, editing, and publishing of workflows over time using a git or merkle tree like approach to hashing the graph/tree.

5. **StateMachine vs. Accumulator**: What's the recommended choice between these? StateMachine seems like "accumulator with reactors" - when would you use one over the other?

    * **Answer**: Accumulators should be used over state machines almost always because they're more flexible. State Machines are planned for deprecation once we finish implementing `state_of` meta conditions in rule / condition macros.

6. **Joins**: The `Runic.Workflow.Join` module isn't exposed via a macro like `Runic.join/1`. Is this intentional? How should users create multi-input dependencies?

    * **Answer**: Joins aren't a user facing component - they're only present when a dependent component is added to other parent components expecting their joined/combined outputs to flow into. Joins only exist when `Workflow.add/3` with a list of `:to` options are provided.

7. **Error Handling**: What happens when a step throws an exception? Is there built-in retry logic or should users handle this in their scheduler?

    * **Answer**: Error handling is a responsibility of the scheduler consuming the Runic Workflow APIs - not Runic itself however Runic will support ease of this use case such as storing metadata that can be used in context of a hook or runnable execution to decide how to handle errors such as retry policies, back off, timeouts, etc

8. **Facts and Ancestry**: The ancestry tuple `{producer_hash, parent_fact_hash}` enables causal tracing. Should users typically access this, or is it internal?

    * **Answer**: Facts are a user facing model representing reactions in the workflow. The ancestry is fine to reference but users will find more convenience using Runic.Workflow reflection APIs around facts in context of their component names, tracking causality, etc

9. **Performance Considerations**: Are there recommended workflow sizes or patterns to avoid? (e.g., very deep pipelines, very wide fan-outs)

    * **Answer**: Long running durable workflows may incur costs when rebuilt with `from_log/1` as the current implementation is reducing serially over all memory edges produced. We'll explore a checkpointing and/or strategies to only recreate workflows with past casual references like ancestry hashes instead of the full fact values to preserve memory.

10. **Kino Integration**: There's a `lib/runic/kino.ex` - what Livebook visualizations are available?

    * **Answer**: See the serializer behaviour implementations and their documented options for visualizing workflows and their execution.

11. **Process Topology**: The README mentions GenStage/Broadway/Flow integration. Are there official adapters or just patterns to follow?

    * **Answer**: Some in-memory / single node implementations following runner/scheduler contracts will likely be provided in Runic and durable + distributed execution with other dependencies in sister libraries.

12. **Build Log vs. Graph**: When should users work with `build_log/1` vs. directly accessing `workflow.graph`?

    * **Answer**: Accessing the graph directly should be avoided directly unless you're debugging, making a custom visualization or doing something fancy with a graph traversal using the Graph module. `build_log/1` is preferable in the case that you're returning a log of serializeable events that can be used to rebuild the workflow without runtime execution memory.

---

## Answered: Variable Pinning (`^var`) vs. Closure Capture

### The Two Approaches

**1. Pinned Variables (`^var`)** - Explicit capture tracked by Runic:
```elixir
multiplier = 10
step = Runic.step(fn x -> x * ^multiplier end)
# step.closure.bindings = %{multiplier: 10}
```

**2. Unpinned Variables (standard closure)** - Implicit Elixir closure capture:
```elixir
multiplier = 10
step = Runic.step(fn x -> x * multiplier end)
# step.closure.bindings = %{}  # Empty! Runic doesn't track it
```

### How They Differ

| Aspect | Pinned (`^var`) | Unpinned (closure) |
|--------|-----------------|-------------------|
| **Works at runtime** | ✅ Yes | ✅ Yes |
| **Runic tracks the value** | ✅ Yes, in `closure.bindings` | ❌ No, empty bindings |
| **Content-addressable hashing** | ✅ Different values → different hashes | ❌ Same hash for different values |
| **Serializable** | ✅ Can serialize & rebuild | ❌ Loses variable reference |
| **build_log/from_log** | ✅ Survives persistence | ❌ Fails with "undefined variable" |

### Content Addressability Demonstration

```elixir
# PINNED: Each value produces a unique hash
steps = for i <- [10, 20, 30] do
  Runic.step(fn x -> x * ^i end)
end
work_hashes = Enum.map(steps, & &1.work_hash)
# => [1693522723, 1462654370, 433024342] - ALL UNIQUE

# UNPINNED: Same hash regardless of value
steps = for i <- [10, 20, 30] do
  Runic.step(fn x -> x * i end)
end
work_hashes = Enum.map(steps, & &1.work_hash)
# => [1697348552, 1697348552, 1697348552] - ALL SAME!
```

This matters for:
- **Deduplication**: Identifying identical components
- **Caching**: Reusing computed results
- **Distributed execution**: Consistent hashing across nodes

### Serialization/Persistence Demonstration

```elixir
multiplier = 3

# PINNED: Survives serialization
pinned_step = Runic.step(fn x -> x * ^multiplier end, name: :scale)
workflow = Runic.workflow(steps: [pinned_step])
log = Workflow.build_log(workflow)

serialized = :erlang.term_to_binary(log)
# ... save to database ...

# Later, in a different process/node:
restored = Workflow.from_log(:erlang.binary_to_term(serialized))
Workflow.react_until_satisfied(restored, 10) |> Workflow.raw_productions()
# => [30] ✅ Works!

# UNPINNED: Fails after serialization
unpinned_step = Runic.step(fn x -> x * multiplier end, name: :scale)
workflow = Runic.workflow(steps: [unpinned_step])
log = Workflow.build_log(workflow)

serialized = :erlang.term_to_binary(log)
# Later...
restored = Workflow.from_log(:erlang.binary_to_term(serialized))
# => ERROR: undefined variable "multiplier" ❌
```

### Trade-offs

| Use Pinned (`^var`) When | Use Unpinned When |
|--------------------------|-------------------|
| Building dynamic workflows at runtime | Static workflows defined at compile time |
| Workflows will be serialized/persisted | Single-process, ephemeral workflows |
| Content-addressable hashing matters | Hashing/identity not important |
| Using `build_log`/`from_log` for durability | Never need to serialize |
| Distributed execution across nodes | Local execution only |

### How It Works Internally

Runic's `traverse_expression/2` function (in [lib/runic.ex:728-763](file:///home/doops/wrk/runic/lib/runic.ex#L728-L763)) walks the AST of lambda expressions:

1. **Pinned variables** (`{:^, meta, [var]}`) are captured:
   - The variable value is evaluated and stored in `closure.bindings`
   - The AST is rewritten to reference the variable directly
   - The binding value is included in hash computation

2. **Unpinned variables** are left as-is:
   - Elixir's normal closure mechanism captures them
   - Runic has no visibility into what was captured
   - The AST references a variable that only exists in the original environment

### Recommendations for Documentation

1. **Always use `^var`** when building workflows dynamically with runtime parameters
2. **Unpinned is fine** for compile-time constants or module attributes
3. **Document clearly** that unpinned variables will fail after serialization
4. **Use pinned** when workflows might be persisted, distributed, or inspected

---

## Usage Cheatsheet Plan

Create `.docs/runic-cheatsheet.md` with:

1. **Quick Start** - Install, require, import
2. **Creating Components** - step, rule, workflow, state_machine, map, reduce, accumulator
3. **Evaluating Workflows** - react, react_until_satisfied, plan_eagerly
4. **Extracting Results** - raw_productions, facts, productions_by_component
5. **Parallel Execution** - async options, prepare_for_dispatch
6. **Serialization** - to_mermaid, to_dot, to_cytoscape, to_edgelist
7. **Persistence** - build_log, from_log
8. **Common Patterns** - pipeline, conditional branching, map-reduce, state machine

---

## Agent Rules Plan

Create `.docs/usage-rules.md` with:

1. **Always `require Runic`** before using macros
2. **Use `^var` syntax** to capture outer variables in lambda expressions
3. **Prefer named components** for debugging and hooks
4. **Use `react_until_satisfied/2`** for complete pipeline evaluation
5. **Use `react/2` + `is_runnable?/1` loop** for controlled execution
6. **Access results via `raw_productions/1`** not direct graph access
7. **For parallel execution**, use `async: true` option or `prepare_for_dispatch/1`
8. **For persistence**, use `build_log/1` and `from_log/1`
9. **Rules return `:error, :no_conditions_satisfied`** when no conditions match
10. **Avoid infinite loops** in `react_until_satisfied/2` - ensure workflows terminate

---

## Proposed Guides

### Guide 1: Implementing a Runic Scheduler GenServer

**Purpose:** Show how to wrap a Runic Workflow in a GenServer for stateful, resumable execution.

**Summary:**
- GenServer state structure holding workflow
- `handle_cast` for async input processing
- `handle_info` with the Task ref to apply results back into the workflow
- Three-phase execution with `prepare_for_dispatch/1`
- Persisting build_log for recovery
- Handling failures and retries

### Guide 2: Utilizing Async Tasks for Parallel Execution

**Purpose:** Demonstrate parallel workflow execution patterns.

**Summary:**
- Using `async: true` option for simple parallelism
- Custom Task.async_stream patterns with `prepare_for_dispatch/1`
- Configuring concurrency and timeouts
- Error handling in async contexts
- When parallelism helps vs. hurts performance
- `async_only: list_of_component_names` option

### Guide 3: Serializing and Persisting Workflow State

**Purpose:** Enable durable execution and workflow recovery.

**Summary:**
- Using `build_log/1` to extract component additions
- Using `invoke_with_events/3` for reaction events
- Serializing Closures and Facts
- `term_to_binary` and `binary_to_term`
- Storing in databases (PostgreSQL JSONB example)
- Rebuilding with `from_log/1`
- Strategies for large workflows

### Guide 4: Handling Errors and Retries

**Purpose:** Build resilient workflows with error handling.

**Summary:**
- What happens when steps throw exceptions
- Building retry logic with hooks
- Creating fallback rules
- Dead letter patterns for failed facts
- Monitoring and alerting patterns

### Guide 5: Building Expert Systems with Rules

**Purpose:** Show rule-based reasoning patterns.

**Summary:**
- Forward chaining with multiple rules
- Conflict resolution (which rule fires first)
- Using `state_of/1` for stateful rules
- Pattern matching with guards
- Building inference engines

### Guide 6: Map-Reduce Patterns for Data Processing

**Purpose:** Demonstrate parallel data processing pipelines.

**Summary:**
- Creating map operations with `Runic.map/2`
- Connecting reduce with `Runic.reduce/3` and `:map` option
- Nested map-reduce pipelines
- Lazy vs. eager evaluation tradeoffs
- Integration with Elixir Streams

### Guide 7: State Machines for Stateful Workflows

**Purpose:** Model stateful business processes.

**Summary:**
- Defining state transitions with reducer
- Adding reactors for state-triggered actions
- Accessing state from rules with `state_of/1`
- Multi-state machine workflows
- Persistence and recovery of state

### Guide 8: Visualizing Workflows with Mermaid and Kino

**Purpose:** Debug and present workflows visually.

**Summary:**
- Generating Mermaid diagrams
- Generating sequence diagrams for causal flows
- Using Kino.Cytoscape in Livebook
- Visualizing workflow execution over time
- Creating documentation from workflow definitions

### Guide 9: Integrating with GenStage and Flow

**Purpose:** Scale workflow execution with backpressure.

**Summary:**
- Creating a GenStage producer from workflow runnables
- Building consumer stages for execution
- Integrating with Broadway for message processing
- Flow patterns for parallelism
- Backpressure and demand management

### Guide 10: Testing Runic Workflows

**Purpose:** Best practices for testing workflow logic.

**Summary:**
- Unit testing individual steps and rules
- Integration testing complete workflows
- Testing conditional branching
- Mocking external dependencies in steps
- Property-based testing with StreamData

---

## Implementation Order

1. **Phase 1: Core API Docs** (Priority 1-3) - Runic module macros and Workflow evaluation
2. **Phase 2: Usage Artifacts** - Cheatsheet and Agent Rules
3. **Phase 3: Advanced API Docs** (Priority 4-6) - Three-phase execution, composition
4. **Phase 4: Protocol Docs** (Priority 10) - Invokable, Component, Transmutable
5. **Phase 5: Guides** - Starting with Scheduler GenServer and Error Handling
