# Exploration: Workflow-as-Aggregate Event Sourcing Model

**Status:** Exploration / Alternative Architecture  
**Related:** [Checkpointing Implementation Plan](checkpointing-implementation-plan.md), [Checkpointing Strategies Proposal](checkpointing-strategies-proposal.md), [Runner Scheduling](full-breadth-runner-scheduling-considerations.md)  
**Influences:** Restate Journal, Commanded (Elixir CQRS/ES), Akka Persistence, Datomic  

---

## Thesis

Instead of instrumenting Runic's existing graph mutation functions (`draw_connection`, `log_fact`, `mark_runnable_as_ran`) to _also_ emit journal events as a side-channel, we restructure the Workflow so that **events are the primary mutation interface**. The workflow graph becomes a _projection_ — a materialized view derived by folding events. Graph state is never mutated directly; all state transitions go through event emission followed by event application.

This is the classical event sourcing aggregate pattern applied to Runic's workflow: the `%Workflow{}` is the aggregate, events are commands that have been validated and accepted, and the graph is the read model rebuilt by replaying them.

The key insight: Runic _already has_ most of the event vocabulary (`ComponentAdded`, `ReactionOccurred`, `RunnableDispatched`, `RunnableCompleted`, `RunnableFailed`). The current `from_log/1` is already an event replay function. What's missing is the inverse — making event emission the _only_ path to state change, rather than having direct graph mutations with events derived after the fact.

---

## Current Architecture: Direct Mutation + Derived Events

Today's mutation flow:

```
Invokable.execute(node, runnable)
  → build apply_fn closure
  → apply_fn.(workflow)
    → Workflow.log_fact(result_fact)           ← direct Graph.add_vertex
    → Workflow.draw_connection(node, fact, :produced)  ← direct Graph.add_edge
    → Workflow.mark_runnable_as_ran(node, fact)        ← direct Graph.update_labelled_edge
    → Workflow.prepare_next_runnables(node, fact)      ← direct Graph.add_edge for each next step
```

Events are derived _after_ the graph has already been mutated:

```
Workflow.log(wrk)
  → build_log(wrk)            ← scans components for ComponentAdded events
  → reactions_occurred(wrk)    ← scans entire edge_index for non-:flow edges → ReactionOccurred
  → wrk.runnable_events       ← already accumulated (RunnableDispatched/Completed/Failed)
```

**Problems this creates:**

1. The "log" is a derived snapshot, not a chronological record. It cannot be diffed or appended.
2. `reactions_occurred/1` scans the whole graph — O(total edges) on every checkpoint.
3. The event vocabulary is incomplete — `ReactionOccurred` is a generic wrapper that lumps together semantically different operations (`:produced`, `:satisfied`, `:ran`, `:runnable`, `:state_produced`, etc.).
4. There's no causal ordering in the derived events — they come out in graph traversal order, not the order they occurred.
5. The `apply_fn` closure on `%Runnable{}` is the _only_ way to express "what this execution did to the workflow." It's not serializable, not inspectable, and not replayable without re-executing.

---

## Proposed Architecture: Event-First Aggregate

### Core Idea

```
                    ┌─────────────┐
  command/input ──► │  validate   │ ──► [Event, Event, ...] ──► fold into graph
                    └─────────────┘         │
                                            ▼
                                      append to journal
                                      (Store.append/3)
```

Every state transition produces one or more domain events. The events are:
1. **Applied** to the in-memory graph immediately (for low-latency runtime)
2. **Buffered** for persistence (flushed on checkpoint)
3. **Replayable** to reconstruct the graph from scratch (`from_events/1`)

The Workflow module gains two new core concepts:

- **`emit/2`** — the only way to mutate workflow state; accepts an event, returns updated workflow
- **`apply_event/2`** — pure function that folds a single event into the graph; used by both `emit/2` (runtime) and `from_events/1` (rehydration)

### Event Vocabulary

Expand the existing event types into a complete domain event language:

```elixir
# === Build-time events (workflow construction) ===
# Already exists:
%ComponentAdded{name, closure, to}

# === Runtime events (workflow execution) ===

# A fact was introduced to the workflow (input or produced)
%FactProduced{
  hash: fact_hash,
  value: term(),           # the actual value (can be large)
  ancestry: {producer_hash, parent_fact_hash} | nil,
  producer_label: :produced | :state_produced | :state_initiated | :reduced | :fan_out | :joined
}

# A component was activated (fact reached it, ready for execution)
%RunnableActivated{
  fact_hash: fact_hash,
  node_hash: node_hash,
  activation_kind: :runnable | :matchable
}

# A component finished processing a fact (consumed the activation)
%ActivationConsumed{
  fact_hash: fact_hash,
  node_hash: node_hash,
  from_label: :runnable | :matchable,
}

# A condition was satisfied by a fact
%ConditionSatisfied{
  fact_hash: fact_hash,
  condition_hash: node_hash,
  weight: non_neg_integer()
}

# A join received a fact from one of its branches
%JoinFactReceived{
  fact_hash: fact_hash,
  join_hash: node_hash,
  weight: non_neg_integer()
}

# A join completed — all branches satisfied
%JoinCompleted{
  join_hash: node_hash,
  result_fact_hash: fact_hash
}

# An edge label was updated (e.g., :joined → :join_satisfied)
%EdgeRelabeled{
  from_vertex: term(),
  to_vertex: term(),
  from_label: atom(),
  to_label: atom()
}

# A downstream subgraph was marked unreachable due to upstream failure
%DownstreamSkipped{
  failed_node_hash: node_hash,
  skipped_node_hashes: [node_hash]
}

# Meta-ref edge drawn (build-time, during component connection)
%MetaRefEstablished{
  from_hash: node_hash,
  to_hash: node_hash,
  kind: atom(),
  properties: map()
}

# === Execution lifecycle events (already exist, enhanced) ===
%RunnableDispatched{...}   # existing
%RunnableCompleted{...}    # existing
%RunnableFailed{...}       # existing

# === Checkpointing events ===
%SnapshotTaken{
  at_sequence: non_neg_integer(),
  graph_binary: binary()    # :erlang.term_to_binary of graph
}
```

