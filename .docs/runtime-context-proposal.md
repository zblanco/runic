# Runtime Context for Runic Workflows — Design Proposal

## Motivation

Runic workflows need access to ambient environment values — secrets, tenant IDs, database URLs, rate-limit tokens — that are:

1. **Not part of the data plane** (should not flow through the fact graph or appear in logs/replays)
2. **Not known at build time** (unlike closure bindings which capture values when the workflow is constructed)
3. **Set once per execution run** at the Runner/scheduler boundary
4. **Available to steps** during their work function invocation

Today, Runic has two mechanisms that partially overlap with this need:

- **Closure bindings** (`^var` capture): Bake values into the component at *construction time*. Not portable — rebuilding the workflow for a different workspace requires reconstructing closures.
- **Meta-context** (`meta_refs` / `state_of`): Reads *workflow-internal* state (e.g., accumulator values) into the `CausalContext` during the prepare phase. Scoped to graph-resident data, not external environment.

Neither mechanism cleanly supports injecting external, run-scoped values without polluting the fact graph or coupling the workflow definition to a specific deployment context.

---

## Design Constraints

Any solution must respect Runic's core properties:

| Property | Constraint |
|---|---|
| **Purely functional data plane** | Context must not alter fact hashes, fact ancestry, or the causal graph |
| **Content addressability** | Workflow hash must be independent of context — same workflow, different context = same hash |
| **Serializable / replayable** | Context values are *not* part of the event log; replay reproduces the same graph without needing the original context |
| **Three-phase execution model** | Context must be available during Phase 2 (execute) without requiring a workflow reference |
| **Distributed dispatch** | Context must travel with `%Runnable{}` structs to remote executors |
| **Composability** | Sub-workflows composed into a parent should inherit context naturally |

---

## Recommended Approach: Component-Keyed Run Context

The core idea: **components reference external values they need, and the runtime API provides those values keyed by component name.** The workflow struct carries a `run_context` map as a staging area, but the *primary user-facing API* is at the runtime boundary (`react`, `react_until_satisfied`, `plan_eagerly`, or Runner opts). The values flow through the existing `CausalContext` into `Runnable` structs, keeping the construction layer clean.

### Design Overview

```
Build time (clean)                    Runtime (context provided)
     │                                     │
     │  step(fn input, ctx ->              │  react_until_satisfied(workflow, input,
     │    ctx.api_key                      │    run_context: %{
     │    ...                              │      call_llm: %{api_key: "sk-..."},
     │  end, name: :call_llm)             │      db_query: %{repo: MyRepo, tenant: "t1"}
     │                                     │    })
     │  # step has no idea what            │
     │  # api_key's value is               │  # OR at Runner level:
     │                                     │  Runner.run(runner, workflow_id, input,
     │                                     │    run_context: %{...})
```

### Step Definition

A step that needs external context is simply an arity-2 function. No special macro, no new DSL — just a function that accepts `(input, context)`:

```elixir
step(fn input, ctx ->
  api_key = ctx.api_key
  call_llm(api_key, input)
end, name: :call_llm)

step(fn input, ctx ->
  repo = ctx.repo
  tenant = ctx.tenant
  Repo.query(repo, "SELECT ...", [tenant])
end, name: :db_query)
```

At build time, `ctx` is unbound — the step doesn't know or care what values it will receive. The workflow is fully portable and content-addressable.

### Runtime API

Context is provided at the execution boundary, keyed by component name:

```elixir
# Via react_until_satisfied
workflow
|> Workflow.react_until_satisfied(input,
  run_context: %{
    call_llm: %{api_key: resolved_key, model: "gpt-4"},
    db_query: %{repo: MyApp.Repo, tenant: workspace_id}
  }
)

# Via react
workflow
|> Workflow.react(input,
  run_context: %{
    call_llm: %{api_key: resolved_key}
  }
)

# Via plan_eagerly + prepare_for_dispatch (external scheduler)
workflow = Workflow.put_run_context(workflow, %{
  call_llm: %{api_key: resolved_key},
  db_query: %{repo: MyApp.Repo, tenant: workspace_id}
})
workflow = Workflow.plan_eagerly(workflow, input)
{workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

# Via Runner
Runner.run(runner, workflow_id, input,
  run_context: %{
    call_llm: %{api_key: resolved_key}
  }
)
```

