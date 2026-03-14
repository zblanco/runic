# Lean Replay & Rehydration Optimizations — Implementation Plan

**Status:** Draft  
**Date:** 2026-02-27  
**Depends on:** [Checkpointing Implementation Plan](checkpointing-implementation-plan.md), [Benchmark Analysis](rehydration-benchmark-analysis.md)  
**Goal:** Eliminate the load-then-discard anti-pattern and reduce peak memory during recovery

---

## Motivation

The current hybrid rehydration path does this:

```
stream events → from_events() builds full Fact structs (peak: 18MB)
             → classify hot/cold
             → dehydrate cold → discard values (settle: 5.2MB)
```

Every cold fact value is deserialized from the event stream, allocated in memory, and
immediately discarded. For `long_50×100KB`, peak memory is 18MB but steady-state is
5.2MB — a 3.5× spike. Lean replay eliminates the spike entirely by never loading
cold values in the first place.

Additionally, the current `classify/2` + `dehydrate/2` two-pass approach allocates
intermediate MapSets that reach 68% of workflow flat_size on `long_100`. A fused
single-pass eliminates this allocation spike.

---

## Improvement 1: Store-Integrated Lean Replay (High Priority)

### 1.1 Overview

The core idea is three-fold:

1. **Value-separated persistence:** When appending `FactProduced` events, strip the
   `value` field and persist it separately via `save_fact/3`. The event stream
   carries only `{hash, ancestry, producer_label, weight}`.

2. **Lean replay mode:** `from_events/2` accepts a `fact_mode: :ref` option that
   makes `apply_event/2` create `FactRef` vertices from `FactProduced` events
   instead of full `Fact` structs.

3. **Post-replay hot resolution:** After lean replay produces a topology-only graph,
   classify hot/cold, then resolve only hot `FactRef`s back to full `Fact`s via
   the store's `load_fact/2`.

Target flow:

```
stream events (values stripped) → from_events(events, fact_mode: :ref)
                                → graph has FactRef vertices (low memory)
                                → classify hot/cold
                                → resolve hot FactRefs via store (load only ~1/3)
                                → ready for execution
```

### 1.2 Value Stripping in Worker Persistence

**File:** `lib/runic/runner/worker.ex`  
**Function:** `handle_task_result/4`

Currently, `flush_pending_facts/2` already persists fact values to the content-addressed
store before checkpointing events. The change is to also strip values from
`FactProduced` events before they enter `uncommitted_events`:

```elixir
# In handle_task_result/4, after flush_pending_facts:
lean_events = strip_fact_values(all_new_events)
```

New private function:

```elixir
defp strip_fact_values(events) do
  Enum.map(events, fn
    %FactProduced{} = e -> %{e | value: nil}
    other -> other
  end)
end
```

**Key invariant:** `flush_pending_facts/2` runs *before* stripping, ensuring values
are persisted to the fact store before being removed from the event stream.

**Backward compatibility:** Stores that don't implement `save_fact/3` should NOT
strip values — they need self-contained events for `from_events/2` to work. Guard
the stripping on `function_exported?(store_mod, :save_fact, 3)`.

```elixir
lean_events =
  if function_exported?(store_mod, :save_fact, 3) do
    strip_fact_values(all_new_events)
  else
    all_new_events
  end
```

**Risk:** Low. This is a one-line map over events at persist time. The in-memory
workflow is unaffected — only the persisted event stream loses values.

### 1.3 Lean Replay Mode in `apply_event/2`

**File:** `lib/workflow.ex`  
**Function:** `apply_event/2` for `FactProduced`

Add a new `apply_event/3` clause that accepts options, or thread options through
`from_events/3`. The cleaner approach is a new `apply_event_lean/2` that creates
`FactRef` instead of `Fact`:

```elixir
# In Workflow module — new function for lean replay
defp apply_event_lean(%__MODULE__{} = wf, %FactProduced{} = e) do
  ref = %FactRef{hash: e.hash, ancestry: e.ancestry}
  wf = log_fact(wf, ref)

  case e.ancestry do
    {producer_hash, _parent_fact_hash} ->
      producer = Map.get(wf.graph.vertices, producer_hash)

      if producer do
        draw_connection(wf, producer, ref, e.producer_label, weight: e.weight || 0)
      else
        wf
      end

    nil ->
      wf
  end
end
```

The `log_fact/2` and `draw_connection/5` functions operate on vertex hashes, so
`FactRef` works identically to `Fact` for graph topology. This has already been
validated by the `dehydrate/2` path which swaps `Fact` → `FactRef` in the vertices
map without edge changes.

**Compatibility check:** Verify that `log_fact/2` handles `FactRef` inputs. It
likely uses `Facts.hash/1` or pattern matches on `%{hash: h}` — both work for
`FactRef`. If it accesses `.value`, that needs a guard.

### 1.4 Extend `from_events/2` to Accept Replay Options

**File:** `lib/workflow.ex`  
**Function:** `from_events/2`

Add a third arity with options:

```elixir
@spec from_events(Enumerable.t(), t() | nil, keyword()) :: t()
def from_events(events, base_workflow \\ nil, opts \\ [])
```

The `fact_mode` option controls which `apply_event` path is used:

```elixir
fact_mode = Keyword.get(opts, :fact_mode, :full)

Enum.reduce(runtime_events, base, fn event, wf ->
  case {fact_mode, event} do
    {:ref, %FactProduced{}} -> apply_event_lean(wf, event)
    _ -> apply_event(wf, event)
  end
end)
```

Only `FactProduced` events are affected — all other event types (`ActivationConsumed`,
`RunnableActivated`, `ConditionSatisfied`, etc.) pass through `apply_event/2`
unchanged, since they reference facts by hash and don't create vertices.

### 1.5 Post-Replay Hot Resolution

**File:** `lib/workflow/rehydration.ex`  
**New function:** `resolve_hot/3`

After lean replay produces a graph with all `FactRef` vertices, classify hot/cold
and resolve only hot refs:

```elixir
@doc """
Resolves hot FactRef vertices back to full Fact structs.

Used after lean replay to load only the values needed for forward execution.
Cold FactRefs remain as lightweight references.
"""
@spec resolve_hot(Workflow.t(), MapSet.t(), FactResolver.t()) :: {Workflow.t(), FactResolver.t()}
def resolve_hot(%Workflow{graph: graph} = workflow, hot_hashes, resolver) do
  # Preload all hot values in one batch
  resolver = FactResolver.preload(resolver, MapSet.to_list(hot_hashes))

  vertices =
    Enum.reduce(hot_hashes, graph.vertices, fn hash, vertices ->
      case Map.get(vertices, hash) do
        %FactRef{} = ref ->
          case FactResolver.resolve(ref, resolver) do
            {:ok, fact} -> Map.put(vertices, hash, fact)
            {:error, _} -> vertices  # leave as ref if store miss
          end

        _ ->
          vertices
      end
    end)

  {%{workflow | graph: %{graph | vertices: vertices}}, resolver}
end
```

### 1.6 Integrate into `Runner.resume/3`

**File:** `lib/runic/runner.ex`  
**Function:** `resume/3`

The resume path currently does:

```elixir
workflow = Workflow.from_events(Enum.to_list(event_stream))
# then optionally: Rehydration.rehydrate(workflow, store)
```

With lean replay, the `:hybrid` path becomes:

```elixir
case rehydration do
  :full ->
    # Legacy: full replay with values (events may carry values from old stores)
    workflow = Workflow.from_events(Enum.to_list(event_stream))
    {workflow, nil}

  :hybrid ->
    # Lean replay: create FactRefs, classify, resolve only hot
    workflow = Workflow.from_events(Enum.to_list(event_stream), nil, fact_mode: :ref)
    %{hot: hot} = Rehydration.classify(workflow)
    resolver = FactResolver.new({store_mod, store_state})
    {workflow, resolver} = Rehydration.resolve_hot(workflow, hot, resolver)
    {workflow, resolver}

  :lazy ->
    # Everything stays as FactRef, resolve on demand
    workflow = Workflow.from_events(Enum.to_list(event_stream), nil, fact_mode: :ref)
    {workflow, FactResolver.new({store_mod, store_state})}
end
```