**Key design decision:** `FactProduced` carries the `value` field. For the journal-on-disk, the value can be extracted and stored separately in the fact store (content-addressed by hash), with the journal entry carrying only the hash+ancestry. This separation happens at the Store adapter level, not in the event model itself. The in-memory event always has the value for immediate graph application.

### The `apply_event/2` Fold Function

This is the heart of the model — a pure function from `(Workflow, Event) → Workflow`:

```elixir
defmodule Runic.Workflow do
  def apply_event(%__MODULE__{} = wf, %FactProduced{} = e) do
    fact = Fact.new(hash: e.hash, value: e.value, ancestry: e.ancestry)

    %{wf | graph:
      wf.graph
      |> Graph.add_vertex(fact)
      |> maybe_add_production_edge(e)
    }
  end

  def apply_event(%__MODULE__{} = wf, %RunnableActivated{} = e) do
    fact_vertex = Map.get(wf.graph.vertices, e.fact_hash)
    node_vertex = Map.get(wf.graph.vertices, e.node_hash)

    %{wf | graph: Graph.add_edge(wf.graph, fact_vertex, node_vertex,
      label: e.activation_kind)}
  end

  def apply_event(%__MODULE__{} = wf, %ActivationConsumed{} = e) do
    fact_vertex = Map.get(wf.graph.vertices, e.fact_hash)
    node_vertex = Map.get(wf.graph.vertices, e.node_hash)

    graph =
      case Graph.update_labelled_edge(wf.graph, fact_vertex, node_vertex, e.from_label,
             label: :ran) do
        %Graph{} = g -> g
        {:error, :no_such_edge} -> wf.graph
      end

    %{wf | graph: graph}
  end

  def apply_event(%__MODULE__{} = wf, %ConditionSatisfied{} = e) do
    fact_vertex = Map.get(wf.graph.vertices, e.fact_hash)
    cond_vertex = Map.get(wf.graph.vertices, e.condition_hash)

    %{wf | graph: Graph.add_edge(wf.graph, fact_vertex, cond_vertex,
      label: :satisfied, weight: e.weight)}
  end

  # ... etc for each event type
end
```

**Critical property:** `apply_event/2` must be deterministic and free of side effects. Given the same event stream and the same initial workflow structure, it must produce the same graph state. This is what makes replay (rehydration) correct.

### The `emit/2` Runtime Interface

```elixir
def emit(%__MODULE__{} = wf, event) do
  wf
  |> apply_event(event)
  |> buffer_event(event)
end

def emit(%__MODULE__{} = wf, events) when is_list(events) do
  Enum.reduce(events, wf, &emit(&2, &1))
end

defp buffer_event(%__MODULE__{} = wf, event) do
  %{wf | journal: [event | wf.journal]}
end
```

### Rehydration via Replay

```elixir
def from_events(events, opts \\ []) do
  {build_events, runtime_events} = Enum.split_with(events, &is_struct(&1, ComponentAdded))

  base = from_log(build_events)  # existing function handles ComponentAdded

  Enum.reduce(runtime_events, base, fn event, wf ->
    apply_event(wf, event)
  end)
end
```

---

## What Changes: Invokable and apply_fn

This is the most consequential refactor. Today, every `Invokable.execute/2` implementation builds a `Runnable` with an `apply_fn` closure that directly mutates the workflow graph. In the event-sourced model, the `apply_fn` must instead **return a list of events** that describe the mutations.

### Current Pattern (every Invokable impl)

```elixir
# Step.execute/2 today:
def execute(%Step{} = step, %Runnable{input_fact: fact, context: ctx} = runnable) do
  result = Components.run(step.work, fact.value, Components.arity_of(step.work))
  result_fact = Fact.new(value: result, ancestry: {step.hash, fact.hash})

  apply_fn = fn workflow ->
    workflow
    |> Workflow.log_fact(result_fact)                          # Graph.add_vertex
    |> Workflow.draw_connection(step, result_fact, :produced)  # Graph.add_edge
    |> Workflow.mark_runnable_as_ran(step, fact)               # Graph.update_labelled_edge
    |> Workflow.prepare_next_runnables(step, result_fact)      # Graph.add_edge × N
  end

  Runnable.complete(runnable, result_fact, apply_fn)
end
```

### Event-Sourced Pattern

```elixir
# Step.execute/2 in event-sourced model:
def execute(%Step{} = step, %Runnable{input_fact: fact, context: ctx} = runnable) do
  result = Components.run(step.work, fact.value, Components.arity_of(step.work))
  result_fact = Fact.new(value: result, ancestry: {step.hash, fact.hash})

  events = [
    %FactProduced{
      hash: result_fact.hash,
      value: result_fact.value,
      ancestry: result_fact.ancestry,
      producer_label: :produced
    },
    %ActivationConsumed{
      fact_hash: fact.hash,
      node_hash: step.hash,
      from_label: :runnable
    }
    # RunnableActivated events for downstream steps are NOT produced here.
    # They're produced by the Workflow.emit handler for FactProduced,
    # which knows the graph topology.
    # OR: the Invokable builds them using ctx.next_step_hashes captured during prepare.
  ]

  Runnable.complete(runnable, result_fact, events)
end
```

