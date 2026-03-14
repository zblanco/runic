# Checkpointing Implementation Plan — Hybrid Rehydration via Event-Sourced Core

**Status:** Updated Draft (post event-sourcing refactor)  
**Depends on:** [Checkpointing Strategies Proposal](checkpointing-strategies-proposal.md), [Runner Scheduling Considerations](full-breadth-runner-scheduling-considerations.md)  
**Influences:** Restate Journal System, Event Sourcing  
**Goal:** Low-latency recovery with bounded memory for long-running workflows  

> The event-sourced core is now implemented. The three-phase execution model
> (`prepare → execute → apply`) produces events as the primary mutation interface,
> and `apply_event/2` folds them into the workflow graph as a pure function.
> This plan focuses on **remaining work**: fact-level storage integration,
> hybrid rehydration, and runtime memory management.

---

## Design Principles

1. **Event stream as source of truth** — Mutations are captured at execution time via `Invokable.execute/2`, which produces a list of event structs (`Workflow.Events`). `Workflow.apply_event/2` folds each event into the graph. `Workflow.from_events/2` rebuilds a workflow from a persisted event stream. This is no longer aspirational — it is the model.

2. **Content-addressed fact storage** — Fact values are stored separately by hash. The `save_fact/3` and `load_fact/2` callbacks exist on `Runic.Runner.Store` but no adapter implements them yet. When built, this decouples "what happened" from "what data was produced".

3. **Hot/cold classification at rehydration boundaries** — The active causal frontier (latest input lineage + pending runnables + meta-ref targets) is loaded eagerly. Everything else stays as lightweight `FactRef` structs, resolved on demand. Not yet implemented.

4. **Purely functional core preserved** — `Workflow` never calls Store directly. The three-phase model (`Invokable.prepare/3` → `Invokable.execute/2` → `Workflow.apply_runnable/2`) keeps side effects entirely in the Worker. The workflow accumulates uncommitted events as data; the Worker drains and persists them.

5. **Full backward compatibility** — `from_log/1` remains unchanged and works alongside `from_events/2`. Legacy `save/3` + `load/2` stores continue to function. Event-sourced stores using `append/3` + `stream/2` are opt-in.

---

## Implemented Foundation

The following is already built and tested. Referenced here for context — see source for details.

### Event-driven core (`lib/workflow/events/` + `lib/workflow/events.ex`)

11 event types covering all core graph mutations:

| Event | Purpose |
|-------|---------|
| `FactProduced` | Fact added to graph with hash, value, ancestry |
| `ActivationConsumed` | Input edge consumed (`:runnable` → `:ran`) |
| `RunnableActivated` | Activation edge drawn for next runnable |
| `ConditionSatisfied` | Condition match result recorded |
| `MapReduceTracked` | Map/Reduce tracking metadata |
| `StateInitiated` | State machine initial state |
| `JoinFactReceived` | Partial join input received |
| `JoinCompleted` | Join satisfied, output produced |
| `JoinEdgeRelabeled` | Join edge label updated |
| `FanOutFactEmitted` | FanOut child fact emitted |
| `FanInCompleted` | FanIn aggregation completed |

Custom event types are supported via the `EventApplicator` protocol (`lib/workflow/event_applicator.ex`).

### Three-phase execution model

- `Invokable.prepare/3` — Builds a `%Runnable{}` with resolved inputs
- `Invokable.execute/2` — Pure computation, produces `%Runnable{events: [...]}` 
- `Workflow.apply_runnable/2` — Folds events via `apply_event/2`, runs hook apply_fns, coordinates via `Coordinator.finalize/3`, activates downstream via `Activator.activate_downstream/3`, buffers `uncommitted_events` when `emit_events: true`

### Extension protocols

- **`Coordinator`** (`lib/workflow/coordinator.ex`) — Post-fold coordination for Join, FanIn. Returns `{workflow, derived_events}`.
- **`Activator`** (`lib/workflow/activator.ex`) — Custom downstream activation for FanOut, Condition matching.
- **`EventApplicator`** (`lib/workflow/event_applicator.ex`) — Protocol dispatch for user-defined event types in `apply_event/2`.

