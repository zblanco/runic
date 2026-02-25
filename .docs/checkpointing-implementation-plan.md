# Checkpointing Implementation Plan — Causal-Lineage-Aware Hybrid Rehydration

**Status:** Draft  
**Depends on:** [Checkpointing Strategies Proposal](checkpointing-strategies-proposal.md), [Runner Scheduling Considerations](full-breadth-runner-scheduling-considerations.md)  
**Influences:** Restate Journal System, Event Sourcing  
**Goal:** Low-latency recovery with bounded memory for long-running workflows  

---

## Design Principles

1. **Append-only journal as source of truth** — Mutations are captured at write-time, not derived by scanning the whole graph. This is the foundation for incremental checkpointing, distribution, and audit.

2. **Content-addressed fact storage** — Fact values are stored separately by hash. The journal references facts by hash+ancestry, never embedding large values. This decouples "what happened" from "what data was produced".

3. **Hot/cold classification at rehydration boundaries** — The active causal frontier (latest input lineage + pending runnables + meta-ref targets) is loaded eagerly. Everything else stays as lightweight FactRefs, resolved on demand.

4. **Purely functional core preserved** — `Workflow` never calls Store directly. Side effects (fact persistence, journal flushing) are performed by the Worker at well-defined flush points. The workflow accumulates pending operations as data.

5. **Full backward compatibility** — `from_log/1` remains unchanged. New capabilities are opt-in via `from_log/2` with a `:rehydration` option and via Store adapters implementing new optional callbacks.

---

## Phase 1: FactRef + Fact-Level Store API (Foundation)

**Goal:** Content-addressed fact storage and a lightweight fact reference struct that can represent a fact in the graph/journal without embedding its value.

**Independently useful:** Store adapters can start persisting fact values immediately. FactRef is the vocabulary type that all subsequent phases depend on.

### 1.1 Add `Runic.Workflow.FactRef`

New file: `lib/workflow/fact_ref.ex`

```elixir
defmodule Runic.Workflow.FactRef do
  @moduledoc """
  A lightweight reference to a fact, holding only its hash and ancestry.

  FactRefs stand in for Facts in the workflow graph when the actual value
  is not loaded into memory. The value can be resolved from a Store on
  demand via `FactResolver`.

  FactRefs are intentionally pure data — no store references, no closures.
  This keeps them serializable and suitable for journal persistence.
  """

  @enforce_keys [:hash]
  defstruct [:hash, :ancestry]

  @type t :: %__MODULE__{
          hash: Runic.Workflow.Fact.hash(),
          ancestry: {Runic.Workflow.Fact.hash(), Runic.Workflow.Fact.hash()} | nil
        }

  @doc "Creates a FactRef from a full Fact, discarding the value."
  def from_fact(%Runic.Workflow.Fact{hash: h, ancestry: a}) do
    %__MODULE__{hash: h, ancestry: a}
  end
end
```

**Design decision — no `store_ref` in FactRef:** Embedding `{store_mod, store_state}` in the ref breaks serialization and leaks runtime concerns into the graph. Resolution always receives a store/resolver context externally. This keeps journal entries portable across store backends.

### 1.2 Add `Runic.Workflow.Facts` helper module

New file: `lib/workflow/facts.ex`

Provides a common interface for accessing hash/ancestry on either `Fact` or `FactRef` without pattern-matching on struct types everywhere.

```elixir
defmodule Runic.Workflow.Facts do
  @moduledoc """
  Unified accessors for Fact and FactRef structs.
  """

  alias Runic.Workflow.{Fact, FactRef}

  def hash(%Fact{hash: h}), do: h
  def hash(%FactRef{hash: h}), do: h

  def ancestry(%Fact{ancestry: a}), do: a
  def ancestry(%FactRef{ancestry: a}), do: a

  def value?(%Fact{value: v}) when not is_nil(v), do: true
  def value?(_), do: false
end
```

This is a compatibility shim — it avoids touching every `%Fact{}` pattern match site in Phase 1. Later phases can route through this when they need to handle both types.

### 1.3 Add `Runic.Workflow.FactResolver`

New file: `lib/workflow/fact_resolver.ex`

Runtime-only resolver that hydrates FactRefs via a Store adapter. Maintains a process-local cache to avoid repeated store round-trips for shared input facts.

