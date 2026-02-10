# Runic Three-Phase Runtime Refactor - Implementation Plan

**Status:** Active Development  
**Date:** January 2026

---

## Executive Summary

This plan breaks down the causal runtime architecture and invokable three-phase refactor into actionable phases. The goal is to improve the Runic Workflow runtime for:

1. **Memory efficiency** — Extract minimal context instead of copying entire workflows
2. **Better decomposition** — Decouple `prepare → execute → apply` for dynamic workflow variance
3. **Controlled execution** — Enable external scheduling, worker pools, and durable execution patterns

---

## Core Contract Changes

### Invokable Protocol (Revised)

```elixir
defprotocol Runic.Workflow.Invokable do
  @spec match_or_execute(node :: struct()) :: :match | :execute
  def match_or_execute(node)

  @doc """
  PREPARE: Build a Runnable with minimal context from the workflow.
  
  Returns:
  - `{:ok, %Runnable{}}` — Ready to execute
  - `{:skip, fun()}` — Node should not execute; fun is `(Workflow.t() -> Workflow.t())` reducer
  - `{:defer, fun()}` — Node is waiting for more data; fun is `(Workflow.t() -> Workflow.t())` reducer
  
  The skip/defer reducers enable future parallelization of the match phase.
  """
  @spec prepare(node :: struct(), workflow :: Workflow.t(), fact :: Fact.t()) ::
    {:ok, Runnable.t()} | {:skip, fun()} | {:defer, fun()}
  def prepare(node, workflow, fact)

  @doc """
  EXECUTE: Run the node's work in isolation. No workflow access.
  
  Returns a Runnable with populated result state and apply_fn reducer.
  The execute implementation calls a private `build_apply/3` to construct
  the apply_fn based on execution results.
  """
  @spec execute(node :: struct(), runnable :: Runnable.t()) :: Runnable.t()
  def execute(node, runnable)
end
```

### Runnable Struct

```elixir
defmodule Runic.Workflow.Runnable do
  @moduledoc """
  A prepared unit of work ready for execution.
  
  Contains everything needed to execute independently of the source workflow,
  plus an apply_fn reducer for applying results back to the workflow.
  """
  
  defstruct [
    :id,                  # Unique identifier (hash of node + fact)
    :node,                # The invokable node struct
    :input_fact,          # The triggering fact
    :context,             # Minimal CausalContext for execution
    :result,              # Populated after execute: the computed result
    :apply_fn,            # fn(workflow) -> workflow — built during execute
    :status,              # :pending | :completed | :failed | :skipped
    :error                # Error info if failed
  ]
end
```

### Key Design Decision: `apply_fn` vs Protocol `apply/3`

Instead of requiring `Invokable.apply/3` as part of the protocol, each `execute/1` implementation builds the `apply_fn` higher-order reducer function and stores it on the `%Runnable{}`. This provides:

- Same polymorphism via closures capturing node/context state
- Simpler protocol surface (only 3 functions instead of 4)
- The apply_fn encapsulates all result states for that execution

---

## Phase 1: Foundation Structs & Infrastructure

**Duration:** 1-2 weeks  
**Risk:** Low  
**Dependencies:** None

### 1.1 Create Runnable Struct

**File:** `lib/workflow/runnable.ex`

```elixir
defmodule Runic.Workflow.Runnable do
  alias Runic.Workflow.Fact
  
  @type status :: :pending | :completed | :failed | :skipped
  
  @type t :: %__MODULE__{
    id: integer(),
    node: struct(),
    input_fact: Fact.t(),
    context: map(),
    result: term() | nil,
    apply_fn: (Workflow.t() -> Workflow.t()) | nil,
    status: status(),
    error: term() | nil
  }
  
  defstruct [
    :id,
    :node,
    :input_fact,
    :context,
    result: nil,
    apply_fn: nil,
    status: :pending,
    error: nil
  ]
  
  def new(node, fact, context) do
    %__MODULE__{
      id: runnable_id(node, fact),
      node: node,
      input_fact: fact,
      context: context,
      status: :pending
    }
  end
  
  defp runnable_id(node, fact) do
    :erlang.phash2({node.hash, fact.hash})
  end
end
```