### 1.7 Handling Mixed Event Streams (Migration)

Existing event streams may contain `FactProduced` events **with** values (persisted
before lean replay was enabled). The lean replay path must handle both:

- `%FactProduced{value: nil}` → create `FactRef` (lean mode)
- `%FactProduced{value: some_value}` → still create `FactRef` in `:ref` mode,
  but cache the value in the resolver for hot resolution

This means `apply_event_lean/2` should optionally populate the resolver cache when
a value is present. However, `apply_event_lean` doesn't have access to the resolver.

**Resolution:** Handle this at the `from_events/3` level. When `fact_mode: :ref`,
do a pre-pass to extract values from events that carry them:

```elixir
# In from_events/3, when fact_mode: :ref
pre_cache =
  for %FactProduced{hash: h, value: v} <- runtime_events,
      not is_nil(v),
      into: %{},
      do: {h, v}
```

Pass `pre_cache` to the caller (via the opts or return value) so the resolver
can be seeded with these values. This handles the migration window where some
events have values and some don't.

**Simpler alternative:** In `fact_mode: :ref`, if a `FactProduced` event carries
a non-nil value, create a full `Fact` instead of a `FactRef`. This avoids the
cache complexity and naturally handles mixed streams — cold facts with values
get dehydrated by the classify+dehydrate step; lean events (nil value) are already
refs. This is the recommended approach for simplicity:

```elixir
defp apply_event_lean(%__MODULE__{} = wf, %FactProduced{value: nil} = e) do
  # Lean event: value was stripped, create FactRef
  ref = %FactRef{hash: e.hash, ancestry: e.ancestry}
  # ... draw_connection as above
end

defp apply_event_lean(%__MODULE__{} = wf, %FactProduced{} = e) do
  # Legacy event with value: create full Fact, will be dehydrated if cold
  apply_event(wf, e)
end
```

### 1.8 Testing Strategy

1. **Unit: value stripping**
   - `strip_fact_values/1` removes values from `FactProduced`, preserves other events
   - Round-trip: produce → flush facts → strip → persist → stream → lean replay → classify → resolve hot → verify execution matches full replay

2. **Unit: `apply_event_lean/2`**
   - `FactProduced` with `value: nil` creates `FactRef` vertex
   - `FactProduced` with value creates full `Fact` (migration path)
   - Graph topology (edges, ancestry) matches full replay

3. **Integration: `from_events/3` with `fact_mode: :ref`**
   - Linear pipeline: lean replay → classify → resolve → execute → same results as full
   - Mixed stream: some events with values, some without → correct graph

4. **Integration: `Runner.resume/3` with `rehydration: :hybrid`**
   - Start workflow → run several inputs → checkpoint → resume with lean → verify execution continues correctly

5. **Memory: peak reduction**
   - Measure peak memory during lean replay vs full replay for `long_50×10KB`
   - Verify peak ≈ steady-state (no spike)

### 1.9 File Change Summary

| File | Change | Risk |
|------|--------|------|
| `lib/runic/runner/worker.ex` | Strip values from events after `flush_pending_facts` | Low — guarded on `save_fact/3` support |
| `lib/workflow.ex` | Add `apply_event_lean/2`, extend `from_events` to accept `fact_mode` | Medium — new code path |
| `lib/workflow/rehydration.ex` | Add `resolve_hot/3` | Low — additive |
| `lib/runic/runner.ex` | Update `resume/3` to use lean replay for `:hybrid`/`:lazy` | Medium — changes recovery path |
| `lib/workflow/events/fact_produced.ex` | No change (value already nullable) | None |

---

