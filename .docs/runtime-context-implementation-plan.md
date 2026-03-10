# Runtime Context — Implementation Plan

Reference: [runtime-context-proposal.md](runtime-context-proposal.md)

This plan implements runtime context injection for Runic workflows via:
1. A `run_context` field on `%Workflow{}` with runtime APIs
2. A `context/1` meta expression for explicit external value references in steps, conditions, and rules
3. Plumbing through `CausalContext` → `Runnable` for the three-phase execution model

---

## Phase 1: Foundation — Struct Fields & Core API

**Goal:** Add the `run_context` field and low-level accessors. No execution changes yet — purely additive, zero breaking changes. All existing tests must continue to pass.

### 1A: `%Workflow{}` struct and API

**File:** `lib/workflow.ex`

- Add `run_context: %{}` to the `defstruct` (after `uncommitted_events`)
- Add `run_context: map()` to the `@type t()` typespec
- Add functions:

```elixir
@doc """
Merges the given context map into the workflow's run context.

Run context provides external, runtime-scoped values (secrets, tenant IDs,
database connections) to components during execution. Values are keyed by
component name for scoped access, with an optional `:_global` key for
values available to all components.

Run context is NOT part of the workflow's content hash, NOT serialized
in the event log, and NOT visible in the fact graph.

## Example

    workflow = Workflow.put_run_context(workflow, %{
      call_llm: %{api_key: "sk-..."},
      _global: %{workspace_id: "ws1"}
    })
"""
@spec put_run_context(t(), map()) :: t()
def put_run_context(%__MODULE__{} = workflow, context) when is_map(context)

@doc """
Returns the full run context map.
"""
@spec get_run_context(t()) :: map()
def get_run_context(%__MODULE__{run_context: ctx})

@doc """
Returns the resolved run context for a specific component.

Merges `_global` context (if any) with the component-specific context.
Component-specific keys take precedence over global keys.

## Example

    Workflow.get_run_context(workflow, :call_llm)
    # => %{workspace_id: "ws1", api_key: "sk-..."}
"""
@spec get_run_context(t(), atom()) :: map()
def get_run_context(%__MODULE__{} = workflow, component_name) when is_atom(component_name)
```

- Ensure `run_context` is excluded from the hash computation path. Verify by reading `Component.hash/1` for `Workflow` — it delegates to `Components.fact_hash(workflow)` which hashes the struct. Since `run_context` defaults to `%{}` and is runtime-mutable, confirm that workflow hashing happens at build time before `run_context` is set. Add a test proving two workflows with different `run_context` produce the same hash.

### 1B: `%CausalContext{}` struct

**File:** `lib/workflow/causal_context.ex`

- Add `run_context: %{}` to `defstruct` (after `meta_context: %{}`)
- Add `run_context: map()` to `@type t()`
- Add builder function:

```elixir
@doc """
Adds run context for external value injection.

Run context contains runtime-scoped values resolved for a specific
component during the prepare phase. Available during execution without
requiring workflow access.
"""
@spec with_run_context(t(), map()) :: t()
def with_run_context(%__MODULE__{} = ctx, run_context) when is_map(run_context)
```

### 1C: Tests for Phase 1

**File:** `test/workflow/run_context_test.exs` (new)

```
describe "Workflow.put_run_context/2"
  - merges context into empty run_context
  - deep merges with existing run_context (top-level merge, not deep)
  - returns updated workflow struct

describe "Workflow.get_run_context/1"
  - returns empty map for new workflow
  - returns full run_context map

describe "Workflow.get_run_context/2"
  - returns component-specific context by name
  - merges _global with component-specific (component wins)
  - returns only _global if no component-specific entry
  - returns empty map if neither exists

describe "CausalContext run_context"
  - new context has empty run_context
  - with_run_context/2 sets the run context
  - defaults don't break existing CausalContext usage

describe "run_context does not affect content addressability"
  - workflow hash is identical with different run_contexts
```

**Verification:** `mix test test/workflow/run_context_test.exs && mix test`

---

## Phase 2: `context/1` Meta Expression

**Goal:** Add `context/1` to the macro DSL so components can declare external value dependencies. Compile-time only — no runtime resolution yet.

### 2A: Meta expression detection

**File:** `lib/runic.ex`

- Add `:context` to `@meta_expression_kinds` list
- Update `build_context_key/2` — for `:context` kind, use the target atom directly as the key (no suffix):

```elixir
defp build_context_key(target, :context) when is_atom(target), do: target
```

- Update `rewrite_meta_refs_in_ast/2` — add clause for `context(:key)` and `context(:key).field`:

```elixir
# context(:key).field - dot access on context expression
{{:., dot_meta, [{:context, _, [target]}, field]}, call_meta, []} ->
  ref = find_ref_by_target(meta_refs, target, :context)
  if ref do
    map_get = quote(do: Map.get(unquote(meta_ctx_var), unquote(ref.context_key), %{}))
    {{:., dot_meta, [map_get, field]}, call_meta, []}
  else
    node
  end

# context(:key) without field access
{:context, _, [target]} when is_atom(target) ->
  ref = find_ref_by_target(meta_refs, target, :context)
  if ref do
    quote(do: Map.get(unquote(meta_ctx_var), unquote(ref.context_key)))
  else
    node
  end
```

- Update `extract_meta_expression_with_fields/1` — add base case for `context/1`:

```elixir
defp extract_meta_expression_with_fields({:context, _, [target]}) do
  {:ok, :context, target, []}
end
```

### 2B: Step macro integration

**File:** `lib/runic.ex`

The standalone `step/1` and `step/2` macros currently do NOT call `detect_meta_expressions`. Update them to:

1. After `traverse_expression`, call `detect_meta_expressions(work)` on the original (pre-rewrite) AST
2. If context refs are found:
   - Call `rewrite_meta_refs_in_ast` on the work function AST
   - Wrap the work function to be arity-2: `fn input, meta_ctx -> <rewritten_body> end`
   - Store `meta_refs` on the Step struct

This mirrors what `compile_meta_when_clause` / `compile_meta_then_clause` do for rules, but for standalone steps.

Create a helper `maybe_compile_meta_step/3` that encapsulates:
```elixir
defp maybe_compile_meta_step(work_ast, rewritten_work, env) do
  meta_refs = detect_meta_expressions(work_ast)

  if meta_refs != [] do
    rewritten = rewrite_meta_refs_in_ast(rewritten_work, meta_refs)
    # Wrap into arity-2 function
    wrapped = quote generated: true do
      fn input, var!(meta_ctx, Runic) ->
        _ = var!(meta_ctx, Runic)
        unquote(rewritten).(input)
      end
    end
    {wrapped, meta_refs}
  else
    {rewritten_work, []}
  end
end
```

Apply this in all `step` macro variants (`step/1` for `{:fn,...}`, `step/2`). The escaped `meta_refs` list is passed to `Step.new(... meta_refs: meta_refs)`.

### 2C: Condition macro integration

**File:** `lib/runic.ex`

Same pattern as 2B but for standalone `condition/1` and `condition/2` macros. When `context/1` is detected:
- Rewrite AST
- Set arity to 2
- Store `meta_refs` on Condition struct

### 2D: Tests for Phase 2

**File:** `test/workflow/run_context_test.exs` (extend)