**This is the first major design tension.** Today's `prepare_next_runnables/3` needs the full workflow graph to find `:flow` successors. In the execute phase, there's no workflow access. Two options:

#### Option A: Capture topology in prepare, emit activation events in execute

During `prepare/3`, capture the next step hashes in the `CausalContext`:

```elixir
def prepare(%Step{} = step, %Workflow{} = workflow, %Fact{} = fact) do
  next_steps = Workflow.next_steps(workflow, step)

  context = CausalContext.new(
    node_hash: step.hash,
    input_fact: fact,
    next_step_hashes: Enum.map(next_steps, & &1.hash),
    next_step_activation_kinds: Enum.map(next_steps, &activation_kind/1),
    # ...
  )

  {:ok, Runnable.new(step, fact, context)}
end
```

Then in `execute/2`, the runnable has enough information to produce `RunnableActivated` events for each downstream step without needing the workflow graph.

**Pros:** Execute phase remains truly isolated; events are self-contained.
**Cons:** More data captured in prepare phase; if the graph changes between prepare and apply (concurrent modifications), the activation events may reference stale topology. However, this is already the case with today's `apply_fn` closures — they capture step references from the prepare-time graph.

#### Option B: Split event production — execute emits core events, apply_event triggers cascading activations

Make `apply_event(%FactProduced{})` automatically walk `:flow` successors and produce `RunnableActivated` events:

```elixir
def apply_event(%__MODULE__{} = wf, %FactProduced{} = e) do
  fact = Fact.new(hash: e.hash, value: e.value, ancestry: e.ancestry)
  wf = %{wf | graph: Graph.add_vertex(wf.graph, fact) |> add_production_edge(e)}

  # Cascading: find downstream steps and activate them
  {producer_hash, _} = e.ancestry
  producer = Map.get(wf.graph.vertices, producer_hash)
  next_steps = Workflow.next_steps(wf, producer)

  activation_events = Enum.map(next_steps, fn step ->
    %RunnableActivated{
      fact_hash: e.hash,
      node_hash: step.hash,
      activation_kind: Private.connection_for_activatable(step)
    }
  end)

  Enum.reduce(activation_events, wf, fn event, w ->
    w |> apply_event(event) |> buffer_event(event)
  end)
end
```