### Data Flow

```
react(workflow, input, run_context: %{call_llm: %{api_key: "sk-..."}})
  │
  ├─ stores run_context on workflow: %{workflow | run_context: ctx}
  │
  ├─ plan_eagerly → marks runnables
  │
  ├─ prepare_for_dispatch
  │     │
  │     └─ Invokable.prepare(step, workflow, fact)
  │           │
  │           ├─ looks up workflow.run_context[step.name]  →  %{api_key: "sk-..."}
  │           │
  │           └─ puts it into CausalContext.run_context
  │                 │
  │                 └─ Runnable{context: %CausalContext{run_context: %{api_key: "sk-..."}}}
  │
  ├─ Invokable.execute(step, runnable)
  │     │
  │     ├─ arity-2 work fn? → step.work.(input, ctx.run_context)
  │     │                              ↑ merged with meta_context if both present
  │     └─ arity-1 work fn? → Components.run(step.work, input, 1)  (unchanged)
  │
  └─ apply_runnable → fold events into workflow (run_context NOT in events)
```

### Interaction with `meta_context`

Steps can already be arity-2 when they have `meta_refs` (e.g., `state_of(:counter)`). The existing `Step.run_with_meta_context/3` handles this. With `run_context`, we have two sources of second-argument data. The approach:

1. **No `meta_refs` + has `run_context`**: second arg is `run_context`
2. **Has `meta_refs` + no `run_context`**: second arg is `meta_context` (existing behavior)
3. **Has `meta_refs` + has `run_context`**: merge them — `meta_context` keys override `run_context` keys (graph-derived state is more specific than ambient environment)
4. **Neither**: arity-1 path, unchanged

```elixir
# In Invokable.execute for Step:
effective_context = merge_contexts(ctx.meta_context, ctx.run_context)

if effective_context != %{} and arity >= 2 do
  step.work.(fact.value, effective_context)
else
  Components.run(step.work, fact.value, arity)
end

defp merge_contexts(meta, run) when meta == %{} and run == %{}, do: %{}
defp merge_contexts(meta, run) when run == %{}, do: meta
defp merge_contexts(meta, run) when meta == %{}, do: run
defp merge_contexts(meta, run), do: Map.merge(run, meta)
```

This means a step with both `state_of(:counter)` and external secrets sees them in one map:
```elixir
step(fn input, ctx ->
  count = ctx.counter_state   # from meta_context (workflow graph)
  key = ctx.api_key            # from run_context (runtime injection)
  ...
end, name: :my_step)
```

### Why Component-Keyed?

Keying by component name rather than a flat global map provides:

1. **Least-privilege by default** — each step only sees the context intended for it, not the entire environment. A step named `:call_llm` only gets `run_context[:call_llm]`.

2. **Clear contract** — the component name acts as a contract: "to run this workflow, provide context for these named components." This is inspectable:
   ```elixir
   # Which components need run_context? Any arity-2 step without meta_refs.
   Workflow.components_requiring_context(workflow)
   # => [:call_llm, :db_query]
   ```

3. **No collision** — different steps can have different `api_key` values without namespace collision.

4. **Composable** — when sub-workflows are composed, their components keep their names. The runner provides a flat map keyed by all component names across the composed graph.

### Broadcast / Global Context

Sometimes you want a value available to *all* steps (e.g., `workspace_id`, `tenant_id`). Support this with a `:_global` key that's merged into every component's context:

```elixir
Workflow.react_until_satisfied(workflow, input,
  run_context: %{
    _global: %{workspace_id: "ws1", tenant_id: "t1"},
    call_llm: %{api_key: "sk-..."}
  }
)
```

Resolution order (later overrides earlier):
1. `_global` context
2. Component-specific context (by name)
3. `meta_context` (from graph state)

This keeps the common case simple while preserving least-privilege for component-specific values.

---

## Explicit Meta Reference API for Run Context

The existing `meta_refs` pipeline (`state_of`, `step_ran?`, `fact_count`, etc.) detects special function calls in the AST at compile time, rewrites them to `Map.get(meta_ctx, :context_key)`, and stores reference metadata on the component struct. This machinery can be extended with new meta expression kinds for runtime context values.