```elixir
defmodule Runic.Workflow.FactResolver do
  @moduledoc """
  Resolves FactRefs to full Facts by loading values from a Store.

  Maintains an in-memory cache of resolved values. The resolver is
  scoped to a single Worker process lifetime — it is not shared across
  processes and requires no coordination.
  """

  alias Runic.Workflow.{Fact, FactRef}

  defstruct [:store, cache: %{}]

  @type t :: %__MODULE__{
          store: {module(), term()},
          cache: %{optional(term()) => term()}
        }

  def new(store) do
    %__MODULE__{store: store, cache: %{}}
  end

  @doc "Resolves a Fact or FactRef to a full Fact with value."
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

  @doc "Preloads a set of fact hashes into the cache via batch store reads."
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

**Cache scope:** The cache lives in Worker process memory and is cleared on Worker stop. No eviction policy initially — for a single workflow's hot set this is bounded and small. If memory pressure becomes an issue (Phase 5+), we can add LRU or size limits.

### 1.4 Extend `Runic.Runner.Store` behaviour

Add new optional callbacks to `lib/runic/runner/store.ex`:

```elixir
# --- Fact-level storage (content-addressed) ---

@callback save_fact(fact_hash :: term(), value :: term(), state()) ::
  :ok | {:error, term()}

@callback load_fact(fact_hash :: term(), state()) ::
  {:ok, term()} | {:error, :not_found | term()}

@callback has_fact?(fact_hash :: term(), state()) :: boolean()

@optional_callbacks [
  checkpoint: 3, delete: 2, list: 1, exists?: 2,
  save_fact: 3, load_fact: 2, has_fact?: 2
]
```

**`save_fact/3` stores the raw value (not the Fact struct)** — the hash and ancestry live in the journal/graph. This makes the fact store a pure content-addressed blob store. `save_fact/3` must be idempotent (upsert semantics) since the same fact hash may be produced by multiple runnables referencing shared inputs.

### 1.5 Implement in ETS and Mnesia adapters

**ETS:** Add a second `:set` table (`Module.concat(runner_name, FactTable)`) keyed by `fact_hash`. `save_fact/3` does `:ets.insert(fact_table, {hash, value})`. `load_fact/2` does `:ets.lookup`.

**Mnesia:** Add a second Mnesia table with attributes `[:fact_hash, :value]`, type `:set`. Same `disc_copies` / `ram_copies` config as the workflow table. Write via `:mnesia.transaction`.

### 1.6 Testing

- Unit tests for FactRef: `from_fact/1`, serialization via `:erlang.term_to_binary/1`.
- Unit tests for FactResolver: resolve Fact (passthrough), resolve FactRef (store hit), resolve FactRef (store miss = error), preload + cache hit.
- Store adapter contract tests: `save_fact` then `load_fact`, idempotent `save_fact`, `has_fact?`.
- Property: `FactRef.from_fact(fact).hash == fact.hash` and `FactRef.from_fact(fact).ancestry == fact.ancestry`.

### 1.7 Integration Points (code changes in existing files)

| File | Change | Risk |
|------|--------|------|
| `lib/runic/runner/store.ex` | Add 3 optional callbacks + update `@optional_callbacks` | None — additive |
| `lib/runic/runner/store/ets.ex` | Add second ETS table + 3 callback impls | Low — isolated |
| `lib/runic/runner/store/mnesia.ex` | Add second Mnesia table + 3 callback impls | Low — isolated |
| `lib/workflow/fact_ref.ex` | New file | None |
| `lib/workflow/facts.ex` | New file | None |
| `lib/workflow/fact_resolver.ex` | New file | None |

**No behavior change to existing runtime.** This phase is purely additive.

---

## Phase 2: Append-Only Journal + Incremental Checkpointing

**Goal:** Capture workflow mutations as they occur in a chronological, append-only journal. Checkpoint writes become O(new events) instead of O(total state).

**Independently useful:** Even without FactRef or hybrid rehydration, incremental checkpointing dramatically reduces checkpoint I/O for long-running workflows. This is the highest-impact change for production use.

### 2.1 Why the current checkpoint model doesn't support incremental

The current `Workflow.log/1` implementation:

```elixir
def log(wrk) do
  build_log(wrk) ++ reactions_occurred(wrk) ++ wrk.runnable_events
end
```

`reactions_occurred/1` scans the entire graph's edge_index for all non-`:flow` edges and produces `%ReactionOccurred{}` events. This is a **derived snapshot** — it re-derives the full state every time. You cannot take a diff of two snapshots cheaply because the order isn't stable.

The `runnable_events` field is already event-like (append-only list of `%RunnableDispatched{}`, `%RunnableCompleted{}`, `%RunnableFailed{}`), but it's mixed with the derived snapshot in `log/1`.

### 2.2 Introduce journal event types

New file: `lib/workflow/journal.ex`

Define the event vocabulary for the append-only journal:

```elixir
defmodule Runic.Workflow.Journal do
  @moduledoc """
  Event types for the append-only workflow journal.

  Journal events represent individual mutations to the workflow state.
  They are emitted during workflow execution and persisted incrementally.
  The full workflow can be reconstructed by replaying journal events
  in order via `from_journal/2`.
  """

  defmodule FactLogged do
    @moduledoc "A fact was added to the workflow graph as a vertex."
    defstruct [:hash, :ancestry, :value]
  end

  defmodule EdgeDrawn do
    @moduledoc "An edge was added between two vertices in the workflow graph."
    defstruct [:from, :to, :label, :weight, :properties]
  end

  defmodule EdgeRelabeled do
    @moduledoc "An existing edge's label was updated (e.g., :runnable → :ran)."
    defstruct [:from, :to, :from_label, :to_label]
  end