### Event buffering on `Workflow` struct

- `emit_events: boolean()` — Controls whether `apply_runnable/2` buffers events
- `uncommitted_events: list()` — Accumulated events (prepend order for O(1))
- `enable_event_emission/1` / `disable_event_emission/1` — Toggle functions

### `Workflow.from_events/2` (`lib/workflow.ex`)

Rebuilds workflow from an event stream. Splits events into structural (ComponentAdded, ReactionOccurred, Runnable lifecycle) and runtime events. Replays structural events via `from_log/1`, then folds runtime events via `apply_event/2`.

### `Runic.Runner.Store` behaviour (`lib/runic/runner/store.ex`)

- **Required:** `init_store/1`, `save/3`, `load/2` (legacy snapshot)
- **Optional stream:** `append/3` → `{:ok, cursor}`, `stream/2` → `{:ok, Enumerable.t()}`
- **Optional snapshots:** `save_snapshot/4`, `load_snapshot/2`
- **Optional facts:** `save_fact/3`, `load_fact/2`
- `supports_stream?/1` — Helper to detect event-sourced capability

### Worker event-sourced checkpointing (`lib/runic/runner/worker.ex`)

- `handle_task_result/4` drains `uncommitted_events` from workflow, reverses for chronological order
- `do_checkpoint/1` routes between event-sourced path (`append/3`) and legacy path (`save/3`)
- `maybe_persist_build_log/3` persists structural events on first start (skipped on resume)
- Worker struct carries `uncommitted_events` and `event_cursor` fields

### `FactRef` (`lib/workflow/fact_ref.ex`)

Lightweight struct with `hash` and `ancestry` fields. Defined but not yet integrated into graph traversal or replay.

---

## Remaining Phase 1: FactResolver + Fact Store Implementations

**Goal:** Content-addressed fact storage and a resolver that hydrates `FactRef` structs from a store. This is the vocabulary layer that all subsequent phases depend on.

### 1.1 Add `Runic.Workflow.Facts` helper module

New file: `lib/workflow/facts.ex`

Unified accessors for `Fact` and `FactRef` without pattern-matching on struct types everywhere:

```elixir
defmodule Runic.Workflow.Facts do
  alias Runic.Workflow.{Fact, FactRef}

  def hash(%Fact{hash: h}), do: h
  def hash(%FactRef{hash: h}), do: h

  def ancestry(%Fact{ancestry: a}), do: a
  def ancestry(%FactRef{ancestry: a}), do: a

  def value?(%Fact{value: v}) when not is_nil(v), do: true
  def value?(_), do: false
end
```

### 1.2 Add `Runic.Workflow.FactResolver`

New file: `lib/workflow/fact_resolver.ex`

Runtime-only resolver that hydrates `FactRef` structs via a Store adapter. Maintains a process-local cache to avoid repeated store round-trips.

```elixir
defmodule Runic.Workflow.FactResolver do
  alias Runic.Workflow.{Fact, FactRef}

  defstruct [:store, cache: %{}]

  @type t :: %__MODULE__{
          store: {module(), term()},
          cache: %{optional(term()) => term()}
        }

  def new(store), do: %__MODULE__{store: store, cache: %{}}

  def resolve(%Fact{value: v} = fact, _resolver) when not is_nil(v), do: {:ok, fact}

  def resolve(%FactRef{hash: h, ancestry: a}, %__MODULE__{} = resolver) do
    case Map.get(resolver.cache, h) do
      nil ->
        {mod, st} = resolver.store
        case mod.load_fact(h, st) do
          {:ok, value} -> {:ok, %Fact{hash: h, ancestry: a, value: value}}
          {:error, _} = err -> err
        end
      value ->
        {:ok, %Fact{hash: h, ancestry: a, value: value}}
    end
  end

  def resolve!(fact_or_ref, resolver) do
    {:ok, fact} = resolve(fact_or_ref, resolver)
    fact
  end

  def preload(%__MODULE__{} = resolver, fact_hashes) when is_list(fact_hashes) do
    {mod, st} = resolver.store

    loaded =
      Enum.reduce(fact_hashes, resolver.cache, fn hash, cache ->
        if Map.has_key?(cache, hash) do
          cache
        else
          case mod.load_fact(hash, st) do
            {:ok, value} -> Map.put(cache, hash, value)
            {:error, _} -> cache
          end
        end
      end)

    %{resolver | cache: loaded}
  end
end
```