## Improvement 2: Fused Single-Pass Classify+Dehydrate (Medium Priority)

### 2.1 Problem

`classify/2` allocates four intermediate `MapSet`s (`all_fact_hashes`, `parent_hashes`,
`hot`, `cold`). On `long_100` (301 facts), this is 172KB of temporary allocations —
68% of the workflow's flat_size. For a system under memory pressure, the classification
itself can push it over the edge.

### 2.2 Approach

Replace the two-function `classify/2` + `dehydrate/2` with a single `rehydrate_fused/3`
that computes hot criteria and dehydrates in one traversal of `graph.vertices`.

The challenge: frontier detection requires knowing *all* parent hashes before deciding
if a fact is on the frontier. This requires either:

- **Two mini-passes over vertices** (scan parents, then dehydrate) — still cheaper
  than the current approach because we skip the intermediate `hot`/`cold` MapSets
- **Single pass with deferred dehydration** — collect parent hashes and dehydration
  candidates simultaneously, then do a final cheap sweep

The two-mini-pass approach is cleaner:

### 2.3 Implementation

**File:** `lib/workflow/rehydration.ex`  
**New function:** `rehydrate_fused/3`

```elixir
@doc """
Single-pass classify+dehydrate. Avoids intermediate hot/cold MapSet allocations.

Pass 1: Scan vertices to collect parent hashes (needed for frontier detection).
         Also pre-compute edge-based hot criteria (pending, join, meta-ref).
Pass 2: Iterate vertices, check hot criteria inline, dehydrate cold in-place.
"""
@spec rehydrate_fused(Workflow.t(), {module(), term()}, keyword()) ::
        {Workflow.t(), FactResolver.t()}
def rehydrate_fused(%Workflow{graph: graph} = workflow, store, _opts \\ []) do
  # Pre-compute edge-based hot sets (these are small — bounded by active edges)
  pending = pending_runnable_input_hashes(graph)
  join_inputs = pending_join_input_hashes(graph)
  meta_targets = meta_ref_target_hashes(workflow)

  # Pass 1: collect parent hashes from ancestry tuples — O(|V|)
  parent_hashes =
    Enum.reduce(graph.vertices, MapSet.new(), fn
      {_hash, %Fact{ancestry: {_, parent}}}, parents -> MapSet.put(parents, parent)
      {_hash, %FactRef{ancestry: {_, parent}}}, parents -> MapSet.put(parents, parent)
      _, parents -> parents
    end)

  # Pass 2: dehydrate cold facts inline — O(|V|)
  vertices =
    Enum.reduce(graph.vertices, graph.vertices, fn
      {hash, %Fact{} = fact}, verts ->
        is_hot =
          MapSet.member?(pending, hash) or
            not MapSet.member?(parent_hashes, hash) or
            MapSet.member?(meta_targets, hash) or
            MapSet.member?(join_inputs, hash)

        if is_hot, do: verts, else: Map.put(verts, hash, Facts.to_ref(fact))

      _, verts ->
        verts
    end)

  workflow = %{workflow | graph: %{graph | vertices: vertices}}
  {workflow, FactResolver.new(store)}
end
```

### 2.4 Allocation Savings

**Eliminated:**
- `all_fact_hashes` MapSet (one entry per fact)
- `hot` MapSet (union of 4 categories)
- `cold` MapSet (difference of all - hot)

**Retained:**
- `parent_hashes` MapSet (unavoidable for frontier detection)
- `pending`, `join_inputs`, `meta_targets` (edge-indexed, typically small)

For `long_100`: eliminates ~100KB of intermediate allocations (the `all_fact_hashes`
and `cold` sets each held 301 and 200 entries respectively).

### 2.5 API Decision

Keep `classify/2` and `dehydrate/2` as public API for callers that need the
classification breakdown (telemetry, debugging). Add `rehydrate_fused/3` as the
optimized path. Update `rehydrate/3` to delegate to the fused version:

```elixir
def rehydrate(%Workflow{} = workflow, store, opts \\ []) do
  rehydrate_fused(workflow, store, opts)
end
```

