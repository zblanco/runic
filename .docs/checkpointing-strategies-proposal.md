# Runic Checkpointing & Rehydration Strategies — Proposal

**Status:** Draft  
**Depends on:** [Runner Implementation (Phase 4)](runner-implementation-plan.md)  
**Related:** Temporal, Azure Durable Functions, Restate, Infinitic

---

## Problem Statement

The current `Workflow.from_log/1` approach performs **full rehydration** — it replays every event in the log to reconstruct the complete workflow state, including all intermediate fact values. This works well for small-to-medium workflows but becomes problematic at scale:

1. **Memory pressure:** Long-running workflows accumulate many facts. A 1000-step pipeline with large intermediate values (e.g., LLM responses, API payloads) loads all of them into memory on resume, even though only the latest few are needed for continued execution.

2. **Rehydration latency:** Replaying hundreds of events serially adds startup latency to resumed workers. In distributed scenarios where workers migrate between nodes, this delay impacts availability.

3. **Checkpoint size:** `Workflow.log/1` serializes the entire graph + all reactions + all runnable events. As workflows grow, checkpoint writes become expensive, creating I/O pressure and GC spikes.

4. **Distribution limitations:** Full rehydration requires the entire log to be transferred to the resuming node. In a cluster, this means large payloads over the network.

---

## Prior Art

### Temporal

Temporal uses **event sourcing** with a distinction between **history events** (durable, ordered, replayed) and **state** (derived from replaying history). Key insights:

- **Sticky execution:** Workers that already have history in memory get preferential routing — avoids rehydration entirely in the common case.
- **Continue-as-new:** When history grows too large, the workflow can "continue as new" — starting fresh with only the latest state, discarding old history. This bounds rehydration cost.
- **Lazy history loading:** History is paginated. During replay, events are fetched in pages from the server rather than loaded all at once.
- **No intermediate values in history:** Activity results are stored as individual events with payloads. The workflow code "replays" by matching events to activity calls, not by storing a snapshot of all state.

### Azure Durable Functions

Azure uses an **event-sourcing replay** model with **checkpointing** built into the orchestrator:

- **Execution history table:** Events stored in Azure Storage Tables with partition keys for efficient range queries.
- **Replay on resume:** The orchestrator function re-executes from the beginning, but when it encounters a completed activity, it returns the stored result instead of re-executing.
- **Extended sessions:** Keep the orchestrator in memory between events to avoid replay altogether (equivalent to Temporal's sticky execution).
- **Entity state snapshots:** For entity-style durable objects, periodic snapshots are taken so replay only needs to process events since the last snapshot.

### Restate

Restate takes a **journal-based** approach that's closer to what Runic could do:

- **Deterministic replay:** Service handlers replay from a persisted journal. Each "journaled action" (analogous to our runnables) stores its result.
- **Partial replay:** Only replays up to the point of the last completed action. New actions execute normally.
- **Suspension points:** When a handler needs to wait for an external event, it suspends and the journal records the suspension. On resume, replay runs up to the suspension point.
- **K/V state:** Handlers have access to a key-value state store that's snapshotted, avoiding the need to replay state mutations.

### Infinitic (JVM)

Infinitic is notable for its **tag-based addressing** and **workflow state machine** approach:

- **Workflow state is a function of task completions.** The workflow engine doesn't store intermediate state — it stores which tasks completed and with what results, then replays the workflow function.
- **Task deduplication via IDs.** Each task dispatch has a deterministic ID. On replay, if a task ID's result exists, it's returned immediately.

---

## Proposed Strategies for Runic

### Strategy 1: Lazy Fact Rehydration (Recommended First Step)

**Core idea:** Store fact hashes and ancestry in the graph, but don't store fact _values_ in memory. Actual values are loaded from the Store on demand.

```
Current model:
  Workflow.from_log(events) → full graph with all Fact structs (values in memory)

Proposed model:
  Workflow.from_log(events, strategy: :lazy) → graph with FactRef structs (hash + ancestry only)
  
  When a runnable needs an input fact's value:
    FactRef.resolve(ref, store) → full Fact with value
```

**Implementation sketch:**

```elixir
defmodule Runic.Workflow.FactRef do
  @moduledoc """
  A lightweight reference to a fact, holding only its hash and ancestry.
  The actual value is lazily loaded from the store when needed.
  """
  defstruct [:hash, :ancestry, :store_ref]
  
  def resolve(%__MODULE__{hash: hash, store_ref: {store_mod, store_state}}) do
    store_mod.load_fact(hash, store_state)
  end
end
```

**Store extension:**

```elixir
# New optional callbacks on Runic.Runner.Store
@callback save_fact(fact_hash :: term(), fact :: Fact.t(), state()) :: :ok | {:error, term()}
@callback load_fact(fact_hash :: term(), state()) :: {:ok, Fact.t()} | {:error, :not_found}

@optional_callbacks [save_fact: 3, load_fact: 2]
```

**Tradeoffs:**
- ✅ Memory consumption bounded by active working set (only facts needed for next runnables)
- ✅ Fast rehydration — only graph structure + fact refs, not values
- ✅ Compatible with existing graph traversal (FactRef implements same protocols as Fact for graph edges)
- ⚠️ Adds latency on first access to a fact value (store round-trip)
- ⚠️ Requires Store adapters to implement fact-level storage
- ⚠️ Complicates the Invokable protocol — prepare/execute need to handle FactRef → Fact resolution

**When to use:** Workflows with large intermediate values (LLM outputs, file contents, API responses) where most intermediates are consumed once and never read again.

### Strategy 2: Incremental Checkpointing

**Core idea:** Instead of serializing `Workflow.log/1` (full snapshot) on every checkpoint, only serialize _new events since the last checkpoint_.

```
Checkpoint 1: [ComponentAdded(:a), ComponentAdded(:b), ReactionOccurred(...)]
Checkpoint 2: [RunnableDispatched(...), RunnableCompleted(...)]  ← delta only
Checkpoint 3: [RunnableDispatched(...), RunnableCompleted(...)]  ← delta only

Full state = Checkpoint 1 ++ Checkpoint 2 ++ Checkpoint 3
```

**Implementation sketch:**

```elixir
# Worker state gains a checkpoint cursor
defstruct [
  # ...existing fields...
  :last_checkpoint_index  # index into runnable_events at last checkpoint
]

defp do_incremental_checkpoint(state) do
  all_events = Workflow.log(state.workflow)
  new_events = Enum.drop(all_events, state.last_checkpoint_index)
  
  store_mod.append(state.id, new_events, store_state)
  
  %{state | last_checkpoint_index: length(all_events)}
end
```

**Store extension:**

```elixir
@callback append(workflow_id(), events :: [struct()], state()) :: :ok | {:error, term()}
@callback load_since(workflow_id(), cursor :: non_neg_integer(), state()) :: 
  {:ok, [struct()]} | {:error, term()}

@optional_callbacks [append: 3, load_since: 3]
```

**Tradeoffs:**
- ✅ Checkpoint writes are O(new events) not O(all events) — critical for long-running workflows
- ✅ Natural append-only log structure — excellent fit for append-optimized stores (Kafka, event stores)
- ✅ Enables efficient distributed replication (ship deltas, not full snapshots)
- ⚠️ Full rehydration still requires reading all segments — can be mitigated with periodic compaction
- ⚠️ Recovery is more complex: must load base + all deltas and replay in order
- ⚠️ Store adapters need an append-capable storage model

**When to use:** High-throughput workflows where checkpoint frequency is high and the log grows quickly.

### Strategy 3: Snapshot + WAL (Write-Ahead Log)

**Core idea:** Periodically take a full snapshot of the workflow state. Between snapshots, write only incremental events to a WAL. On recovery, load latest snapshot + replay WAL.

```
Snapshot 1 (at cycle 100): [full workflow state as binary]
WAL: [event 101, event 102, ..., event 150]

Recovery: deserialize(Snapshot 1) |> replay([event 101..150])
```

**Implementation sketch:**

```elixir
defstruct [
  # ...existing fields...
  :snapshot_interval,       # take snapshot every N cycles
  :cycles_since_snapshot    
]

defp maybe_snapshot(%{cycles_since_snapshot: n, snapshot_interval: interval} = state) 
     when n >= interval do
  snapshot = :erlang.term_to_binary(state.workflow)
  store_mod.save_snapshot(state.id, snapshot, store_state)
  store_mod.truncate_wal(state.id, store_state)
  %{state | cycles_since_snapshot: 0}
end
```

**Tradeoffs:**
- ✅ Fastest recovery — deserialize snapshot + replay small WAL
- ✅ Bounds WAL growth — periodic compaction via snapshotting
- ✅ Well-understood pattern (databases, Kafka, etc.)
- ⚠️ Snapshots can be large (full binary serialization of workflow)
- ⚠️ Snapshot creation is expensive — must be carefully scheduled
- ⚠️ Binary serialization of workflow structs may not be portable across code versions
- ⚠️ More complex Store interface (snapshot + WAL)

**When to use:** Workflows that run for extended periods (hours/days) with many cycles, where fast recovery is critical.

### Strategy 4: Sticky Execution (Avoid Rehydration)

**Core idea:** Don't rehydrate at all — keep the workflow in memory and route new inputs to the node that already has it loaded. Only rehydrate when the node crashes or is drained.

```
Node A has Workflow :wf1 in memory
  → New input for :wf1 → route to Node A (no rehydration needed)
  
Node A crashes
  → Node B picks up :wf1 → rehydrate from store (rare event)
```

**Implementation sketch:**

This is more of an operational strategy than a code change. The Runner already supports this pattern naturally:

```elixir
# The Worker is already a long-lived GenServer with in-memory state.
# Multiple run/4 calls to the same worker reuse the existing workflow state.
# Rehydration only happens on resume/3 after a crash.
```

The key enhancement would be **cluster-aware routing** in a distributed Runner:

```elixir
defmodule Runic.Runner.Distributed do
  def run(cluster, workflow_id, input, opts) do
    case locate_worker(cluster, workflow_id) do
      {:local, pid} -> GenServer.cast(pid, {:run, input, opts})
      {:remote, node} -> :rpc.cast(node, Runic.Runner, :run, [...])
      :not_found -> start_and_run(cluster, workflow_id, input, opts)
    end
  end
end
```

**Tradeoffs:**
- ✅ Zero rehydration cost in the common case
- ✅ Best latency — no store reads on the hot path
- ✅ Natural fit for Runic's existing Worker model
- ⚠️ Requires cluster-aware routing (beyond single-node Runner)
- ⚠️ Node affinity can cause hotspots — need rebalancing
- ⚠️ Still needs a fallback rehydration strategy for crashes/drains

**When to use:** Production deployments where workflows receive frequent inputs and node crashes are rare.

### Strategy 5: Causal-Lineage-Aware Hybrid Rehydration

**Core idea:** Combine lazy fact storage with _selective eager loading_ based on causal lineage. On rehydration, only facts in the **active causal frontier** — the most recent generation of facts sharing lineage with the last input — are loaded eagerly into memory. All prior generations remain as `FactRef`s, resolved from the Store on demand. State machine references (`:state_of`, `:latest_value`, etc.) are also eagerly resolved since they're required for transition rule evaluation.

This directly addresses Strategy 1's main tradeoff (latency on first access) by ensuring the facts most likely to be consumed next are already in memory, while still keeping historical intermediates out of the working set.

```
Workflow state after processing inputs A, B, C:

  Input A → fact_a1 → fact_a2 → fact_a3 (terminal)     ← all FactRef (cold)
  Input B → fact_b1 → fact_b2 (terminal)                ← all FactRef (cold)
  Input C → fact_c1 → fact_c2 (active frontier)         ← eagerly loaded (hot)
                  ↘ fact_c3 (active frontier)            ← eagerly loaded (hot)
  
  StateMachine(:cart) → current_state = %{total: 42}    ← eagerly loaded (hot)
```

**Lineage classification during rehydration:**

The graph already encodes everything needed. Each fact's `ancestry` field is `{producer_hash, parent_fact_hash}`, forming a causal chain back to the root input fact. The rehydration algorithm:

1. Walk `:produced` / `:state_produced` edges to identify **leaf facts** — facts with no downstream `:runnable` or `:ran` edges whose consumers have completed.
2. Trace each leaf's `ancestry` chain to its root input fact.
3. Identify the **most recent input generation** — the input(s) from the latest `run/4` call. Facts whose lineage traces to this generation are the **active frontier**.
4. Additionally, resolve any facts referenced by `:meta_ref` edges with `kind: :state_of`, `:latest_value`, or `:latest_fact` — these are needed for state machine transition evaluation and condition guards regardless of lineage.
5. Everything else stays as a `FactRef`.

**Implementation sketch:**

```elixir
defmodule Runic.Workflow.Rehydration do
  @moduledoc """
  Strategies for selectively loading fact values during workflow restoration.
  """

  alias Runic.Workflow.{Fact, FactRef}

  @type strategy :: :full | :lazy | :hybrid

  @doc """
  Classifies facts into hot (eagerly loaded) and cold (lazy ref) sets.
  
  Hot facts:
    - Facts on the active causal frontier (latest input lineage)
    - Facts referenced by :meta_ref edges (:state_of, :latest_value, :latest_fact)
    - Facts with pending :runnable edges (about to be consumed)
  
  Cold facts:
    - All other facts (prior input generations, consumed intermediates)
  """
  @spec classify(Runic.Workflow.t()) :: %{hot: MapSet.t(), cold: MapSet.t()}
  def classify(workflow) do
    pending_inputs = pending_runnable_inputs(workflow)
    meta_ref_targets = meta_ref_fact_targets(workflow)
    frontier = active_frontier_facts(workflow)
    
    hot = MapSet.union(frontier, MapSet.union(pending_inputs, meta_ref_targets))
    
    all_facts = all_fact_hashes(workflow)
    cold = MapSet.difference(all_facts, hot)
    
    %{hot: hot, cold: cold}
  end

  defp active_frontier_facts(workflow) do
    # Find the most recent input facts (no ancestry = root input)
    # Then find all facts whose lineage chain traces to them
    # ...graph traversal using ancestry tuples...
  end

  defp meta_ref_fact_targets(workflow) do
    # Walk :meta_ref edges, resolve the getter, identify which facts
    # the getter would access (e.g., latest :state_produced fact for :state_of)
    # ...
  end

  defp pending_runnable_inputs(workflow) do
    # Facts with outgoing :runnable edges — about to be consumed
    # ...
  end
end
```

**Rehydration flow with `from_log/2`:**

```elixir
# Current (full):
Workflow.from_log(events)

# Lazy (Strategy 1):
Workflow.from_log(events, rehydration: :lazy, store: {store_mod, store_state})

# Hybrid (Strategy 5):
Workflow.from_log(events, rehydration: :hybrid, store: {store_mod, store_state})
#   1. Rebuild graph structure from events (same as today)
#   2. Classify facts into hot/cold via Rehydration.classify/1
#   3. Hot facts: resolve values eagerly from store
#   4. Cold facts: leave as FactRef in graph
```

**State machine integration detail:**

State machines are the most important case for eager resolution beyond the frontier. A `StateMachine` reactor's `prepare` phase calls a `:state_of` getter that traverses `:state_produced` edges to find the accumulator's current state fact. If that fact is a `FactRef`, the getter must resolve it synchronously — adding latency to every state machine evaluation.

The hybrid approach avoids this by recognizing `:meta_ref` edges during classification:

```
StateMachine(:cart)
  ├── Accumulator(:cart_state) ─[:state_produced]→ Fact{value: %{total: 42}} ← HOT
  ├── Condition(:can_checkout)  ─[:meta_ref, kind: :state_of]→ Accumulator
  └── Reactor(:add_item)       ─[:meta_ref, kind: :state_of]→ Accumulator

On rehydration: the :meta_ref edges from Condition/Reactor to Accumulator
signal that the Accumulator's latest :state_produced fact must be hot.
```

This extends naturally to other meta-ref kinds:
- `:latest_value` / `:latest_fact` — the most recent production of a component, needed for guards
- `:step_ran?` — boolean, no fact value needed (derived from edge labels)
- `:all_values` / `:all_facts` — potentially large; could be loaded lazily with a warning

**Tradeoffs:**
- ✅ Best of both worlds: low memory (cold historical facts) + low latency (hot frontier + state refs)
- ✅ No store round-trips on the critical path — frontier facts are pre-loaded
- ✅ State machine transitions never block on store reads
- ✅ Naturally adaptive — the hot set grows/shrinks with workflow shape, not history length
- ✅ Causal lineage is already encoded in `Fact.ancestry` — no new data structures needed
- ⚠️ Classification algorithm adds rehydration-time cost (graph traversal)
- ⚠️ Edge case: workflows where old-generation facts are consumed by new-generation steps (cross-lineage joins) — the Join node's `prepare` phase may need to resolve cold FactRefs
- ⚠️ More complex than pure lazy — requires understanding of which meta-ref kinds need eager resolution

**When to use:** Workflows with mixed characteristics — state machines + pipelines, multiple sequential inputs, large intermediate values — where neither pure lazy nor pure eager is ideal.

**Application to other strategies:**

The causal lineage classification is orthogonal to _how_ facts are stored and can enhance other strategies:

- **Incremental checkpointing (Strategy 2) + lineage awareness:** When writing a delta checkpoint, only serialize fact _values_ for the active frontier. Prior-generation fact values are already in earlier checkpoints. This reduces delta size significantly for workflows that accumulate many facts across inputs.

- **Snapshot + WAL (Strategy 3) + lineage awareness:** Snapshots can use the hybrid approach — serialize the full graph structure but only embed values for hot facts. Cold fact values are stored separately (content-addressed by hash). This makes snapshots smaller and faster to create while still providing fast recovery of the working set.

- **Sticky execution (Strategy 4) + lineage eviction:** Even for in-memory workers, the classification can drive memory pressure relief. When a Worker's memory exceeds a threshold, evict cold facts to the Store, replacing them with FactRefs. The Worker continues operating with the hot set in memory. This turns sticky execution into a bounded-memory strategy without losing correctness.

---

## Comparison Matrix

| Strategy | Memory | Rehydration Speed | Checkpoint Cost | Distribution | Complexity |
|----------|--------|-------------------|-----------------|--------------|------------|
| Full (current) | High | Slow (O(events)) | High (full log) | Poor (full transfer) | Low |
| Lazy Facts | Low | Fast (refs only) | Medium | Medium | Medium |
| Incremental | Medium | Slow (replay deltas) | Low (delta only) | Good (ship deltas) | Medium |
| Snapshot + WAL | Medium | Fast (snapshot + small WAL) | Medium (periodic) | Medium | High |
| Sticky | Lowest (no rehydration) | N/A (in-memory) | Same as current | Needs routing | Low-Medium |
| Hybrid (lineage) | Low | Fast (frontier + refs) | Medium | Good (ship frontier) | Medium-High |

---

## Recommended Roadmap

### Near-term (Phase 5-6)

1. **Incremental checkpointing** — Lowest risk, highest impact for long-running workflows. Add `append/3` to Store behaviour, modify `do_checkpoint` to track cursor. Compatible with existing ETS adapter (just append to the same key's list).

2. **`continue_as_new` API** — Temporal-inspired. When a workflow's event history exceeds a threshold, snapshot the current state and start a new workflow ID with only the latest facts. This bounds unbounded growth.

### Medium-term

3. **FactRef + lazy fact rehydration** — Requires Store extension for fact-level storage (`save_fact/3`, `load_fact/2`) and a `FactRef` struct that implements the same graph protocols as `Fact`. The `Invokable.prepare` step resolves FactRefs before execution. This is a prerequisite for Strategy 5.

4. **Hybrid causal-lineage rehydration** — Build on FactRef infrastructure. Add `Rehydration.classify/1` to partition facts into hot/cold sets using ancestry chains and `:meta_ref` edge analysis. Integrate into `from_log/2` as `rehydration: :hybrid`. This is the recommended default for production workflows with state machines or multi-input patterns.

5. **Snapshot + WAL** — For Mnesia or PostgreSQL adapters where binary snapshots are natural. Can compose with the hybrid classifier to produce smaller snapshots (only hot fact values embedded, cold values content-addressed separately).

### Long-term

6. **Sticky execution / distributed routing** — Requires cluster-aware Runner infrastructure. Build on `Horde` or custom registry for cross-node Worker lookup. Most impactful in production deployments. Compose with lineage-based eviction for bounded-memory workers.

7. **Lineage-driven memory pressure relief** — For long-lived sticky workers, use the hybrid classifier at runtime (not just rehydration) to evict cold facts to the Store when process memory exceeds a configurable threshold. This enables unbounded workflow lifetimes with bounded memory.

---

## Open Questions

1. **Fact deduplication:** Multiple runnables may share the same input fact. With lazy loading, should we cache resolved facts in a process-local LRU to avoid repeated store reads?

2. **Compaction semantics:** When incrementally checkpointing, when should we compact (merge all deltas into a single log)? On explicit `checkpoint/2`? After N deltas? On `stop/3`?

3. **Versioning:** If the workflow code changes between checkpoint and resume (new steps added, step functions changed), how do we handle schema migration? Temporal solves this with "versioning" markers in the workflow code.

4. **Fact TTL:** Should facts have a time-to-live after which they're eligible for eviction from memory (and only available via store lookup)? This would provide automatic memory management without explicit lazy loading.

5. **Store-level fact addressing:** The current Store behaviour operates at workflow-log granularity. Fact-level storage needs either:
   - A separate fact store (content-addressed by hash)
   - Embedded fact storage within the workflow log (and lazy extraction)
   - Which approach better serves the distribution story?

6. **Cross-lineage Joins:** A Join node waits for facts from multiple branches, potentially spanning different input generations. When the hybrid classifier marks one branch's facts as cold and the other's as hot, the Join's `prepare` phase will need to resolve cold FactRefs. Should Join nodes force all their input branches' latest facts to be classified as hot? This would widen the hot set but guarantee zero-latency join evaluation.

7. **Lineage depth threshold:** For deeply nested pipelines (A → B → C → D → ... → Z), should the entire latest-input lineage chain be hot, or only the N most recent generations? A configurable depth limit could bound the hot set for very deep workflows while still covering the common case.

8. **Runtime eviction vs. rehydration-time classification:** Strategy 5's classifier could run at two points — during `from_log` (rehydration) and during normal execution (memory pressure). Should the Worker monitor its own memory and trigger eviction proactively, or should this be driven by an external signal (e.g., system memory pressure callback)?
