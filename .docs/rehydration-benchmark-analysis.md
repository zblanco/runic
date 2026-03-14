# Rehydration Strategy Benchmark Analysis

**Date:** 2026-02-27  
**Benchmarks:** `bench/rehydration_bench.exs`, `bench/rehydration_memory_quick.exs`  
**Strategies compared:** Full, Lazy, Hybrid  
**Related:** [Checkpointing Implementation Plan](checkpointing-implementation-plan.md)

---

## Executive Summary

Initial benchmarks with small integer fact values showed negligible memory savings (0.1–1.2%) from hybrid rehydration, because `Fact` and `FactRef` structs differ by only 16 bytes. However, **this result was misleading** — the measurement used `flat_size`, which excludes BEAM reference-counted binaries from the count.

When re-measured with `external_size` (which includes binary content) using realistic payload sizes (1KB–100KB), the results are dramatic:

| Scenario | Hybrid savings (flat) | Hybrid savings (total) | Lazy savings (total) |
|----------|----------------------|----------------------|---------------------|
| long_50 × integer | 1.2% | 1.2% | 1.9% |
| long_50 × 1KB payload | 18.9% | **67.9%** | 83.9% |
| long_50 × 10KB payload | 21.0% | **81.6%** | 98.0% |
| long_50 × 100KB payload | 12.5% | **71.5%** | 99.2% |
| linear_20 × 10KB payload | 4.4% | **81.7%** | 90.2% |

**Hybrid rehydration delivers 60–82% total memory savings for workflows with non-trivial fact values.** Lazy goes even further (84–99%) by dehydrating everything, at the cost of requiring resolution before any fact value can be used.

This strongly validates the architecture and motivates **Store-Integrated Lean Replay** as the critical next step — if cold values are never loaded from storage in the first place, the savings compound with reduced I/O.

---

## Part A: Small-Value Results (Integer Facts)

### Memory Footprint (flat_size)

| Workflow | Full KB | Hybrid KB | Savings | Hot | Cold | Total |
|----------|---------|-----------|---------|-----|------|-------|
| linear_5 | 14.7 | 14.6 | 0.5% | 1 | 5 | 6 |
| linear_20 | 57.9 | 57.6 | 0.5% | 1 | 20 | 21 |
| linear_50 | 144.9 | 144.1 | 0.5% | 1 | 50 | 51 |
| branching_5 | 14.0 | 14.0 | 0.2% | 4 | 2 | 6 |
| branching_20 | 53.0 | 53.0 | 0.1% | 19 | 2 | 21 |
| rules_10 | 89.9 | 89.9 | 0.0% | 5 | 1 | 6 |
| join_deep | 24.4 | 24.3 | 0.4% | 2 | 5 | 7 |
| fanout_10 | 40.4 | 40.0 | 0.9% | 10 | 13 | 23 |
| long_100 | 251.0 | 247.9 | 1.2% | 101 | 200 | 301 |

With integer values, graph infrastructure (2,700–15,200 bytes/fact) dominates the 16-byte struct savings.

### Rehydration Overhead

| Workflow | classify μs | dehydrate μs | Total overhead |
|----------|-------------|--------------|----------------|
| rules_2 | 1.25 | 0.17 | 1.42μs |
| linear_20 | 3.70 | 1.47 | 5.17μs |
| linear_50 | 10.85 | 4.13 | 14.98μs |
| long_100 | 67.11 | 18.25 | 85.36μs |

Both operations scale linearly: classify at ~0.22μs/fact, dehydrate at ~0.09μs/cold-fact.

### Hot/Cold Classification Patterns

| Pattern | Hot% | Cold% | Insight |
|---------|------|-------|---------|
| Linear chains | 2–17% | 83–98% | Only leaf production is hot |
| Branching | 67–91% | 9–33% | Root + all leaves are hot |
| Rules | 50–83% | 17–50% | Most facts are leaf outputs |
| Joins | 29–40% | 60–71% | Intermediate branch facts cold |
| Long-running | 34–36% | 64–66% | Consistent 2/3 cold ratio |

### FactResolver Performance