### 2.6 Testing

- Verify `rehydrate_fused/3` produces identical results to `classify/2` + `dehydrate/2`
  across all benchmark workflow shapes
- Property test: for any workflow, `rehydrate_fused` and `rehydrate` (old path) produce
  the same set of `FactRef` hashes in the output graph
- Memory benchmark: measure peak allocation during fused vs. two-pass on `long_100`

---

## Improvement 3: Value-Size-Aware Strategy Selection (Medium Priority)

### 3.1 Problem

Hybrid rehydration overhead exceeds savings for small-value/small-graph workflows.
`branching_20` classifies 19/21 facts as hot — doing all the classification work
to dehydrate only 2 facts. The benchmark shows 0.1% savings for integer values.

### 3.2 Approach

Add a size-sampling heuristic to `rehydrate/3` that skips classification for
workflows where the overhead isn't justified.

### 3.3 Implementation

**File:** `lib/workflow/rehydration.ex`  
**New function:** `should_rehydrate?/2`

```elixir
@doc """
Heuristic check: returns true if hybrid rehydration is likely to produce
meaningful memory savings for this workflow.

Samples a small number of fact values and checks total fact count against
thresholds derived from benchmark data.
"""
@spec should_rehydrate?(Workflow.t(), keyword()) :: boolean()
def should_rehydrate?(%Workflow{graph: graph}, opts \\ []) do
  min_facts = Keyword.get(opts, :min_facts, 50)
  min_value_bytes = Keyword.get(opts, :min_value_bytes, 256)
  sample_size = Keyword.get(opts, :sample_size, 10)

  facts =
    graph.vertices
    |> Map.values()
    |> Enum.filter(&is_struct(&1, Fact))

  total_facts = length(facts)

  if total_facts < min_facts do
    false
  else
    # Sample fact values for external_size
    sample =
      facts
      |> Enum.take_random(sample_size)
      |> Enum.map(fn %Fact{value: v} -> :erlang.external_size(v) end)

    case sample do
      [] -> false
      sizes -> Enum.sum(sizes) / length(sizes) >= min_value_bytes
    end
  end
end
```

Update `rehydrate/3` to use the heuristic:

```elixir
def rehydrate(%Workflow{} = workflow, store, opts \\ []) do
  skip_heuristic = Keyword.get(opts, :force, false)

  if skip_heuristic or should_rehydrate?(workflow, opts) do
    rehydrate_fused(workflow, store, opts)
  else
    # Not worth it — return workflow unchanged with a resolver for on-demand use
    {workflow, FactResolver.new(store)}
  end
end
```

### 3.4 Threshold Justification (from benchmarks)

| Threshold | Rationale |
|-----------|-----------|
| `min_facts: 50` | Below 50 facts, classification overhead (5-15μs) exceeds struct savings even at 1KB values |
| `min_value_bytes: 256` | Below 256B, Fact→FactRef saves only 16 bytes/struct. At 256B+, external_size savings dominate |
| `sample_size: 10` | 10 samples is sufficient for a representative median. Sampling cost: ~1μs |

### 3.5 Lean Replay Interaction

When using lean replay (`fact_mode: :ref`), the heuristic is irrelevant — values are
already absent from the graph. The heuristic applies only to the in-memory dehydration
path (legacy stores or full replay).

### 3.6 Testing

- Verify small-value workflows skip classification
- Verify large-value workflows proceed with classification
- Verify `:force` option bypasses the heuristic
- Benchmark: confirm heuristic sampling adds < 5μs overhead

---

## Improvement 4: `external_size`-Aware Memory Monitoring (Low Priority)

### 4.1 Problem

`:erts_debug.flat_size/1` excludes reference-counted binaries >64B. For workflows
with 10KB+ values, flat_size reports 12.5% savings while actual total memory savings
are 71.5%. Any telemetry, eviction, or monitoring heuristic using flat_size is
misleading.