end
```

**Why new event types instead of reusing `ReactionOccurred`?** `ReactionOccurred` was designed for the derived-snapshot model and includes serialization concerns (getter_fn stripping). Journal events should be minimal and chronological. We keep `ReactionOccurred` for `log/1` backward compatibility and introduce clean event types for the journal.

### 2.3 Add journal buffer to Workflow struct

Add two new fields to `Runic.Workflow`:

```elixir
defstruct [
  # ... existing fields ...
  journal: [],                # reverse-ordered list of new events since last flush
  pending_fact_values: %{},   # hash -> value, facts produced since last flush
]
```

`journal` accumulates events in reverse order (head-prepend for performance). The Worker reverses on flush. `pending_fact_values` captures fact values that need to be persisted to the fact store before the journal is appended (write-ordering guarantee: values before references).

### 2.4 Emit journal events at mutation points

The critical mutation points in `lib/workflow/private.ex`:

#### 2.4.1 `log_fact/2` — fact vertex creation

```elixir
# Current:
def log_fact(%Workflow{graph: graph} = wrk, %Fact{} = fact) do
  %Workflow{wrk | graph: Graph.add_vertex(graph, fact)}
end

# Updated:
def log_fact(%Workflow{graph: graph} = wrk, %Fact{} = fact) do
  %Workflow{
    wrk
    | graph: Graph.add_vertex(graph, fact),
      journal: [
        %Journal.FactLogged{hash: fact.hash, ancestry: fact.ancestry, value: fact.value}
        | wrk.journal
      ],
      pending_fact_values: Map.put(wrk.pending_fact_values, fact.hash, fact.value)
  }
end
```

#### 2.4.2 `draw_connection/5` — edge creation

```elixir
# After the existing Graph.add_edge call, also emit:
journal: [
  %Journal.EdgeDrawn{
    from: vertex_id(node_1),
    to: vertex_id(node_2),
    label: connection,
    weight: weight,
    properties: strip_unjournalable(connection, properties)
  }
  | wrk.journal
]
```

Where `strip_unjournalable/2` removes `:getter_fn` from `:meta_ref` edge properties (same as existing `strip_getter_fn_for_serialization/2` in `workflow.ex`).

`vertex_id/1` extracts the vertex identifier (hash for components, `{hash, ancestry}` or hash for facts) — whatever `Components.vertex_id_of/1` returns.

#### 2.4.3 `mark_runnable_as_ran/3` — edge label update

```elixir
# After the existing Graph.update_labelled_edge call, also emit:
journal: [
  %Journal.EdgeRelabeled{
    from: vertex_id(fact),
    to: vertex_id(step),
    from_label: connection_for_activatable(step),
    to_label: :ran
  }
  | wrk.journal
]
```

**Important:** This edge update is the most critical journaling point. Without it, replaying the journal would leave `:runnable` edges in place, causing `is_runnable?/1` to return true for already-completed work — an infinite loop on recovery.

### 2.5 Extend Store behaviour for append semantics

Add to `lib/runic/runner/store.ex`:

```elixir
# --- Append-only journal ---

@callback append(workflow_id(), events :: [struct()], state()) ::
  :ok | {:error, term()}

@callback load_all(workflow_id(), state()) ::
  {:ok, [struct()]} | {:error, :not_found | term()}

@callback load_since(workflow_id(), cursor :: non_neg_integer(), state()) ::
  {:ok, [struct()]} | {:error, term()}