```
describe "context/1 meta expression detection"
  - detect_meta_expressions finds context(:key) in step AST
  - detect_meta_expressions finds context(:key).field with field_path
  - context_key is the target directly (no suffix)
  - does not collide with state_of refs

describe "context/1 in step macro"
  - step with context(:api_key) has meta_refs on struct
  - meta_ref has kind: :context, target: :api_key, context_key: :api_key
  - step work function is arity 2
  - step with context(:config).pool_size has field_path [:pool_size]
  - step without context/1 is unchanged (no meta_refs, original arity)

describe "context/1 in condition macro"
  - condition with context(:feature_flag) has meta_refs
  - condition arity is 2

describe "context/1 in rule DSL"
  - context(:key) in where clause produces condition meta_refs with kind: :context
  - context(:key) in then clause produces reaction meta_refs with kind: :context
  - mixed state_of + context in where clause produces both ref kinds
```

**Verification:** `mix test test/workflow/run_context_test.exs && mix test`

---

## Phase 3: Runtime Resolution & Execution

**Goal:** Wire `run_context` through the prepare → execute pipeline so `context/1` values are available during step/condition execution. This is the core runtime integration.

### Work Streams

Phase 3 has two independent work streams that can be implemented in parallel:

#### Stream A: Prepare-phase resolution

**File:** `lib/workflow/private.ex`

Update `prepare_meta_context/2` to also resolve `:context`-kind refs from `workflow.run_context`. Context refs do NOT use graph edges — they read directly from the workflow's `run_context` field.

```elixir
def prepare_meta_context(%Workflow{graph: graph} = workflow, node) do
  # Existing: resolve graph-based meta_refs via :meta_ref edges
  graph_context =
    graph
    |> Graph.out_edges(node_vertex(node), by: :meta_ref)
    |> Enum.reduce(%{}, fn edge, acc ->
      properties = edge.properties || %{}
      getter_fn = Map.get(properties, :getter_fn)
      context_key = Map.get(properties, :context_key)
      target = edge.v2

      if getter_fn && context_key do
        value = getter_fn.(workflow, target)
        Map.put(acc, context_key, value)
      else
        acc
      end
    end)

  # NEW: resolve :context-kind refs from run_context
  external_context = resolve_context_refs(workflow, node)

  # graph context overrides external (more specific wins)
  Map.merge(external_context, graph_context)
end

defp resolve_context_refs(%Workflow{} = workflow, node) do
  meta_refs = Map.get(node, :meta_refs, [])

  meta_refs
  |> Enum.filter(fn ref -> ref.kind == :context end)
  |> Enum.reduce(%{}, fn ref, acc ->
    component_ctx = Workflow.get_run_context(workflow, node.name)
    value = Map.get(component_ctx, ref.target)
    Map.put(acc, ref.context_key, value)
  end)
end
```

**File:** `lib/workflow/component.ex` (Condition impl)

Update `Component.connect/3` for Condition to skip `:meta_ref` edge creation for `:context`-kind refs. These refs have no graph target — they reference external values.

```elixir
defp create_meta_ref_edges(workflow, %{meta_refs: meta_refs, hash: node_hash, name: name})
     when is_list(meta_refs) and meta_refs != [] do
  Enum.reduce(meta_refs, workflow, fn meta_ref, wrk ->
    # Skip :context refs — they have no graph target
    if meta_ref.kind == :context do
      wrk
    else
      # existing edge creation logic...
    end
  end)
end
```

Similarly, if Step has a `Component.connect` that processes `meta_refs`, apply the same guard. (Steps don't currently draw meta_ref edges in `Component.connect` — that's done by Condition. Verify this.)

#### Stream B: Execute-phase context passing

**File:** `lib/workflow/invokable.ex`

Update `Invokable.prepare/3` for **Step** to also copy `workflow.run_context` (resolved for this component) into `CausalContext.run_context`:

```elixir
def prepare(%Step{} = step, %Workflow{} = workflow, %Fact{} = fact) do
  fan_out_context = build_fan_out_context(workflow, step, fact)

  meta_context =
    if Step.has_meta_refs?(step) do
      Workflow.prepare_meta_context(workflow, step)
    else
      %{}
    end

  # NEW: resolve component-scoped run_context
  run_context = Workflow.get_run_context(workflow, step.name)

  context =
    CausalContext.new(
      node_hash: step.hash,
      input_fact: fact,
      ancestry_depth: Workflow.ancestry_depth(workflow, fact),
      hooks: Workflow.get_hooks(workflow, step.hash),
      fan_out_context: fan_out_context,
      meta_context: meta_context,
      run_context: run_context
    )

  {:ok, Runnable.new(step, fact, context)}
end
```

Update `Invokable.prepare/3` for **Condition** similarly:

```elixir
def prepare(%Condition{} = condition, %Workflow{} = workflow, %Fact{} = fact) do
  meta_context =
    if Condition.has_meta_refs?(condition) do
      Workflow.prepare_meta_context(workflow, condition)
    else
      %{}
    end

  # NEW
  run_context = Workflow.get_run_context(workflow, condition.name)

  context =
    CausalContext.new(
      node_hash: condition.hash,
      input_fact: fact,
      ancestry_depth: Workflow.ancestry_depth(workflow, fact),
      hooks: Workflow.get_hooks(workflow, condition.hash),
      meta_context: meta_context,
      run_context: run_context
    )

  {:ok, Runnable.new(condition, fact, context)}
end
```

Update `Invokable.execute/2` for **Step**:

The execute function must merge `run_context` and `meta_context` to form the effective context passed to arity-2 work functions. The existing code has two paths — `meta_refs` present → `run_with_meta_context`, otherwise → `Components.run`. Unify into a single resolution:

```elixir
def execute(%Step{} = step, %Runnable{input_fact: fact, context: ctx} = runnable) do
  with {:ok, before_apply_fns} <- HookRunner.run_before(ctx, step, fact) do
    try do
      result = run_step_work(step, fact.value, ctx)
      # ... rest unchanged
    rescue
      e -> Runnable.fail(runnable, e)
    end
  else
    {:error, reason} -> Runnable.fail(runnable, {:hook_error, reason})
  end
end

defp run_step_work(step, input, ctx) do
  effective_context = merge_effective_context(ctx.meta_context, ctx.run_context)
  arity = Components.arity_of(step.work)

  cond do
    effective_context != %{} and arity >= 2 ->
      step.work.(input, effective_context)

    Step.has_meta_refs?(step) and ctx.meta_context != %{} ->
      Step.run_with_meta_context(step, input, ctx.meta_context)

    true ->
      Components.run(step.work, input, arity)
  end
end

# run_context is base, meta_context overrides (graph state is more specific)
defp merge_effective_context(meta, run) when map_size(meta) == 0 and map_size(run) == 0, do: %{}
defp merge_effective_context(meta, run) when map_size(run) == 0, do: meta
defp merge_effective_context(meta, run) when map_size(meta) == 0, do: run
defp merge_effective_context(meta, run), do: Map.merge(run, meta)
```

Update `Invokable.execute/2` for **Condition**:

```elixir
def execute(%Condition{} = condition, %Runnable{input_fact: fact, context: ctx} = runnable) do
  with {:ok, before_apply_fns} <- HookRunner.run_before(ctx, condition, fact) do
    effective_context = merge_effective_context(ctx.meta_context, ctx.run_context)

    satisfied =
      if effective_context != %{} and condition.arity == 2 do
        Condition.check_with_meta_context(condition, fact, effective_context)
      else
        Condition.check(condition, fact)
      end
    # ... rest unchanged
  end
end
```

### 3C: Tests for Phase 3

**File:** `test/workflow/run_context_test.exs` (extend)

```
describe "context/1 resolution in steps"
  - step with context(:api_key) receives value from run_context during execution
  - step receives _global values when no component-specific entry
  - component-specific context overrides _global
  - step without context/1 is unaffected by run_context
  - step result flows through fact graph normally (context not in facts)

describe "context/1 resolution in conditions"
  - condition with context(:feature_flag) receives value from run_context
  - condition gates correctly based on context value
  - condition without context/1 is unaffected

describe "mixed state_of + context in rules"
  - rule with state_of(:counter) and context(:limit) in where clause
    resolves both from graph state and run_context respectively
  - meta_context keys override run_context keys on collision

describe "context isolation from data plane"
  - run_context values do not appear in produced facts
  - run_context values do not appear in event log
  - workflow replay without run_context replays fact graph correctly
```

**Verification:** `mix test test/workflow/run_context_test.exs && mix test`

---

## Phase 4: Runtime API Integration

**Goal:** Wire `run_context` into all user-facing execution APIs so context can be provided at the point of use.

### 4A: `react/2,3` and `react_until_satisfied/2,3`

**File:** `lib/workflow.ex`

Add a private helper:

```elixir
defp maybe_apply_run_context(workflow, opts) do
  case Keyword.get(opts, :run_context) do
    nil -> workflow
    ctx when is_map(ctx) -> put_run_context(workflow, ctx)
  end
end
```

Update `react/3` (the entry point that receives a fact + opts):

```elixir
def react(%__MODULE__{} = wrk, %Fact{ancestry: nil} = fact, opts) do
  wrk
  |> maybe_apply_run_context(opts)
  |> invoke(root(), fact)
  |> react(opts)
end
```

Update `react_until_satisfied/3` entry points:

```elixir
def react_until_satisfied(%__MODULE__{} = workflow, nil, opts) do
  opts = maybe_convert_deadline(opts)
  workflow = maybe_apply_run_context(workflow, opts)
  do_react_until_satisfied(workflow, is_runnable?(workflow), opts)
end

def react_until_satisfied(%__MODULE__{} = wrk, %Fact{ancestry: nil} = fact, opts) do
  opts = maybe_convert_deadline(opts)
  wrk = maybe_apply_run_context(wrk, opts)

  wrk
  |> react(fact, opts)
  |> react_until_satisfied(nil, opts)
end
```

Update the `@doc` for `react_until_satisfied/3` — add `:run_context` to the Options section:

```
- `:run_context` - A map of external values keyed by component name, made available
  to components that use `context/1` expressions. Supports a `:_global` key for
  values available to all components. See "Runtime Context" section.
```

### 4B: Runner Worker

**File:** `lib/runic/runner/worker.ex`

Update `handle_cast({:run, input, opts}, state)`:

```elixir
def handle_cast({:run, input, opts}, %__MODULE__{status: status} = state)
    when status in [:idle, :running] do
  policies = merge_runtime_policies(opts, state.workflow.scheduler_policies)

  workflow =
    state.workflow
    |> maybe_set_policies(policies, state.workflow.scheduler_policies)
    |> maybe_apply_run_context(opts)          # NEW
    |> Workflow.plan_eagerly(input)

  state = %{state | workflow: workflow, status: :running}
  state = dispatch_runnables(state)
  state = maybe_transition_to_idle(state)

  {:noreply, state}
end

defp maybe_apply_run_context(workflow, opts) do
  case Keyword.get(opts, :run_context) do
    nil -> workflow
    ctx when is_map(ctx) -> Workflow.put_run_context(workflow, ctx)
  end
end
```

**File:** `lib/runic/runner.ex`

Update `@doc` for `run/4` to document the `:run_context` option.

### 4C: Tests for Phase 4

**File:** `test/workflow/run_context_test.exs` (extend)

```
describe "react/3 with run_context option"
  - passes context to steps via opts
  - context persists across react cycles in react_until_satisfied

describe "react_until_satisfied/3 with run_context option"
  - full pipeline execution with context injection
  - multi-step pipeline where only some steps use context
```

**File:** `test/runner/worker_test.exs` (extend, or new `test/runner/run_context_test.exs`)

```
describe "Runner.run with run_context"
  - worker applies run_context from opts before plan_eagerly
  - context values available to steps during worker dispatch
```

**Verification:** `mix test test/workflow/run_context_test.exs && mix test test/runner/`

---

## Phase 5: Introspection & Validation

**Goal:** Let users (and Runners) discover what context a workflow requires and validate it before execution.

### 5A: Introspection API

**File:** `lib/workflow.ex`

```elixir
@doc """
Returns a map of component names to their required context keys.

Only includes components that use `context/1` meta expressions.
Components without context requirements are omitted.

## Example

    Workflow.required_context_keys(workflow)
    # => %{call_llm: [:api_key, :model], db_query: [:repo, :tenant_id]}
"""
@spec required_context_keys(t()) :: %{atom() => [atom()]}
def required_context_keys(%__MODULE__{graph: graph})
```

Implementation: walk all vertices in the graph, filter to structs with `meta_refs`, collect those with `kind: :context`, group by component name.

### 5B: Validation API

**File:** `lib/workflow.ex`

```elixir
@doc """
Validates that the given run_context satisfies all `context/1` references
in the workflow.

Returns `:ok` if all required keys are present, or `{:error, missing}` with
a map of component names to their missing context keys.

## Example

    Workflow.validate_run_context(workflow, %{call_llm: %{api_key: "sk-..."}})
    # => :ok

    Workflow.validate_run_context(workflow, %{})
    # => {:error, %{call_llm: [:api_key], db_query: [:repo, :tenant_id]}}
"""
@spec validate_run_context(t(), map()) :: :ok | {:error, %{atom() => [atom()]}}
def validate_run_context(%__MODULE__{} = workflow, context) when is_map(context)
```

### 5C: Tests for Phase 5

**File:** `test/workflow/run_context_test.exs` (extend)

```
describe "Workflow.required_context_keys/1"
  - returns empty map for workflow with no context refs
  - returns component → keys map for workflow with context refs
  - includes refs from both steps and conditions
  - does not include state_of or other meta ref kinds

describe "Workflow.validate_run_context/2"
  - returns :ok when all keys present
  - returns {:error, missing} when keys missing
  - considers _global keys as satisfying any component's requirements
  - returns :ok for workflow with no context requirements
```

**Verification:** `mix test test/workflow/run_context_test.exs`

---

## Phase 6: Documentation

**Goal:** Document the new feature in moduledocs, guides, and the cheatsheet.

### 6A: Module-level documentation

- **`lib/workflow.ex` `@moduledoc`**: Add a "Runtime Context" section to the module doc, after the "External Scheduler Integration" section. Cover: what run_context is, how to provide it via `react_until_satisfied` opts, how it differs from closure bindings, and how it interacts with the three-phase model.