**Cache scope:** Lives in Worker process memory, cleared on Worker stop. No eviction policy initially — bounded by hot set size.

### 1.3 Implement `save_fact/3` and `load_fact/2` in Store adapters

**ETS adapter:** Add a second `:set` table (`Module.concat(runner_name, FactTable)`) keyed by `fact_hash`. `save_fact/3` → `:ets.insert`, `load_fact/2` → `:ets.lookup`.

**Mnesia adapter:** Add a second Mnesia table with attributes `[:fact_hash, :value]`, type `:set`. Same storage mode config as the workflow table.

Both are pure content-addressed blob stores — `save_fact/3` stores the raw value (not the Fact struct). Must be idempotent (upsert semantics).

### 1.4 `vertex_id_of` for FactRef

Add `Components.vertex_id_of(%FactRef{hash: h})` returning `h` — same identity as `Fact`. A FactRef is a placeholder for the same logical fact; when resolved, vertex identity is preserved.

### 1.5 Testing

- Unit: `FactRef.from_fact/1` (if added), serialization round-trip, `Facts` accessors
- Unit: `FactResolver` — resolve Fact (passthrough), resolve FactRef (store hit), resolve FactRef (store miss → error), preload + cache hit
- Store contract: `save_fact` then `load_fact`, idempotent `save_fact`
- Property: `FactRef` hash/ancestry match source Fact

### 1.6 Integration Points

| File | Change | Risk |
|------|--------|------|
| `lib/runic/runner/store/ets.ex` | Add second ETS table + `save_fact/3`, `load_fact/2` | Low — isolated |
| `lib/runic/runner/store/mnesia.ex` | Add second Mnesia table + callbacks | Low — isolated |
| `lib/workflow/fact_ref.ex` | Already exists — may need `from_fact/1` | None |
| `lib/workflow/facts.ex` | New file | None |
| `lib/workflow/fact_resolver.ex` | New file | None |
| `lib/workflow/components.ex` | Add `vertex_id_of` clause for FactRef | Low — additive |

**No behavior change to existing runtime.** This phase is purely additive.

---

## Remaining Phase 2: Complete Event Capture + Value Separation

**Goal:** (1) Close the activation event gap so the event stream is a complete, replayable record of all state transitions. (2) Decouple fact values from the event stream so replay can reconstruct graph topology without loading all values into memory.

### 2.0 Close the activation event capture gap (prerequisite)

**This is the highest-priority correctness item.** Currently, `apply_runnable/2` step 4 calls `emit_downstream_activations/2` which calls `draw_connection` directly — these activation edges are graph mutations **not captured** in `uncommitted_events`. The event stream is therefore incomplete: replaying it via `from_events/2` produces a graph *without* activation edges, which means `is_runnable?/1` returns `false` and the workflow stalls.

The gap exists in two places:

1. **Default activation** (`default_emit_downstream/2` in `workflow.ex:3028-3035`): Iterates `next_steps/2` and calls `draw_connection(wf, result, step, connection_for_activatable(step))` for each downstream node. These `:runnable`/`:matchable` edge draws are not captured.

2. **Custom `Activator` implementations**: `FanOut`, `Condition`, `Conjunction`, `StateCondition`, `MemoryAssertion` all call `draw_connection` or `prepare_next_runnables` (which calls `draw_connection`) — none captured.