**Pros:** Execute phase only emits "what happened" (fact produced, activation consumed). Topology logic stays in the workflow.
**Cons:** `apply_event` is no longer a simple fold — it has cascading side effects (emitting further events). This is an "event-carried state transfer" pattern that complicates replay (you need to suppress cascade events during replay since they're already in the journal, or you need to distinguish "primary" from "derived" events).

#### Option C (Recommended): Events from execute, apply as fold, activation as a separate apply-phase step

Keep `apply_event/2` as a pure fold. Keep `prepare_next_runnables` as a separate post-apply step. The Runnable returns events from `execute/2` that describe what happened. `Workflow.apply_runnable/2` folds them and then runs `prepare_next_runnables`:

```elixir
def apply_runnable(%__MODULE__{} = wf, %Runnable{status: :completed, events: events, result: result_fact}) do
  # Fold core events (fact produced, activation consumed, condition satisfied, etc.)
  wf = Enum.reduce(events, wf, &apply_event(&2, &1))

  # Then run topology-dependent cascading (this produces & folds activation events)
  case result_fact do
    %Fact{ancestry: {producer_hash, _}} ->
      producer = Map.get(wf.graph.vertices, producer_hash)
      wf |> emit_activations(producer, result_fact)

    _ -> wf
  end
end

defp emit_activations(wf, producer, fact) do
  Workflow.next_steps(wf, producer)
  |> Enum.reduce(wf, fn step, w ->
    emit(w, %RunnableActivated{
      fact_hash: fact.hash,
      node_hash: step.hash,
      activation_kind: Private.connection_for_activatable(step)
    })
  end)
end
```

**This is the cleanest separation.** Execute phase produces "what happened" events. Apply phase folds them and handles topology-dependent cascading. During replay, cascading events are already in the journal, so you replay them directly without re-deriving.

---

## What Changes: The Runnable Struct

The `%Runnable{}` struct gains an `events` field alongside or replacing `apply_fn`:

```elixir
defstruct [
  :id, :node, :input_fact, :context,
  :status, :result, :error,
  :apply_fn,    # DEPRECATED — kept for backward compat during migration
  :events       # NEW — list of domain events produced by execution
]
```

During migration, `apply_runnable/2` checks for `events` first:

```elixir
def apply_runnable(wf, %Runnable{events: events}) when is_list(events) and events != [] do
  # Event-sourced path
  Enum.reduce(events, wf, &apply_event(&2, &1))
  |> maybe_emit_cascading_activations(runnable)
end

def apply_runnable(wf, %Runnable{apply_fn: apply_fn}) when is_function(apply_fn) do
  # Legacy path
  apply_fn.(wf)
end
```

**Major benefit:** `events` is serializable, inspectable, and replayable. `apply_fn` is none of those. This directly solves the "remote Executor" problem from the scheduling doc — instead of trying to serialize/reconstruct `apply_fn`, the remote Executor returns the Runnable with `events`, and the Worker folds them.

---

## What Changes: Store Contracts

The Store behaviour simplifies dramatically. Instead of separate `save/load` (full snapshot) and `append/load_all` (journal), there's one primary interface:

```elixir
defmodule Runic.Runner.Store do
  @type workflow_id :: term()
  @type event :: struct()
  @type cursor :: non_neg_integer()
  @type state :: term()

  # === Core (required) ===
  @callback init_store(opts :: keyword()) :: {:ok, state()} | {:error, term()}
  @callback append(workflow_id(), events :: [event()], state()) :: {:ok, cursor()} | {:error, term()}
  @callback stream(workflow_id(), state()) :: {:ok, Enumerable.t()} | {:error, :not_found | term()}

  # === Snapshot (optional — for faster recovery) ===
  @callback save_snapshot(workflow_id(), cursor(), snapshot :: binary(), state()) :: :ok | {:error, term()}
  @callback load_snapshot(workflow_id(), state()) :: {:ok, {cursor(), binary()}} | {:error, :not_found | term()}

  # === Fact-level storage (optional — for hybrid rehydration) ===
  @callback save_fact(fact_hash :: term(), value :: term(), state()) :: :ok | {:error, term()}
  @callback load_fact(fact_hash :: term(), state()) :: {:ok, term()} | {:error, :not_found | term()}

  # === Lifecycle (optional) ===
  @callback delete(workflow_id(), state()) :: :ok | {:error, term()}
  @callback list(state()) :: {:ok, [workflow_id()]} | {:error, term()}
  @callback exists?(workflow_id(), state()) :: boolean()

  @optional_callbacks [
    save_snapshot: 4, load_snapshot: 2,
    save_fact: 3, load_fact: 2,
    delete: 2, list: 1, exists?: 2
  ]
end
```

**Key simplification:** `save/3` and `load/2` are gone as required callbacks. The event stream is the source of truth. Snapshots are optional acceleration — load snapshot at cursor N, then replay events since N.

The existing `save/load` pattern maps to: "snapshot at cursor 0 containing the full derived log." Adapter migration can provide backward-compatible `save/load` on top of `append/stream` internally.

### Store Adapter Implications

**ETS:** Events in an `:ordered_set` table keyed by `{workflow_id, sequence}`. `stream/2` returns a lazy enumerable over `:ets.select`. Snapshots in the existing `:set` table.

**Mnesia:** Events in an ordered table. Transaction-wrapped `append`. `stream/2` via `:mnesia.select` with key range. Natural fit for disc_copies durability.

**Future Postgres (Ecto):** Events in a `workflow_events` table with `(workflow_id, sequence)` primary key. `append` is a batch insert. `stream` is a `SELECT ... ORDER BY sequence`. Snapshots in a `workflow_snapshots` table. This is the canonical event store schema.

**Future Kafka/EventStore:** Direct append to a topic/stream partitioned by workflow_id. Native consumer for stream. Snapshots via compaction or a side table.

---

## What Changes: Executor Contract

The Executor gains explicit event awareness. Instead of receiving an opaque `work_fn` closure, it can receive a serializable dispatch intent:

```elixir
defmodule Runic.Runner.Executor do
  # Option A: closure-based (local executors, backward compat)
  @callback dispatch(work_fn :: (-> term()), dispatch_opts(), executor_state()) ::
              {handle(), executor_state()}

  # Option B: intent-based (remote executors, durable execution)
  @callback dispatch_intent(intent :: DispatchIntent.t(), dispatch_opts(), executor_state()) ::
              {handle(), executor_state()}

  @optional_callbacks [dispatch_intent: 3]
end

defmodule Runic.Runner.DispatchIntent do
  @moduledoc """
  A fully serializable representation of work to be done.
  Replaces the opaque work_fn closure for remote/durable executors.
  """
  defstruct [
    :workflow_id,
    :runnable_id,
    :node,          # the component struct (serializable via Closure)
    :input_fact,    # the input Fact
    :context,       # CausalContext (serializable)
    :policy         # SchedulerPolicy (serializable after stripping fallback fn)
  ]
end
```

**The execute phase returns events, not a closure.** A remote Executor:
1. Receives a `DispatchIntent`
2. Reconstructs the Runnable from the intent
3. Calls `Invokable.execute(node, runnable)`
4. Gets back a `%Runnable{events: [...]}` — fully serializable
5. Sends the events back to the coordinating Worker

No need to reconstruct `apply_fn`. No closure serialization. The events _are_ the result.

---

## What Changes: Worker Lifecycle

The Worker becomes an event-sourced aggregate host:

```elixir
defmodule Runic.Runner.Worker do
  defstruct [
    :id, :runner, :workflow, :store,
    :task_supervisor, :max_concurrency,
    :on_complete, :checkpoint_strategy,
    :resolver,
    status: :idle,
    active_tasks: %{},
    dispatch_times: %{},
    event_cursor: 0,           # monotonic sequence for journal ordering
    uncommitted_events: [],    # events not yet flushed to store
    cycle_count: 0,
    started_at: nil
  ]

  # After a task completes:
  defp handle_task_result(ref, %Runnable{events: events} = executed, state) do
    # 1. Fold events into workflow (immediate in-memory state change)
    workflow = Enum.reduce(events, state.workflow, &Workflow.apply_event(&2, &1))

    # 2. Run cascading activations (topology-dependent, produces more events)
    {workflow, activation_events} = emit_cascading_activations(workflow, executed)

    # 3. Buffer all events for persistence
    all_events = events ++ activation_events
    state = %{state |
      workflow: workflow,
      uncommitted_events: state.uncommitted_events ++ all_events,
      event_cursor: state.event_cursor + length(all_events)
    }

    # 4. Maybe flush to store
    state = maybe_checkpoint(state)

    # 5. Continue dispatch loop
    state = dispatch_runnables(state)
    maybe_transition_to_idle(state)
  end

  defp do_checkpoint(state) do
    {store_mod, store_state} = state.store
    events = state.uncommitted_events

    unless Enum.empty?(events) do
      # Extract and persist fact values first
      flush_fact_values(events, store_mod, store_state)
      # Then append events
      {:ok, _cursor} = store_mod.append(state.id, events, store_state)
    end

    %{state | uncommitted_events: []}
  end

  # Recovery: replay from store
  def resume(runner, workflow_id, opts) do
    {store_mod, store_state} = get_store(runner)

    {base_cursor, base_workflow} =
      if function_exported?(store_mod, :load_snapshot, 2) do
        case store_mod.load_snapshot(workflow_id, store_state) do
          {:ok, {cursor, binary}} -> {cursor, :erlang.binary_to_term(binary)}
          {:error, :not_found} -> {0, build_base_workflow(store_mod, store_state, workflow_id)}
        end
      else
        {0, build_base_workflow(store_mod, store_state, workflow_id)}
      end

    {:ok, event_stream} = store_mod.stream(workflow_id, store_state)

    workflow =
      event_stream
      |> Stream.drop(base_cursor)
      |> Enum.reduce(base_workflow, &Workflow.apply_event(&2, &1))

    start_worker(runner, workflow_id, workflow, opts)
  end
end
```

---

## Hybrid Rehydration in the Event-Sourced Model

The checkpointing strategies compose naturally:

### Strategy: Snapshot + Event Replay (Snapshot+WAL equivalent)

1. Periodically snapshot the full graph state at cursor N
2. On recovery: load snapshot, replay events since N
3. The "WAL" is just the tail of the event stream

### Strategy: Hybrid Rehydration (Strategy 5)

During replay, use `FactRef` for cold facts:

```elixir
def apply_event_hybrid(wf, %FactProduced{} = e, %{hot_hashes: hot}) do
  if MapSet.member?(hot, e.hash) do
    # Hot: load full fact with value
    fact = Fact.new(hash: e.hash, value: e.value, ancestry: e.ancestry)
    %{wf | graph: Graph.add_vertex(wf.graph, fact) |> add_production_edge(e)}
  else
    # Cold: use FactRef (no value in memory)
    ref = FactRef.new(hash: e.hash, ancestry: e.ancestry)
    %{wf | graph: Graph.add_vertex(wf.graph, ref) |> add_production_edge(e)}
  end
end
```

The hot set is determined by a two-pass replay:
1. First pass: replay all events to build the graph structure (with FactRefs everywhere)
2. Classify hot/cold using the lineage algorithm from the checkpointing proposal
3. Second pass (selective): resolve hot FactRefs to full Facts from the fact store

Or, more efficiently: stream events in reverse from the tail to identify the hot set before the forward replay. The last `FactProduced` events with `:runnable`/`:matchable` activations downstream are hot.

### Strategy: Sticky + Eviction

For long-running workers: when memory exceeds a threshold, identify cold facts via the classifier, replace their graph vertices with FactRefs, and note the eviction. No event is emitted for eviction (it's a read-model optimization, not a domain event).

---

## Benefits of the Event-Sourced Model

### 1. Serializable Execution Results (solves the apply_fn problem)

Today's `apply_fn` is an anonymous closure that captures step references, facts, and hooks in its environment. It cannot be serialized, inspected, or transmitted across process/node boundaries. This is the single biggest obstacle to remote executors and durable execution replay.

With events as the execution result, `%Runnable{events: [...]}` is fully serializable. Remote Executors return events. Durable replay uses events. No closure reconstruction needed.

### 2. Natural Append-Only Persistence

The event journal _is_ the checkpoint. No derived snapshot scanning. No O(total edges) serialization. `append/3` is O(new events). The Store contract is simpler and maps directly to event store, Kafka, and Postgres patterns.

### 3. Temporal Queries and Audit

With a chronological event stream, you can answer questions like:
- "What was the workflow state at event N?" — replay to N
- "What happened between events N and M?" — slice the stream
- "Which facts were produced by input X?" — filter FactProduced events by ancestry chain
- "How long did step Y take?" — correlate RunnableDispatched/Completed events

### 4. Cleaner Invokable Protocol

The execute phase returns data (events), not behavior (closures). This makes Invokable implementations:
- **Testable** — assert on the events produced, not on opaque closures
- **Composable** — merge event lists from multiple executions
- **Inspectable** — log/debug what an execution did without running it

### 5. Natural Fit for Distribution

Events are the lingua franca of distributed systems. A distributed Runner can:
- Ship events between nodes (already serializable)
- Use event ordering for consistency (causal via ancestry)
- Deduplicate via event IDs/hashes

### 6. Decoupled Read Models

The graph is just one projection of the event stream. Other projections are possible:
- A "production log" that tracks only FactProduced events
- A "performance model" that tracks dispatch/completion timing
- A "dependency map" that tracks which facts depend on which inputs

---

## Concerns, Unknowns, and Complications

### Concern 1: Scope of the Refactor — Every Invokable Implementation

**Impact: HIGH — this is the biggest cost**

Every `Invokable.execute/2` implementation must change from producing an `apply_fn` closure to producing a list of events. The affected implementations:

| Invokable Impl | Complexity | Notes |
|----------------|------------|-------|
| `Root` | Low | Simple: FactProduced + activations |
| `Step` | Medium | Core pattern, hooks, fan-out tracking |
| `Condition` | Medium | Branching: satisfied vs not, hooks |
| `Conjunction` | Low | Mostly delegating to Condition pattern |
| `MemoryAssertion` | Medium | Needs workflow access in prepare (already handled) |
| `StateCondition` | Medium | Reads accumulator state, conditional branching |
| `StateReaction` | Medium | Reads state, produces fact, state edge semantics |
| `Accumulator` | **High** | Init vs update paths, `:state_produced` vs `:state_initiated` edges, complex edge semantics |
| `Join` | **High** | Multi-branch coordination, `:joined` → `:join_satisfied` relabeling, recheck on apply for concurrent arrivals |
| `FanOut` | Medium | Iterates over enumerable, produces N facts + N activations |
| `FanIn` | **High** | Complex coordination with `mapped` state, batch completion detection, `reduce_with_while` |

The Accumulator, Join, and FanIn implementations are the most complex because they have:
- Multiple edge label transitions (`:joined` → `:join_satisfied`, `:state_initiated`, etc.)
- Coordination state (`mapped`, `satisfied_by_parent`)
- Conditional branching within apply (Join's "recheck if can complete now")

**The Join recheck problem:** Today, Join's `apply_fn` re-examines the graph to see if other branches have arrived during concurrent execution. In the event model, this logic must either:
- Move to the Worker's `apply_runnable` (which has the current graph state), or
- Be expressed as conditional events ("if join can complete, emit JoinCompleted; else emit JoinFactReceived"), determined during apply, not execute

This is the hardest case because it violates the "execute produces events without graph access" principle. The execute phase doesn't know if the join can complete — that depends on what other branches have done concurrently.

**Mitigation:** The Join's execute phase always produces a `JoinFactReceived` event. The Worker's apply phase, after folding the event, checks if the join is now complete and emits `JoinCompleted` + downstream activations. This is a cascade pattern similar to how `prepare_next_runnables` works today.

### Concern 2: The `mapped` State (FanOut/FanIn Coordination)

The `workflow.mapped` field tracks fan-out batch state — which fan-out facts have been processed by which steps, and whether a fan-in batch is ready. This state is currently mutated directly by `maybe_prepare_map_reduce` and read by FanIn's invoke/execute.

**In the event model, `mapped` mutations must also be events.** This requires either:
- New event types like `%FanOutBatchTracked{source_fact_hash, fan_out_hash, fan_out_fact_hash, step_hash}` and `%FanInCompleted{...}`
- Or: treating `mapped` as a derived projection that's rebuilt from FactProduced + ActivationConsumed events during replay

The latter is cleaner but requires FanIn's logic to be expressible purely from event history. Today it depends on the `mapped` data structure which is a mutable accumulator — this is fundamentally at odds with event sourcing where state is derived.

**This is a significant design challenge.** The `mapped` field is essentially a coordination protocol for scatter-gather that was designed around direct mutation. Expressing it as events requires rethinking the coordination model.

### Concern 3: Hooks and Side Effects

Today's hooks (`before_hooks`, `after_hooks`) can mutate the workflow arbitrarily — they receive `(step, workflow, fact)` and return a new workflow. In the event model, hooks would need to return events instead of directly-mutated workflows.

This is a breaking change to the hook API. Options:
- **Hook events:** Hooks return `{workflow_events, hook_apply_fns}` where workflow_events are domain events and hook_apply_fns are for non-event side effects (logging, metrics, etc.)
- **Hooks as middleware:** Run hooks in the apply phase with full graph access, but don't journal their mutations. Accept that hook effects are not replayable.
- **Defer:** Keep hooks as direct mutations initially. They run during the apply phase and modify the graph directly. Their effects are captured in the next snapshot but not as individual events.

**Recommendation:** Defer. Hooks are an escape hatch for user-defined side effects. Making them event-sourced adds complexity without proportional benefit. They run during apply and their effects are captured in snapshots.

### Concern 4: Performance of Event Application

Today, `Workflow.log_fact` + `draw_connection` + `mark_runnable_as_ran` makes 3-4 graph operations per runnable execution. In the event model, each operation is a separate event that goes through `apply_event/2`, adding:
- Event struct allocation
- Pattern matching dispatch in `apply_event/2`
- Vertex lookup by hash (for edge creation events that reference vertex hashes rather than structs)

For tight loops (small, fast steps), this overhead could be measurable. However:
- The event structs are small (hashes + atoms)
- Pattern matching is O(1) in Elixir
- Vertex lookup is already O(1) via `graph.vertices[hash]`

**Benchmark needed:** Before committing to this architecture, benchmark the per-event overhead vs direct mutation on a tight pipeline (1000 steps, simple arithmetic). If overhead is >10%, consider batch-applying events or offering a "direct mode" for workflows that don't need durability.

### Concern 5: Event Ordering and Concurrency

When multiple runnables execute concurrently (via `Task.async_stream` or the Executor), they each produce independent event lists. The Worker folds them sequentially in `handle_info` arrival order. This is correct because:
- Events from a single runnable are internally ordered
- Events from different runnables are independent (no shared state)
- The Worker is the serialization point (single GenServer)

**However:** If two concurrent runnables produce facts that activate the _same_ downstream step, the arrival order determines which `RunnableActivated` event comes first. This is not a correctness issue (both activations will eventually be processed), but it means the event stream is not deterministically replayable if execution order varies. This is the same non-determinism that exists today — it's inherent to concurrent execution.

For deterministic replay, the event stream must be the ground truth. Replay applies events in stream order regardless of whether a concurrent re-execution would produce them in a different order. This is the standard event sourcing guarantee: the stream _is_ what happened.

### Concern 6: Breaking Changes Surface Area

| Area | Breaking? | Impact |
|------|-----------|--------|
| `Invokable.execute/2` return type | **YES** | All implementations must return events. Custom user implementations break. |
| `%Runnable{}` struct | **YES** | New `events` field, `apply_fn` deprecated |
| `Workflow.apply_runnable/2` | Behavioral | Still takes a Runnable, but folding mechanism changes |
| `Workflow.log/1` | No | Can still produce the derived snapshot for backward compat |
| `Workflow.from_log/1` | No | Unchanged — still replays ComponentAdded + ReactionOccurred |
| Store behaviour | **YES** | `save/load` replaced by `append/stream` as core contract |
| Worker internals | Yes (internal) | Major refactor, but internal to Runner |
| Hook API | Deferred | Can keep hooks as direct mutations initially |
| Public `draw_connection`, `log_fact`, `mark_runnable_as_ran` | Soft deprecation | Still work, but emit events internally. Eventually private. |
| `prepare_for_dispatch/1` | No | Unchanged |
| `react/2`, `react_until_satisfied/3` | No | Work via events internally, same API |
| Custom `Invokable` implementations | **YES** | Must return events instead of apply_fn |

The highest-impact breaking change is `Invokable.execute/2`. This affects:
- All 11 built-in implementations (Root, Step, Condition, Conjunction, MemoryAssertion, StateCondition, StateReaction, Accumulator, Join, FanOut, FanIn)
- Any user-defined custom Invokable implementations

### Concern 7: Migration Path

A big-bang migration is risky. Incremental approach:

**Phase 1: Dual-mode Runnable**
- Add `events` field to `%Runnable{}`
- `apply_runnable/2` checks `events` first, falls back to `apply_fn`
- Built-in Invokable implementations migrate one-by-one to produce events
- Legacy `apply_fn` path continues to work

**Phase 2: Event-aware Workflow**
- Add `apply_event/2` to `Workflow`
- Add journal buffer (`uncommitted_events`)
- Public mutation functions (`log_fact`, `draw_connection`, `mark_runnable_as_ran`) internally emit events
- `from_events/1` added alongside `from_log/1`

**Phase 3: Store migration**
- Add `append/stream` to Store behaviour
- Existing `save/load` implementations wrapped internally
- Worker gains event-sourced checkpoint path

**Phase 4: Deprecation**
- `apply_fn` deprecated on Runnable
- `save/load` deprecated on Store (or made optional, derived from append/stream)
- Public mutation functions deprecated in favor of `emit/2`

---

## How This Interacts with Runner Scheduling

### Executor Behaviour

The event model dramatically simplifies the Executor story:

- **Local TaskExecutor:** Receives `work_fn` closure, returns `%Runnable{events: [...]}`. No change needed — events travel in-process via message passing.
- **Remote/Durable Executor (Oban, distributed):** Receives `DispatchIntent` (serializable). Remote side executes, returns `%Runnable{events: [...]}` (serializable). No `apply_fn` reconstruction needed. The events _are_ the result.
- **Promise model:** A Promise executes multiple runnables in sequence. Each produces events. The Promise returns the concatenated event list. The Worker folds all events on Promise completion. Clean composition.

### Scheduler Strategy

Scheduler strategies analyze the graph to decide dispatch granularity. In the event model, they can also inspect the event stream for runtime profiling:
- "Step X produced events with large `FactProduced.value`" → future dispatches of X use a different Executor
- "Step Y's events show it always produces exactly one FactProduced" → safe to batch with downstream via Promise

### Checkpointing

Checkpointing is trivially correct: `append` the uncommitted events. The cursor advances. Recovery is `stream` + `fold`. Snapshots are optional acceleration. No derived log scanning, no O(total) serialization.

---

## Comparison: Instrumented Mutations vs Event-Sourced Aggregate

| Dimension | Instrumented Mutations (Plan A) | Event-Sourced Aggregate (This Exploration) |
|-----------|--------------------------------|-------------------------------------------|
| **Scope of change** | Medium — add journal emission to 3 mutation functions | Large — rewrite all Invokable execute impls |
| **Store contract** | Additive (append alongside save/load) | Replacement (append/stream as core) |
| **apply_fn problem** | Unsolved — still a closure | Solved — events replace closures |
| **Remote executor** | Still needs apply_fn reconstruction | Events are natively serializable |
| **Replay correctness** | Depends on journal capturing all mutations | Guaranteed by construction (events are the only mutation path) |
| **Performance overhead** | Low (add buffer write per mutation) | Unknown — needs benchmarking (event struct allocation + dispatch) |
| **Hook compat** | Full (hooks still mutate directly) | Partial (hooks need adaptation or exemption) |
| **Migration risk** | Low — purely additive | Medium-High — breaking Invokable protocol change |
| **Long-term architecture** | Dual-path (events + direct mutations) | Single path (events only) |
| **Testability** | Similar to today | Better — assert on events, not closures |
| **Auditability** | Good (journal + derived log) | Excellent (event stream is complete history) |
| **Distribution readiness** | Partial (still needs apply_fn for remoting) | Full (events are the lingua franca) |

---

## Verdict: Is This Worth Pursuing?

### Arguments For

1. **It solves the apply_fn serialization problem definitively.** This is the single biggest blocker for remote executors, durable replay, and the distribution story. The instrumented-mutations approach defers this problem; the event-sourced approach solves it.

2. **It makes the Store contract cleaner.** Append/stream is more natural for event stores, Kafka, and Postgres than save/load. The instrumented approach adds append alongside save/load, creating a dual-path store that adapters must implement.

3. **It's the "correct" long-term architecture.** If Runic is heading toward durable execution, distributed workflows, and production-grade reliability, event sourcing is the industry-standard foundation. Building it now avoids a larger migration later.

4. **It improves testability.** Asserting "this execution produced these events" is more precise and debuggable than "this execution produced this closure that when applied produces this graph."

### Arguments Against

1. **The refactor scope is large.** 11 Invokable implementations, the Runnable struct, the Store behaviour, and the Worker. This is weeks of work with high regression risk.

2. **FanIn/Join/Accumulator coordination logic is hard to express as events.** The `mapped` state and Join's concurrent recheck pattern are designed around direct mutation. Expressing them as event-derived state requires rethinking these coordination protocols.

3. **Performance is unknown.** The per-event overhead may matter for tight computational pipelines. Runic's value proposition includes being a low-overhead composition tool — if event sourcing adds measurable overhead to `react_until_satisfied`, that's a real cost.

4. **User-facing breaking change.** Custom Invokable implementations break. The protocol is documented and part of the extensibility story. A breaking change here needs a clear migration guide and deprecation period.

### Recommendation

**Pursue a hybrid approach:**

1. **Phase 1-2 from the instrumented-mutations plan** (FactRef, incremental checkpointing) ships first for immediate production value with low risk.

2. **In parallel, prototype the event-sourced model** for `Step` and `Condition` only (the simplest, most common cases). Validate:
   - Performance overhead per event
   - Whether the Runnable `events` field works cleanly with the existing Worker
   - Whether `from_events/1` replay produces identical graph state to `from_log/1`

3. **If the prototype validates, migrate toward event sourcing incrementally** using the dual-mode Runnable (`events` || `apply_fn` fallback). Migrate Invokable implementations one at a time, starting with Step/Condition/Root and ending with Join/FanIn/Accumulator.

4. **Defer hook migration.** Hooks remain direct mutations that run during the apply phase. They're not part of the replayable event stream.

5. **The Store contract can evolve in lockstep.** `append/stream` becomes the primary interface. `save/load` becomes a derived convenience that internally snapshots the current state.

This gives the long-term architectural benefits of event sourcing while managing the migration risk through incremental adoption and backward compatibility.

---

## Open Questions

### OQ-1: Event Granularity — Fine vs Coarse

Should a Step execution produce 4 fine-grained events (`FactProduced`, `ActivationConsumed`, `RunnableActivated` × N)? Or one coarse event (`StepCompleted{input_fact, result_fact, next_activations: [...]}`)?

Fine-grained is more composable and enables richer projections. Coarse is fewer events (better throughput) and simpler replay. The event sourcing literature generally favors fine-grained domain events with optional projections for performance-sensitive reads.

**Recommendation:** Fine-grained. The number of events per step (3-5) is small. If throughput becomes an issue, batch-persist events and apply them atomically.

### OQ-2: Should apply_event Cascade or Not?

If `apply_event(%FactProduced{})` triggers `RunnableActivated` emissions, events cascade during apply. This means:
- During normal execution: `emit(FactProduced)` → internally also emits `RunnableActivated` events → all buffered
- During replay: `apply_event(FactProduced)` must _not_ cascade (activations are already in the stream)

This dual behavior is error-prone. Alternatives:
- **No cascade:** Execute phase explicitly produces all events (including activations). Requires topology info in CausalContext (Option A above).
- **Cascade with replay flag:** `apply_event(wf, event, mode: :live | :replay)`. Live mode cascades; replay mode doesn't.
- **Separate "derived" events:** Mark activation events as derived. During replay, skip re-deriving them.

**Recommendation:** No cascade. Capture topology during prepare, emit all events in execute. This keeps `apply_event` as a pure fold and avoids the live/replay divergence.

### OQ-3: Event Identity and Deduplication

Should events have unique IDs? If the same runnable is re-executed (retry), it produces new events. Should the retry's events replace the original's, or append alongside?

**Recommendation:** Events are append-only. Retries produce new events with new sequence numbers. The latest `RunnableCompleted` for a given `runnable_id` is the accepted result. Failed attempts are `RunnableFailed` events that remain in the stream for audit.

### OQ-4: Can This Be Feature-Flagged?

Can the event-sourced path coexist with the direct-mutation path behind a configuration flag, so users can opt in gradually?

Yes, if:
- `%Runnable{}` supports both `events` and `apply_fn`
- `apply_runnable/2` dispatches based on which field is populated
- Invokable implementations are migrated one at a time

The flag would be at the workflow level: `Workflow.new(event_sourced: true)` configures all Invokable impls to produce events instead of closures. This requires either protocol dispatch awareness of the flag, or separate Invokable implementations per mode (not ideal).

**More practical:** Migrate implementations one at a time. The dual-mode Runnable handles both paths. No flag needed — the Runnable itself signals which path to take.

### OQ-5: Impact on `react/2` and `react_until_satisfied/3`

These are the most common user-facing APIs. In the event-sourced model:

```elixir
def react(%__MODULE__{} = workflow, opts) do
  {workflow, runnables} = prepare_for_dispatch(workflow)
  executed = execute_runnables(runnables, opts)

  Enum.reduce(executed, workflow, fn runnable, wf ->
    # Fold events instead of calling apply_fn
    apply_runnable(wf, runnable)
  end)
end
```

From the user's perspective, the API is unchanged. `react/2` still takes a workflow and returns a workflow. The internal mechanism changes from closure application to event folding. This should be transparent.

**However:** If `react/2` is used without a Runner (no Store, no Worker), the events are produced and folded but never persisted. This is fine — the in-memory workflow state is identical. Events are only persisted when a Runner/Worker manages the lifecycle.

This means the event-sourced model doesn't impose persistence on users who just want `react_until_satisfied` in a script. The events exist transiently in the workflow's journal buffer and are GC'd when the workflow is GC'd. Only the Runner flushes them to the Store.