- **`lib/runic.ex` `@moduledoc` / README section**: Add documentation for `context/1` as a meta expression. Add examples showing `context(:key)` in step and rule definitions.

- **`lib/workflow/causal_context.ex` `@moduledoc`**: Add `run_context` to the "Node-Specific Context Fields" list.

- **`lib/workflow/step.ex` `@moduledoc`**: Add a "Runtime Context Support" section similar to the existing "Meta Expression Support" section.

- **`lib/workflow/condition.ex` `@moduledoc`**: Same — note that conditions can use `context/1`.

### 6B: Guide updates

- **`guides/execution-strategies.md`**: Add a section on providing `run_context` when using `react_until_satisfied`, `prepare_for_dispatch`, and Runner APIs.

- **`guides/cheatsheet.md`**: Add `context/1` to the meta expressions list. Add `run_context:` to the options examples.

### 6C: Docstrings on new functions

All new public functions (`put_run_context/2`, `get_run_context/1,2`, `required_context_keys/1`, `validate_run_context/2`) get full `@doc` with examples, as written in the phases above.

---

## Phase Summary & Dependencies

```
Phase 1 ─── Foundation (structs, API)
  │
  ▼
Phase 2 ─── context/1 Macro (compile-time)
  │
  ▼
Phase 3 ─── Runtime Resolution ──┬── Stream A: prepare_meta_context + Component.connect
  │                               └── Stream B: Invokable.prepare + execute
  ▼
Phase 4 ─── Runtime API (react, runner) ── can parallelize 4A and 4B
  │
  ▼
Phase 5 ─── Introspection & Validation
  │
  ▼
Phase 6 ─── Documentation ── can parallelize 6A, 6B, 6C
```

Phases 1→2→3 are strictly sequential (each depends on the prior).
Phase 3 streams A and B can be parallelized.
Phase 4A and 4B can be parallelized.
Phase 5 depends on phases 1-3.
Phase 6 can be parallelized across sub-tasks and depends on all prior phases being stable.

---

## Files Modified (Summary)

| File | Changes |
|---|---|
| `lib/workflow.ex` | `run_context` field, `put_run_context`, `get_run_context`, `required_context_keys`, `validate_run_context`, `maybe_apply_run_context`, react/react_until_satisfied opts, docs |
| `lib/workflow/causal_context.ex` | `run_context` field, `with_run_context/2` |
| `lib/workflow/invokable.ex` | `prepare/3` for Step + Condition (copy run_context), `execute/2` for Step + Condition (merge + pass), `run_step_work` + `merge_effective_context` helpers |
| `lib/workflow/private.ex` | `prepare_meta_context/2` (resolve `:context`-kind refs), `resolve_context_refs/2` helper |
| `lib/workflow/component.ex` | Condition `connect/3` — skip `:meta_ref` edge for `:context`-kind refs |
| `lib/workflow/step.ex` | `@moduledoc` update |
| `lib/workflow/condition.ex` | `@moduledoc` update |
| `lib/runic.ex` | `@meta_expression_kinds`, `build_context_key`, `rewrite_meta_refs_in_ast`, `extract_meta_expression_with_fields`, `step/1,2` macros, `condition/1,2` macros |
| `lib/runic/runner/worker.ex` | `handle_cast({:run,...})` — apply run_context, `maybe_apply_run_context/2` |
| `lib/runic/runner.ex` | `run/4` doc update |
| `guides/execution-strategies.md` | Runtime context section |
| `guides/cheatsheet.md` | `context/1` and `run_context:` entries |

## Files Created

| File | Purpose |
|---|---|
| `test/workflow/run_context_test.exs` | All run_context and context/1 tests |

---

## Risk Areas & Testing Focus

### Arity detection ambiguity

The `Components.arity_of/1` function is used throughout the codebase to determine how to call work functions. When `context/1` rewrites a step's work function to arity-2, this must be transparent to the existing execution paths.

**Test:** A step compiled with `context/1` reports arity 2 via `Components.arity_of`. The `run_step_work` helper correctly routes to the arity-2 path when `effective_context != %{}`.

### Backward compatibility with existing arity-2 steps

Steps already support arity-2 for `meta_refs` (`state_of` etc.). Ensure that existing workflows using `state_of` in rules continue to work identically.

**Test:** Run the existing `test/workflow/meta_context_test.exs` and `test/meta_expression_follow_up_test.exs` after all changes. These must pass unchanged.

### Content addressability

`run_context` must not participate in hashing. Since `run_context` is set at runtime (after build), and workflow hashing happens at build time, this should be safe. But verify edge cases: what if someone calls `put_run_context` before `Workflow.add`? The hash is computed from graph topology, not the struct's flat fields.

**Test:** Two workflows with identical components but different `run_context` produce the same hash from `Component.hash/1`.

### Event-sourced replay

`run_context` is not in the event log. Replaying from a log should produce the same graph. If a step used `context(:api_key)` during original execution, replay doesn't re-execute — it applies stored `FactProduced` events. The fact values are deterministic per the original execution.

**Test:** Build a workflow with `context/1` steps, execute it, get the build log, replay via `from_log/1`, verify the graph structure is correct.

### Three-phase dispatch round-trip

`run_context` on `CausalContext` must survive the prepare → (serialize) → execute cycle. `CausalContext` is a plain struct with maps — `term_to_binary` / `binary_to_term` round-trips correctly.

**Test:** Prepare a runnable, serialize + deserialize it, execute it, verify the result is correct.

### Component.connect for context refs

`:context`-kind meta_refs must NOT cause `UnresolvedReferenceError` during `Component.connect`. The existing Condition `connect/3` iterates `meta_refs` and expects to find graph targets for each — `:context` refs have no target. The guard (`if meta_ref.kind == :context, do: wrk`) must be in place before any test that adds a condition with `context/1` to a workflow.

**Test:** Adding a condition with `context(:key)` to a workflow via `Workflow.add` does not raise.

---

## Phase 7: `context/1` in Accumulator

**Goal:** Enable `context/1` in accumulator reducer functions so stateful components can reference external runtime values (e.g., rate limits, decay factors, configuration thresholds).

### 7A: Accumulator macro — meta expression detection

**File:** `lib/runic.ex`

The `accumulator/3` macro currently calls `traverse_expression` on `reducer_fun` but does NOT call `detect_meta_expressions`. Update it to detect and rewrite `context/1` references in the reducer function.

Create a helper `maybe_compile_meta_reducer/3` analogous to `maybe_compile_meta_work/3`:

```elixir
defp maybe_compile_meta_reducer(reducer_ast, rewritten_reducer, _env) do
  meta_refs = detect_meta_expressions(reducer_ast)

  if meta_refs != [] do
    rewritten = rewrite_meta_refs_in_ast(rewritten_reducer, meta_refs)

    # Accumulator reducers are arity-2: (value, acc) -> new_acc
    # Rewrite to arity-3: (value, acc, meta_ctx) -> new_acc
    wrapped =
      quote generated: true do
        fn value, acc, var!(meta_ctx, Runic) ->
          _ = var!(meta_ctx, Runic)
          unquote(rewritten).(value, acc)
        end
      end

    {wrapped, meta_refs}
  else
    {rewritten_reducer, []}
  end
end
```

Apply this in the `accumulator/3` macro after `traverse_expression`:

```elixir
{rewritten_reducer_fun, reducer_bindings} = traverse_expression(reducer_fun, __CALLER__)
{final_reducer, meta_refs} = maybe_compile_meta_reducer(reducer_fun, rewritten_reducer_fun, __CALLER__)
escaped_meta_refs = Macro.escape(meta_refs)
```

Pass `meta_refs: escaped_meta_refs` when constructing the `%Accumulator{}` struct.

### 7B: Accumulator struct — `meta_refs` field

**File:** `lib/workflow/accumulator.ex`

- Add `meta_refs: []` to the `defstruct`
- Add a `has_meta_refs?/1` function:

```elixir
@spec has_meta_refs?(t()) :: boolean()
def has_meta_refs?(%__MODULE__{meta_refs: meta_refs}), do: meta_refs != []
```

### 7C: Invokable — Accumulator prepare/execute with context

**File:** `lib/workflow/invokable.ex`

Update `Invokable` impl for `Accumulator`:

**prepare/3:** Add meta_context and run_context resolution (same pattern as Step):

```elixir
def prepare(%Accumulator{} = acc, %Workflow{} = workflow, %Fact{} = fact) do
  last_state_fact = last_known_state(workflow, acc)

  meta_context =
    if Accumulator.has_meta_refs?(acc) do
      Workflow.prepare_meta_context(workflow, acc)
    else
      %{}
    end

  run_context = Workflow.get_run_context(workflow, acc.name)

  context =
    CausalContext.new(
      node_hash: acc.hash,
      input_fact: fact,
      ancestry_depth: Workflow.ancestry_depth(workflow, fact),
      hooks: Workflow.get_hooks(workflow, acc.hash),
      last_known_state: if(last_state_fact, do: last_state_fact.value, else: nil),
      is_state_initialized: not is_nil(last_state_fact),
      mergeable: acc.mergeable,
      meta_context: meta_context,
      run_context: run_context
    )

  {:ok, Runnable.new(acc, fact, context)}
end
```

**execute/2:** Update the reducer calls to pass effective_context when meta_refs are present:

```elixir
defp run_accumulator_reducer(acc, value, state, ctx) do
  effective_context = merge_effective_context(ctx.meta_context, ctx.run_context)
  arity = Function.info(acc.reducer, :arity) |> elem(1)

  cond do
    effective_context != %{} and arity == 3 ->
      acc.reducer.(value, state, effective_context)

    true ->
      apply(acc.reducer, [value, state])
  end
end
```

Replace the direct `apply(acc.reducer, [fact.value, ctx.last_known_state])` calls in `execute/2` with calls to `run_accumulator_reducer/4`.

### 7D: Component.connect — Accumulator meta_ref edges

**File:** `lib/workflow/component.ex`

The Accumulator `Component.connect/3` implementation currently does not handle `meta_refs`. Since `context/1` refs skip edge creation (no graph target), this requires only a guard — but we still need to add the `create_meta_ref_edges` call so that future non-context meta_refs (e.g., `state_of` in an accumulator) would also work.

Update the Accumulator `connect/3` implementation to call `create_meta_ref_edges_for_accumulator/2` after registration, following the same skip-for-context pattern used in Rule's `create_meta_ref_edges_for_node`.

### 7E: Tests for Phase 7

**File:** `test/workflow/run_context_test.exs` (extend)

```
describe "context/1 in accumulator"
  - accumulator with context(:key) in reducer has meta_refs on struct
  - meta_ref has kind: :context, target matches
  - accumulator reducer is arity 3 when context is used
  - accumulator without context/1 is unchanged
  - accumulator in workflow receives context values during execution
  - accumulator with context(:decay_factor) applies decay to state
  - accumulator with context and state_of mixed refs
  - required_context_keys/1 includes accumulator context refs
  - validate_run_context/2 checks accumulator requirements

describe "accumulator context runtime behavior"
  - context value changes between react cycles affect accumulator behavior
  - accumulator without run_context set uses nil for context values
  - context does not affect content addressability of accumulator
```

**Verification:** `mix test test/workflow/run_context_test.exs && mix test`

---

## Phase 8: `context/1` in Map Components

**Goal:** Enable `context/1` in map pipeline functions. Map components internally construct a pipeline workflow containing steps — the `context/1` support flows through the inner step compilation.

### 8A: Analysis — Map pipeline step compilation

The `map/2` macro delegates step compilation to `pipeline_workflow_of_map_expression/3`, which calls `CompilationUtils.pipeline_step(expression)`. When the expression is an `{:fn, _, _}`, the pipeline step wraps it into a `Step.new(work: ...)`.

There are two sub-cases:

1. **Simple function map:** `Runic.map(fn x -> context(:key) + x end)` — The inner fn is compiled via `CompilationUtils.pipeline_step`, which builds a raw Step without running through the `Runic.step` macro. This means `detect_meta_expressions` is never called.

2. **Explicit step pipeline map:** `Runic.map({Runic.step(fn x -> context(:key) + x end), [...]})` — The `Runic.step` macro IS invoked, so `context/1` detection already works for the inner steps. This case may already work.

### 8B: CompilationUtils — meta expression support

**File:** `lib/workflow/compilation_utils.ex`

Update `pipeline_step/1` to detect and rewrite `context/1` meta expressions in the work function AST. When `context/1` is found:

1. Call `Runic.detect_meta_expressions(expression)` on the original AST
2. Call `Runic.rewrite_meta_refs_in_ast(expression, meta_refs)` to rewrite
3. Wrap the function to arity-2 `(input, meta_ctx)`
4. Pass `meta_refs: meta_refs` to `Step.new`

This requires `CompilationUtils` to have access to the detection/rewrite functions. Since these are currently private in `Runic`, either:
- Make `detect_meta_expressions/1` and `rewrite_meta_refs_in_ast/2` `@doc false` public functions, or
- Move meta expression utilities to `CompilationUtils` (more appropriate — they are compilation utilities)

Recommended approach: make them `@doc false` public in `Runic` for now (minimal change), then consider refactoring to `CompilationUtils` in a future cleanup.

### 8C: FanOut — run_context propagation

**File:** `lib/workflow/invokable.ex`

The `FanOut` Invokable doesn't execute work functions — it splits enumerables. It does NOT need `context/1` support directly. However, the steps inside a map pipeline DO execute, and they already go through the Step `Invokable` implementation which resolves `run_context` during `prepare/3`.

Verify that `run_context` propagation works through the FanOut → Step → FanIn pipeline by checking that:
1. The parent workflow's `run_context` is available during `Step.prepare/3` for map-internal steps
2. The `run_context` survives the fan-out/fan-in coordination

This should work already since `prepare/3` reads `run_context` from the workflow struct, and map-internal steps are prepared in the same workflow context. Add tests to confirm.

### 8D: Tests for Phase 8

**File:** `test/workflow/run_context_test.exs` (extend)

```
describe "context/1 in map"
  - map with simple fn using context(:key) — step has meta_refs
  - map with explicit step pipeline using context(:key) — already works
  - map pipeline execution receives context values
  - map with context in a multi-step pipeline
  - map-reduce pattern with context in the map step
  - context values consistent across all fan-out branches

describe "map context runtime behavior"
  - map with context(:multiplier) applies multiplier to each element
  - map without run_context set uses nil for context values
  - required_context_keys/1 includes map-internal step context refs
```