@optional_callbacks [
  checkpoint: 3, delete: 2, list: 1, exists?: 2,
  save_fact: 3, load_fact: 2, has_fact?: 2,
  append: 3, load_all: 2, load_since: 3
]
```

### 2.6 ETS adapter journal implementation

Use a separate `:ordered_set` table for the journal:

```elixir
# Table: {workflow_id, seq} -> event
# append/3: writes events with monotonically increasing seq per workflow_id
# load_all/2: :ets.select for all {workflow_id, _} ordered by seq
# load_since/3: :ets.select for {workflow_id, seq} where seq > cursor
```

Maintain a counter in the existing workflow table entry or a separate `:counters` ref for seq generation.

### 2.7 Worker incremental checkpoint integration

Changes to `lib/runic/runner/worker.ex`:

Add to Worker state:

```elixir
defstruct [
  # ... existing fields ...
  :resolver,              # %FactResolver{} for lazy loading (Phase 3+)
  journal_cursor: 0,      # seq counter for journal append ordering
]
```

Update `do_checkpoint/1`:

```elixir
defp do_checkpoint(%{store: {store_mod, store_state}, id: id, workflow: wf} = state) do
  Telemetry.store_span(:checkpoint, %{workflow_id: id}, fn ->
    if function_exported?(store_mod, :append, 3) do
      # Incremental path: flush pending facts, then append journal delta
      flush_pending_facts(wf, store_mod, store_state)
      delta = Enum.reverse(wf.journal)
      unless Enum.empty?(delta), do: store_mod.append(id, delta, store_state)
    else
      # Legacy path: full snapshot
      log = Workflow.log(wf)
      if function_exported?(store_mod, :checkpoint, 3) do
        store_mod.checkpoint(id, log, store_state)
      else
        store_mod.save(id, log, store_state)
      end
    end
  end)

  # Clear the journal buffer after successful persistence
  %{state | workflow: Workflow.flush_journal(wf)}
end

defp flush_pending_facts(wf, store_mod, store_state) do
  if function_exported?(store_mod, :save_fact, 3) do
    Enum.each(wf.pending_fact_values, fn {hash, value} ->
      store_mod.save_fact(hash, value, store_state)
    end)
  end
end
```

Add `Workflow.flush_journal/1`:

```elixir
def flush_journal(%__MODULE__{} = wf) do
  %{wf | journal: [], pending_fact_values: %{}}
end
```

### 2.8 Write-ordering guarantee

**Facts must be persisted before journal events that reference them.** The flush sequence is:

1. `save_fact/3` for each entry in `pending_fact_values`
2. `append/3` for the journal delta

If step 2 fails after step 1, we have orphaned fact values (harmless — content-addressed, idempotent). If step 1 fails, we abort before step 2 (no dangling references in the journal). This provides at-least-once durability without requiring transactions.

For store adapters with transaction support (Mnesia, Postgres), a future `append_with_facts/4` callback could provide atomicity. Not needed for Phase 2.

### 2.9 `from_journal/2` — journal-based rehydration

Add to `lib/workflow.ex`:

```elixir
@doc """
Rebuilds a workflow from a build log + append-only journal events.

Unlike `from_log/1` which expects the derived snapshot format, this
function replays chronological journal events on top of the base
workflow structure (from build_log events).

## Options

  * `:rehydration` - `:full` (default), `:lazy`, or `:hybrid`
  * `:store` - `{store_mod, store_state}` required for `:lazy` and `:hybrid`
"""
def from_journal(build_log_events, journal_events, opts \\ []) do
  # Phase 1: rebuild static structure from ComponentAdded events
  base = from_log(build_log_events)

  # Phase 2: replay journal events chronologically
  Enum.reduce(journal_events, base, fn
    %Journal.FactLogged{} = event, wrk ->
      replay_fact_logged(wrk, event, opts)

    %Journal.EdgeDrawn{} = event, wrk ->
      replay_edge_drawn(wrk, event)

    %Journal.EdgeRelabeled{} = event, wrk ->
      replay_edge_relabeled(wrk, event)

    # Support legacy event types mixed in (RunnableDispatched etc.)
    %RunnableDispatched{} = event, wrk ->
      %{wrk | runnable_events: wrk.runnable_events ++ [event]}

    %RunnableCompleted{} = event, wrk ->
      %{wrk | runnable_events: wrk.runnable_events ++ [event]}

    %RunnableFailed{} = event, wrk ->
      %{wrk | runnable_events: wrk.runnable_events ++ [event]}
  end)