### 1.2 Create CausalContext Module

**File:** `lib/workflow/causal_context.ex`

Minimal immutable context extracted from workflow during prepare phase:

```elixir
defmodule Runic.Workflow.CausalContext do
  @moduledoc """
  Minimal context for executing a runnable without the full workflow.
  Built during prepare phase, consumed during execute phase.
  """
  
  defstruct [
    :node_hash,           # Hash of the node being invoked
    :input_fact,          # The fact triggering this invocation
    :ancestry_depth,      # Depth in causal chain (replaces generation)
    :hooks,               # {before_hooks, after_hooks} for this node
    # Node-specific context fields (populated based on node type)
    :last_known_state,    # For stateful nodes (StateReaction, Accumulator, etc.)
    :satisfied_conditions, # For Conjunction
    :join_context,        # For Join: %{joins: [...], satisfied: %{}}
    :fan_out_context,     # For steps in mapped pipelines
    :fan_in_context       # For FanIn coordination
  ]
end
```

### 1.3 Update Invokable Protocol

**File:** `lib/workflow/invokable.ex`

Add new protocol functions while keeping `invoke/3` for backward compatibility during migration:

```elixir
defprotocol Runic.Workflow.Invokable do
  def match_or_execute(node)
  
  # Legacy - keep during migration
  def invoke(node, workflow, fact)
  
  # New three-phase API
  @spec prepare(node :: struct(), workflow :: Workflow.t(), fact :: Fact.t()) ::
    {:ok, Runnable.t()} | {:skip, fun()} | {:defer, fun()}
  def prepare(node, workflow, fact)
  
  @spec execute(node :: struct(), runnable :: Runnable.t()) :: Runnable.t()
  def execute(node, runnable)
end
```

### 1.4 Ancestry Depth Helper

Add to `Workflow` module:

```elixir
@doc """
Computes the causal depth of a fact by walking its ancestry chain.
Replaces generation counter for causal ordering.
"""
def ancestry_depth(%Fact{ancestry: nil}), do: 0
def ancestry_depth(%Fact{ancestry: {_producer_hash, parent_fact_hash}}, workflow) do
  parent_fact = workflow.graph.vertices[parent_fact_hash]
  1 + ancestry_depth(parent_fact, workflow)
end
```

### Deliverables Phase 1

- [x] `Runic.Workflow.Runnable` struct module
- [x] `Runic.Workflow.CausalContext` struct module  
- [x] Updated `Runic.Workflow.Invokable` protocol with `prepare/3` and `execute/2`
- [x] `Workflow.ancestry_depth/2` helper function
- [x] Unit tests for new structs

---

## Phase 2: Implement Prepare/Execute for Simple Nodes

**Duration:** 1-2 weeks  
**Risk:** Medium  
**Dependencies:** Phase 1

Implement the three-phase pattern for the simplest, fully parallelizable nodes first.

### 2.1 Step (Core Data Transformation)

**File:** `lib/workflow/invokable.ex` (Step impl)