**Verification:** `mix test test/workflow/run_context_test.exs && mix test`

---

## Phase 9: `context/1` in Reduce Components

**Goal:** Enable `context/1` in reduce (FanIn) reducer functions so aggregation logic can reference external runtime values.

### 9A: Reduce macro — meta expression detection

**File:** `lib/runic.ex`

The `reduce/3` macro creates a `%Reduce{}` containing a `%FanIn{}` with a `reducer` function. Apply the same `maybe_compile_meta_reducer/3` helper from Phase 7:

```elixir
{rewritten_reducer_fun, reducer_bindings} = traverse_expression(reducer_fun, __CALLER__)
{final_reducer, meta_refs} = maybe_compile_meta_reducer(reducer_fun, rewritten_reducer_fun, __CALLER__)
escaped_meta_refs = Macro.escape(meta_refs)
```

Pass `meta_refs: escaped_meta_refs` to the `%FanIn{}` struct.

### 9B: FanIn struct — `meta_refs` field

**File:** `lib/workflow/fan_in.ex`

- Add `meta_refs: []` to the `defstruct`
- Add `has_meta_refs?/1`:

```elixir
def has_meta_refs?(%__MODULE__{meta_refs: meta_refs}), do: meta_refs != []
```

### 9C: Reduce struct — propagation

**File:** `lib/workflow/reduce.ex`

The `%Reduce{}` struct wraps `%FanIn{}`. The `meta_refs` live on the `FanIn` since that's the actual execution node. The `Reduce` struct does not need a separate `meta_refs` field — the introspection APIs (`required_context_keys/1`) should walk into the FanIn.

However, for `Workflow.get_run_context(workflow, name)`, the FanIn doesn't have a `name` field. The parent Reduce has the name. Update the FanIn `prepare/3` to resolve `run_context` using the parent Reduce's name.

**Approach:** During `Component.connect/3` for Reduce, store the Reduce name on the FanIn via a `:component_of` edge property, OR add a `name` field to FanIn that gets set during Reduce construction.

Recommended: Add `name: nil` to FanIn's `defstruct`. In the `reduce/3` macro, set `fan_in.name` to the reduce name. This gives FanIn a stable identity for `get_run_context` lookups.

### 9D: Invokable — FanIn prepare/execute with context

**File:** `lib/workflow/invokable.ex`

Update the FanIn `Invokable` implementation:

**prepare/3:** Add meta_context and run_context resolution:

```elixir
meta_context =
  if FanIn.has_meta_refs?(fan_in) do
    Workflow.prepare_meta_context(workflow, fan_in)
  else
    %{}
  end

run_context = Workflow.get_run_context(workflow, fan_in.name)
```

Add these to the `CausalContext.new(...)` calls in both the `nil` (simple) and `%FanOut{}` (fan_out_reduce) branches.

**execute/2:** In the `:simple` mode, update the `reduce_with_while` call to pass context:

```elixir
defp fan_in_reduce_with_context(enumerable, acc, reducer, effective_context) do
  arity = Function.info(reducer, :arity) |> elem(1)

  if effective_context != %{} and arity == 3 do
    Enum.reduce_while(enumerable, acc, fn value, acc ->
      case reducer.(value, acc, effective_context) do
        {:cont, new_acc} -> {:cont, new_acc}
        {:halt, new_acc} -> {:halt, new_acc}
        new_acc -> {:cont, new_acc}
      end
    end)
  else
    Enum.reduce_while(enumerable, acc, fn value, acc ->
      case reducer.(value, acc) do
        {:cont, new_acc} -> {:cont, new_acc}
        {:halt, new_acc} -> {:halt, new_acc}
        new_acc -> {:cont, new_acc}
      end
    end)
  end
end
```

For the `:fan_out_reduce` mode, the reduce happens in `Coordinator.finalize` (the old path in `fan_in.ex`) and in the `maybe_finalize_coordination` path. Both need to pass context. Since the `Coordinator.finalize` operates with the full workflow available, it can resolve context there. Alternatively, store the effective_context on the CausalContext during prepare so it's available during finalize.

### 9E: Introspection — walk into FanIn

**File:** `lib/workflow.ex`

Update `required_context_keys/1` to also inspect FanIn vertices for `meta_refs`. Currently it only looks at vertices that have a `meta_refs` field and a `name` field. FanIn now has both (after adding `name` in 9C).

### 9F: Tests for Phase 9

**File:** `test/workflow/run_context_test.exs` (extend)

```
describe "context/1 in reduce"
  - reduce with context(:key) in reducer has meta_refs on FanIn struct
  - FanIn reducer is arity 3 when context is used
  - reduce without context/1 is unchanged
  - simple reduce with context receives values during execution
  - map-reduce with context in the reducer
  - reduce with context(:weight) applies weighted aggregation
  - required_context_keys/1 includes reduce context refs (under reduce name)
  - validate_run_context/2 checks reduce requirements

describe "reduce context runtime behavior"
  - context value changes between invocations affect reduce behavior
  - reduce without run_context set uses nil for context values
  - context does not affect content addressability of reduce
```

**Verification:** `mix test test/workflow/run_context_test.exs && mix test`

---

## Phase 10: `context/1` in StateMachine

**Goal:** Enable `context/1` in state machine reducer clauses and reactor functions. State machines are complex composite components — the `context/1` support needs to flow through their internal StateCondition and StateReaction nodes.

### 10A: Analysis — StateMachine internals

State machines compile into an internal workflow containing:
- An `Accumulator` holding current state
- `StateCondition` nodes (match on `(input, current_state)` → boolean)
- The accumulator's `reducer` (produces next state)
- Optional `StateReaction` nodes (side-effect functions)
- Optional `MemoryAssertion` nodes (check accumulator state)

`context/1` in a state machine reducer clause could appear in:
1. The guard/condition part → compiled into `StateCondition.work` (arity-2: input, state)
2. The body/transition part → compiled into the `Accumulator.reducer`
3. Reactor functions → compiled into `StateReaction.work`

### 10B: StateCondition — context support

**File:** `lib/workflow/state_condition.ex`

- Add `meta_refs: []` and `name: nil` to the `defstruct`
- Update `StateCondition.new/3` to accept optional `meta_refs` and `name` params

**File:** `lib/runic.ex`

In `build_reducer_workflow_ast/3`, the `state_cond_fun` is built from clause guards. To support `context/1`:
1. Run `detect_meta_expressions` on the clause guard AST
2. If context refs found, rewrite the state_cond_fun to arity-3: `(input, state, meta_ctx)`
3. Pass `meta_refs` to `StateCondition.new`

**File:** `lib/workflow/invokable.ex`

Update `Invokable` for `StateCondition`:
- `prepare/3`: Resolve meta_context and run_context when `meta_refs != []`
- `execute/2`: Call arity-3 work function when effective_context is present

### 10C: StateReaction — context support

**File:** `lib/workflow/state_reaction.ex`

- Add `meta_refs: []` and `name: nil` to the `defstruct`
- Update `StateReaction.new/1` to accept `meta_refs` and `name`

**File:** `lib/runic.ex`