end
```

The `replay_fact_logged/3` function is where rehydration strategy diverges:

- `:full` — creates `%Fact{hash, ancestry, value}` and adds to graph (same as today)
- `:lazy` — creates `%FactRef{hash, ancestry}` and adds to graph (value stays in store)
- `:hybrid` — creates `%FactRef{}` initially, then classifies and resolves hot facts (Phase 4)

### 2.10 Testing

- Unit tests for journal event emission: run a workflow through `react/2`, verify `wf.journal` contains expected FactLogged, EdgeDrawn, EdgeRelabeled events in chronological order.
- Round-trip test: `from_journal(build_log, journal_events)` produces equivalent workflow state to `from_log(Workflow.log(wf))`.
- Worker incremental checkpoint test: run workflow, checkpoint, verify `append/3` called with delta events. Resume from `load_all/2`, verify equivalent state.
- Legacy fallback test: store without `append/3` falls back to `save/3` with full log.

### 2.11 Integration Points

| File | Change | Risk |
|------|--------|------|
| `lib/workflow.ex` | Add `journal`/`pending_fact_values` to struct, `flush_journal/1`, `from_journal/3` | Low — additive fields, new function |
| `lib/workflow/private.ex` | Emit journal events in `log_fact/2`, `draw_connection/5`, `mark_runnable_as_ran/3` | **Medium** — touches hot path, must not break existing behavior |
| `lib/workflow/journal.ex` | New file (event types) | None |
| `lib/runic/runner/store.ex` | Add `append/3`, `load_all/2`, `load_since/3` optional callbacks | None — additive |
| `lib/runic/runner/store/ets.ex` | Journal table + implementations | Low |
| `lib/runic/runner/store/mnesia.ex` | Journal table + implementations | Low |
| `lib/runic/runner/worker.ex` | Incremental checkpoint path in `do_checkpoint/1`, `flush_pending_facts/3` | Low-Medium |

**Key risk:** The journal emission in `private.ex` mutation points must be tested carefully. The `draw_connection/5` function is called from many paths (Invokable.prepare/execute apply_fns, fan-out/fan-in, state machines). All paths must produce valid journal events.

---

## Phase 3: FactRefs in the Journal + Value Separation

**Goal:** Journal events reference facts by hash only. Large fact values live exclusively in the fact store. The graph can contain both `%Fact{}` (hot, value loaded) and `%FactRef{}` (cold, value in store).

**Depends on:** Phase 1 (FactRef, fact store), Phase 2 (journal emission)

### 3.1 Journal event payload: FactRef, not Fact

Modify `Journal.FactLogged` to carry only the ref:

```elixir
defmodule Journal.FactLogged do
  defstruct [:hash, :ancestry]
  # value is NOT in the journal event — it's in the fact store
end
```

The value is persisted separately via `pending_fact_values` → `save_fact/3`. The journal only records "fact X with ancestry Y was logged" — no data payload.

**Backward compatibility:** The journal write path already separates value persistence (`pending_fact_values`) from event emission (`journal`). This change just removes `value` from the event struct. Old journals with embedded values can be handled by `from_journal/3` detecting the presence of a `:value` field.

### 3.2 Graph vertex identity consideration

Currently, `Graph.add_vertex(graph, fact)` uses the fact struct as the vertex, and `Components.vertex_id_of/1` extracts an identity (the hash). Edges reference vertices by their struct value.

**For Phase 3, facts in the graph may be either `%Fact{}` or `%FactRef{}`.**

The `vertex_identifier` function in `new_graph/0`:

```elixir
Graph.new(vertex_identifier: &Components.vertex_id_of/1, multigraph: true)
```

This means libgraph identifies vertices by the return of `vertex_id_of/1` — the hash. So `%Fact{hash: h}` and `%FactRef{hash: h}` would collide on vertex identity (same hash). This is actually what we want: a FactRef with the same hash as a Fact represents the same vertex.

**Action needed:** Ensure `Components.vertex_id_of/1` handles `%FactRef{}`:

```elixir
def vertex_id_of(%FactRef{hash: h}), do: h
```

**Edge `v1`/`v2` fields:** libgraph stores the original structs in edge `v1`/`v2`. Code that pattern-matches on `edge.v2` being `%Fact{}` (e.g., in `raw_productions/2`, `facts/1`) will not match `%FactRef{}`. These sites need updating:

- `facts/1` — filter for both `%Fact{}` and `%FactRef{}`
- `raw_productions/2` — needs to resolve FactRef values (or this is only called when values are in memory)
- Any other site that does `match?(%Fact{}, v)` on graph vertices

### 3.3 Resolve before execute — the dispatch boundary

The cleanest integration point is `prepare_for_dispatch/1`. Currently:

```elixir
def prepare_for_dispatch(workflow) do
  runnables = next_runnables(workflow)
  # ... prepare each into %Runnable{input_fact: fact} ...
end
```

For the Worker path, add a resolver-aware variant:

```elixir
def prepare_for_dispatch(workflow, opts \\ []) do
  resolver = Keyword.get(opts, :resolver)
  runnables = next_runnables(workflow)

  # If any runnable's input_fact is a FactRef and we have a resolver,
  # resolve it to a full Fact before building the Runnable
  # ... (resolve in Invokable.prepare/3 via the context, or here) ...
end
```

**Alternative: resolve in Worker before calling prepare.** The Worker already knows the resolver. It could resolve all pending runnable input facts before `prepare_for_dispatch`. This avoids threading resolver through the pure Workflow API.

```elixir
# In Worker.dispatch_runnables/1:
defp dispatch_runnables(%__MODULE__{} = state) do
  workflow = maybe_resolve_pending_facts(state.workflow, state.resolver)
  {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)
  # ...
end

defp maybe_resolve_pending_facts(workflow, nil), do: workflow
defp maybe_resolve_pending_facts(workflow, resolver) do
  # For each fact with a :runnable/:matchable edge, if it's a FactRef,
  # resolve and replace in the graph
  # ...