```elixir
defimpl Runic.Workflow.Invokable, for: Runic.Workflow.Step do
  alias Runic.Workflow.{Runnable, CausalContext, Fact, Components}
  
  def match_or_execute(_), do: :execute
  
  # PREPARE - extract minimal context
  def prepare(%Step{} = step, workflow, fact) do
    context = %CausalContext{
      node_hash: step.hash,
      input_fact: fact,
      ancestry_depth: Workflow.ancestry_depth(fact, workflow),
      hooks: {
        Map.get(workflow.before_hooks, step.hash, []),
        Map.get(workflow.after_hooks, step.hash, [])
      },
      fan_out_context: build_fan_out_context(workflow, step, fact)
    }
    
    {:ok, Runnable.new(step, fact, context)}
  end
  
  # EXECUTE - pure computation + build apply_fn
  def execute(%Step{} = step, %Runnable{input_fact: fact, context: ctx} = runnable) do
    try do
      # Run before hooks
      run_hooks(elem(ctx.hooks, 0), step, fact)
      
      # Execute work function
      result = Components.run(step.work, fact.value, Components.arity_of(step.work))
      
      # Build result fact
      result_fact = Fact.new(value: result, ancestry: {step.hash, fact.hash})
      
      # Build apply_fn that captures all state needed
      apply_fn = build_apply(step, result_fact, ctx)
      
      %{runnable | 
        result: result_fact, 
        apply_fn: apply_fn, 
        status: :completed}
    rescue
      e ->
        %{runnable | status: :failed, error: e}
    end
  end
  
  # Private: build the workflow reducer function
  defp build_apply(%Step{} = step, result_fact, ctx) do
    fn workflow ->
      workflow
      |> Workflow.log_fact(result_fact)
      |> Workflow.draw_connection(step, result_fact, :produced, 
           weight: ctx.ancestry_depth + 1)
      |> Workflow.mark_runnable_as_ran(step, ctx.input_fact)
      |> Workflow.run_after_hooks(step, result_fact)
      |> Workflow.prepare_next_runnables(step, result_fact)
      |> maybe_track_for_fan_in(step, result_fact, ctx)
    end
  end
  
  # Legacy invoke - delegate to three-phase
  def invoke(step, workflow, fact) do
    case prepare(step, workflow, fact) do
      {:ok, runnable} ->
        executed = execute(step, runnable)
        executed.apply_fn.(workflow)
      {:skip, reduce_fn} -> reduce_fn.(workflow)
      {:defer, reduce_fn} -> reduce_fn.(workflow)
    end
  end
end
```

### 2.2 Condition (Pure Predicate)

```elixir
defimpl Runic.Workflow.Invokable, for: Runic.Workflow.Condition do
  def match_or_execute(_), do: :match
  
  def prepare(%Condition{} = cond, workflow, fact) do
    context = %CausalContext{
      node_hash: cond.hash,
      input_fact: fact,
      ancestry_depth: Workflow.ancestry_depth(fact, workflow),
      hooks: {[], Map.get(workflow.after_hooks, cond.hash, [])}
    }
    {:ok, Runnable.new(cond, fact, context)}
  end
  
  def execute(%Condition{} = cond, %Runnable{input_fact: fact, context: ctx} = runnable) do
    satisfied = Condition.check(cond, fact)
    apply_fn = build_apply(cond, satisfied, ctx)
    
    %{runnable | 
      result: satisfied, 
      apply_fn: apply_fn, 
      status: :completed}
  end
  
  defp build_apply(%Condition{} = cond, satisfied, ctx) do
    fn workflow ->
      if satisfied do
        workflow
        |> Workflow.prepare_next_runnables(cond, ctx.input_fact)
        |> Workflow.draw_connection(ctx.input_fact, cond, :satisfied)
        |> Workflow.mark_runnable_as_ran(cond, ctx.input_fact)
        |> Workflow.run_after_hooks(cond, ctx.input_fact)
      else
        workflow
        |> Workflow.mark_runnable_as_ran(cond, ctx.input_fact)
        |> Workflow.run_after_hooks(cond, ctx.input_fact)
      end
    end
  end
end
```

### 2.3 FanOut (Collection Split)

```elixir
def prepare(%FanOut{} = fan_out, workflow, fact) do
  if Enumerable.impl_for(fact.value) do
    context = %CausalContext{
      node_hash: fan_out.hash,
      input_fact: fact,
      ancestry_depth: Workflow.ancestry_depth(fact, workflow),
      fan_out_context: %{
        is_reduced: is_reduced?(workflow, fan_out),
        source_fact_hash: fact.hash
      }
    }
    {:ok, Runnable.new(fan_out, fact, context)}
  else
    # Not enumerable - skip with reducer fn
    {:skip, fn wf -> Workflow.mark_runnable_as_ran(wf, fan_out, fact) end}
  end
end

def execute(%FanOut{} = fan_out, %Runnable{input_fact: fact, context: ctx} = runnable) do
  values = Enum.to_list(fact.value)
  apply_fn = build_apply(fan_out, values, ctx)
  
  %{runnable | result: values, apply_fn: apply_fn, status: :completed}
end
```