### Why an Explicit Meta Ref?

Without it, arity-2 steps are ambiguous: does the second argument come from `meta_context` (graph state), `run_context` (external injection), or both? An explicit meta ref like `context(:api_key)` makes the *intent* clear at the definition site, enables compile-time detection of which components need external context, and lets the prepare phase resolve exactly what each component requires.

It also means standalone `step` macros (not just rules) can participate in the meta_refs system — currently `detect_meta_expressions` is only called during rule compilation. Extending it to steps would let:

```elixir
# A step that explicitly declares it needs an external value
step(fn input ->
  api_key = context(:api_key)
  call_llm(api_key, input)
end, name: :call_llm)
```

...compile into an arity-2 function with `meta_refs` on the Step struct, just like `state_of` does for rules today.

### Candidate Names

| Meta Expression | Suffix for `context_key` | Semantics |
|---|---|---|
| `context(:api_key)` | (none — key is the target itself) | Generic external value. Clear, short, mirrors `state_of` pattern. |
| `run_context(:api_key)` | (none) | More explicit about *when* it's provided. Longer. |
| `env(:database_url)` | `_env` | OS-env connotation might confuse. |
| `secret(:openai_key)` | `_secret` | Too specific — context isn't always secrets. |
| `provided(:tenant_id)` | `_provided` | Clear about external origin. Unusual verb form. |
| `inject(:workspace_id)` | `_injected` | DI terminology. Not very Elixir-idiomatic. |
| `external(:rate_limit)` | `_external` | Clear but verbose. |

**Recommendation: `context/1`** — it's the shortest, most natural name. It reads well in both steps and rules, and the naming mirrors the `run_context` API at the runtime boundary. If we want to distinguish from Elixir's generic use of "context", `run_context/1` is the safe alternative.

### Construction Examples

#### Standalone Steps

```elixir
# Simple — one external value
step(fn input ->
  api_key = context(:api_key)
  LLM.complete(api_key, input)
end, name: :call_llm)

# Multiple external values
step(fn input ->
  repo = context(:repo)
  tenant = context(:tenant_id)
  Repo.all(repo, from(u in User, where: u.tenant_id == ^tenant))
end, name: :load_users)

# Field access (like state_of(:config).enabled)
step(fn input ->
  pool_size = context(:database).pool_size
  # ...
end, name: :db_query)
```

#### Rules with `context/1` in Where and Then Clauses

```elixir
# Feature flag gating in a condition
rule name: :premium_feature do
  given(request: req)
  where(context(:feature_flags).premium_enabled == true)
  then(fn %{request: req} -> process_premium(req) end)
end

# Secret in the reaction
rule name: :notify do
  given(event: event)
  where(event.type == :alert)
  then(fn %{event: event} ->
    webhook_url = context(:webhook_url)
    notify(webhook_url, event)
  end)
end

# Mixed with state_of — both graph state and external context
rule name: :rate_limited_action do
  given(request: req)
  where(state_of(:request_counter) < context(:rate_limit))
  then(fn %{request: req} ->
    api_key = context(:api_key)
    call_api(api_key, req)
  end)
end
```

#### Conditions as Standalone Components

```elixir
condition(fn input ->
  min_tier = context(:min_tier)
  input.user.tier >= min_tier
end, name: :tier_gate)
```

### Compile-Time Behavior

The `step/1,2` macro would detect `context(:key)` calls the same way `rule` detects `state_of(:name)`:

1. `detect_meta_expressions(ast)` finds `context(:api_key)` → produces `%{kind: :context, target: :api_key, field_path: [], context_key: :api_key}`
2. `rewrite_meta_refs_in_ast(ast, meta_refs)` rewrites to `Map.get(var!(meta_ctx, Runic), :api_key)`
3. The work function becomes arity-2: `fn input, meta_ctx -> ... end`
4. `meta_refs: [%{kind: :context, target: :api_key, ...}]` is stored on the Step struct

For `context_key` derivation, unlike `state_of` which appends `_state`, `context/1` uses the target directly — `context(:api_key)` → context_key `:api_key`. This is because external context keys are user-chosen names, not component references.

```elixir
# In build_context_key/2:
:context -> ""  # target IS the key: context(:api_key) → :api_key

# Or more precisely:
defp build_context_key(target, :context) when is_atom(target), do: target
```