Note that coordination-derived events (from `Coordinator.finalize/3`) **are** captured in `uncommitted_events` — the asymmetry is that coordination was designed to be event-complete while activation was not.

**Fix:** Make `emit_downstream_activations` produce `RunnableActivated` events instead of (or in addition to) calling `draw_connection` directly. The `RunnableActivated` event type already exists with the right fields (`fact_hash`, `node_hash`, `activation_kind`), and `apply_event/2` already handles it correctly.

Concretely, change `default_emit_downstream/2` to:

```elixir
defp default_emit_downstream(%__MODULE__{} = wf, %Runnable{result: result, node: node})
     when is_struct(result, Fact) do
  next = next_steps(wf, node)

  activation_events =
    Enum.map(next, fn step ->
      %RunnableActivated{
        fact_hash: result.hash,
        node_hash: step.hash,
        activation_kind: Private.connection_for_activatable(step)
      }
    end)

  Enum.reduce(activation_events, wf, fn event, w -> apply_event(w, event) end)
end
```

And similarly update `Activator` implementations (or provide an event-emitting helper they can use). The key invariant: **every graph mutation during `apply_runnable/2` must be representable as an event in the stream.**

This also means updating the event buffering in step 5 of `apply_runnable/2` to capture activation events. The cleanest approach: accumulate all events produced during the entire apply phase (core events + derived events + activation events) rather than only the input `events` list. Consider threading an event accumulator through steps 1-4 instead of collecting them separately.

**Impact on `from_events/2`:** Once activation events are in the stream, `from_events/2` produces a fully-correct workflow with all activation edges — no need for a "re-derive activations" pass during replay.

**Testing:** Run a multi-step workflow, capture events, replay via `from_events/2`, verify `is_runnable?` returns the same result as the original workflow at each step. This is the most critical correctness test for the entire checkpointing system.

### 2.1 Key insight: event stream as journal

We don't need a separate journal — the event stream IS the journal. `FactProduced` events already carry `hash`, `value`, and `ancestry`. Value separation means: (1) the Worker persists fact values via `save_fact/3` at produce time, and (2) during lean replay, events can reconstruct the graph with `FactRef` structs instead of full `Fact` structs.

### 2.2 Worker-side fact persistence at produce time

After `Workflow.apply_runnable/2` in `handle_task_result/4`, scan `uncommitted_events` for `FactProduced` events and persist their values:

```elixir
defp flush_pending_facts(uncommitted_events, {store_mod, store_state}) do
  if function_exported?(store_mod, :save_fact, 3) do
    Enum.each(uncommitted_events, fn
      %FactProduced{hash: h, value: v} -> store_mod.save_fact(h, v, store_state)
      _ -> :ok
    end)
  end
end
```

This ensures fact values are durably stored before the checkpoint appends events referencing them.

### 2.3 Graph vertex handling for FactRef

Extend graph operations that pattern-match on `%Fact{}` to also accept `%FactRef{}`. The `Facts` helper module (Phase 1) provides the compatibility layer. Key sites:

- `next_steps/2` — traversal from fact vertices
- `prepared_runnables/1` — input resolution
- `is_runnable?/1` — activation checks

### 2.4 Worker pre-dispatch resolution of FactRef inputs

Before dispatching a runnable whose input is a `FactRef`, the Worker must resolve it to a full `Fact` via the `FactResolver`. This happens in `dispatch_runnables/1`, before constructing the task closure:

```elixir
# In dispatch_runnables, before Task.Supervisor.async_nolink:
runnable = maybe_resolve_inputs(runnable, state.resolver)
```

The Executor never sees FactRefs — it receives resolved Facts inside Runnables.

### 2.5 Meta-ref resolution for state machines