### Deliverables Phase 2

- [x] Step: prepare/execute/build_apply implementation
- [x] Condition: prepare/execute/build_apply implementation
- [x] FanOut: prepare/execute/build_apply implementation
- [x] Conjunction: prepare/execute/build_apply implementation
- [x] Tests validating three-phase produces same results as legacy invoke

---

## Phase 3: Stateful & Coordination Nodes

**Duration:** 2 weeks  
**Risk:** High  
**Dependencies:** Phase 2

These nodes require special handling due to state dependencies or coordination.

### 3.1 StateReaction & StateCondition

**Strategy:** Capture `last_known_state` in context during prepare.

```elixir
def prepare(%StateReaction{} = sr, workflow, fact) do
  last_state = Workflow.last_known_state(workflow, sr)
  
  context = %CausalContext{
    node_hash: sr.hash,
    input_fact: fact,
    ancestry_depth: Workflow.ancestry_depth(fact, workflow),
    last_known_state: if(last_state, do: last_state.value, else: nil),
    hooks: get_hooks(workflow, sr.hash)
  }
  
  {:ok, Runnable.new(sr, fact, context)}
end

def execute(%StateReaction{} = sr, %Runnable{context: ctx} = runnable) do
  # Use state from context, not workflow
  result = Components.run(sr.work, ctx.last_known_state, sr.arity)
  
  case result do
    {:error, :no_match_of_lhs_in_reactor_fn} ->
      apply_fn = fn workflow -> 
        Workflow.mark_runnable_as_ran(workflow, sr, ctx.input_fact) 
      end
      %{runnable | result: :no_match, apply_fn: apply_fn, status: :completed}
      
    value ->
      result_fact = Fact.new(value: value, ancestry: {sr.hash, ctx.input_fact.hash})
      apply_fn = build_apply(sr, result_fact, ctx)
      %{runnable | result: result_fact, apply_fn: apply_fn, status: :completed}
  end
end
```

### 3.2 Accumulator

**Strategy:** Non-parallelizable by default. Include state initialization check in context.

```elixir
def prepare(%Accumulator{} = acc, workflow, fact) do
  last_state = last_known_state(workflow, acc)
  
  context = %CausalContext{
    node_hash: acc.hash,
    input_fact: fact,
    ancestry_depth: Workflow.ancestry_depth(fact, workflow),
    last_known_state: if(last_state, do: last_state.value, else: nil),
    is_state_initialized: not is_nil(last_state)
  }
  
  {:ok, Runnable.new(acc, fact, context)}
end
```

**Note:** Accumulators are order-dependent. The scheduler must serialize these or use CRDT-style merge for concurrent updates.

### 3.3 Join

**Strategy:** Check satisfaction status during prepare, defer if not ready.

```elixir
def prepare(%Join{} = join, workflow, fact) do
  # Collect current join state
  satisfied = collect_satisfied_joins(workflow, join, fact)
  would_complete = MapSet.size(satisfied) + 1 >= length(join.joins)
  
  context = %CausalContext{
    node_hash: join.hash,
    input_fact: fact,
    ancestry_depth: Workflow.ancestry_depth(fact, workflow),
    join_context: %{
      joins: join.joins,
      satisfied: satisfied,
      would_complete: would_complete,
      values: if(would_complete, do: collect_values_in_order(workflow, join, satisfied, fact), else: nil)
    }
  }
  
  {:ok, Runnable.new(join, fact, context)}
end

def execute(%Join{} = join, %Runnable{context: ctx} = runnable) do
  if ctx.join_context.would_complete do
    join_fact = Fact.new(value: ctx.join_context.values, ancestry: {join.hash, ctx.input_fact.hash})
    apply_fn = build_apply_completed(join, join_fact, ctx)
    %{runnable | result: join_fact, apply_fn: apply_fn, status: :completed}
  else
    # Still waiting
    apply_fn = build_apply_waiting(join, ctx)
    %{runnable | result: :waiting, apply_fn: apply_fn, status: :completed}
  end
end
```