### Prepare-Phase Resolution

During `Invokable.prepare/3`, `context`-kind meta_refs are resolved differently from `state_of`-kind refs. Instead of traversing `:meta_ref` graph edges to read graph state, they read from `workflow.run_context`:

```elixir
def prepare_meta_context(%Workflow{} = workflow, node) do
  # Existing: resolve graph-based meta_refs via :meta_ref edges
  graph_context = resolve_graph_meta_refs(workflow, node)

  # NEW: resolve context-kind meta_refs from run_context
  external_context = resolve_external_meta_refs(workflow, node)

  Map.merge(external_context, graph_context)
end

defp resolve_external_meta_refs(%Workflow{run_context: run_ctx}, node) do
  node
  |> meta_refs_of_kind(:context)
  |> Enum.reduce(%{}, fn ref, acc ->
    # Look up in run_context — first by component name, then global
    component_ctx = Workflow.get_run_context(workflow, node.name)
    value = Map.get(component_ctx, ref.target)
    Map.put(acc, ref.context_key, value)
  end)
end
```

This means `context(:api_key)` refs don't need `:meta_ref` edges in the graph at all — they're not references to other *components*, they're references to *external values*. This is a key distinction from `state_of`. No edges, no `Component.connect` changes, no `UnresolvedReferenceError` at build time.

### What `context/1` Refs Enable

With explicit refs, we get compile-time introspection for free:

```elixir
# Which external context keys does this workflow need?
Workflow.required_context_keys(workflow)
# => %{call_llm: [:api_key], db_query: [:repo, :tenant_id], _conditions: [:feature_flags]}

# Validate at the runner boundary before execution
Workflow.validate_run_context(workflow, provided_context)
# => :ok | {:error, missing: [call_llm: [:api_key]]}
```

This is significantly more useful than the implicit arity-2 approach — the workflow can *tell you* what it needs.

### Comparison: Implicit Arity-2 vs Explicit `context/1`

| Aspect | Implicit arity-2 | Explicit `context/1` |
|---|---|---|
| Step definition | `fn input, ctx -> ctx.api_key end` | `fn input -> context(:api_key) end` |
| Intent clarity | Ambiguous — is 2nd arg meta? run? | Explicit — this is an external value |
| Introspection | Can't distinguish run_context from meta_context needs | `meta_refs` on struct says exactly what's needed |
| Validation | Runtime KeyError on missing values | `validate_run_context/2` before execution |
| Rule integration | Awkward — rule DSL doesn't expose 2nd arg | Natural — `context(:key)` in where/then |
| Standalone steps | Works but requires step macro changes for arity detection | Works via existing `detect_meta_expressions` pipeline |
| Both meta + context | Merged map, key collision possible | Separate meta_ref kinds, explicit resolution |
| Backward compat | Fully compatible | Fully compatible (additive) |

**Recommendation:** Support *both*. The explicit `context/1` ref is the primary, recommended API. An arity-2 step without `meta_refs` or `context` refs still receives `run_context` as a fallback for simple/ad-hoc usage. But `context/1` is what we document, what enables validation, and what composes cleanly with the rule DSL.

### Implementation Path for `context/1`

1. Add `:context` to `@meta_expression_kinds` in `lib/runic.ex`
2. Update `build_context_key/2` — `context` kind uses target directly as key
3. Update `rewrite_meta_refs_in_ast/2` — add clause for `context(:key)` rewriting
4. Update `step/1,2` macros — call `detect_meta_expressions` on work AST, if found, rewrite to 2-arity and store `meta_refs` on Step struct
5. Update `prepare_meta_context` (or add parallel resolver) — resolve `:context`-kind refs from `workflow.run_context` instead of graph edges
6. Skip `:meta_ref` edge creation for `:context`-kind refs in `Component.connect` (no graph target to point to)
7. Add `Workflow.required_context_keys/1` for introspection
8. Add `Workflow.validate_run_context/2` for runner-level validation

---

## Workflow Struct Changes

### `run_context` Field

```elixir
defstruct [
  # ... existing fields ...
  run_context: %{}
]
```

**Not included in workflow hash.** Same as `inputs`, `mapped`, `runnable_events` — runtime state, not definition.