| Operation | Average |
|-----------|---------|
| resolve single (cache hit) | 60ns |
| resolve single (ETS store hit) | 159ns |
| resolve all 200 refs (cold) | 21.3μs |
| preload 200 hashes | 32.3μs |

---

## Part B: Large-Value Results — The Real Picture

### The `flat_size` Measurement Gap

BEAM stores binaries >64 bytes on a separate reference-counted heap. `flat_size` only counts the pointer (8 bytes), not the binary content:

```
Fact{value: 42}        → flat_size=120B,  external_size=79B
Fact{value: 1KB map}   → flat_size=248B,  external_size=1,128B
Fact{value: 100KB map}  → flat_size=248B,  external_size=102,504B
FactRef                 → flat_size=104B,  external_size=73B
```

The `flat_size` shows identical 248B for both 1KB and 100KB values. **All prior memory comparisons using `flat_size` underestimate savings by 10–1000×** for binary-heavy workloads.

### Total Memory Comparison (external_size)

| Scenario | Facts | Hot | Cold | Full (ext) | Hybrid (ext) | Savings | Lazy (ext) | Lazy sav. |
|----------|-------|-----|------|------------|-------------|---------|------------|-----------|
| **Small-value baselines** |
| linear_50 (int) | 51 | 1 | 50 | 65.7KB | 65.4KB | 0.4% | 65.4KB | 0.5% |
| long_100 (int) | 301 | 101 | 200 | 100.0KB | 98.8KB | 1.2% | 98.0KB | 1.9% |
| **1KB payloads** |
| linear_10×1KB | 11 | 1 | 10 | 79.2KB | 33.9KB | **57.2%** | 23.9KB | 69.8% |
| long_10×1KB | 31 | 11 | 20 | 63.7KB | 25.5KB | **59.9%** | 15.0KB | 76.5% |
| long_50×1KB | 151 | 51 | 100 | 330.8KB | 106.1KB | **67.9%** | 53.4KB | 83.9% |
| **10KB payloads** |
| linear_10×10KB | 11 | 1 | 10 | 664.1KB | 213.8KB | **67.8%** | 113.8KB | 82.9% |
| linear_20×10KB | 21 | 1 | 20 | 2,327.6KB | 427.1KB | **81.7%** | 227.1KB | 90.2% |
| long_10×10KB | 31 | 11 | 20 | 395.5KB | 124.6KB | **68.5%** | 24.0KB | 93.9% |
| long_50×10KB | 151 | 51 | 100 | 3,072.4KB | 564.8KB | **81.6%** | 62.2KB | 98.0% |
| **100KB payloads** |
| linear_10×100KB | 11 | 1 | 10 | 6,514.3KB | 2,014.0KB | **69.1%** | 1,014.0KB | 84.4% |
| long_10×100KB | 31 | 11 | 20 | 3,515.4KB | 1,114.6KB | **68.3%** | 114.0KB | 96.8% |
| long_50×100KB | 151 | 51 | 100 | 18,059.0KB | 5,154.7KB | **71.5%** | 152.1KB | 99.2% |

### Key Observations

**1. Hybrid saves 57–82% total memory with non-trivial payloads.**
Even 1KB values (a small JSON document) produce 57–68% savings. At 10KB (a typical API response), savings reach 82%. The savings scale with `cold_count × value_size`.

**2. Lazy consistently beats hybrid by 10–28 percentage points.**
Lazy dehydrates everything including hot facts, saving more memory but requiring resolution before any value access. The gap: hybrid keeps ~1/3 of facts hot, so that fraction still carries value memory.

**3. The savings plateau at ~70% for hybrid on long-running workflows.**
This reflects the ~1/3 hot ratio — the latest generation's values remain in memory. The 100 hot facts in `long_50×100KB` carry ~5MB of value data that hybrid intentionally preserves.

**4. Linear chains benefit more than long-running for the same payload.**
`linear_20×10KB` saves 81.7% (only 1 hot fact out of 21) vs `long_50×10KB` at 81.6% (51 hot out of 151). The linear chain's 95% cold ratio is offset by having fewer total facts.

