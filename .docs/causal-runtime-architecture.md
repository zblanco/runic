# Runic Causal Runtime Architecture

**RFC/Architecture Plan**  
**Status:** Draft  
**Authors:** Runic Core Team  
**Date:** January 2026

---

## Abstract

This document proposes a redesign of Runic's concurrent workflow execution model to address three fundamental issues:

1. **Generation tracking complexity** — The `generations` counter causes coordination failures in concurrent/merged workflows
2. **Memory overhead** — Copying entire workflow structs into parallel tasks is expensive and unnecessary
3. **Invoke coupling** — The `Invokable.invoke/3` protocol conflates side-effect execution with scheduling concerns

We propose a **causality-first runtime** that replaces generation counters with content-addressed fact ancestry, introduces a **`%Runnable{}`** struct with minimal causal context, and separates invocation into a **prepare → execute → apply** promise/continuation model suitable for durable execution.

---

## Table of Contents

1. [Problem Statement](#problem-statement)
2. [Prior Art & Research](#prior-art--research)
3. [Proposed Architecture](#proposed-architecture)
4. [Causal Context Model](#causal-context-model)
5. [Runnable Struct & Protocol](#runnable-struct--protocol)
6. [Promise + Continuation Execution Model](#promise--continuation-execution-model)
7. [Scheduler Coordination](#scheduler-coordination)
8. [Mergeable State & CRDT Considerations](#mergeable-state--crdt-considerations)
9. [Implementation Plan](#implementation-plan)
10. [Alternatives Considered](#alternatives-considered)
11. [Open Questions](#open-questions)
12. [References](#references)

---

## Problem Statement

### 1. Generation Tracking Failures

Runic workflows track a `generations` counter that increments on each input cycle. This is used to:
- Order causal productions (edge weights)
- Track FanOut/FanIn batch coordination
- Determine "events since" a given fact

Keeping the generation node in the graph and connecting facts to it provides a relatively cheap graph traversal to identify facts produced in the same generation.

But there's no real cost difference to placing the original input facts hash on an edge for filtration either although it may warrant adjacency indexing.

When workflows execute concurrently (via `Task.async`) and merge, the generation counter diverges between branches. The prior thread fixed FanIn coordination by switching to `source_fact.hash`-based keys, but the underlying issue remains: **generation is a global mutable counter that doesn't compose under concurrency**.

```elixir
# Problem: generation diverges across parallel branches
Task.async(fn -> Workflow.invoke(workflow, step1, fact1) end)  # gen = 5
Task.async(fn -> Workflow.invoke(workflow, step2, fact2) end)  # gen = 5

# After merge: which is gen 6? Both? Neither? 
```

### 2. Memory Overhead in Parallel Execution

The current parallel execution pattern copies the entire workflow into each task:

```elixir
Task.Supervisor.async(TaskRunner, fn ->
   {runnable_key, Runic.Workflow.invoke(session.workflow, step, fact)}
end)
```

For large workflows with many facts/edges, this is prohibitively expensive. The task only needs:
- The step to invoke
- The input fact
- Minimal causal context for stateful operations

### 3. Invoke Protocol Coupling

`Invokable.invoke/3` currently handles:
- Executing the step's work function
- Creating result facts
- Drawing edges in the graph
- Preparing next runnables
- Tracking FanIn coordination data
- Running hooks
- Making decisions in context of workflow state

This conflation makes it difficult to:
- Execute work separately from state updates
- Defer state application until coordination
- Support durable execution with replay/memoization
  * This is currently implemented via the event logging system but has limitations around checkpointing or serializing cheaper to recreate workflow representations.

---

## Prior Art & Research

### Durable Execution Frameworks (Jack Vanlightly)

From [Demystifying Determinism in Durable Execution](https://jack-vanlightly.com/blog/2025/11/24/demystifying-determinism-in-durable-execution):

> "Durable execution separates **control flow** from **side effects**. Control flow must be deterministic because recovery re-executes from the top. Side effects are memoized and only require idempotency."

Key insights for Runic:
- **Deterministic replay** requires consistent decision paths → ancestry hashes provide this
- **Side effects** should be recorded separately → our "produced" edges are the memoization log
- **Idempotency** comes from fact content-addressing → same inputs = same fact hash

From [The Durable Function Tree](https://jack-vanlightly.com/blog/2025/12/4/the-durable-function-tree-part-1):

> "Each function invocation returns a **durable promise** to the caller. When a child completes, its promise resolves, allowing the parent to resume. Failures are contained to a single branch."

Key insights:
- **Function trees** map naturally to our DAG of steps
- **Suspension points** = waiting for runnable completion
- **Independent retry** = each task can fail/retry without restarting siblings

### Forward Chaining with State Monad

The "Forward Chaining with State Monad" paper describes production systems where:
- Rules fire based on working memory facts
- State is threaded through rule applications as a monad
- Conflict resolution determines which rules fire

Runic's model is similar but uses a **graph** as the state container rather than a flat working memory.

### Wolfram Physics / Causal Graphs

Stephen Wolfram's computational physics models use **causal graphs** where:
- Nodes are states/events
- Edges represent causal relationships
- The graph itself is the "spacetime" of the computation
- No global clock — only local causal ordering

This maps directly to our ancestry model:
- Facts are events in the causal graph
- `ancestry: {producer_hash, parent_fact_hash}` is the causal link
- No global generation — only relative causal order

---

## Proposed Architecture

### Overview Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                         SCHEDULER                                │
│  (owns source-of-truth Workflow, coordinates merge)             │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │                    Workflow State                            │ │
│  │  • Graph (vertices: steps, facts, edges: causal links)      │ │
│  │  • Components registry                                       │ │
│  │  • Mapped tracking data                                      │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                              │                                   │
│                    ┌─────────▼─────────┐                         │
│                    │  prepare_runnable │                         │
│                    │  (build causal    │                         │
│                    │   context)        │                         │
│                    └─────────┬─────────┘                         │
│                              │                                   │
│         ┌────────────────────┼────────────────────┐              │
│         ▼                    ▼                    ▼              │
│  ┌─────────────┐      ┌─────────────┐      ┌─────────────┐       │
│  │ %Runnable{} │      │ %Runnable{} │      │ %Runnable{} │       │
│  │ step + fact │      │ step + fact │      │ step + fact │       │
│  │ + context   │      │ + context   │      │ + context   │       │
│  └──────┬──────┘      └──────┬──────┘      └──────┬──────┘       │
│         │                    │                    │              │
└─────────┼────────────────────┼────────────────────┼──────────────┘
          │                    │                    │
          ▼                    ▼                    ▼
   ┌─────────────┐      ┌─────────────┐      ┌─────────────┐
   │    Task 1   │      │    Task 2   │      │    Task 3   │
   │  execute()  │      │  execute()  │      │  execute()  │
   │             │      │             │      │             │
   │ Returns:    │      │ Returns:    │      │ Returns:    │
   │ Continuation│      │ Continuation│      │ Continuation│
   └──────┬──────┘      └──────┬──────┘      └──────┬──────┘
          │                    │                    │
          └────────────────────┼────────────────────┘
                               ▼
                    ┌─────────────────────┐
                    │   apply_results()   │
                    │  (merge into truth) │
                    └─────────────────────┘
```

### Key Components

1. **CausalContext** — Minimal immutable context extracted from workflow for invocation
2. **Runnable** — Promise struct containing step + fact + causal context + continuation
3. **Continuation** — Function to apply execution results back to workflow
4. **Scheduler** — Owns source-of-truth workflow, coordinates prepare/apply cycle

---

## Causal Context Model

### Design Goal

> "What is the minimal context I can extract from the workflow in minimal time/space complexity to execute a runnable properly?"

### CausalContext Struct

```elixir
defmodule Runic.Workflow.CausalContext do
  @moduledoc """
  Minimal immutable context for executing a runnable without the full workflow.
  
  Built during `prepare_runnable/3` and passed into task execution.
  Content-addressed using causal hashes rather than mutable generation counters.
  """
  
  defstruct [
    :step_hash,           # Hash of the step being invoked
    :input_fact,          # The fact triggering this invocation
    :ancestry_chain,      # List of {producer_hash, fact_hash} back to root
    :required_state,      # For stateful steps: last known state facts
    :fan_out_context,     # For mapped steps: {source_fact_hash, fan_out_hash, expected_hashes}
    :join_context,        # For joins: list of required parent step hashes
    :hooks                # Before/after hooks for this step
  ]
  
  @type t :: %__MODULE__{
    step_hash: integer(),
    input_fact: Fact.t(),
    ancestry_chain: [{integer(), integer()}],
    required_state: map(),
    fan_out_context: {integer(), integer(), [integer()]} | nil,
    join_context: [integer()] | nil,
    hooks: {[function()], [function()]}
  }
end
```

### Building the Ancestry Chain

Instead of generation counters, we trace **causal ancestry** from the input fact:

```elixir
def build_ancestry_chain(workflow, %Fact{ancestry: nil}), do: []

def build_ancestry_chain(workflow, %Fact{ancestry: {producer_hash, parent_fact_hash}} = fact) do
  parent_fact = workflow.graph.vertices[parent_fact_hash]
  
  [{producer_hash, parent_fact_hash} | build_ancestry_chain(workflow, parent_fact)]
end
```

This chain is:
- **Immutable** — determined entirely by fact content
- **Deterministic** — same fact always produces same chain
- **Minimal** — O(depth) rather than O(workflow size)

### Causal Ordering Without Generations

To order facts causally (for "events since X" queries), we compare ancestry chains:

```elixir
def causally_after?(fact_a, fact_b, workflow) do
  chain_a = build_ancestry_chain(workflow, fact_a)
  chain_b = build_ancestry_chain(workflow, fact_b)
  
  # A is after B if B's hash appears in A's ancestry
  Enum.any?(chain_a, fn {_producer, fact_hash} -> 
    fact_hash == fact_b.hash 
  end)
end
```

For edge weights (currently using `causal_generation`), we use **ancestry depth** or **topological order** from the DAG.

---

## Runnable Struct & Protocol

### Runnable Struct

```elixir
defmodule Runic.Workflow.Runnable do
  @moduledoc """
  A prepared unit of work ready for execution.
  
  Contains everything needed to execute independently of the source workflow,
  plus a continuation function for applying results back.
  """
  
  defstruct [
    :id,                  # Unique identifier (content hash of step + fact)
    :step,                # The invokable step struct
    :input_fact,          # The triggering fact
    :causal_context,      # Minimal context for execution
    :output_fact,         # Populated after execution
    :continuation,        # fn(workflow, output_fact) -> workflow
    :status,              # :pending | :running | :completed | :failed
    :idempotency_key,     # For durable execution: check if already dispatched
    :retry_count,         # Number of retries attempted
    :error                # Error info if failed
  ]
  
  @type t :: %__MODULE__{
    id: binary(),
    step: struct(),
    input_fact: Fact.t(),
    causal_context: CausalContext.t(),
    output_fact: Fact.t() | nil,
    continuation: (Workflow.t(), Fact.t() -> Workflow.t()),
    status: :pending | :running | :completed | :failed,
    idempotency_key: binary(),
    retry_count: non_neg_integer(),
    error: term() | nil
  }
  
  def idempotency_key(%__MODULE__{step: step, input_fact: fact}) do
    :erlang.phash2({step.hash, fact.hash})
  end
end
```

### Preparable Protocol

Add a new protocol for building runnables:

```elixir
defprotocol Runic.Workflow.Preparable do
  @moduledoc """
  Protocol for preparing a runnable from a step + fact pair.
  
  Each invokable type can build its own specialized CausalContext
  containing only the data it needs for execution.
  """
  
  @doc """
  Builds a Runnable struct with minimal causal context.
  """
  @spec prepare_runnable(step :: struct(), workflow :: Workflow.t(), fact :: Fact.t()) :: 
    Runnable.t()
  def prepare_runnable(step, workflow, fact)
end
```

### Example: Step Preparable Implementation

```elixir
defimpl Runic.Workflow.Preparable, for: Runic.Workflow.Step do
  alias Runic.Workflow.{Runnable, CausalContext, Fact}
  
  def prepare_runnable(%Step{} = step, workflow, fact) do
    context = %CausalContext{
      step_hash: step.hash,
      input_fact: fact,
      ancestry_chain: CausalContext.build_ancestry_chain(workflow, fact),
      fan_out_context: build_fan_out_context(workflow, step, fact),
      hooks: {
        Map.get(workflow.before_hooks, step.hash, []),
        Map.get(workflow.after_hooks, step.hash, [])
      }
    }
    
    %Runnable{
      id: Runnable.idempotency_key(step, fact),
      step: step,
      input_fact: fact,
      causal_context: context,
      continuation: &apply_step_result/2,
      status: :pending,
      retry_count: 0
    }
  end
  
  defp build_fan_out_context(workflow, step, fact) do
    if MapSet.member?(workflow.mapped.mapped_paths, step.hash) do
      case find_fan_out_info(workflow, fact) do
        {source_hash, fan_out_hash, _} -> 
          expected = workflow.mapped[{source_hash, fan_out_hash}] || []
          {source_hash, fan_out_hash, expected}
        nil -> 
          nil
      end
    else
      nil
    end
  end
  
  # The continuation function - applied after execution
  defp apply_step_result(workflow, %Runnable{output_fact: result_fact, step: step, input_fact: fact}) do
    # All graph updates happen here, in the scheduler context
    workflow
    |> Workflow.log_fact(result_fact)
    |> Workflow.draw_connection(step, result_fact, :produced, weight: ancestry_depth(result_fact))
    |> Workflow.mark_runnable_as_ran(step, fact)
    |> Workflow.run_after_hooks(step, result_fact)
    |> Workflow.prepare_next_runnables(step, result_fact)
    |> maybe_track_for_fan_in(step, result_fact)
  end
end
```

---

## Promise + Continuation Execution Model

### Three-Phase Execution

```
┌──────────────┐      ┌──────────────┐      ┌──────────────┐
│   PREPARE    │ ──▶  │   EXECUTE    │ ──▶  │    APPLY     │
│  (Scheduler) │      │   (Task)     │      │  (Scheduler) │
└──────────────┘      └──────────────┘      └──────────────┘
       │                     │                     │
       │                     │                     │
       ▼                     ▼                     ▼
  Build Runnable       Run work fn          Merge results
  with context         Pure computation     Update workflow
  Check idempotency    No workflow access   Draw edges
  Dispatch if needed   Return output fact   Schedule next
```

### Execute Function

Execution is pure — it only needs the step and fact:

```elixir
defmodule Runic.Workflow.Executor do
  @moduledoc """
  Pure execution of runnable work, separate from scheduling concerns.
  """
  
  @doc """
  Executes a runnable and returns the completed runnable with output fact.
  
  This function has NO access to the workflow — only the Runnable's contents.
  It is suitable for running in isolated tasks, remote workers, or durable execution replay.
  """
  @spec execute(Runnable.t()) :: {:ok, Runnable.t()} | {:error, Runnable.t()}
  def execute(%Runnable{step: step, input_fact: fact, causal_context: ctx} = runnable) do
    try do
      # Run before hooks (captured in context)
      {before_hooks, _} = ctx.hooks
      Enum.each(before_hooks, & &1.(step, fact))
      
      # Execute the actual work
      result = execute_work(step, fact)
      
      # Create output fact with causal ancestry
      output_fact = Fact.new(value: result, ancestry: {step.hash, fact.hash})
      
      {:ok, %{runnable | output_fact: output_fact, status: :completed}}
    rescue
      e ->
        {:error, %{runnable | status: :failed, error: e, retry_count: runnable.retry_count + 1}}
    end
  end
  
  defp execute_work(%{work: work}, %Fact{value: value}) do
    Components.run(work, value, Components.arity_of(work))
  end
end
```

### Scheduler Coordination

```elixir
defmodule Runic.Workflow.Scheduler do
  @moduledoc """
  Coordinates workflow execution with prepare/execute/apply phases.
  
  The Scheduler owns the source-of-truth workflow and coordinates:
  - Preparing runnables with minimal context
  - Dispatching to task executors
  - Applying results back and scheduling next runnables
  """
  
  def run_cycle(workflow, dispatched \\ MapSet.new()) do
    runnables = 
      workflow
      |> Workflow.next_runnables()
      |> Enum.map(fn {step, fact} -> 
        Preparable.prepare_runnable(step, workflow, fact) 
      end)
      |> Enum.reject(fn r -> MapSet.member?(dispatched, r.id) end)
    
    if Enum.empty?(runnables) do
      {:done, workflow}
    else
      # Dispatch and execute in parallel
      completed = execute_parallel(runnables)
      
      # Apply all results back to workflow
      workflow = Enum.reduce(completed, workflow, fn runnable, wrk ->
        runnable.continuation.(wrk, runnable)
      end)
      
      # Track dispatched for idempotency
      new_dispatched = Enum.reduce(runnables, dispatched, fn r, acc ->
        MapSet.put(acc, r.id)
      end)
      
      run_cycle(workflow, new_dispatched)
    end
  end
  
  defp execute_parallel(runnables) do
    runnables
    |> Enum.map(fn runnable ->
      Task.async(fn -> Executor.execute(runnable) end)
    end)
    |> Task.await_many()
    |> Enum.map(fn 
      {:ok, r} -> r
      {:error, r} -> handle_failure(r)
    end)
  end
end
```

---

## Mergeable State & CRDT Considerations

### The Merge Problem

When parallel tasks complete, their results must merge consistently:

```
Workflow (gen=5)
      │
      ├─── Task A: produces fact_a, draws edges
      │
      └─── Task B: produces fact_b, draws edges

Merged Workflow: must contain both facts with correct edges
```

### Causal Consistency via Ancestry

With ancestry-based causality, merging is simpler:

1. **Facts are content-addressed** — Same value + ancestry = same hash
2. **Edges are deterministic** — `{producer, fact, label}` tuples merge as sets
3. **No generation conflicts** — Ancestry depth replaces generation counters

### Graph Merge as Set Union

```elixir
def merge_graphs(g1, g2) do
  # Vertices: union by hash (content-addressed)
  vertices = Map.merge(g1.vertices, g2.vertices)
  
  # Edges: union by {v1, v2, label} key
  edges = merge_edge_indices(g1.edge_index, g2.edge_index)
  
  %Graph{vertices: vertices, edge_index: edges, ...}
end
```

### Mapped Tracking Data

For FanIn coordination, the `workflow.mapped` data uses stable keys:

```elixir
# Key: {source_fact_hash, fan_out_hash} — stable across branches
# Value: list of emitted fact hashes

# Merge: union of lists (order doesn't matter for set membership check)
def merge_mapped(m1, m2) do
  Map.merge(m1, m2, fn
    :mapped_paths, s1, s2 -> MapSet.union(s1, s2)
    {:fan_in_completed, _, _}, v1, v2 -> v1 or v2
    _key, v1, v2 when is_list(v1) and is_list(v2) -> Enum.uniq(v1 ++ v2)
    _key, v1, v2 when is_map(v1) and is_map(v2) -> Map.merge(v1, v2)
    _key, _v1, v2 -> v2
  end)
end
```

---

## Implementation Plan

### Phase 1: CausalContext & Runnable Structs (Week 1-2)

1. Create `Runic.Workflow.CausalContext` module
2. Create `Runic.Workflow.Runnable` module
3. Add `Runic.Workflow.Preparable` protocol
4. Implement `Preparable` for `Step` (simplest case)
5. Add tests for context building and ancestry chain

### Phase 2: Executor Separation (Week 2-3)

1. Create `Runic.Workflow.Executor` module
2. Extract pure execution logic from current `Invokable` impls
3. Implement continuation functions for result application
4. Add tests for execute → apply cycle

### Phase 3: Scheduler Implementation (Week 3-4)

1. Create `Runic.Workflow.Scheduler` module
2. Implement `run_cycle/2` with prepare/execute/apply phases
3. Add idempotency tracking
4. Add tests for parallel execution without full workflow copies

### Phase 4: Migrate Remaining Invokables (Week 4-6)

1. Implement `Preparable` for:
   - `Condition`
   - `Conjunction`
   - `FanOut`
   - `FanIn`
   - `Join`
   - `StateReaction`
   - `Accumulator`
   - `StateMachine`
2. Handle special cases (FanIn coordination, Join waiting)

### Phase 5: Remove Generation Counter (Week 6-7)

1. Replace `causal_generation/2` with `ancestry_depth/2`
2. Update edge weights to use ancestry depth
3. Update `events_produced_since/2` to use ancestry comparison
4. Remove `workflow.generations` field
5. Update tests

### Phase 6: Durable Execution Hooks (Week 7-8)

1. Add `DurableStore` behaviour for memoization
2. Add idempotency checks in Scheduler
3. Add replay support using `Runnable` structs
4. Add tests for crash recovery scenarios

---

## Alternatives Considered

### Alternative 1: Vector Clocks Instead of Ancestry Chains

**Approach:** Use vector clocks where each step maintains a logical clock.

**Pros:**
- Efficient concurrent ordering
- Well-understood in distributed systems

**Cons:**
- Requires knowing all "processes" (steps) upfront
- Doesn't map naturally to DAG structure
- More complex than necessary for our use case

**Decision:** Ancestry chains are sufficient and simpler. Our DAG naturally encodes causality.

### Alternative 2: Keep Generations, Fix Merge Logic

**Approach:** Make generation merging smarter (max of branches, track per-branch).

**Pros:**
- Smaller change to existing code
- Preserves existing mental model

**Cons:**
- Still a global mutable counter
- Merge logic becomes complex
- Doesn't solve the fundamental composition problem

**Decision:** Generation counters are fundamentally flawed for concurrent execution. Better to remove them.

### Alternative 3: Copy-on-Write Workflow with Structural Sharing

**Approach:** Use persistent data structures so copying is cheap (structural sharing).

**Pros:**
- Minimal code changes
- Copying becomes O(log n) instead of O(n)

**Cons:**
- Doesn't address the scheduling/execution coupling
- Still copying more than needed
- Elixir already has some structural sharing; the Graph library may not

**Decision:** This could complement our approach but doesn't solve the core issues.

---

## Open Questions

1. **How to handle hooks in isolated execution?**
   - Hooks may have side effects that depend on workflow state
   - Option A: Capture hook closures in CausalContext
   - Option B: Run hooks only in apply phase (scheduler context)

2. **How to handle StateReaction/Accumulator state lookups?**
   - These need to read current state from workflow
   - Option A: Include last state fact in CausalContext
   - Option B: Make stateful steps non-parallelizable (serialize through scheduler)

3. **Should we persist Runnable structs for durable execution?**
   - Could enable true suspend/resume across process restarts
   - Requires serializable step structs (closures are problematic)

4. **How to handle dynamic workflow modification during execution?**
   - Current model allows adding steps during invoke
   - New model would need to batch these for apply phase

5. **What's the right abstraction for distributed execution?**
   - Current design assumes single-node Task parallelism
   - For multi-node, Runnables could be serialized and sent to workers
   - Needs thought on how to handle continuation functions

---

## References

1. Jack Vanlightly, "Demystifying Determinism in Durable Execution" (2025)  
   https://jack-vanlightly.com/blog/2025/11/24/demystifying-determinism-in-durable-execution

2. Jack Vanlightly, "The Durable Function Tree" (2025)  
   https://jack-vanlightly.com/blog/2025/12/4/the-durable-function-tree-part-1

3. "Forward Chaining with State Monad" — Production system semantics with monadic state threading

4. Stephen Wolfram, "A New Kind of Science" — Causal graph models of computation

5. Temporal.io Documentation — Workflow and Activity separation patterns  
   https://docs.temporal.io/

6. Restate.dev Documentation — Durable execution with virtual objects  
   https://docs.restate.dev/

7. Marc Shapiro et al., "Conflict-free Replicated Data Types" — CRDT theory for mergeable state

---

## Appendix A: Current vs. Proposed Code Comparison

### Current: Invoke copies entire workflow

```elixir
# In test/parallel runner
Task.async(fn ->
  Workflow.invoke(workflow, step, fact)  # Full workflow copied into task
end)
```

### Proposed: Execute with minimal context

```elixir
# In Scheduler
runnables = Workflow.next_runnables(workflow)
            |> Enum.map(&Preparable.prepare_runnable(&1, workflow))

Task.async_stream(runnables, fn runnable ->
  Executor.execute(runnable)  # Only Runnable struct (small) in task
end)
|> Enum.reduce(workflow, fn {:ok, r}, wrk -> 
  r.continuation.(wrk, r) 
end)
```

### Current: Generation-based causal ordering

```elixir
def causal_generation(workflow, fact) do
  workflow.graph
  |> Graph.edges(fact, by: [:produced, ...])
  |> hd()
  |> Map.get(:weight)
  |> Kernel.+(1)
end
```

### Proposed: Ancestry-based ordering

```elixir
def ancestry_depth(%Fact{ancestry: nil}), do: 0
def ancestry_depth(%Fact{ancestry: {_, parent_hash}}, workflow) do
  parent = workflow.graph.vertices[parent_hash]
  1 + ancestry_depth(parent, workflow)
end
```

---

## Appendix B: Runnable Lifecycle Diagram

```
              ┌─────────────────────────────────────────────┐
              │              SCHEDULER                       │
              │  (source-of-truth workflow)                  │
              └─────────────────────────────────────────────┘
                    │                           ▲
                    │ prepare_runnable()        │ continuation()
                    ▼                           │
              ┌─────────────┐             ┌─────────────┐
              │  Runnable   │────────────▶│  Runnable   │
              │  :pending   │  execute()  │ :completed  │
              │             │             │ output_fact │
              └─────────────┘             └─────────────┘
                    │                           │
                    │    ┌───────────────┐      │
                    └───▶│ Task/Worker   │◀─────┘
                         │ (isolated)    │
                         └───────────────┘
                         
                         Only has access to:
                         • step struct
                         • input fact  
                         • causal context
                         
                         No workflow access!
```