### API

```elixir
@spec put_run_context(t(), map()) :: t()
def put_run_context(%__MODULE__{} = workflow, context) when is_map(context) do
  %{workflow | run_context: Map.merge(workflow.run_context, context)}
end

@spec get_run_context(t()) :: map()
def get_run_context(%__MODULE__{run_context: ctx}), do: ctx

@spec get_run_context(t(), atom()) :: map()
def get_run_context(%__MODULE__{run_context: ctx}, component_name) when is_atom(component_name) do
  global = Map.get(ctx, :_global, %{})
  component = Map.get(ctx, component_name, %{})
  Map.merge(global, component)
end
```

---

## CausalContext Changes

Add `run_context: %{}`:

```elixir
defstruct [
  # ... existing fields ...
  run_context: %{}
]

@spec with_run_context(t(), map()) :: t()
def with_run_context(%__MODULE__{} = ctx, run_context) when is_map(run_context) do
  %{ctx | run_context: run_context}
end
```

---

## Invokable.prepare Changes (Step)

```elixir
def prepare(%Step{} = step, %Workflow{} = workflow, %Fact{} = fact) do
  fan_out_context = build_fan_out_context(workflow, step, fact)

  meta_context =
    if Step.has_meta_refs?(step) do
      Workflow.prepare_meta_context(workflow, step)
    else
      %{}
    end

  # NEW: resolve component-keyed run_context for this step
  run_context = Workflow.get_run_context(workflow, step.name)

  context =
    CausalContext.new(
      node_hash: step.hash,
      input_fact: fact,
      ancestry_depth: Workflow.ancestry_depth(workflow, fact),
      hooks: Workflow.get_hooks(workflow, step.hash),
      fan_out_context: fan_out_context,
      meta_context: meta_context,
      run_context: run_context         # NEW
    )

  {:ok, Runnable.new(step, fact, context)}
end
```

---

## Invokable.execute Changes (Step)

```elixir
def execute(%Step{} = step, %Runnable{input_fact: fact, context: ctx} = runnable) do
  with {:ok, before_apply_fns} <- HookRunner.run_before(ctx, step, fact) do
    try do
      result = run_step_work(step, fact.value, ctx)

      result_fact = Fact.new(value: result, ancestry: {step.hash, fact.hash})
      # ... rest unchanged
    rescue
      e -> Runnable.fail(runnable, e)
    end
  end
end

defp run_step_work(step, input, ctx) do
  effective_context = merge_contexts(ctx.meta_context, ctx.run_context)
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

defp merge_contexts(meta, run) when map_size(meta) == 0 and map_size(run) == 0, do: %{}
defp merge_contexts(meta, run) when map_size(run) == 0, do: meta
defp merge_contexts(meta, run) when map_size(meta) == 0, do: run
defp merge_contexts(meta, run), do: Map.merge(run, meta)
```

---

## Runtime API Integration

### `react/2,3`

```elixir
def react(%__MODULE__{} = wrk, %Fact{ancestry: nil} = fact, opts) do
  wrk
  |> maybe_apply_run_context(opts)
  |> invoke(root(), fact)
  |> react(opts)
end

defp maybe_apply_run_context(workflow, opts) do
  case Keyword.get(opts, :run_context) do
    nil -> workflow
    ctx when is_map(ctx) -> put_run_context(workflow, ctx)
  end
end
```

### `react_until_satisfied/2,3`

Same pattern — `maybe_apply_run_context` in the entry points before delegation to `do_react_until_satisfied`.

### Runner Worker

The Worker's `handle_cast({:run, input, opts}, state)` extracts `run_context` from opts and applies it to the workflow before `plan_eagerly`:

```elixir
def handle_cast({:run, input, opts}, %__MODULE__{status: status} = state)
    when status in [:idle, :running] do
  policies = merge_runtime_policies(opts, state.workflow.scheduler_policies)

  workflow =
    state.workflow
    |> maybe_set_policies(policies, state.workflow.scheduler_policies)
    |> maybe_apply_run_context(opts)      # NEW
    |> Workflow.plan_eagerly(input)

  state = %{state | workflow: workflow, status: :running}
  state = dispatch_runnables(state)
  state = maybe_transition_to_idle(state)

  {:noreply, state}
end
```