In `maybe_add_reactors/3`, reactor functions are wrapped in arity-1 functions that receive the last known state. To support `context/1`:
1. Run `detect_meta_expressions` on each reactor clause body
2. If context refs found, rewrite to include `meta_ctx` parameter
3. Pass `meta_refs` and a generated name to `StateReaction.new`

**File:** `lib/workflow/invokable.ex`

Update `Invokable` for `StateReaction`:
- `prepare/3`: Resolve meta_context and run_context when `meta_refs != []`
- `execute/2`: Pass effective_context to the work function when present

### 10D: StateMachine name propagation

StateMachine internal components (StateCondition, StateReaction, Accumulator) need names for `get_run_context(workflow, name)` to resolve correctly. Currently, StateCondition and StateReaction don't have names.

**Approach:** During `workflow_of_state_machine/4`, derive names from the state machine name:
- StateConditions: `:"#{sm_name}_cond_#{index}"`
- StateReactions: `:"#{sm_name}_reactor_#{index}"`
- Accumulator: `:"#{sm_name}_acc"`

For `run_context` resolution, the parent state machine's name should be the primary lookup key. Add a resolution path: when a StateCondition/StateReaction has no component-specific context entry, fall back to the parent StateMachine's context entry.

This can be achieved by:
1. Storing the parent state machine name on the internal components
2. In `get_run_context/2`, checking both the component name and the parent name

Alternative (simpler): Use the state machine's name directly for all internal component lookups. Store `sm_name` on each internal component as a `context_name` field.

### 10E: Tests for Phase 10

**File:** `test/workflow/run_context_test.exs` (extend)

```
describe "context/1 in state_machine"
  - state machine with context(:key) in reducer guard has meta_refs on StateCondition
  - state machine with context(:key) in reducer body has meta_refs on Accumulator
  - state machine with context(:key) in reactor has meta_refs on StateReaction
  - context values available during state transition execution
  - state machine with context(:threshold) — transitions depend on runtime threshold
  - state machine without context/1 is unchanged
  - required_context_keys/1 includes state machine context refs

describe "state_machine context runtime behavior"
  - context value changes between react cycles affect transition behavior
  - state machine context works with react_until_satisfied
  - state machine context works with Runner
```

**Verification:** `mix test test/workflow/run_context_test.exs && mix test`

---

## Phase 11: Default Values & Fallback Functions for `context/1`

**Goal:** Allow `context/1` expressions to specify a default value or fallback function so workflows can operate without `run_context` being set — enabling mock/stub injection patterns and environment-specific defaults.

### 11A: Extended syntax

Support two new forms alongside the existing `context(:key)`:

```elixir
# Default literal value — used when run_context doesn't provide :api_key
context(:api_key, default: "test-key-xxx")

# Default function — called when run_context doesn't provide :api_key
context(:api_key, default: fn -> System.get_env("API_KEY") end)
```

The `context/1` form remains unchanged (resolves to `nil` when missing, preserving backward compatibility).

### 11B: Meta expression detection — default extraction

**File:** `lib/runic.ex`

Update `extract_meta_expression_with_fields/1` to handle the 2-arity `context/2` form:

```elixir
defp extract_meta_expression_with_fields({:context, _, [target, opts]}) when is_list(opts) do
  default = Keyword.get(opts, :default)
  {:ok, :context, target, [], default}
end

defp extract_meta_expression_with_fields({:context, _, [target]}) do
  {:ok, :context, target, [], nil}
end
```

Update the `meta_ref` map structure to include an optional `:default` field:

```elixir
%{
  kind: :context,
  target: :api_key,
  field_path: [],
  context_key: :api_key,
  default: "test-key-xxx"   # or fn -> ... end, or nil
}
```

### 11C: AST rewriting — default resolution

**File:** `lib/runic.ex`

Update `rewrite_meta_refs_in_ast/2` for the `context` clauses to generate code that checks for `nil` and applies the default:

```elixir
# context(:key) with default
{:context, _, [target]} when is_atom(target) ->
  ref = find_ref_by_target(meta_refs, target, :context)
  if ref do
    value_expr = quote(do: Map.get(unquote(meta_ctx_var), unquote(ref.context_key)))

    case ref.default do
      nil ->
        value_expr

      default when is_function(default) ->
        quote do
          case unquote(value_expr) do
            nil -> unquote(Macro.escape(default)).()
            val -> val
          end
        end

      default ->
        quote do
          case unquote(value_expr) do
            nil -> unquote(Macro.escape(default))
            val -> val
          end
        end
    end
  else
    node
  end
```

Note: Since defaults are embedded in the compiled function, they participate in the step's content hash (via the closure). Two steps with different defaults produce different hashes. This is correct — they are semantically different components.

### 11D: Runtime resolution — default application

**File:** `lib/workflow/private.ex`

Update `resolve_context_refs/2` to apply defaults when the resolved value is `nil`:

```elixir
defp resolve_context_refs(%Workflow{} = workflow, node) do
  meta_refs = Map.get(node, :meta_refs, [])

  meta_refs
  |> Enum.filter(fn ref -> ref.kind == :context end)
  |> Enum.reduce(%{}, fn ref, acc ->
    component_ctx = Workflow.get_run_context(workflow, node.name)
    value = Map.get(component_ctx, ref.target)

    resolved =
      case {value, Map.get(ref, :default)} do
        {nil, nil} -> nil
        {nil, default} when is_function(default) -> default.()
        {nil, default} -> default
        {value, _} -> value
      end

    Map.put(acc, ref.context_key, resolved)
  end)
end
```

This provides two layers of defaulting:
1. **AST-level:** The compiled function itself has a `case nil -> default` fallback, so even when executed remotely (three-phase dispatch) without the workflow, defaults work.
2. **Prepare-level:** `resolve_context_refs` applies defaults when building meta_context, so the default value flows into the CausalContext.

### 11E: Introspection — defaults in required_context_keys

**File:** `lib/workflow.ex`

Update `required_context_keys/1` to distinguish between required (no default) and optional (has default) context keys:

```elixir
@doc """
Returns a map of component names to their context key requirements.

Keys are annotated with whether they have defaults:
  %{call_llm: [api_key: :required, model: {:optional, "gpt-4"}]}
"""
@spec required_context_keys(t()) :: %{atom() => keyword()}
```

Update `validate_run_context/2` to only report keys WITHOUT defaults as missing:

```elixir
# Keys with defaults are satisfied even without explicit run_context entries
```

### 11F: Tests for Phase 11

**File:** `test/workflow/run_context_test.exs` (extend)

```
describe "context/2 with default literal"
  - step with context(:key, default: "fallback") has default in meta_ref
  - step uses default when run_context does not provide key
  - step uses run_context value when provided (overrides default)
  - default is embedded in closure — different defaults produce different hashes
  - default works in conditions
  - default works in rule where/then clauses
  - default works in accumulator reducer

describe "context/2 with default function"
  - step with context(:key, default: fn -> System.get_env("KEY") end) uses fn
  - default function is called each time (not cached)
  - default function works in three-phase dispatch

describe "context/2 interaction with validate_run_context"
  - keys with defaults are NOT reported as missing
  - keys without defaults ARE reported as missing
  - required_context_keys distinguishes required vs optional

describe "context/2 backward compatibility"
  - context(:key) without default still resolves to nil when missing
  - existing workflows unchanged
```