### 3.4 FanIn

**Strategy:** Complex coordination - check readiness during prepare, collect sister values if ready.

```elixir
def prepare(%FanIn{} = fan_in, workflow, fact) do
  fan_out = find_upstream_fan_out(workflow, fan_in)
  
  case fan_out do
    nil ->
      # Simple reduce mode
      {:ok, Runnable.new(fan_in, fact, %CausalContext{fan_in_context: %{mode: :simple}})}
      
    %FanOut{} ->
      {ready, sister_values} = check_fan_in_readiness(workflow, fan_in, fan_out, fact)
      
      context = %CausalContext{
        node_hash: fan_in.hash,
        input_fact: fact,
        fan_in_context: %{
          mode: :fan_out_reduce,
          ready: ready,
          sister_values: sister_values,
          # ... other tracking keys
        }
      }
      {:ok, Runnable.new(fan_in, fact, context)}
  end
end
```

### 3.5 MemoryAssertion

**Strategy:** Execute predicate during prepare phase (not parallelizable).

```elixir
def prepare(%MemoryAssertion{} = ma, workflow, fact) do
  # Run assertion immediately since it needs full workflow
  result = ma.memory_assertion.(workflow, fact)
  
  context = %CausalContext{
    node_hash: ma.hash,
    input_fact: fact,
    ancestry_depth: Workflow.ancestry_depth(fact, workflow),
    # Pre-computed result stored in context
    memory_snapshot: result
  }
  
  {:ok, Runnable.new(ma, fact, context)}
end

def execute(%MemoryAssertion{} = ma, %Runnable{context: ctx} = runnable) do
  # Result already computed in prepare
  apply_fn = build_apply(ma, ctx.memory_snapshot, ctx)
  %{runnable | result: ctx.memory_snapshot, apply_fn: apply_fn, status: :completed}
end
```

### Deliverables Phase 3

- [x] StateReaction: three-phase with state capture
- [x] StateCondition: three-phase with state capture
- [x] Accumulator: three-phase with serialization awareness
- [x] Join: three-phase with defer support (+ parallel apply-phase completion check)
- [x] FanIn: three-phase with readiness check
- [x] MemoryAssertion: synchronous execution in prepare
- [x] Integration tests for stateful workflows

---

## Phase 4: Runtime API Updates

**Duration:** 1-2 weeks  
**Risk:** Medium  
**Dependencies:** Phase 3

Update `Workflow.plan`, `Workflow.react`, and related APIs to use the three-phase model.

### 4.1 Update `next_runnables` to Return `%Runnable{}`

```elixir
@doc """
Returns a list of prepared %Runnable{} structs ready for execution.
Replaces the old {node, fact} tuple format.
"""
def next_runnables(%__MODULE__{} = workflow) do
  for %Graph.Edge{} = edge <- Graph.edges(workflow.graph, by: [:runnable, :matchable]),
      node = edge.v2,
      fact = edge.v1 do
    case Invokable.prepare(node, workflow, fact) do
      {:ok, runnable} -> runnable
      {:skip, _} -> nil
      {:defer, _} -> nil
    end
  end
  |> Enum.reject(&is_nil/1)
end
```

### 4.2 Update `react/1` and `react/2`

```elixir
def react(%__MODULE__{generations: generations} = workflow) when generations > 0 do
  workflow
  |> next_runnables()
  |> Enum.map(fn runnable -> Invokable.execute(runnable.node, runnable) end)
  |> Enum.reduce(workflow, fn runnable, wrk ->
    runnable.apply_fn.(wrk)
  end)
end

def react(%__MODULE__{} = workflow, %Fact{ancestry: nil} = fact) do
  # Root handling - might not need Invokable protocol
  workflow
  |> log_fact(fact)
  |> prepare_next_generation(fact)
  |> prepare_next_runnables(root(), fact)
  |> react()
end
```