State machine `:meta_ref` edges reference facts by getter functions. When the target fact is a FactRef, the getter must resolve through the FactResolver. This requires threading the resolver through meta-ref resolution or eagerly resolving meta-ref targets during rehydration (handled in Phase 3's hot-set classification).

### 2.6 Fact hash semantics: value + ancestry

`Fact.new/1` computes hash via `Components.fact_hash({value, fact.ancestry})` — the hash incorporates both value and ancestry. This means two facts with identical values but different producers get different hashes and different store entries. For `save_fact/3`, this is correct: the fact store is causally-addressed, not just content-addressed. No deduplication across lineages, which preserves audit trail completeness. The trade-off (slightly more storage) is worth the causal correctness.

### 2.7 Testing

- Activation event capture: produce → apply → verify `uncommitted_events` contains `RunnableActivated` events for all downstream connections. Replay via `from_events/2` produces identical graph.
- Round-trip: produce facts → `save_fact` → checkpoint events (without values) → replay with `FactRef` → resolve via `load_fact` → verify values match
- Graph traversal: workflow with FactRef vertices behaves identically to one with Fact vertices for `next_steps`, `is_runnable?`
- Pre-dispatch resolution: Worker resolves FactRef inputs before dispatch, Executor receives full Facts

---

## Remaining Phase 3: Lineage Classification + Hybrid Rehydration

**Goal:** Smart rehydration that loads only the causally relevant facts into memory, leaving historical facts as lightweight FactRefs.

### 3.1 Causal lineage classification

Three categories of facts at rehydration time:

1. **Pending runnable inputs** — Facts on `:runnable` edges (active input to a not-yet-executed node). Always hot.
2. **Active frontier** — The latest-generation facts in each lineage. These are the "tips" of the causal graph. Hot by default.
3. **Meta-ref targets** — Facts referenced by `:meta_ref` edges (state machine current state). Always hot.

Everything else is **cold** — intermediate results from prior generations that are no longer needed for forward execution.

**Edge case — cross-lineage joins:** A Join node may have inputs from different root lineages. If one branch is hot and the other cold, the classifier marks all pending runnable inputs (Category 1) as hot regardless of lineage.

**Edge case — accumulator init facts:** Ancestry like `{acc.hash, Components.fact_hash(init_val)}` where the parent hash may not correspond to a real fact vertex. The lineage walk must stop when a parent hash is not found in the graph.

### 3.2 `Rehydration.classify/1`

```elixir
defmodule Runic.Workflow.Rehydration do
  alias Runic.Workflow.{Facts, Fact, FactRef}

  @type classification :: %{hot: MapSet.t(), cold: MapSet.t()}

  @spec classify(Runic.Workflow.t(), keyword()) :: classification()
  def classify(workflow, opts \\ []) do
    pending = pending_runnable_input_hashes(workflow)
    meta_targets = meta_ref_target_hashes(workflow)
    frontier = active_frontier_hashes(workflow)

    hot = MapSet.union(frontier, MapSet.union(pending, meta_targets))

    all_fact_hashes =
      for v <- Graph.vertices(workflow.graph),
          is_struct(v, Fact) or is_struct(v, FactRef),
          into: MapSet.new(),
          do: Facts.hash(v)

    cold = MapSet.difference(all_fact_hashes, hot)
    %{hot: hot, cold: cold}
  end
end
```

**Configurable depth limit:** `opts[:max_lineage_depth]` bounds the forward walk from root inputs. Default: `nil` (unlimited).

### 3.3 Integrate into `from_events/2` hybrid path

Extend `from_events/2` (or add `from_events/3`) to accept rehydration options:

```elixir
def from_events(events, base_workflow \\ nil, opts \\ []) do
  rehydration = Keyword.get(opts, :rehydration, :full)
  store = Keyword.get(opts, :store)

  # Step 1: structural + runtime replay (with FactRefs in :lean mode)
  workflow = do_from_events(events, base_workflow, fact_mode(rehydration))

  case rehydration do
    :full -> workflow
    :lazy -> {workflow, FactResolver.new(store)}
    :hybrid ->
      %{hot: hot_hashes} = Rehydration.classify(workflow, opts)
      resolver = FactResolver.new(store) |> FactResolver.preload(MapSet.to_list(hot_hashes))
      workflow = resolve_hot_facts(workflow, hot_hashes, resolver)
      {workflow, resolver}
  end
end
```

### 3.4 Testing

- Classification correctness: build a workflow with multiple input generations, verify hot set contains only latest-generation facts + pending runnables + meta-ref targets
- Hybrid round-trip: produce → checkpoint → clear memory → rehydrate hybrid → verify hot facts have values, cold facts are FactRefs → continue execution → verify results match full rehydration
- Edge cases: accumulator init ancestry walk terminates, cross-lineage Join inputs are hot, empty workflow → empty sets

---

## Remaining Phase 4: Full Worker Integration

**Goal:** Wire remaining pieces into the Worker lifecycle. Event draining and checkpoint routing are already implemented — this phase covers resolver management, hybrid recovery, fact persistence at produce time, and snapshot strategy.

### 4.1 Worker state additions

```elixir
defstruct [
  # ... existing fields (id, runner, workflow, store, event_cursor, uncommitted_events, ...) ...
  :resolver,           # %FactResolver{} — lazily initialized on first use
]
```

### 4.2 Resolver lifecycle

- Initialize `FactResolver` on Worker start (or lazily on first FactRef encounter)
- Pass resolver to `dispatch_runnables` for pre-dispatch input resolution
- Clear resolver cache on Worker stop (automatic — process-local)

### 4.3 Recovery path: `resume/3` with hybrid rehydration

```elixir
def resume(runner, workflow_id, opts) do
  {store_mod, store_state} = get_store(runner)
  rehydration = Keyword.get(opts, :rehydration, :full)

  workflow =
    if Runic.Runner.Store.supports_stream?(store_mod) do
      {:ok, event_stream} = store_mod.stream(workflow_id, store_state)
      Workflow.from_events(Enum.to_list(event_stream), nil,
        rehydration: rehydration,
        store: {store_mod, store_state}
      )
    else
      {:ok, log} = store_mod.load(workflow_id, store_state)
      Workflow.from_log(log)
    end

  start_worker(runner, workflow_id, workflow, Keyword.put(opts, :resumed, true))
end
```

### 4.4 Fact persistence at produce time

In `handle_task_result/4`, after draining `uncommitted_events`, call `flush_pending_facts/2` (from Phase 2) to persist fact values before the checkpoint appends event references.

### 4.5 Snapshot + WAL strategy

Add checkpoint strategies for the hybrid model:

- `:incremental` — Always use `append/3` (error if store doesn't support it)
- `:snapshot_and_wal` — Periodic full snapshot via `save_snapshot/4` + incremental WAL between snapshots

Snapshot creation: serialize the `%Workflow{}` struct (with `emit_events: false` and `uncommitted_events: []`) via `:erlang.term_to_binary/1`. On recovery: `load_snapshot/2` returns `{cursor, binary}`, deserialize, then replay events after cursor via `stream/2`.

### 4.6 Telemetry

```elixir
[:runic, :runner, :store, :append]
[:runic, :runner, :store, :save_fact]
[:runic, :runner, :rehydration, :classify]  # measurements: hot_count, cold_count, total_facts
[:runic, :runner, :fact, :resolve]
```

---

## Interaction with Runner Scheduling Doc

### Promise model compatibility

Promises execute multiple runnables within a single task context. Journal events accumulate in the Promise's local workflow copy. When the Promise resolves and the Worker applies results, these events merge into the source-of-truth workflow's `uncommitted_events`. Checkpoints happen at Promise completion, not between individual runnables within a Promise.

### Executor behaviour compatibility

The Executor dispatches `work_fn` closures. Fact resolution happens before the closure is constructed (in Worker's `dispatch_runnables`), so the Executor never sees FactRefs. For remote Executors (Oban, distributed), fact values are serialized with the Runnable — the remote side doesn't need access to the fact store.

### Sticky execution synergy

Sticky execution keeps the workflow in memory. The hybrid classifier can drive **runtime eviction** — when a Worker's memory exceeds a threshold, classify and evict cold facts to FactRefs. This is a natural extension of Phase 3's classifier used at runtime instead of only at rehydration.

---

## Phasing Summary

```
Phase 1: FactResolver + Fact Store Implementations       ← Foundation, no behavior change
  │
  ├── Phase 2: Complete Event Capture + Value Separation  ← Correctness fix + value decoupling
  │     │
  │     │  2.0: Close activation event gap (PREREQUISITE — blocks replay correctness)
  │     │  2.1-2.5: Value separation, FactRef graph ops, pre-dispatch resolution
  │     │  2.6: Fact hash semantics confirmed (value + ancestry = causal addressing)
  │     │
  │     └── Phase 3: Lineage Classification +             ← Smart rehydration
  │           Hybrid Rehydration
  │           │
  │           └── Phase 4: Full Worker Integration        ← Resolver lifecycle, snapshot+WAL
  │
  └── (Future) Runtime eviction, compaction, distribution
```

Each phase is independently testable and shippable. **Phase 2.0 (activation event capture) is the most critical correctness item** — without it, `from_events/2` produces incomplete graphs and replay-based recovery silently stalls. Phase 1 alone provides the vocabulary for all subsequent work. Phase 2 delivers event completeness and storage-level value separation. Phases 3-4 build toward the full hybrid rehydration vision.

---

## Open Decisions

### OD-1: Event compaction

When does the event stream get compacted? Options:
- Never (pure append-only, rely on store-level compaction)
- On explicit `continue_as_new` API call (Temporal-style)
- After N events (configurable threshold)
- On Worker stop/drain

**Recommendation:** Start with "on explicit call" and "on Worker stop". Add threshold-based compaction later as a checkpoint strategy option.

### OD-2: Fact value deduplication

Multiple runnables may produce facts with the same value hash. `save_fact/3` is idempotent, so duplicates are harmless but waste I/O.

**Recommendation:** Let the store adapter handle deduplication (ETS/Mnesia upsert is naturally idempotent). Don't add dedup logic to the Worker.

### OD-3: Resolver cache lifetime

Should the resolver cache persist across Worker restarts, or rebuild from scratch on each recovery?

**Recommendation:** Rebuild from scratch. The hybrid classifier identifies the hot set, and preloading is fast (bounded by hot set size). Persisting the cache adds complexity without proportional benefit.

### OD-4: Value in `FactProduced` during event emission

Should `FactProduced` events carry the full value when buffered in `uncommitted_events`, or should the value always be persisted separately via `save_fact/3` and omitted from the event?

**Trade-off:** Carrying the value makes events self-contained (simpler replay, no fact store dependency). Omitting the value makes the event stream leaner (important for large payloads). A pragmatic middle ground: always carry the value in the event during emission, but strip values when creating snapshots or compacting.

### OD-5: `from_events/2` rehydration options interface

How should `from_events/2` accept rehydration options? Options:
- Extend signature to `from_events/3` with an opts keyword list
- Pass options via a wrapper struct
- Keep `from_events/2` pure and add `rehydrate/3` as a separate function

**Recommendation:** `from_events/3` with opts. It's the simplest extension and follows Elixir convention. The function already has `base_workflow` as an optional second arg — adding `opts` as a third is natural.

### OD-6: Snapshot strategy

When to create a snapshot vs. full replay? Options:
- After every N events (e.g., every 1000)
- On Worker stop/drain
- On explicit API call
- Adaptive (when replay time exceeds threshold)

**Recommendation:** Start with "on Worker stop" + "on explicit call". Add event-count-based snapshotting as a configurable threshold later. The `save_snapshot/4` + `load_snapshot/2` callbacks already exist for this.

---

## Design Questions for the Architect

**Q1: The event stream mixes structural events (ComponentAdded) and runtime events (FactProduced, etc.). Should snapshots capture only the runtime event cursor, or embed a serialized workflow struct?**

A1: Workflow struct snapshot + cursor is more practical for recovery speed. Full replay from event 0 is correct but slow for long-running workflows. The `save_snapshot/4` + `load_snapshot/2` callbacks already exist for this pattern — serialize the workflow struct, record the cursor position, and on recovery replay only events after the cursor.

**Q2: `apply_runnable/2` buffers `uncommitted_events` for the core events and coordination-derived events, but downstream activation edges drawn by `emit_downstream_activations` (which calls `draw_connection` directly) are NOT captured as events in `uncommitted_events`. For full replay correctness, should these be captured?**

A2: **RESOLVED — promoted to Phase 2.0.** This is a correctness gap. The fix is to make `emit_downstream_activations` produce `RunnableActivated` events (the type already exists with the right fields) and fold them via `apply_event/2` like everything else. See Phase 2.0 for the concrete implementation plan. The key invariant: every graph mutation during `apply_runnable/2` must be representable as an event in the stream. Additionally, the event buffering in step 5 of `apply_runnable/2` must be updated to capture activation events — either by threading an accumulator through the entire apply phase or by diffing `uncommitted_events` before and after.

**Q3: The `Coordinator.finalize/3` protocol returns `{workflow, derived_events}` where derived events ARE captured in `uncommitted_events`. But the activation that happens AFTER coordination (when `derived_events == []`) isn't. Is this asymmetry intentional?**

A3: **RESOLVED — consequence of incremental development, fixed by Phase 2.0.** Coordination events were designed to be self-contained because Joins and FanIns need precise edge control. The default activation path was left as direct graph mutation. Phase 2.0 unifies both paths by making `emit_downstream_activations` produce `RunnableActivated` events that are folded and buffered like coordination events. After this change, the `Activator` protocol contract should specify that implementations return events (or call a helper that produces them) rather than calling `draw_connection` directly.

**Q4: For content-addressed fact storage, should the hash be computed from the value alone, or from value + ancestry? Value-only deduplicates across lineages (same value, different producers). Value + ancestry preserves causal uniqueness.**

A4: **RESOLVED — confirmed by code.** `Fact.new/1` computes hash via `Components.fact_hash({value, fact.ancestry})` — the hash incorporates both value and ancestry. The fact store is therefore **causally-addressed**: two facts with the same value but different producers get different hashes. This is correct for an audit trail and means `save_fact/3` entries are unique per causal lineage. See Phase 2.6 for implications.

**Q5: When rehydrating with `:hybrid` mode, the classifier needs the graph to already have all vertices (as Facts or FactRefs) to perform the lineage walk. But `from_events/2` currently creates full `Fact` structs. Should we add a `:lean` mode to `from_events/2` that creates `FactRef` structs instead, then resolves hot ones after classification?**

A5: Yes, this is the intended two-pass approach: (1) replay with FactRefs to get graph topology without loading values, (2) classify hot/cold, (3) resolve hot FactRefs via the store. `from_events/2` would need an option like `fact_mode: :ref | :full` to control whether `FactProduced` events create `Fact` or `FactRef` vertices. This is only useful when the event stream has had values stripped (via compaction or lean persistence) — if events carry full values, creating FactRefs is wasteful since the value is already in memory.

**Q6: The Worker's `maybe_persist_build_log/3` persists structural events on first start. If the workflow structure changes (e.g., dynamic component addition at runtime), how do we handle structural events interleaved with runtime events during replay?**

A6: `from_events/2` already splits by event type — `ComponentAdded` goes to `from_log`, runtime events go to `apply_event`. This means interleaving is handled correctly at the split level. However, ordering matters: if a runtime event references a component that was dynamically added, that `ComponentAdded` event must appear before the runtime event in the stream. The current `append`-based persistence preserves chronological order, so this works. Dynamic structural changes mid-execution are an edge case worth testing explicitly.
