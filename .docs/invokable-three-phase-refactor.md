# Invokable Node Reference & Three-Phase Refactor Guide

**Reference Document**  
**Status:** Draft  
**Date:** January 2026

---

## Table of Contents

1. [Overview](#overview)
2. [Invokable Node Reference](#invokable-node-reference)
   - [Root](#root)
   - [Condition](#condition)
   - [Conjunction](#conjunction)
   - [MemoryAssertion](#memoryassertion)
   - [Step](#step)
   - [StateReaction](#statereaction)
   - [StateCondition](#statecondition)
   - [Accumulator](#accumulator)
   - [Join](#join)
   - [FanOut](#fanout)
   - [FanIn](#fanin)
3. [Three-Phase Protocol Design](#three-phase-protocol-design)
4. [Detailed Refactor Specifications](#detailed-refactor-specifications)

---

## Overview

This document serves as a reference for refactoring Runic's `Invokable` protocol implementations into a three-phase causal runtime model:

1. **Prepare** — Build a `%Runnable{}` with minimal context needed for execution
2. **Execute** — Run the step's work function in isolation (potentially parallel)
3. **Apply** — Reduce the execution result back into the workflow's memory

### Classification of Invokables

Invokables fall into two categories based on `match_or_execute/1`:

| Category | Nodes | Behavior |
|----------|-------|----------|
| **Match** (`:matchable`) | Condition, Conjunction, MemoryAssertion, StateCondition | Checks a predicate, gates downstream flow |
| **Execute** (`:runnable`) | Root, Step, StateReaction, Accumulator, Join, FanOut, FanIn | Produces new facts or coordinates data |

---

## Invokable Node Reference

### Root

**Module:** `Runic.Workflow.Root`

**Purpose:**  
Entry point for input facts into the workflow. Logs the input fact, advances generation, and prepares runnables for all root-connected nodes.

**Part of Component:** None (built-in workflow primitive)

**Current Behavior:**
```elixir
def invoke(%Root{} = root, workflow, fact) do
  workflow
  |> Workflow.log_fact(fact)
  |> Workflow.prepare_next_generation(fact)
  |> Workflow.prepare_next_runnables(root, fact)
end
```

**Additional Context Needed:**
- None beyond the input fact

**Edges Drawn:**
- `generation` edge: `fact → generation_counter`
- `matchable`/`runnable` edges: `fact → next_nodes`

---

### Condition

**Module:** `Runic.Workflow.Condition`

**Purpose:**  
A predicate gate that checks if the input fact satisfies a condition function. If satisfied, prepares downstream runnables. If not, marks as ran without propagating.

**Part of Component:**  
- `Rule` (left-hand side / LHS)
- Can be standalone

**Current Behavior:**
```elixir
def invoke(%Condition{} = condition, workflow, fact) do
  if Condition.check(condition, fact) do
    workflow
    |> Workflow.prepare_next_runnables(condition, fact)
    |> Workflow.draw_connection(fact, condition, :satisfied)
    |> Workflow.mark_runnable_as_ran(condition, fact)
    |> Workflow.run_after_hooks(condition, fact)
  else
    workflow
    |> Workflow.mark_runnable_as_ran(condition, fact)
    |> Workflow.run_after_hooks(condition, fact)
  end
end
```

**Additional Context Needed:**
- None (pure predicate on fact value)

**Edges Drawn:**
- On success: `:satisfied` edge: `fact → condition`
- Always: Updates `:matchable` → `:ran`

---

### Conjunction

**Module:** `Runic.Workflow.Conjunction`

**Purpose:**  
Logical AND gate that waits for ALL required conditions to be satisfied before propagating. Checks if all `condition_hashes` have `:satisfied` edges from the current fact.

**Part of Component:**  
- `Rule` (when multiple conditions are joined with `and`)

**Current Behavior:**
```elixir
def invoke(%Conjunction{} = conj, workflow, fact) do
  satisfied_conditions = Workflow.satisfied_condition_hashes(workflow, fact)
  
  if conj.hash not in satisfied_conditions and
       Enum.all?(conj.condition_hashes, &(&1 in satisfied_conditions)) do
    workflow
    |> Workflow.prepare_next_runnables(conj, fact)
    |> Workflow.draw_connection(fact, conj, :satisfied, weight: causal_generation)
    |> Workflow.mark_runnable_as_ran(conj, fact)
  else
    Workflow.mark_runnable_as_ran(workflow, conj, fact)
  end
end
```

**Additional Context Needed:**
- `condition_hashes` — Set of condition hashes that must be satisfied
- `satisfied_condition_hashes(workflow, fact)` — Current satisfaction state from graph

**Edges Drawn:**
- On all satisfied: `:satisfied` edge: `fact → conjunction`

---

### MemoryAssertion

**Module:** `Runic.Workflow.MemoryAssertion`

**Purpose:**  
A predicate that can query the full workflow memory (graph) to make decisions. Unlike Condition, it receives both the workflow and fact.

**Part of Component:**  
- `StateMachine` (for state-dependent branching)

**Current Behavior:**
```elixir
def invoke(%MemoryAssertion{} = ma, workflow, fact) do
  if ma.memory_assertion.(workflow, fact) do
    workflow
    |> Workflow.draw_connection(fact, ma, :satisfied, weight: causal_generation)
    |> Workflow.mark_runnable_as_ran(ma, fact)
    |> Workflow.prepare_next_runnables(ma, fact)
  else
    Workflow.mark_runnable_as_ran(workflow, ma, fact)
  end
end
```

**Additional Context Needed:**
- **Full workflow access** — The `memory_assertion` function takes `(workflow, fact)`
- This is a special case that may need workflow snapshot or specific memory queries

**Edges Drawn:**
- On success: `:satisfied` edge: `fact → memory_assertion`

**⚠️ Special Consideration:**  
MemoryAssertion requires workflow access. Options:
1. Execute synchronously in scheduler (not parallelizable)
2. Extract specific graph queries into context during prepare
3. Pass serialized memory snapshot (expensive)

---

### Step

**Module:** `Runic.Workflow.Step`

**Purpose:**  
Executes a work function on the fact value and produces a new result fact. Core data transformation node.

**Part of Component:**  
- `Rule` (right-hand side / RHS)
- `Map` (per-item processing)
- Standalone

**Current Behavior:**
```elixir
def invoke(%Step{} = step, workflow, fact) do
  result = Components.run(step.work, fact.value, Components.arity_of(step.work))
  result_fact = Fact.new(value: result, ancestry: {step.hash, fact.hash})
  
  causal_generation = Workflow.causal_generation(workflow, fact)
  
  workflow
  |> Workflow.log_fact(result_fact)
  |> Workflow.draw_connection(step, result_fact, :produced, weight: causal_generation)
  |> Workflow.mark_runnable_as_ran(step, fact)
  |> Workflow.run_after_hooks(step, result_fact)
  |> Workflow.prepare_next_runnables(step, result_fact)
  |> maybe_prepare_map_reduce(step, result_fact)
end
```

**Additional Context Needed:**
- If in FanOut/FanIn pipeline: `fan_out_context` for tracking (source_fact_hash, fan_out_hash)
- Hooks: `before_hooks`, `after_hooks`

**Edges Drawn:**
- `:produced` edge: `step → result_fact`
- Updates `:runnable` → `:ran`
- Downstream: `:matchable`/`:runnable` edges to next nodes

**FanIn Tracking (for mapped steps):**
- Updates `workflow.mapped[{source_fact_hash, step.hash}]` with seen facts

---

### StateReaction

**Module:** `Runic.Workflow.StateReaction`

**Purpose:**  
Executes a work function using the last known state from an Accumulator. Produces a fact based on accumulated state rather than the input fact value.

**Part of Component:**  
- `StateMachine` (reactor functions)

**Current Behavior:**
```elixir
def invoke(%StateReaction{} = sr, workflow, fact) do
  last_known_state = Workflow.last_known_state(workflow, sr)
  result = Components.run(sr.work, last_known_state, sr.arity)
  
  unless result == {:error, :no_match_of_lhs_in_reactor_fn} do
    result_fact = Fact.new(value: result, ancestry: {sr.hash, fact.hash})
    
    workflow
    |> Workflow.log_fact(result_fact)
    |> Workflow.draw_connection(sr, result_fact, :produced, weight: causal_generation)
    |> Workflow.run_after_hooks(sr, result_fact)
    |> Workflow.prepare_next_runnables(sr, result_fact)
    |> Workflow.mark_runnable_as_ran(sr, fact)
  else
    Workflow.mark_runnable_as_ran(workflow, sr, fact)
  end
end
```

**Additional Context Needed:**
- `state_hash` — Hash of the Accumulator this reaction reads from
- `last_known_state` — The current state value from the Accumulator

**Edges Drawn:**
- `:produced` edge: `state_reaction → result_fact`

**⚠️ Special Consideration:**  
Requires reading `last_known_state` from workflow. Must include state value in `CausalContext` during prepare.

---

### StateCondition

**Module:** `Runic.Workflow.StateCondition`

**Purpose:**  
A predicate that checks both the input fact AND the current state from an Accumulator. Stateful branching logic.

**Part of Component:**  
- `StateMachine` (state-dependent conditions)

**Current Behavior:**
```elixir
def invoke(%StateCondition{} = sc, workflow, fact) do
  last_known_state = Workflow.last_known_state(workflow, sc)
  sc_result = sc.work.(fact.value, last_known_state)
  
  if sc_result do
    workflow
    |> Workflow.prepare_next_runnables(sc, fact)
    |> Workflow.draw_connection(fact, sc, :satisfied, weight: causal_generation)
    |> Workflow.mark_runnable_as_ran(sc, fact)
  else
    Workflow.mark_runnable_as_ran(workflow, sc, fact)
  end
end
```

**Additional Context Needed:**
- `state_hash` — Hash of the Accumulator this condition reads from
- `last_known_state` — Current state value

**Edges Drawn:**
- On success: `:satisfied` edge: `fact → state_condition`

---

### Accumulator

**Module:** `Runic.Workflow.Accumulator`

**Purpose:**  
Stateful reducer that maintains accumulated state across invocations. Each fact updates the state via a reducer function.

**Part of Component:**  
- `StateMachine` (state container)
- Standalone for stateful aggregation

**Current Behavior:**
```elixir
def invoke(%Accumulator{} = acc, workflow, fact) do
  last_known_state = last_known_state(workflow, acc)
  
  unless is_nil(last_known_state) do
    next_state = apply(acc.reducer, [fact.value, last_known_state.value])
    next_state_produced_fact = Fact.new(value: next_state, ancestry: {acc.hash, fact.hash})
    
    workflow
    |> Workflow.log_fact(next_state_produced_fact)
    |> Workflow.draw_connection(acc, fact, :state_produced, weight: causal_generation)
    |> Workflow.mark_runnable_as_ran(acc, fact)
    |> Workflow.run_after_hooks(acc, next_state_produced_fact)
    |> Workflow.prepare_next_runnables(acc, next_state_produced_fact)
  else
    # Initialize state first
    init_fact = init_fact(acc)
    next_state = apply(acc.reducer, [fact.value, init_fact.value])
    next_state_produced_fact = Fact.new(value: next_state, ancestry: {acc.hash, fact.hash})
    
    workflow
    |> Workflow.log_fact(init_fact)
    |> Workflow.draw_connection(acc, init_fact, :state_initiated, weight: causal_generation)
    |> Workflow.log_fact(next_state_produced_fact)
    |> Workflow.draw_connection(acc, next_state_produced_fact, :state_produced, weight: causal_generation)
    |> Workflow.mark_runnable_as_ran(acc, fact)
    |> Workflow.run_after_hooks(acc, next_state_produced_fact)
    |> Workflow.prepare_next_runnables(acc, next_state_produced_fact)
  end
end
```

**Additional Context Needed:**
- `last_known_state` — Current accumulated state (or nil if first invocation)
- `init` — Initialization function for first state

**Edges Drawn:**
- First time: `:state_initiated` edge: `acc → init_fact`
- Always: `:state_produced` edge: `acc → next_state_fact`

**⚠️ Special Consideration:**  
Accumulator is **stateful** — concurrent invocations must be serialized or use conflict resolution. May need to be non-parallelizable or use CRDT-style merge.

---

### Join

**Module:** `Runic.Workflow.Join`

**Purpose:**  
Synchronization barrier that waits for facts from ALL parent steps before producing a combined fact. Collects values in join order.

**Part of Component:**  
- Created when a step has multiple parents: `Workflow.add(step, to: [step_a, step_b])`

**Current Behavior:**
```elixir
def invoke(%Join{} = join, workflow, fact) do
  # Draw :joined edge for this fact
  workflow = Workflow.draw_connection(workflow, fact, join, :joined, weight: causal_generation)
  
  # Check all :joined edges, deduplicate by parent hash
  joined_edges = Graph.in_edges(workflow.graph, join) |> Enum.filter(&(&1.label == :joined))
  
  possible_priors_by_parent = 
    joined_edges
    |> Enum.reduce(%{}, fn edge, acc ->
      parent_hash = elem(edge.v1.ancestry, 0)
      if parent_hash in join.joins and not Map.has_key?(acc, parent_hash) do
        Map.put(acc, parent_hash, edge.v1)
      else
        acc
      end
    end)
  
  # Sort values by join order
  possible_priors = join.joins |> Enum.map(&Map.get(possible_priors_by_parent, &1)) |> ...
  
  if Enum.count(join.joins) == Enum.count(possible_priors) do
    join_bindings_fact = Fact.new(value: possible_priors, ancestry: {join.hash, fact.hash})
    
    workflow
    |> Workflow.log_fact(join_bindings_fact)
    |> Workflow.prepare_next_runnables(join, join_bindings_fact)
    |> Workflow.draw_connection(join, join_bindings_fact, :produced, weight: workflow.generations)
    |> Workflow.run_after_hooks(join, join_bindings_fact)
    # Mark all :joined edges as :join_satisfied
  else
    Workflow.mark_runnable_as_ran(workflow, join, fact)
  end
end
```

**Additional Context Needed:**
- `joins` — List of parent step hashes that must contribute facts
- Current `:joined` edges from graph to check completion status
- Previously joined facts and their values

**Edges Drawn:**
- Each arrival: `:joined` edge: `fact → join`
- On completion: `:produced` edge: `join → combined_fact`
- Updates `:joined` → `:join_satisfied`

**⚠️ Special Consideration:**  
Join is a **coordination point** — multiple facts arrive asynchronously. May need:
1. Atomic check-and-complete in apply phase
2. Deferred execution until all facts arrive

---

### FanOut

**Module:** `Runic.Workflow.FanOut`

**Purpose:**  
Splits an enumerable fact into multiple individual facts, one per element. Enables parallel processing of collections.

**Part of Component:**  
- `Map` (fan-out portion)
- `Reduce` (when linked to FanIn)

**Current Behavior:**
```elixir
def invoke(%FanOut{} = fan_out, workflow, source_fact) do
  unless is_nil(Enumerable.impl_for(source_fact.value)) do
    is_reduced? = is_reduced?(workflow, fan_out)
    causal_generation = Workflow.causal_generation(workflow, source_fact)
    
    Enum.reduce(source_fact.value, workflow, fn value, wrk ->
      fact = Fact.new(value: value, ancestry: {fan_out.hash, source_fact.hash})
      
      wrk
      |> Workflow.log_fact(fact)
      |> Workflow.prepare_next_runnables(fan_out, fact)
      |> Workflow.draw_connection(fan_out, fact, :fan_out, weight: causal_generation)
      |> maybe_prepare_map_reduce(is_reduced?, fan_out, fact, source_fact)
    end)
    |> Workflow.mark_runnable_as_ran(fan_out, source_fact)
  else
    Workflow.mark_runnable_as_ran(workflow, fan_out, source_fact)
  end
end
```

**Additional Context Needed:**
- `is_reduced?` — Whether this FanOut is connected to a FanIn (has `:fan_in` edge)

**Edges Drawn:**
- For each element: `:fan_out` edge: `fan_out → element_fact`
- Downstream: `:matchable`/`:runnable` edges for each element

**Tracking (for FanIn):**
- Updates `workflow.mapped[{source_fact.hash, fan_out.hash}]` with list of emitted fact hashes

---

### FanIn

**Module:** `Runic.Workflow.FanIn`

**Purpose:**  
Collects all facts from a FanOut's parallel branches and reduces them into a single result. Completes when all expected facts have arrived.

**Part of Component:**  
- `Reduce` (reduction portion of map-reduce)

**Current Behavior:**
```elixir
def invoke(%FanIn{} = fan_in, workflow, fact) do
  fan_out = find_upstream_fan_out(workflow, fan_in)
  
  case fan_out do
    nil ->
      # Simple reduce (no FanOut, just reduce enumerable)
      reduced_value = reduce_with_while(fact.value, fan_in.init.(), fan_in.reducer)
      reduced_fact = Fact.new(value: reduced_value, ancestry: {fan_in.hash, fact.hash})
      
      workflow
      |> Workflow.log_fact(reduced_fact)
      |> Workflow.draw_connection(fan_in, reduced_fact, :reduced, weight: causal_generation)
      |> Workflow.prepare_next_runnables(fan_in, reduced_fact)
      |> Workflow.mark_runnable_as_ran(fan_in, fact)
      
    %FanOut{} ->
      source_fact_hash = find_fan_out_source_fact_hash(workflow, fact)
      
      # Check idempotency (already completed for this batch?)
      already_completed? = has_reduced_output?(workflow, fan_in, source_fact_hash)
      
      # Check if all expected facts have arrived
      expected_key = {source_fact_hash, fan_out.hash}
      seen_key = {source_fact_hash, parent_step_hash}
      
      expected_set = MapSet.new(workflow.mapped[expected_key] || [])
      seen_set = MapSet.new(Map.keys(workflow.mapped[seen_key] || %{}))
      
      ready? = not already_completed? and 
               not Enum.empty?(expected_set) and 
               MapSet.equal?(expected_set, seen_set)
      
      if ready? do
        # Collect values in FanOut emission order
        sister_fact_values = ...
        reduced_value = reduce_with_while(sister_fact_values, fan_in.init.(), fan_in.reducer)
        reduced_fact = Fact.new(value: reduced_value, ancestry: {fan_in.hash, fact.hash})
        
        workflow
        |> Workflow.log_fact(reduced_fact)
        |> Workflow.draw_connection(fan_in, reduced_fact, :reduced, weight: causal_generation)
        |> Workflow.prepare_next_runnables(fan_in, reduced_fact)
        |> mark_fan_in_completed(completed_key)
        |> cleanup_mapped(...)
      else
        Workflow.mark_runnable_as_ran(workflow, fan_in, fact)
      end
  end
end
```

**Additional Context Needed:**
- `fan_out` — Upstream FanOut node (via `:fan_in` edge)
- `source_fact_hash` — Hash of the fact that triggered the FanOut (stable batch ID)
- `expected_list` — List of fact hashes emitted by FanOut
- `seen_map` — Map of fact hashes that have been processed by mapped steps
- `already_completed?` — Whether this batch has already been reduced

**Edges Drawn:**
- On completion: `:reduced` edge: `fan_in → reduced_fact`

**⚠️ Special Consideration:**  
FanIn is a **coordination point**. The "execute" phase is really just checking readiness. Actual reduction happens when all facts arrive. May need:
1. Prepare phase returns `:not_ready` status
2. Only execute when ready
3. Apply phase is idempotent

---

## Three-Phase Protocol Design

### Updated Invokable Protocol

> **Design Decision:** Instead of requiring `Invokable.apply/3` as part of the protocol, 
> each `execute/1` implementation builds an `apply_fn` higher-order reducer function and 
> stores it on the `%Runnable{}` struct. This provides the same polymorphism via closures
> that capture node/context state, with a simpler protocol surface. The `build_apply/3`
> function is now a **private function** within each protocol implementation that `execute/1`
> calls internally to construct the apply function based on execution results.

```elixir
defprotocol Runic.Workflow.Invokable do
  @moduledoc """
  Protocol for workflow node invocation in three phases:
  
  1. **prepare/3** — Extract minimal context from workflow, build Runnable
  2. **execute/1** — Run work in isolation, populate result and apply_fn on Runnable
  
  The apply phase is not part of the protocol — instead, execute/1 returns a Runnable
  with an `apply_fn` field containing a `(Workflow.t() -> Workflow.t())` reducer.
  """
  
  @doc """
  Returns whether this node is a `:match` or `:execute` phase node.
  """
  @spec match_or_execute(node :: struct()) :: :match | :execute
  def match_or_execute(node)
  
  @doc """
  PREPARE: Build a Runnable with minimal context from the workflow.
  
  Returns:
  - `{:ok, %Runnable{}}` — Ready to execute
  - `{:skip, fun()}` — Node should not execute; fun is `(Workflow.t() -> Workflow.t())` reducer
  - `{:defer, fun()}` — Node is waiting for more data; fun is `(Workflow.t() -> Workflow.t())` reducer
  
  The skip/defer reducers enable future parallelization of the match/plan phase.
  """
  @spec prepare(node :: struct(), workflow :: Workflow.t(), fact :: Fact.t()) ::
    {:ok, Runnable.t()} | {:skip, fun()} | {:defer, fun()}
  def prepare(node, workflow, fact)
  
  @doc """
  EXECUTE: Run the node's work in isolation. No workflow access.
  
  Takes a prepared Runnable and returns the same Runnable with:
  - `result` populated with the execution output
  - `apply_fn` populated with a `(Workflow.t() -> Workflow.t())` reducer
  - `status` updated to `:completed` or `:failed`
  
  The execute implementation calls a private `build_apply/3` internally to construct
  the apply_fn based on the execution results.
  
  Note: node is first arg for protocol dispatch in Elixir.
  """
  @spec execute(node :: struct(), runnable :: Runnable.t()) :: Runnable.t()
  def execute(node, runnable)
end
```

### Private `build_apply/3` Pattern

Each protocol implementation includes a private `build_apply/3` function that `execute/1`
calls to construct the `apply_fn`:

```elixir
# Inside each Invokable implementation:

def execute(%Step{} = step, %Runnable{input_fact: fact, context: ctx} = runnable) do
  result = Components.run(step.work, fact.value, Components.arity_of(step.work))
  result_fact = Fact.new(value: result, ancestry: {step.hash, fact.hash})
  
  # Call private build_apply to construct the reducer
  apply_fn = build_apply(step, result_fact, ctx)
  
  %{runnable | result: result_fact, apply_fn: apply_fn, status: :completed}
end

# Private function - not part of protocol
defp build_apply(%Step{} = step, result_fact, ctx) do
  fn workflow ->
    workflow
    |> Workflow.log_fact(result_fact)
    |> Workflow.draw_connection(step, result_fact, :produced, weight: ctx.ancestry_depth + 1)
    |> Workflow.mark_runnable_as_ran(step, ctx.input_fact)
    |> Workflow.run_after_hooks(step, result_fact)
    |> Workflow.prepare_next_runnables(step, result_fact)
  end
end
```

### Runnable Struct

```elixir
defmodule Runic.Workflow.Runnable do
  @moduledoc """
  A prepared unit of work ready for execution.
  
  Contains everything needed to execute independently of the source workflow.
  After execute/1, contains result and apply_fn for reducing back into workflow.
  """
  
  @type status :: :pending | :completed | :failed | :skipped
  
  @type t :: %__MODULE__{
    id: integer(),
    node: struct(),
    input_fact: Fact.t(),
    context: CausalContext.t(),
    status: status(),
    result: term() | nil,
    apply_fn: (Workflow.t() -> Workflow.t()) | nil,
    error: term() | nil
  }
  
  defstruct [
    :id,                    # Idempotency key: hash of {node.hash, fact.hash}
    :node,                  # The invokable node struct
    :input_fact,            # Triggering fact
    :context,               # CausalContext with minimal workflow data
    :status,                # :pending | :completed | :failed | :skipped
    :result,                # Output value/fact after execution
    :apply_fn,              # (Workflow.t() -> Workflow.t()) reducer built during execute
    :error                  # Error info if failed
  ]
  
  def new(node, fact, context) do
    %__MODULE__{
      id: :erlang.phash2({node.hash, fact.hash}),
      node: node,
      input_fact: fact,
      context: context,
      status: :pending
    }
  end
end
```

### CausalContext Struct

```elixir
defmodule Runic.Workflow.CausalContext do
  defstruct [
    :node_hash,             # Hash of the invoking node
    :input_fact,            # Copy of input fact
    :ancestry_chain,        # List of {producer_hash, fact_hash} to root
    :ancestry_depth,        # Integer depth for edge weights
    :hooks,                 # {before_hooks, after_hooks} lists
    
    # Stateful node context
    :last_known_state,      # For StateReaction, StateCondition, Accumulator
    :is_state_initialized,  # Boolean for Accumulator first-run check
    
    # Coordination context  
    :join_context,          # For Join: %{joins: [...], satisfied: %{hash => fact}}
    :fan_in_context,        # For FanIn: %{source_hash, expected, seen, ready?}
    :fan_out_context,       # For Step in map: %{source_hash, fan_out_hash}
    
    # Condition context
    :satisfied_conditions,  # For Conjunction: MapSet of satisfied hashes
    
    # Memory assertion context
    :memory_snapshot        # For MemoryAssertion: serialized query results
  ]
end
```

---

## Detailed Refactor Specifications

### Root

> **Note:** The `%Root{}` is a built-in workflow primitive. Consider handling it directly
> in the `Workflow` module rather than through the `Invokable` protocol since its behavior
> is tightly coupled to workflow initialization (logging fact, preparing generation, etc.).

```elixir
# Option 1: Keep in Invokable protocol
defimpl Runic.Workflow.Invokable, for: Runic.Workflow.Root do
  
  def match_or_execute(_), do: :execute
  
  # PREPARE
  def prepare(%Root{} = root, workflow, fact) do
    context = %CausalContext{
      node_hash: root.hash,
      input_fact: fact,
      ancestry_depth: 0,
      hooks: {[], []}
    }
    
    {:ok, Runnable.new(root, fact, context)}
  end
  
  # EXECUTE
  def execute(%Root{} = root, %Runnable{input_fact: fact, context: ctx} = runnable) do
    # Root doesn't transform data, just sets up workflow for next runnables
    apply_fn = build_apply(root, fact, ctx)
    
    %{runnable | result: fact.value, apply_fn: apply_fn, status: :completed}
  end
  
  defp build_apply(%Root{} = root, fact, _ctx) do
    fn workflow ->
      workflow
      |> Workflow.log_fact(fact)
      |> Workflow.prepare_next_generation(fact)
      |> Workflow.prepare_next_runnables(root, fact)
    end
  end
end

# Option 2: Handle Root directly in Workflow module (recommended)
# This avoids protocol overhead for a built-in primitive
defmodule Runic.Workflow do
  def handle_root_input(%__MODULE__{} = workflow, %Fact{} = fact) do
    workflow
    |> log_fact(fact)
    |> prepare_next_generation(fact)
    |> prepare_next_runnables(root(), fact)
  end
end
```

---

### Condition

```elixir
defimpl Runic.Workflow.Invokable, for: Runic.Workflow.Condition do
  
  def match_or_execute(_), do: :match
  
  # PREPARE
  def prepare(%Condition{} = cond, workflow, fact) do
    context = %CausalContext{
      node_hash: cond.hash,
      input_fact: fact,
      ancestry_depth: Workflow.ancestry_depth(fact, workflow),
      hooks: {[], Map.get(workflow.after_hooks, cond.hash, [])}
    }
    
    {:ok, Runnable.new(cond, fact, context)}
  end
  
  # EXECUTE
  def execute(%Condition{} = cond, %Runnable{input_fact: fact, context: ctx} = runnable) do
    satisfied = Condition.check(cond, fact)
    apply_fn = build_apply(cond, satisfied, ctx)
    
    %{runnable | result: satisfied, apply_fn: apply_fn, status: :completed}
  end
  
  # Private: build apply_fn based on result
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

---

### Conjunction

```elixir
defimpl Runic.Workflow.Invokable, for: Runic.Workflow.Conjunction do
  
  def match_or_execute(_), do: :match
  
  # PREPARE
  def prepare(%Conjunction{} = conj, workflow, fact) do
    satisfied = Workflow.satisfied_condition_hashes(workflow, fact)
    
    context = %CausalContext{
      node_hash: conj.hash,
      input_fact: fact,
      ancestry_depth: ancestry_depth(workflow, fact),
      satisfied_conditions: satisfied
    }
    
    {:ok, %Runnable{
      id: runnable_id(conj, fact),
      node: conj,
      input_fact: fact,
      context: context,
      status: :pending
    }}
  end
  
  # EXECUTE (check if all conditions satisfied)
  def execute(%Conjunction{condition_hashes: required} = conj, _fact, context) do
    already_satisfied = conj.hash in context.satisfied_conditions
    all_met = Enum.all?(required, &(&1 in context.satisfied_conditions))
    
    if not already_satisfied and all_met do
      {:ok, :satisfied}
    else
      {:ok, :not_satisfied}
    end
  end
  
  # APPLY
  def build_apply(%Conjunction{} = conj, result, context) do
    fn workflow, runnable ->
      case result do
        :satisfied ->
          workflow
          |> Workflow.prepare_next_runnables(conj, runnable.input_fact)
          |> Workflow.draw_connection(runnable.input_fact, conj, :satisfied,
               weight: context.ancestry_depth)
          |> Workflow.mark_runnable_as_ran(conj, runnable.input_fact)
          
        :not_satisfied ->
          Workflow.mark_runnable_as_ran(workflow, conj, runnable.input_fact)
      end
    end
  end
end
```

---

### MemoryAssertion

**⚠️ Non-Parallelizable** — Requires full workflow access

```elixir
defimpl Runic.Workflow.Invokable, for: Runic.Workflow.MemoryAssertion do
  
  def match_or_execute(_), do: :match
  
  # PREPARE
  # Option 1: Execute in prepare phase (synchronous)
  def prepare(%MemoryAssertion{} = ma, workflow, fact) do
    # Run assertion immediately since it needs workflow
    result = ma.memory_assertion.(workflow, fact)
    
    context = %CausalContext{
      node_hash: ma.hash,
      input_fact: fact,
      ancestry_depth: ancestry_depth(workflow, fact),
      # Store pre-computed result
      memory_snapshot: result
    }
    
    {:ok, %Runnable{
      id: runnable_id(ma, fact),
      node: ma,
      input_fact: fact,
      context: context,
      status: :pending,
      result: if(result, do: :satisfied, else: :not_satisfied)
    }}
  end
  
  # EXECUTE (result already computed in prepare)
  def execute(%MemoryAssertion{}, _fact, context) do
    {:ok, context.memory_snapshot}
  end
  
  # APPLY
  def build_apply(%MemoryAssertion{} = ma, result, context) do
    fn workflow, runnable ->
      if result do
        workflow
        |> Workflow.draw_connection(runnable.input_fact, ma, :satisfied,
             weight: context.ancestry_depth)
        |> Workflow.mark_runnable_as_ran(ma, runnable.input_fact)
        |> Workflow.prepare_next_runnables(ma, runnable.input_fact)
      else
        Workflow.mark_runnable_as_ran(workflow, ma, runnable.input_fact)
      end
    end
  end
end
```

---

### Step

```elixir
defimpl Runic.Workflow.Invokable, for: Runic.Workflow.Step do
  
  def match_or_execute(_), do: :execute
  
  # PREPARE
  def prepare(%Step{} = step, workflow, fact) do
    context = %CausalContext{
      node_hash: step.hash,
      input_fact: fact,
      ancestry_depth: ancestry_depth(workflow, fact),
      hooks: get_hooks(workflow, step.hash),
      fan_out_context: build_fan_out_context(workflow, step, fact)
    }
    
    {:ok, %Runnable{
      id: runnable_id(step, fact),
      node: step,
      input_fact: fact,
      context: context,
      status: :pending,
      on_start: fn -> run_before_hooks(context.hooks) end
    }}
  end
  
  # EXECUTE (pure computation)
  def execute(%Step{work: work} = step, fact, _context) do
    try do
      result = Components.run(work, fact.value, Components.arity_of(work))
      {:ok, result}
    rescue
      e -> {:error, e}
    end
  end
  
  # APPLY
  def build_apply(%Step{} = step, result, context) do
    fn workflow, runnable ->
      result_fact = Fact.new(
        value: result, 
        ancestry: {step.hash, runnable.input_fact.hash}
      )
      
      workflow
      |> Workflow.log_fact(result_fact)
      |> Workflow.draw_connection(step, result_fact, :produced, 
           weight: context.ancestry_depth + 1)
      |> Workflow.mark_runnable_as_ran(step, runnable.input_fact)
      |> Workflow.run_after_hooks(step, result_fact)
      |> Workflow.prepare_next_runnables(step, result_fact)
      |> maybe_track_for_fan_in(step, result_fact, context)
    end
  end
  
  defp maybe_track_for_fan_in(workflow, step, fact, context) do
    case context.fan_out_context do
      nil -> workflow
      {source_hash, fan_out_hash, _} ->
        key = {source_hash, step.hash}
        # Get the fan_out_fact_hash that produced the input
        fan_out_fact_hash = elem(context.input_fact.ancestry, 1)
        seen = workflow.mapped[key] || %{}
        seen = Map.put(seen, fan_out_fact_hash, fact.hash)
        
        workflow
        |> store_fan_out_hash_for_batch(source_hash, fan_out_hash)
        |> Map.put(:mapped, Map.put(workflow.mapped, key, seen))
    end
  end
end
```

---

### StateReaction

**⚠️ Requires State** — Include last state in context

```elixir
defimpl Runic.Workflow.Invokable, for: Runic.Workflow.StateReaction do
  
  def match_or_execute(_), do: :execute
  
  # PREPARE
  def prepare(%StateReaction{} = sr, workflow, fact) do
    last_state = Workflow.last_known_state(workflow, sr)
    
    context = %CausalContext{
      node_hash: sr.hash,
      input_fact: fact,
      ancestry_depth: ancestry_depth(workflow, fact),
      last_known_state: last_state,
      hooks: get_hooks(workflow, sr.hash)
    }
    
    {:ok, %Runnable{
      id: runnable_id(sr, fact),
      node: sr,
      input_fact: fact,
      context: context,
      status: :pending
    }}
  end
  
  # EXECUTE (uses state from context, not workflow)
  def execute(%StateReaction{work: work, arity: arity}, _fact, context) do
    try do
      result = Components.run(work, context.last_known_state, arity)
      if result == {:error, :no_match_of_lhs_in_reactor_fn} do
        {:ok, :no_match}
      else
        {:ok, result}
      end
    rescue
      e -> {:error, e}
    end
  end
  
  # APPLY
  def build_apply(%StateReaction{} = sr, result, context) do
    fn workflow, runnable ->
      case result do
        :no_match ->
          Workflow.mark_runnable_as_ran(workflow, sr, runnable.input_fact)
          
        value ->
          result_fact = Fact.new(
            value: value,
            ancestry: {sr.hash, runnable.input_fact.hash}
          )
          
          workflow
          |> Workflow.log_fact(result_fact)
          |> Workflow.draw_connection(sr, result_fact, :produced,
               weight: context.ancestry_depth + 1)
          |> Workflow.run_after_hooks(sr, result_fact)
          |> Workflow.prepare_next_runnables(sr, result_fact)
          |> Workflow.mark_runnable_as_ran(sr, runnable.input_fact)
      end
    end
  end
end
```

---

### StateCondition

**⚠️ Requires State** — Include last state in context

```elixir
defimpl Runic.Workflow.Invokable, for: Runic.Workflow.StateCondition do
  
  def match_or_execute(_), do: :match
  
  # PREPARE
  def prepare(%StateCondition{} = sc, workflow, fact) do
    last_state = Workflow.last_known_state(workflow, sc)
    
    context = %CausalContext{
      node_hash: sc.hash,
      input_fact: fact,
      ancestry_depth: ancestry_depth(workflow, fact),
      last_known_state: last_state
    }
    
    {:ok, %Runnable{
      id: runnable_id(sc, fact),
      node: sc,
      input_fact: fact,
      context: context,
      status: :pending
    }}
  end
  
  # EXECUTE (check condition with state)
  def execute(%StateCondition{work: work}, fact, context) do
    result = work.(fact.value, context.last_known_state)
    if result, do: {:ok, :satisfied}, else: {:ok, :not_satisfied}
  end
  
  # APPLY
  def build_apply(%StateCondition{} = sc, result, context) do
    fn workflow, runnable ->
      case result do
        :satisfied ->
          workflow
          |> Workflow.prepare_next_runnables(sc, runnable.input_fact)
          |> Workflow.draw_connection(runnable.input_fact, sc, :satisfied,
               weight: context.ancestry_depth)
          |> Workflow.mark_runnable_as_ran(sc, runnable.input_fact)
          
        :not_satisfied ->
          Workflow.mark_runnable_as_ran(workflow, sc, runnable.input_fact)
      end
    end
  end
end
```

---

### Accumulator

**⚠️ Stateful & Order-Dependent** — May need serialization

```elixir
defimpl Runic.Workflow.Invokable, for: Runic.Workflow.Accumulator do
  
  def match_or_execute(_), do: :execute
  
  # PREPARE
  def prepare(%Accumulator{} = acc, workflow, fact) do
    last_state = last_known_state(workflow, acc)
    
    context = %CausalContext{
      node_hash: acc.hash,
      input_fact: fact,
      ancestry_depth: ancestry_depth(workflow, fact),
      last_known_state: if(last_state, do: last_state.value, else: nil),
      is_state_initialized: not is_nil(last_state),
      hooks: get_hooks(workflow, acc.hash)
    }
    
    {:ok, %Runnable{
      id: runnable_id(acc, fact),
      node: acc,
      input_fact: fact,
      context: context,
      status: :pending
    }}
  end
  
  # EXECUTE (compute next state)
  def execute(%Accumulator{reducer: reducer, init: init}, fact, context) do
    current_state = context.last_known_state || init.()
    next_state = apply(reducer, [fact.value, current_state])
    {:ok, %{next_state: next_state, was_initialized: context.is_state_initialized}}
  end
  
  # APPLY
  def build_apply(%Accumulator{} = acc, result, context) do
    fn workflow, runnable ->
      next_state_fact = Fact.new(
        value: result.next_state,
        ancestry: {acc.hash, runnable.input_fact.hash}
      )
      
      workflow = 
        if result.was_initialized do
          workflow
        else
          # First time: log init fact
          init_fact = Fact.new(
            value: acc.init.(), 
            ancestry: {acc.hash, Components.fact_hash(acc.init.())}
          )
          workflow
          |> Workflow.log_fact(init_fact)
          |> Workflow.draw_connection(acc, init_fact, :state_initiated,
               weight: context.ancestry_depth)
        end
      
      workflow
      |> Workflow.log_fact(next_state_fact)
      |> Workflow.draw_connection(acc, next_state_fact, :state_produced,
           weight: context.ancestry_depth)
      |> Workflow.mark_runnable_as_ran(acc, runnable.input_fact)
      |> Workflow.run_after_hooks(acc, next_state_fact)
      |> Workflow.prepare_next_runnables(acc, next_state_fact)
    end
  end
end
```

---

### Join

**⚠️ Coordination Point** — May defer until ready

```elixir
defimpl Runic.Workflow.Invokable, for: Runic.Workflow.Join do
  
  def match_or_execute(_), do: :execute
  
  # PREPARE
  def prepare(%Join{} = join, workflow, fact) do
    # Collect current join state
    joined_edges = Graph.in_edges(workflow.graph, join) 
                   |> Enum.filter(&(&1.label == :joined))
    
    satisfied_by_parent = 
      joined_edges
      |> Enum.reduce(%{}, fn edge, acc ->
        parent_hash = elem(edge.v1.ancestry, 0)
        if parent_hash in join.joins and not Map.has_key?(acc, parent_hash) do
          Map.put(acc, parent_hash, edge.v1)
        else
          acc
        end
      end)
    
    # Check if this fact would complete the join
    current_parent = elem(fact.ancestry, 0)
    satisfied_after = Map.put(satisfied_by_parent, current_parent, fact)
    
    all_satisfied = Enum.all?(join.joins, &Map.has_key?(satisfied_after, &1))
    
    context = %CausalContext{
      node_hash: join.hash,
      input_fact: fact,
      ancestry_depth: ancestry_depth(workflow, fact),
      join_context: %{
        joins: join.joins,
        satisfied: satisfied_by_parent,
        would_complete: all_satisfied,
        values_in_order: if(all_satisfied, 
          do: Enum.map(join.joins, &Map.get(satisfied_after, &1).value),
          else: nil
        )
      }
    }
    
    {:ok, %Runnable{
      id: runnable_id(join, fact),
      node: join,
      input_fact: fact,
      context: context,
      status: :pending
    }}
  end
  
  # EXECUTE
  def execute(%Join{}, _fact, context) do
    if context.join_context.would_complete do
      {:ok, {:completed, context.join_context.values_in_order}}
    else
      {:ok, :waiting}
    end
  end
  
  # APPLY
  def build_apply(%Join{} = join, result, context) do
    fn workflow, runnable ->
      # Always draw :joined edge for this fact
      workflow = Workflow.draw_connection(
        workflow, 
        runnable.input_fact, 
        join, 
        :joined, 
        weight: context.ancestry_depth
      )
      
      case result do
        {:completed, values} ->
          join_fact = Fact.new(
            value: values,
            ancestry: {join.hash, runnable.input_fact.hash}
          )
          
          workflow
          |> Workflow.log_fact(join_fact)
          |> Workflow.prepare_next_runnables(join, join_fact)
          |> Workflow.draw_connection(join, join_fact, :produced,
               weight: context.ancestry_depth + 1)
          |> Workflow.run_after_hooks(join, join_fact)
          |> mark_all_joined_as_satisfied(join)
          
        :waiting ->
          Workflow.mark_runnable_as_ran(workflow, join, runnable.input_fact)
      end
    end
  end
end
```

---

### FanOut

```elixir
defimpl Runic.Workflow.Invokable, for: Runic.Workflow.FanOut do
  
  def match_or_execute(_), do: :execute
  
  # PREPARE
  def prepare(%FanOut{} = fan_out, workflow, fact) do
    # Check if enumerable
    unless is_nil(Enumerable.impl_for(fact.value)) do
      is_reduced = is_reduced?(workflow, fan_out)
      
      context = %CausalContext{
        node_hash: fan_out.hash,
        input_fact: fact,
        ancestry_depth: ancestry_depth(workflow, fact),
        fan_out_context: %{
          is_reduced: is_reduced,
          source_fact_hash: fact.hash
        }
      }
      
      {:ok, %Runnable{
        id: runnable_id(fan_out, fact),
        node: fan_out,
        input_fact: fact,
        context: context,
        status: :pending
      }}
    else
      # Not enumerable - skip with reducer fn
      {:skip, fn wf -> Workflow.mark_runnable_as_ran(wf, fan_out, fact) end}
    end
  end
  
  # EXECUTE (split enumerable into list of values)
  def execute(%FanOut{} = fan_out, %Runnable{input_fact: fact, context: ctx} = runnable) do
    values = Enum.to_list(fact.value)
    apply_fn = build_apply(fan_out, values, ctx)
    
    %{runnable | result: values, apply_fn: apply_fn, status: :completed}
  end
  
  # APPLY (creates multiple facts and runnables)
  def build_apply(%FanOut{} = fan_out, values, context) do
    fn workflow, runnable ->
      source_fact = runnable.input_fact
      is_reduced = context.fan_out_context.is_reduced
      
      workflow = 
        Enum.reduce(values, workflow, fn value, wrk ->
          fact = Fact.new(
            value: value, 
            ancestry: {fan_out.hash, source_fact.hash}
          )
          
          wrk
          |> Workflow.log_fact(fact)
          |> Workflow.prepare_next_runnables(fan_out, fact)
          |> Workflow.draw_connection(fan_out, fact, :fan_out,
               weight: context.ancestry_depth)
          |> maybe_track_expected(is_reduced, fan_out, fact, source_fact)
        end)
      
      Workflow.mark_runnable_as_ran(workflow, fan_out, source_fact)
    end
  end
  
  defp maybe_track_expected(workflow, true, fan_out, fact, source_fact) do
    key = {source_fact.hash, fan_out.hash}
    current = workflow.mapped[key] || []
    Map.put(workflow, :mapped, Map.put(workflow.mapped, key, [fact.hash | current]))
  end
  
  defp maybe_track_expected(workflow, false, _, _, _), do: workflow
end
```

---

### FanIn

**⚠️ Complex Coordination** — Check readiness, reduce when complete

```elixir
defimpl Runic.Workflow.Invokable, for: Runic.Workflow.FanIn do
  
  def match_or_execute(_), do: :execute
  
  # PREPARE
  def prepare(%FanIn{} = fan_in, workflow, fact) do
    fan_out = find_upstream_fan_out(workflow, fan_in)
    
    case fan_out do
      nil ->
        # Simple reduce - no FanOut, just reduce the enumerable
        context = %CausalContext{
          node_hash: fan_in.hash,
          input_fact: fact,
          ancestry_depth: ancestry_depth(workflow, fact),
          fan_in_context: %{mode: :simple}
        }
        
        {:ok, %Runnable{
          id: runnable_id(fan_in, fact),
          node: fan_in,
          input_fact: fact,
          context: context,
          status: :pending
        }}
        
      %FanOut{} ->
        source_fact_hash = find_fan_out_source_fact_hash(workflow, fact)
        parent_step_hash = elem(fact.ancestry, 0)
        
        # Check completion status
        already_completed = has_reduced_output?(workflow, fan_in, source_fact_hash) or
                           Map.get(workflow.mapped, {:fan_in_completed, source_fact_hash, fan_in.hash}, false)
        
        expected_key = {source_fact_hash, fan_out.hash}
        seen_key = {source_fact_hash, parent_step_hash}
        
        expected_list = workflow.mapped[expected_key] || []
        expected_set = MapSet.new(expected_list)
        seen_map = workflow.mapped[seen_key] || %{}
        seen_set = MapSet.new(Map.keys(seen_map))
        
        ready = not already_completed and 
                not Enum.empty?(expected_set) and
                MapSet.equal?(expected_set, seen_set)
        
        # Collect values in order if ready
        sister_values = 
          if ready do
            expected_in_order = Enum.reverse(expected_list)
            for origin <- expected_in_order do
              sister_hash = seen_map[origin]
              workflow.graph.vertices[sister_hash].value
            end
          else
            nil
          end
        
        context = %CausalContext{
          node_hash: fan_in.hash,
          input_fact: fact,
          ancestry_depth: ancestry_depth(workflow, fact),
          fan_in_context: %{
            mode: :fan_out_reduce,
            source_fact_hash: source_fact_hash,
            fan_out_hash: fan_out.hash,
            ready: ready,
            already_completed: already_completed,
            sister_values: sister_values,
            expected_key: expected_key,
            seen_key: seen_key
          }
        }
        
        {:ok, %Runnable{
          id: runnable_id(fan_in, fact),
          node: fan_in,
          input_fact: fact,
          context: context,
          status: :pending
        }}
    end
  end
  
  # EXECUTE
  def execute(%FanIn{init: init, reducer: reducer}, fact, context) do
    case context.fan_in_context.mode do
      :simple ->
        # Simple reduce on enumerable
        reduced = reduce_with_while(fact.value, init.(), reducer)
        {:ok, {:reduced, reduced}}
        
      :fan_out_reduce ->
        if context.fan_in_context.ready do
          reduced = reduce_with_while(
            context.fan_in_context.sister_values, 
            init.(), 
            reducer
          )
          {:ok, {:reduced, reduced}}
        else
          {:ok, :waiting}
        end
    end
  end
  
  # APPLY
  def build_apply(%FanIn{} = fan_in, result, context) do
    fn workflow, runnable ->
      case result do
        {:reduced, value} ->
          reduced_fact = Fact.new(
            value: value,
            ancestry: {fan_in.hash, runnable.input_fact.hash}
          )
          
          workflow
          |> Workflow.log_fact(reduced_fact)
          |> Workflow.draw_connection(fan_in, reduced_fact, :reduced,
               weight: context.ancestry_depth + 1)
          |> Workflow.run_after_hooks(fan_in, reduced_fact)
          |> Workflow.prepare_next_runnables(fan_in, reduced_fact)
          |> Workflow.mark_runnable_as_ran(fan_in, runnable.input_fact)
          |> maybe_cleanup_fan_in_tracking(context)
          
        :waiting ->
          Workflow.mark_runnable_as_ran(workflow, fan_in, runnable.input_fact)
      end
    end
  end
  
  defp maybe_cleanup_fan_in_tracking(workflow, context) do
    case context.fan_in_context.mode do
      :simple -> workflow
      :fan_out_reduce ->
        source_hash = context.fan_in_context.source_fact_hash
        completed_key = {:fan_in_completed, source_hash, context.node_hash}
        
        workflow
        |> Map.put(:mapped, Map.put(workflow.mapped, completed_key, true))
        |> Map.put(:mapped, Map.delete(workflow.mapped, context.fan_in_context.expected_key))
        |> Map.put(:mapped, Map.delete(workflow.mapped, context.fan_in_context.seen_key))
        |> Map.put(:mapped, Map.delete(workflow.mapped, {:fan_out_for_batch, source_hash}))
    end
  end
end
```

---

## Summary Table

| Node | Phase | Parallelizable | Extra Context Needed |
|------|-------|----------------|---------------------|
| **Root** | Execute | ✅ | None |
| **Condition** | Match | ✅ | None |
| **Conjunction** | Match | ✅ | `satisfied_condition_hashes` |
| **MemoryAssertion** | Match | ❌ | Full workflow (execute in prepare) |
| **Step** | Execute | ✅ | `fan_out_context` if mapped |
| **StateReaction** | Execute | ⚠️ | `last_known_state` |
| **StateCondition** | Match | ⚠️ | `last_known_state` |
| **Accumulator** | Execute | ❌ | `last_known_state`, order-dependent |
| **Join** | Execute | ⚠️ | `satisfied` facts, atomicity concern |
| **FanOut** | Execute | ✅ | `is_reduced` flag |
| **FanIn** | Execute | ⚠️ | `expected`, `seen`, `ready` state |

**Legend:**
- ✅ Fully parallelizable
- ⚠️ Parallelizable with state captured in context
- ❌ Requires serialization or special handling