---

## Content Addressability Analysis

**Does `run_context` break content addressability?**

No. Content addressability in Runic is based on:
- Component hashes (derived from work function AST + closure bindings)
- Fact hashes (derived from value content)
- Graph topology (edges between hashed vertices)

`run_context` participates in none of these. It is analogous to `scheduler_policies`, `before_hooks`, `after_hooks`, `inputs`, `mapped` — all runtime state that does not affect the workflow's content hash. Two workflows with identical graph topology and components but different `run_context` values have the same hash.

**Does it break functional purity?**

The data plane remains pure — facts flow through the graph based on step outputs, and the causal ancestry is fully determined by step hashes and input fact hashes. `run_context` is an *input to the work function* the same way the fact value is — it doesn't introduce hidden mutation or side-channel state in the graph.

The key distinction: closure bindings are *part of the component definition* (they affect the hash). Run context is *part of the execution environment* (it does not affect the hash). This is the correct separation — the same workflow definition should be executable in different environments.

**Replay / Event Sourcing:**

When replaying from a log, `run_context` is not in the events. The replayed facts have the same hashes because they were produced by the same step hashes + input fact hashes. If a user wants to *re-execute* (not replay) a workflow in a different environment, they provide new `run_context` — and get new fact values. This is expected and correct.

---

## Distributed Dispatch

`run_context` travels naturally through the existing path:

1. `Workflow.run_context` → copied into `CausalContext.run_context` during `prepare/3`
2. `CausalContext` is stored on `Runnable.context`
3. `Runnable` is serialized and dispatched to remote executor
4. Remote executor calls `Invokable.execute(runnable.node, runnable)` → reads `ctx.run_context`

No new fields on `Runnable` needed. CausalContext already carries `meta_context`, `fan_out_context`, etc. through the same path.

---

## Secret References (Follow-Up)

`SecretRef` is orthogonal to the context plumbing — it's a value type that can live inside `run_context`:

```elixir
Workflow.react_until_satisfied(workflow, input,
  run_context: %{
    call_llm: %{api_key: %SecretRef{name: "openai_key", provider: :vault}}
  }
)
```

Resolution would happen at the executor boundary (Runner or custom executor) before `Invokable.execute`. This can be a before-hook or an executor concern. Recommend deferring to a follow-up.

---

## Implementation Steps

1. Add `run_context: %{}` to `%Workflow{}` defstruct and `@type t()`
2. Add `Workflow.put_run_context/2`, `Workflow.get_run_context/1`, `Workflow.get_run_context/2`
3. Add `run_context: %{}` to `%CausalContext{}` defstruct and `@type t()`
4. Add `CausalContext.with_run_context/2`
5. Update `Invokable.prepare/3` for Step to resolve component-keyed `run_context` from workflow and put into CausalContext
6. Update `Invokable.execute/2` for Step to merge `run_context` with `meta_context` and pass to arity-2 work functions
7. Add `maybe_apply_run_context/2` helper, wire into `react/2,3` and `react_until_satisfied/2,3`
8. Wire into Runner Worker `handle_cast({:run, ...})`
9. Optionally add `Workflow.components_requiring_context/1` for introspection
10. Also update Condition `prepare/execute` if conditions should receive run_context (feature flags use case)
11. Tests: context in steps, component-keyed scoping, `_global` merge, meta+run merge, isolation from fact graph, distributed dispatch round-trip

---

## Open Questions

1. **Should Conditions also receive `run_context`?** Useful for feature flags (`ctx.feature_enabled?`). Same arity-2 pattern applies. Recommend yes, as a follow-up.

2. **Validation / introspection**: Should we provide `Workflow.components_requiring_context/1` that returns names of arity-2 steps without `meta_refs`? Helpful for runner-level validation ("you forgot to provide context for `:db_query`").

3. **Name normalization**: Component names can be atoms or strings. `get_run_context/2` should normalize. Current `SchedulerPolicy` resolver already does this via `normalize_name/1` — we can reuse the pattern.

4. **Should `_global` be a reserved key or a separate API?** Could also be `Workflow.react(w, input, run_context: ctx, global_context: %{workspace_id: "ws1"})`. The `_global` convention is simpler but slightly implicit.