end
```

**Recommended approach:** Resolve at the Worker level before dispatch. This keeps `Workflow` pure and avoids threading runtime concerns (store access) through the functional core. The Worker is already the integration point for all runtime concerns (telemetry, persistence, policies).

### 3.4 Meta-ref resolution for state machines

State machine transitions depend on `:meta_ref` edges with getters (`:state_of`, `:latest_value`, etc.). These getters traverse the graph to find the latest `:state_produced` fact. If that fact is a `%FactRef{}`, the getter returns a FactRef (no value).

**Resolution timing:** The `prepare` phase of stateful components (Rules with state conditions, Accumulators) reads state via meta-ref getters. If the resolver has preloaded the hot set (Phase 4), these facts are already `%Fact{}` in the graph. If not, the getter must resolve lazily.

**Phase 3 approach:** Do not solve this completely. Instead:
1. Ensure meta-ref getters don't crash on FactRef (return the ref or nil)
2. The Worker's pre-dispatch resolution covers pending runnable inputs
3. Phase 4's hot-set classification ensures state facts are preloaded

### 3.5 Testing

- Journal round-trip with FactRef: produce facts → journal captures FactLogged (no value) → fact values in store → `from_journal` with `:lazy` → FactRefs in graph → resolve via FactResolver → values match originals.
- Graph vertex identity: `FactRef` and `Fact` with same hash produce same vertex_id.
- Worker dispatch with FactRef resolution: FactRef inputs are resolved to Facts before execution.

---

## Phase 4: Lineage Classification + Hybrid Rehydration

**Goal:** On recovery via `from_journal/3` with `rehydration: :hybrid`, classify facts into hot (eagerly loaded) and cold (FactRef) sets. Preload the hot set into the resolver cache. The workflow is immediately ready to continue execution with minimal store round-trips.

**Depends on:** Phase 1 (FactRef, FactResolver), Phase 2 (journal-based rehydration), Phase 3 (FactRef in graph)

### 4.1 Hot/Cold Classification Algorithm

New file: `lib/workflow/rehydration.ex`

The classifier identifies three categories of "hot" facts:

#### Category 1: Pending runnable inputs

Facts with outgoing `:runnable` or `:matchable` edges. These are about to be consumed by the next dispatch cycle.

```elixir
defp pending_runnable_input_hashes(workflow) do
  for %Graph.Edge{v1: fact} <- Graph.edges(workflow.graph, by: [:runnable, :matchable]),
      is_struct(fact, Fact) or is_struct(fact, FactRef),
      into: MapSet.new() do
    Facts.hash(fact)
  end
end
```

#### Category 2: Meta-ref targets (state machine state, latest values)

Walk `:meta_ref` edges, identify the target component, find its latest `:state_produced` or `:produced` fact.

```elixir
defp meta_ref_target_hashes(workflow) do
  for %Graph.Edge{properties: props} = edge <-
        Graph.edges(workflow.graph, by: :meta_ref),
      kind = Map.get(props || %{}, :kind),
      kind in [:state_of, :latest_value, :latest_fact],
      into: MapSet.new() do
    # Find the latest :state_produced/:produced fact from the target component
    target = edge.v2
    latest_fact_hash(workflow, target, kind)
  end
  |> MapSet.delete(nil)
end

defp latest_fact_hash(workflow, target, :state_of) do
  Graph.out_edges(workflow.graph, target, by: :state_produced)
  |> Enum.max_by(&ancestry_depth(workflow, &1.v2), fn -> nil end)
  |> case do
    nil -> nil
    edge -> Facts.hash(edge.v2)
  end
end
```

#### Category 3: Active causal frontier (latest input lineage)

Identify the most recent root input fact(s) (ancestry = nil), then mark all facts whose lineage traces back to them.

```elixir
defp active_frontier_hashes(workflow) do
  all_facts = for v <- Graph.vertices(workflow.graph),
                  is_struct(v, Fact) or is_struct(v, FactRef), do: v

  # Root inputs: facts with nil ancestry
  root_inputs = Enum.filter(all_facts, &(Facts.ancestry(&1) == nil))

  # Find the most recent root input(s) by ancestry depth of their descendants
  # (the root with the deepest descendant chain is the latest input)
  latest_root = find_latest_root_input(workflow, root_inputs)

  case latest_root do
    nil -> MapSet.new()
    root ->
      # Walk forward from root through :produced/:state_produced edges
      # collecting all descendant fact hashes
      collect_lineage_descendants(workflow, Facts.hash(root))
  end