### 4.3 Update `react_until_satisfied`

```elixir
def react_until_satisfied(%__MODULE__{} = workflow) do
  do_react_until_satisfied(workflow, is_runnable?(workflow))
end

defp do_react_until_satisfied(workflow, true) do
  # Get runnables, execute, apply
  runnables = next_runnables(workflow)
  executed = Enum.map(runnables, fn r -> Invokable.execute(r.node, r) end)
  
  workflow = Enum.reduce(executed, workflow, fn runnable, wrk ->
    runnable.apply_fn.(wrk)
  end)
  
  do_react_until_satisfied(workflow, is_runnable?(workflow))
end

defp do_react_until_satisfied(workflow, false), do: workflow
```

### 4.4 Root Handling

Since `%Root{}` is a built-in workflow primitive, consider handling it directly in `Workflow` module rather than through `Invokable` protocol:

```elixir
defp handle_root_input(workflow, fact) do
  workflow
  |> log_fact(fact)
  |> prepare_next_generation(fact)
  |> prepare_next_runnables(root(), fact)
end
```

### Deliverables Phase 4

- [x] `prepared_runnables/1` returns `[%Runnable{}]` (new function, kept legacy `next_runnables/1`)
- [x] `react_three_phase/1`, `react_three_phase/2` three-phase versions (legacy `react/1`, `react/2` preserved)
- [x] `react_until_satisfied_three_phase/1`, `/2` three-phase versions
- [x] `react_parallel/2` parallel execution using Task.async_stream
- [x] `react_until_satisfied_parallel/3` parallel until-satisfied loop
- [ ] `plan/1`, `plan/2`, `plan_eagerly/1`, `/2` updated (deferred - legacy still works)
- [ ] Root handling simplified (optional protocol removal - deferred)
- [x] All existing tests pass with new implementation

---

## Phase 5: External Scheduler Support

**Duration:** 1 week  
**Risk:** Low  
**Dependencies:** Phase 4

Enable external processes (GenServers, worker pools) to drive execution.

### 5.1 Scheduler-Friendly API

```elixir
@doc """
Prepares all available runnables for external dispatch.
Returns {workflow_with_tracking, [%Runnable{}]}.
"""
def prepare_for_dispatch(%__MODULE__{} = workflow) do
  runnables = next_runnables(workflow)
  {workflow, runnables}
end

@doc """
Applies a completed runnable back to the workflow.
Called by scheduler after receiving execution results.
"""
def apply_runnable(%__MODULE__{} = workflow, %Runnable{status: :completed} = runnable) do
  runnable.apply_fn.(workflow)
end

def apply_runnable(%__MODULE__{} = workflow, %Runnable{status: :failed} = runnable) do
  # Handle failure - log error, mark as failed, etc.
  handle_failed_runnable(workflow, runnable)
end
```

### 5.2 Example External Scheduler

```elixir
defmodule MyApp.WorkflowScheduler do
  use GenServer
  
  def handle_cast({:run, fact}, %{workflow: workflow} = state) do
    # Phase 1: Prepare
    workflow = Workflow.handle_root_input(workflow, fact)
    {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)
    
    # Phase 2: Execute (dispatch to worker pool)
    executed = Task.async_stream(runnables, fn r -> Invokable.execute(r.node, r) end, timeout: :infinity)
    
    # Phase 3: Apply
    workflow = 
      Enum.reduce(executed, workflow, fn {:ok, runnable}, wrk ->
        Workflow.apply_runnable(wrk, runnable)
      end)
    
    # Continue until satisfied
    if Workflow.is_runnable?(workflow) do
      GenServer.cast(self(), :continue)
    end
    
    {:noreply, %{state | workflow: workflow}}
  end
end
```