**Verification:** `mix test test/workflow/run_context_test.exs && mix test`

---

## Phase 12: Documentation for Phases 7–11

**Goal:** Update all documentation to cover `context/1` in accumulators, map, reduce, state machines, and the default value mechanism.

### 12A: Module-level documentation

- **`lib/workflow/accumulator.ex` `@moduledoc`**: Add a "Runtime Context" section explaining `context/1` in reducer functions with examples.

- **`lib/workflow/reduce.ex` `@moduledoc`**: Add a "Runtime Context" section explaining `context/1` in reducer functions, noting that context is resolved via the reduce component's name.

- **`lib/workflow/fan_in.ex` `@moduledoc`**: Note that FanIn supports `meta_refs` for `context/1` when used as part of a reduce.

- **`lib/workflow/map.ex` `@moduledoc`**: Add a "Runtime Context" section explaining that `context/1` in map pipeline steps is supported, with examples.

- **`lib/workflow/state_machine.ex` `@moduledoc`**: Add a "Runtime Context" section covering `context/1` in reducer clauses and reactors.

- **`lib/workflow/state_condition.ex` `@moduledoc`**: Note that state conditions support `meta_refs` for `context/1` expressions.

- **`lib/workflow/state_reaction.ex` `@moduledoc`**: Note that state reactions support `meta_refs` for `context/1` expressions.

### 12B: Guide updates

- **`guides/cheatsheet.md`**: Update the `context/1` section to include accumulator, map, reduce, and state_machine examples. Add `context/2` with default syntax.

- **`guides/execution-strategies.md`**: Update the runtime context section to cover all component types and the default value mechanism.

### 12C: Docstrings on new/updated functions

- `Accumulator.has_meta_refs?/1`
- `FanIn.has_meta_refs?/1`
- `maybe_compile_meta_reducer/3` (private, but `@doc false`)
- Updated `required_context_keys/1` with optional/required distinction
- Updated `validate_run_context/2` with default-aware validation

### 12D: README updates

- **`README.md`**: Update the `context/1` example section to show usage across component types and with defaults.

---

## Phase Summary & Dependencies (Extended)

```
Phase 1 ─── Foundation (structs, API)
  │
  ▼
Phase 2 ─── context/1 Macro (compile-time)
  │
  ▼
Phase 3 ─── Runtime Resolution ──┬── Stream A: prepare_meta_context + Component.connect
  │                               └── Stream B: Invokable.prepare + execute
  ▼
Phase 4 ─── Runtime API (react, runner)
  │
  ▼
Phase 5 ─── Introspection & Validation
  │
  ▼
Phase 6 ─── Documentation (Phases 1-5)
  │
  ├── Phase 7 ─── Accumulator context/1 ─────────┐
  ├── Phase 8 ─── Map context/1 ─────────────────┤
  ├── Phase 9 ─── Reduce context/1 ──────────────┤ (parallelizable)
  └── Phase 10 ── StateMachine context/1 ────────┘
       │
       ▼
  Phase 11 ─── Default Values / Fallback Functions
       │
       ▼
  Phase 12 ─── Documentation (Phases 7-11)
```

Phases 7, 8, 9, 10 can be parallelized — they each touch different component types. Phase 7's `maybe_compile_meta_reducer` helper is reused by Phase 9.

Phase 11 depends on Phases 7–10 being stable so defaults work across all component types.

Phase 12 depends on all prior phases.

---

## Extended Files Modified (Phases 7–12)

| File | Changes |
|---|---|
| `lib/runic.ex` | `maybe_compile_meta_reducer/3`, accumulator macro context detection, reduce macro context detection, state_machine clause context detection, `context/2` form in `extract_meta_expression_with_fields`, `rewrite_meta_refs_in_ast` default handling, public `detect_meta_expressions/1` and `rewrite_meta_refs_in_ast/2` |
| `lib/workflow/accumulator.ex` | `meta_refs: []` field, `has_meta_refs?/1`, `@moduledoc` update |
| `lib/workflow/fan_in.ex` | `meta_refs: []` field, `name: nil` field, `has_meta_refs?/1`, `@moduledoc` update |
| `lib/workflow/reduce.ex` | `@moduledoc` update |
| `lib/workflow/map.ex` | `@moduledoc` update |
| `lib/workflow/state_machine.ex` | `@moduledoc` update |
| `lib/workflow/state_condition.ex` | `meta_refs: []` field, `name: nil` field, `@moduledoc` update |
| `lib/workflow/state_reaction.ex` | `meta_refs: []` field, `name: nil` field, `@moduledoc` update |
| `lib/workflow/invokable.ex` | Accumulator prepare/execute context, FanIn prepare/execute context, StateCondition prepare/execute context, StateReaction prepare/execute context |
| `lib/workflow/component.ex` | Accumulator `connect/3` meta_ref edges |
| `lib/workflow/private.ex` | `resolve_context_refs/2` default application |
| `lib/workflow/compilation_utils.ex` | `pipeline_step/1` meta expression support |
| `lib/workflow.ex` | `required_context_keys/1` optional/required distinction, `validate_run_context/2` default-aware validation |
| `guides/cheatsheet.md` | `context/2` syntax, all component examples |
| `guides/execution-strategies.md` | All component types, defaults |
| `README.md` | Extended context examples |

## Files Modified in Tests

| File | Purpose |
|---|---|
| `test/workflow/run_context_test.exs` | Extended with accumulator, map, reduce, state_machine, and default value tests |

---

## Risk Areas & Testing Focus (Phases 7–12)

### Accumulator arity change

Accumulator reducers are currently always arity-2 `(value, acc)`. Introducing arity-3 `(value, acc, meta_ctx)` changes the calling convention. The `apply(acc.reducer, [value, state])` calls must be updated to check arity first.

**Test:** Existing accumulator tests pass unchanged. New accumulator with `context/1` has arity-3 reducer. Both paths work in the same workflow.

### FanIn coordination with context

The FanIn `fan_out_reduce` mode involves deferred execution and coordination across multiple fact arrivals. Context must be consistently available across all coordination attempts.

**Test:** Map-reduce with context in the reducer produces correct results for multi-element input lists.

### StateMachine compilation complexity

State machines have the most complex compilation pipeline. `context/1` detection must happen at the right phase of clause processing — before the state_cond_fun and reactor functions are fully wrapped.

**Test:** State machine with `context(:threshold)` in a guard-like clause correctly transitions based on runtime threshold values.

### Default function serialization

Default functions (fn → ...) are closures. They must serialize correctly for `build_log/1` and `from_log/1`. Since defaults are embedded in the meta_ref map which is stored on the struct, they will be part of the closure's captured bindings.

**Test:** A workflow with `context(:key, default: fn -> "test" end)` survives `build_log |> from_log` round-trip and produces correct results.

### Meta_refs field absence on existing structs

Adding `meta_refs: []` to Accumulator, FanIn, StateCondition, and StateReaction is a struct change. Existing serialized workflows (via `build_log`) may not have this field. The `Map.get(node, :meta_refs, [])` pattern in `resolve_context_refs/2` provides safe fallback, but deserialization of old structs needs verification.

**Test:** Deserializing a pre-Phase-7 workflow struct (without `meta_refs` field on Accumulator) does not crash and behaves correctly.