end
```

**Lineage walk direction:** We walk **forward** (producer → produced facts) from the latest root input, not backward from leaf facts. This is more efficient because:
- Forward walk follows `:produced`/`:state_produced` edges (out-edges from components)
- Backward walk would need to follow `ancestry` tuples and lookup vertices by hash

**Edge case — cross-lineage joins:** A Join node may have inputs from different root lineages. If one branch is hot and the other is cold, the Join's `prepare` will need to resolve cold FactRefs. The classifier handles this by also marking Category 1 (pending runnable inputs) as hot — if a Join is pending, both its input facts are hot regardless of lineage.

**Edge case — accumulator init facts:** Accumulator init facts have ancestry like `{acc.hash, Components.fact_hash(init_val)}` where the parent hash may not correspond to a real fact vertex. The lineage walk must stop when a parent hash is not found in the graph.

### 4.2 `Rehydration.classify/1`

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

**Configurable depth limit:** Add `opts[:max_lineage_depth]` to bound the forward walk from root inputs. Default: `nil` (unlimited). For deeply nested pipelines, a limit of ~50 covers most practical cases while bounding the hot set.

### 4.3 Integrate into `from_journal/3` hybrid path

```elixir
def from_journal(build_log_events, journal_events, opts) do
  rehydration = Keyword.get(opts, :rehydration, :full)
  store = Keyword.get(opts, :store)

  # Step 1: rebuild structure + replay with FactRefs (lazy)
  base = from_log(build_log_events)
  workflow = replay_journal(base, journal_events, :lazy)

  case rehydration do
    :full ->
      # Resolve ALL FactRefs to Facts
      resolver = FactResolver.new(store)
      resolve_all_facts(workflow, resolver)

    :lazy ->
      # Leave everything as FactRef
      {workflow, FactResolver.new(store)}

    :hybrid ->
      # Classify, preload hot set, leave cold as FactRef
      %{hot: hot_hashes} = Rehydration.classify(workflow, opts)
      resolver = FactResolver.new(store) |> FactResolver.preload(MapSet.to_list(hot_hashes))

      # Replace hot FactRefs in graph with resolved Facts
      workflow = resolve_hot_facts(workflow, hot_hashes, resolver)
      {workflow, resolver}
  end
end
```

### 4.4 Testing

- Classification correctness: build a workflow with multiple input generations, verify hot set contains only latest-generation facts + pending runnables + meta-ref targets.
- Hybrid rehydration round-trip: produce → checkpoint → clear memory → rehydrate hybrid → verify hot facts have values, cold facts are FactRefs → continue execution → verify results match full rehydration.
- Edge cases: accumulator init ancestry walk terminates, cross-lineage Join inputs are hot, empty workflow classifies to empty sets.

---

## Phase 5: Worker Lifecycle Integration

**Goal:** Wire everything together in the Worker's lifecycle: fact persistence on produce, incremental checkpointing with journal, resolver management, and hybrid recovery on resume.

**Depends on:** All prior phases

### 5.1 Worker state additions

```elixir
defstruct [
  # ... existing fields ...
  :resolver,           # %FactResolver{} — lazily initialized on first use
  journal_cursor: 0,   # monotonic counter for journal ordering
]
```

### 5.2 Production-time fact persistence

After `Workflow.apply_runnable/2` in `handle_task_result/4`, flush any pending fact values:

```elixir
defp handle_task_result(ref, executed, events, state) do
  # ... existing code ...
  workflow = Workflow.apply_runnable(state.workflow, executed)

  # Flush newly produced fact values to store (Phase 1 API)
  state = flush_pending_facts_if_needed(%{state | workflow: workflow})

  # ... rest of existing code ...
end
```

This ensures fact values are durably stored before the next checkpoint appends journal events referencing them.

### 5.3 Recovery path: `resume/3` with hybrid rehydration

In `Runic.Runner.resume/3` (or Worker init recovery):

```elixir
def resume(runner, workflow_id, opts) do
  {store_mod, store_state} = get_store(runner)
  rehydration = Keyword.get(opts, :rehydration, :full)

  workflow =
    cond do
      rehydration != :full and function_exported?(store_mod, :load_all, 2) ->
        # Journal-based recovery
        {:ok, all_events} = store_mod.load_all(workflow_id, store_state)
        {build_events, journal_events} = split_build_and_journal(all_events)
        Workflow.from_journal(build_events, journal_events,
          rehydration: rehydration,
          store: {store_mod, store_state}
        )

      true ->
        # Legacy full-snapshot recovery
        {:ok, log} = store_mod.load(workflow_id, store_state)
        Workflow.from_log(log)
    end

  start_worker(runner, workflow_id, workflow, opts)