### Deliverables Phase 5

- [x] `prepare_for_dispatch/1` API
- [x] `apply_runnable/2` API
- [x] Example scheduler implementation (see `react_parallel/2` and docstrings)
- [x] Documentation for external scheduling patterns (see README.md)

---

## Phase 6: Remove Generation Counter

**Duration:** 1 week  
**Risk:** Medium  
**Dependencies:** Phase 4

Replace `workflow.generations` with ancestry-based causal ordering.

### 6.1 Replace `causal_generation/2`

```elixir
# OLD
def causal_generation(workflow, fact), do: workflow.generations

# NEW
def causal_depth(workflow, fact) do
  ancestry_depth(fact, workflow)
end
```

### 6.2 Update Edge Weights

All `:produced`, `:satisfied`, etc. edges use `ancestry_depth + 1` instead of generation counter.

### 6.3 Update `events_produced_since/2`

Use ancestry comparison instead of generation comparison.

### 6.4 Remove `workflow.generations` Field

After all references are updated, remove the field from the struct.

### Deliverables Phase 6

- [x] `ancestry_depth/2` implemented
- [x] `causal_depth/2` added as new API (delegates to ancestry_depth)
- [x] `root_ancestor_hash/2` helper added
- [x] `react/1` and `react_three_phase/1` use `is_runnable?/1` instead of generations guard
- [ ] Edge weights fully transitioned to ancestry depth (partial - three-phase uses it)
- [ ] `events_produced_since/2` updated to use ancestry depth
- [ ] `generations` field removed from struct (deferred - breaking change)
- [x] All tests pass

**Note:** Full generation counter removal is deferred as a breaking change.
The three-phase execution model already uses `ancestry_depth` for edge weights.
Legacy `causal_generation/2` and `events_produced_since/2` still function for backward compatibility.

---

## Migration Strategy

### Backward Compatibility

1. **Keep `invoke/3`** during migration — delegate to three-phase internally
2. **Deprecation warnings** — Log when legacy `invoke/3` is called directly
3. **Feature flag** — Optional `use_three_phase: true` config for gradual rollout

### Test Strategy

1. **Parallel testing** — Run same workflows through both paths, compare results
2. **Property-based tests** — Verify three-phase produces identical facts/edges
3. **Performance benchmarks** — Measure memory reduction, execution time

### Rollout Order

1. Simple nodes (Step, Condition, FanOut) — Low risk, high coverage
2. Coordination nodes (Join, FanIn) — Medium risk, test thoroughly
3. Stateful nodes (Accumulator, StateReaction) — High risk, careful validation
4. Runtime API updates — Breaking change, coordinate with users

---

## Parallelization Classification

| Node | Parallelizable | Notes |
|------|----------------|-------|
| **Step** | ✅ | Fully parallel |
| **Condition** | ✅ | Fully parallel |
| **Conjunction** | ✅ | Satisfied state captured in context |
| **FanOut** | ✅ | Fully parallel |
| **MemoryAssertion** | ❌ | Executes in prepare phase |
| **StateReaction** | ⚠️ | Parallel if state captured, but stale reads possible |
| **StateCondition** | ⚠️ | Same as StateReaction |
| **Accumulator** | ❌ | Must serialize — order dependent |
| **Join** | ⚠️ | Parallel with atomic completion check |
| **FanIn** | ⚠️ | Parallel with coordination in context |

---

## Open Questions

1. **Hook execution timing** — Before hooks in execute phase? After hooks in apply phase?
2. **Error handling** — How to handle failed runnables? Retry policy?
3. **Durable execution** — Should `%Runnable{}` be serializable for persistence?
4. **State conflicts** — CRDT-style merge for concurrent Accumulator updates?

---

## Success Criteria

1. **Memory reduction** — Runnables contain <10% of workflow memory footprint
2. **API compatibility** — All existing tests pass with new implementation
3. **Performance** — No regression in eager evaluation benchmarks
4. **Scheduler integration** — External schedulers can drive execution without copying workflows