### 4.2 Approach

Add telemetry events from `Rehydration` with both `flat_size` and `external_size`
measurements. This is informational — no behavior change.

### 4.3 Implementation

**File:** `lib/runic/runner/worker.ex` (or a new telemetry helper)

Add telemetry emission after rehydration in the resume path:

```elixir
:telemetry.execute(
  [:runic, :runner, :rehydration, :complete],
  %{
    hot_count: MapSet.size(hot),
    cold_count: MapSet.size(cold),
    total_facts: MapSet.size(hot) + MapSet.size(cold),
    flat_size_bytes: :erts_debug.flat_size(workflow) * :erlang.system_info(:wordsize),
    external_size_bytes: :erlang.external_size(workflow)
  },
  %{
    workflow_id: workflow_id,
    strategy: rehydration,
    workflow_name: workflow.name
  }
)
```

**File:** `lib/runic/runner/telemetry.ex`

Add a helper for rehydration-specific telemetry if one doesn't exist, or add to
the existing `Telemetry` module.

### 4.4 Future: Runtime Eviction

The hybrid classifier can drive runtime memory management beyond just the resume path.
When a Worker's memory exceeds a threshold (detected via `Process.info(self(), :memory)`
or a periodic timer), it can:

1. Run `classify/2` on the current workflow
2. Dehydrate cold facts
3. Persist evicted values via `save_fact/3`

This is a natural extension but should be a separate implementation once the core
lean replay path is stable.

---

## Implementation Order & Dependencies

```
┌─────────────────────────────────────────────────────┐
│  1. Store-Integrated Lean Replay                    │
│     1.2  Value stripping in Worker                  │
│     1.3  apply_event_lean/2                         │
│     1.4  from_events/3 with fact_mode               │
│     1.5  resolve_hot/3 in Rehydration               │
│     1.6  Resume path integration                    │
│     1.7  Migration: mixed event streams             │
│     1.8  Tests                                      │
├─────────────────────────────────────────────────────┤
│  2. Fused Classify+Dehydrate  (independent of #1)   │
│     2.3  rehydrate_fused/3                          │
│     2.5  Update rehydrate/3 to delegate             │
│     2.6  Tests + memory benchmark                   │
├─────────────────────────────────────────────────────┤
│  3. Value-Size Heuristic  (depends on #2)           │
│     3.3  should_rehydrate?/2                        │
│     3.3  Update rehydrate/3 with guard              │
│     3.6  Tests                                      │
├─────────────────────────────────────────────────────┤
│  4. Telemetry  (independent, do anytime)            │
│     4.3  Emit external_size measurements            │
└─────────────────────────────────────────────────────┘
```

Improvements #1 and #2 are independent and can be implemented in parallel.
Improvement #3 depends on #2 (uses `rehydrate_fused` as the hot path).
Improvement #4 is standalone telemetry work.

---

## Risk Assessment

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| `log_fact/2` doesn't handle `FactRef` input | Medium | Verify before implementing; add clause if needed |
| Mixed event stream (values + no values) during migration | High | `apply_event_lean` falls back to full `Fact` when value present |
| `draw_connection` needs `Fact.value` | Low | Already validated by `dehydrate/2` path which swaps Fact→FactRef |
| Store without `save_fact/3` gets stripped events | Medium | Guard stripping on `function_exported?` |
| Fused pass produces different hot/cold than two-pass | Low | Property test against reference implementation |
| `external_size/1` is expensive to call in hot path | Low | Only used in telemetry and sampling heuristic, not in critical path |

---

## Success Metrics

| Metric | Current | Target |
|--------|---------|--------|
| Peak memory during recovery (`long_50×100KB`) | 18MB | ≤ 6MB |
| Classify+dehydrate temp allocation (`long_100`) | 172KB | < 50KB |
| Recovery path for small workflows (< 50 facts, int values) | 5-15μs overhead | 0μs (skipped) |
| Telemetry accuracy for binary-heavy workflows | off by 10-100× | within 5% |