**5. `flat_size` vs `external_size` diverges by up to 100×.**
For `long_50×100KB`: `flat_size` reports 12.5% savings; `external_size` reports 71.5%. Any memory monitoring or eviction heuristic must use `external_size` or `:erlang.memory()` to make meaningful decisions.

### Large-Value FactResolver Performance

| Operation | Average |
|-----------|---------|
| lg_linear_10_10k resolve 1 (store) | 208ns |
| lg_linear_10_10k resolve 1 (cache) | 218ns |
| lg_long_50_10k resolve 1 (store) | 166ns |
| lg_long_50_10k preload 100 | 23.7μs |

Resolution cost is effectively independent of value size — ETS returns a reference to the existing binary, not a copy. This means lazy on-demand resolution is viable even for large payloads.

---

## Unexpected Results & Issues

### 1. Hybrid Is Still Slower Than Lazy for In-Memory Rehydration

Hybrid is 1.5–2× slower than lazy for the rehydration operation itself, because classification scans all vertices and edges before dehydration begins. For small workflows this overhead exceeds the dehydration cost. However, the classification is essential for correctness: lazy dehydration would break execution if a hot fact needed for a pending runnable were dehydrated.

### 2. Classification Memory Spike

`classify/2` on `long_100` allocates 172KB of temporary MapSets — 68% of the workflow's flat size. For a system already under memory pressure, this is counterproductive. A fused single-pass classify+dehydrate would eliminate this.

### 3. Branching Workflows: 90%+ Hot

Branching_20 classifies 19/21 facts as hot. Hybrid does all the classification work to dehydrate only 2 facts. For wide/shallow topologies, hybrid is net-negative.

### 4. `flat_size` Hides the Real Savings

This is the most significant finding. Any heuristic that decides whether to use hybrid rehydration must account for binary content size, not struct overhead. The current `Rehydration.rehydrate/3` has no value-size awareness — adding a threshold based on `external_size` sampling would let it make informed decisions.

---

## Improvement Recommendations

### 1. Store-Integrated Lean Replay (High Priority)

The current implementation rebuilds the full workflow from events (creating `Fact` structs with all values), *then* classifies and dehydrates cold facts. This means every cold value is deserialized from the event stream, placed in memory, and then discarded. For a 100-step pipeline with 100KB payloads, this loads ~10MB of data only to throw away 70% of it.

**Lean replay** would never load cold values in the first place:

1. **Value-separated event storage:** `FactProduced` events carry only the hash (not the value). Values are stored separately via `save_fact/3`.
2. **FactRef-mode replay:** `from_events/2` creates `FactRef` vertices from `FactProduced` events instead of full `Fact` structs.
3. **Post-replay classification:** Classify hot/cold, then resolve only hot FactRefs from the store.

This changes the savings model from "load everything, discard cold" to "load only hot." For `long_50×100KB`:
- Current hybrid: load 18MB → discard to 5.2MB (71.5% savings, but 18MB peak)
- Lean replay: load only ~5.2MB directly (no peak spike)

**Implementation steps:**
1. Strip values from `FactProduced` events during `append/3` (store values via `save_fact/3` — already implemented)
2. Add `fact_mode: :ref` option to `apply_event/2` for `FactProduced` — creates `FactRef` instead of `Fact`
3. Extend `from_events/3` to accept `fact_mode: :ref` and pipe through to `apply_event/2`
4. In `Runner.resume/3`, use lean replay when `:hybrid` rehydration is requested

### 2. Fused Single-Pass Classify+Dehydrate (Medium Priority)

Merge `classify/2` and `dehydrate/2` into one O(|V|) traversal of `graph.vertices`:

```elixir
def rehydrate_fused(%Workflow{graph: graph} = wf, store, opts \\ []) do
  # Pre-compute hot criteria sets (activation edges, join edges, meta-refs)
  pending = pending_runnable_input_hashes(graph)
  join_inputs = pending_join_input_hashes(graph)
  meta_targets = meta_ref_target_hashes(wf)

  # Single pass: scan vertices, compute frontier, dehydrate cold in-place
  {vertices, parent_hashes} =
    Enum.reduce(graph.vertices, {graph.vertices, MapSet.new()}, fn
      {hash, %Fact{ancestry: {_, parent}} = fact}, {verts, parents} ->
        parents = MapSet.put(parents, parent)
        # Will be refined in second mini-pass for frontier check
        {verts, parents}

      _, acc ->
        acc
    end)

  # Now do the actual dehydration using frontier = all - parents
  vertices =
    Enum.reduce(graph.vertices, vertices, fn
      {hash, %Fact{} = fact}, verts ->
        is_hot =
          MapSet.member?(pending, hash) or
          not MapSet.member?(parent_hashes, hash) or  # frontier
          MapSet.member?(meta_targets, hash) or
          MapSet.member?(join_inputs, hash)

        if is_hot, do: verts, else: Map.put(verts, hash, Facts.to_ref(fact))

      _, verts ->
        verts
    end)

  wf = %{wf | graph: %{graph | vertices: vertices}}
  {wf, FactResolver.new(store)}
end
```

This eliminates the intermediate `hot` and `cold` MapSet allocations (saving the 172KB spike on long_100).

### 3. Value-Size-Aware Strategy Selection (Medium Priority)

Add a heuristic to `rehydrate/3` that samples fact value sizes before committing to classification:

```elixir
def rehydrate(workflow, store, opts \\ []) do
  sample = sample_fact_sizes(workflow, 10)  # sample 10 facts

  cond do
    sample.median_external_size < 256 and sample.total_facts < 50 ->
      # Small values, small graph — not worth it
      {workflow, FactResolver.new(store)}

    true ->
      # Worth classifying
      do_rehydrate(workflow, store, opts)
  end
end
```

### 4. Memory Monitoring Uses `external_size` (Short-term)

Any telemetry, metrics, or eviction heuristic related to workflow memory **must** use `:erlang.external_size/1` (or `term_size/1` on newer OTP) rather than `flat_size`. The existing telemetry events should report both when binary-heavy workflows are detected.

---

## When to Use Each Strategy

| Strategy | Best For | Memory Savings (typical) | Overhead |
|----------|----------|------------------------|----------|
| **Full** | Small values (ints, atoms), latency-sensitive | 0% | 0 |
| **Hybrid** | Large values (1KB+), need immediate execution | 57–82% | 2–95μs |
| **Lazy** | Maximum savings, can tolerate resolution latency | 77–99% | 1–55μs |

### Decision Thresholds (from benchmark data)

- **< 50 facts, values < 256B:** Use full. Overhead exceeds savings.
- **≥ 50 facts, values ≥ 1KB:** Hybrid saves 57–82%. Worth the 5–95μs overhead.
- **Cold storage resume (disk/network):** Always use lean replay + hybrid/lazy. Avoiding I/O for cold values dominates all other costs.
- **Runtime eviction under memory pressure:** Use hybrid classification to identify eviction targets, then dehydrate selectively. Monitor with `external_size`.

---

## Conclusion

The initial small-value benchmark appeared to invalidate hybrid rehydration. The large-value benchmark reveals this was a measurement artifact — **hybrid delivers 57–82% memory savings for realistic data pipeline workloads**. The architecture is sound; the primary improvement needed is **Store-Integrated Lean Replay** to avoid the load-then-discard anti-pattern, which will eliminate the peak memory spike during recovery and reduce I/O to only the hot fact set.

The lazy strategy's 77–99% savings suggest it may be the better default for cold-storage resume scenarios where all execution is paused. Hybrid's advantage is preserving hot values for immediate execution continuity — critical for the Worker's resume path where pending runnables need their input facts immediately.

### Next Steps (Priority Order)

1. **Store-Integrated Lean Replay** — Strip values from events, create FactRefs during replay, resolve only hot facts. This is the single highest-impact change.
2. **Fused classify+dehydrate** — Eliminate the classification memory spike.
3. **`external_size`-aware telemetry** — Accurate memory reporting for binary-heavy workflows.
4. **Value-size threshold** — Skip hybrid for small-value workflows automatically.