end
```

### 5.4 Checkpoint strategy integration

The existing checkpoint strategies (`:every_cycle`, `{:every_n, n}`, `:on_complete`, `:manual`) work with the new incremental path. The `do_checkpoint/1` function (modified in Phase 2) handles the routing between incremental and legacy paths based on store capabilities.

Add a new strategy for the hybrid model:

- `:incremental` — always use `append/3` (error if store doesn't support it)
- `:snapshot_and_wal` — periodic full snapshot + incremental WAL between snapshots (Phase 5+, requires `save/3` + `append/3`)

### 5.5 Telemetry

Extend telemetry events for observability:

```elixir
# Journal append
[:runic, :runner, :store, :append]
# Fact store write
[:runic, :runner, :store, :save_fact]
# Rehydration classification
[:runic, :runner, :rehydration, :classify]  # measurements: hot_count, cold_count, total_facts
# Fact resolution (cold → hot)
[:runic, :runner, :fact, :resolve]
```

---

## Interaction with Runner Scheduling Doc

### Promise model compatibility

Promises (Phase C in the scheduling doc) execute multiple runnables within a single task context. For checkpointing:

- **Journal events within a Promise:** The Promise's local workflow copy accumulates journal events as runnables execute. When the Promise resolves and the Worker applies results, these journal events are merged into the source-of-truth workflow's journal.
- **Checkpoint boundaries:** Checkpoints happen at Promise completion, not between individual runnables within a Promise. This is natural — the Worker's `handle_task_result` triggers `maybe_checkpoint` once per completed dispatch unit.

### Executor behaviour compatibility

The Executor behaviour (Phase A in scheduling doc) dispatches `work_fn` closures. The fact resolution happens before the closure is constructed (in Worker's `dispatch_runnables`), so the Executor never sees FactRefs — it receives resolved Facts inside Runnables.

For remote Executors (Oban, distributed) that serialize Runnables:
- Fact values are serialized with the Runnable (they're already resolved)
- The remote side doesn't need access to the fact store for execution
- Only the coordinating Worker needs the resolver

### Sticky execution synergy

Sticky execution (Strategy 4) keeps the workflow in memory. The hybrid classification can drive **runtime eviction** — when a Worker's memory exceeds a threshold, classify and evict cold facts to FactRefs. This is a natural extension of Phase 4's classifier used at runtime instead of only at rehydration.

---

## Phasing Summary

```
Phase 1: FactRef + Fact Store API          ← Foundation, no behavior change
  │
  ├── Phase 2: Journal + Incremental       ← Highest impact for production
  │     Checkpointing
  │     │
  │     └── Phase 3: FactRefs in Journal   ← Value separation, memory savings
  │           │
  │           ├── Phase 4: Lineage          ← Smart rehydration
  │           │     Classification
  │           │
  │           └── Phase 5: Worker           ← Full integration
  │                 Integration
  │
  └── (Future) Runtime eviction, Snapshot+WAL, Distribution
```

Each phase is independently testable and shippable. Phase 1 + 2 alone provide significant value for production workflows. Phase 3-5 build toward the full hybrid rehydration vision.

---

## Open Decisions

### OD-1: Journal event granularity

Should every `draw_connection` call produce a journal event, or should we batch related edge operations? For example, `Invokable.apply_fn` typically calls `log_fact` + `draw_connection(:produced)` + `mark_runnable_as_ran` + `prepare_next_runnables` (which calls `draw_connection(:runnable)` for each next step). This produces 4+ journal events for a single runnable completion.

**Recommendation:** Fine-grained events. Batching adds complexity and the journal is append-only — readers can batch on replay if needed. Individual events are also more useful for debugging and audit.

### OD-2: Journal compaction

When does the journal get compacted (merged into a single snapshot)? Options:
- Never (pure append-only, rely on store-level compaction)
- On explicit `continue_as_new` API call (Temporal-style)
- After N events (configurable threshold)
- On Worker stop/drain

**Recommendation:** Start with "on explicit call" and "on Worker stop". Add threshold-based compaction later as a checkpoint strategy option.

### OD-3: Fact value deduplication

Multiple runnables may produce facts with the same input value hash (e.g., shared constants). `save_fact/3` is idempotent, so duplicates are harmless but waste I/O.

**Recommendation:** Let the store adapter handle deduplication (ETS/Mnesia upsert is naturally idempotent). Don't add dedup logic to the Worker.

### OD-4: Resolver cache lifetime

Should the resolver cache persist across Worker restarts, or is it rebuilt from scratch on each recovery?

**Recommendation:** Rebuild from scratch. The hybrid classifier already identifies the hot set, and preloading is fast (bounded by hot set size, not total fact count). Persisting the cache adds complexity without proportional benefit.

### OD-5: `vertex_id_of` for FactRef

How should `Components.vertex_id_of/1` handle FactRef? Options:
- Return `ref.hash` (same as Fact — vertex identity by hash)
- Return `{:ref, ref.hash}` (distinct from Fact — two vertices)

**Recommendation:** Return `ref.hash` (same identity). A FactRef is a placeholder for the same logical fact. When hot-loading resolves a FactRef to a Fact, the vertex identity doesn't change.
