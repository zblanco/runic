# Issue 19: compact preparation and bounded dispatch

This branch removes redundant mapped FanIn batch snapshots, constructs FanOut activation events in linear time, and exposes opt-in lazy activation selection before contexts are prepared. It preserves the existing coordinator as the authority for completion and ordered reduction. The runtime Worker and Scheduler grouping contract are unchanged.

## Implementation

Mapped `Invokable.prepare/3` now carries only `mode`, `source_fact_hash`, `fan_out_hash`, `expected_key`, and `seen_key` in `fan_in_context`. Hooks, meta references, runtime context, ancestry, and ordinary runnable identity remain intact. `Coordinator.finalize/3` continues to inspect the current workflow, gather ordered values once, consume sister activations, and record completion. A context prepared before the last arrival can still complete correctly when applied afterward. There is no new coordinator state or event format.

The FanIn association lookup now calls `Multigraph.in_edges(graph, fan_in, by: :fan_in)`. This branch alone still inherits the dependency's eager adjacency construction. The graph-indexes branch makes that accessor partition-local; the two changes are complementary.

FanOut activation event accumulation now prepends reversed groups and reverses once at the end. The event sequence and application order are preserved exactly. FanOut execution also drops an unnecessary `Enum.to_list/1`. It remains an eager emission barrier: all output occurrences, returned facts, and their events still exist before application.

## Optional Core API

```elixir
# Existing semantics and order, including empty options:
{wf, all} = Workflow.prepare_for_dispatch(wf)
{wf, all} = Workflow.prepare_for_dispatch(wf, [])

# Local lazy descriptors, without prepared contexts or payload envelopes:
refs = Workflow.activation_descriptors(wf)
# %{fact_hash: ..., node_hash: ..., activation_kind: :runnable | :matchable}

# Prepare at most 32 selected activations. Excluded work is not counted.
{wf, selected} =
  Workflow.prepare_for_dispatch(wf,
    limit: 32,
    exclude: fn ref -> in_flight?.(ref.fact_hash, ref.node_hash) end
  )
```

The limit counts attempts, including skip/defer, rather than just successful runnables. Skip/defer reducers update the returned workflow immediately. Consequently `selected == []` does not prove that the workflow is drained; inspect the pending agenda and the scheduler's deferral policy. A no-progress defer can remain pending indefinitely, so runtime retry/backoff policy still matters. `limit: 0` performs no preparation; invalid/unknown options raise.

Preparation does not reserve or consume selected runnable activations. Asynchronous callers must exclude in-flight work, or apply results before pulling the next prefix. Each call reads a fresh immutable workflow snapshot. If skip/defer consumes another selected activation, its pending edge is rechecked before preparation.

The descriptor stream retains its workflow snapshot and is intended for local selection, not transmission. Selected `Runnable` envelopes retain the ordinary cross-process execution contract. Enumeration order is unspecified, while mapped FanIn reduction preserves source order through coordinator lookup. Existing `/1` ordering is unchanged. Definition composition requires no cache invalidation: the next call reads the updated graph.

The implementation traverses existing active label partitions using a map iterator and selects the Fact/FactRef endpoint of each directed activation edge to avoid a frontier-sized deduplication set. It never prepares all contexts and then takes a prefix. This is a Core-level facility applicable to Steps, rules, custom Invokable implementations, and collection pipelines. It deliberately relies on Runic's directed, label-partitioned Fact/FactRef-to-node activation invariant; it is not a general arbitrary-Multigraph traversal API.

## Space and time

Let `n` be the batch size, `q` the simultaneously prepared mapped FanIn arrivals, `b` the selected preparation limit, `d` the ancestry depth, and `H` retained workflow history. Assume fixed-size identities and separate payload cost from record counts.

| Operation | Prior behavior | This branch |
|---|---|---|
| Mapped FanIn batch context | Fresh `n`-value list per ready arrival: Θ(qn) list cells and work | Constant number of references per arrival: O(q) context records |
| FanIn readiness snapshots during prepare | Repeated expected/seen set construction | Removed; current-state completion remains in Coordinator |
| FanOut activation event accumulation | Repeated append over a growing event prefix: quadratic list-cell allocation for fixed downstream degree | One prepend per event plus final reverse: linear event-list construction |
| Prepared contexts in explicit prefix mode | Full frontier contexts prepared before selection | At most `b` selected preparations per call |
| Input/output/provenance retention | Source, facts, edges, mapped state remain resident | Unchanged, O(H + observed occurrences/edges + payloads) |

The fixed compact context excludes input payload, hooks, resolved meta/runtime values, and node closures; those still contribute to a runnable's flat size. Preparation still pays ancestry lookup, hashing, graph access, and custom node-specific context work. The standalone branch does not fix every quadratic graph operation.

Prefix traversal is not claimed to be O(b) under every topology. It visits active-partition owners until enough eligible descriptors are found; exclusions or many non-Fact owners can require a broader scan. `MapSet` enumeration can materialize one Fact's outgoing active degree. Repeated prefix selection can rescan excluded/pending work; fair scheduling or persistent cursors would require a separate snapshot/version and reservation contract. The selected context bound is robust, but total live memory is not bounded independently of `n`.

Within one BEAM process, existing terms may share heap structure. Sending an eager list of `q` batch-sized envelopes to tasks can flatten that sharing and copy terms; compact contexts eliminate the redundant batch fields before that boundary. Same-node reference-counted binaries remain a distinct case. Distributed encoding similarly avoids those fields, but the selected input payload, functions, identities, results, and provenance events still contribute. Encoding byte counts are estimates of transport volume, not WAN latency or remote execution measurements.

The execution span of an arbitrary ordered reducer remains linear in its input count. This branch does not assume associativity/commutativity, parallelize the reducer, prune history, or change failure/cancellation obligations. More fundamental collection admission and batch ownership can build on compact descriptors while preserving causal occurrence identities.

## Verification and evidence

Commands run from this independent worktree with private copied `deps` and `_build`:

```sh
mix format lib/workflow.ex lib/workflow/invokable.ex lib/workflow/fan_out.ex \
  lib/workflow/causal_context.ex test/support/dispatch_probe.ex \
  test/support/dispatch_probe_invokable.ex test/workflow/compact_dispatch_test.exs
mix test test/workflow/compact_dispatch_test.exs test/three_phase_test.exs \
  test/three_phase_invokable_test.exs test/workflow/fan_out_join_dispatch_test.exs
mix test
```

Final complete suite: **55 doctests, 1,420 tests, 0 failures, 13 skipped** (4.5 seconds; correctness run, not a performance comparison). The new test module contains ten tests (the FactRef visibility test was added after the complete-suite run and awaits the next serialized verification window). It verifies:

- Identical mapped FanIn context flat size at batch sizes 8, 32, and 128, with exactly the five stable coordination fields.
- Instrumented preparation of exactly 3 selected nodes from a 100-node frontier; descriptors alone do not call prepare; excluded in-flight work stays untouched.
- Lean replay FactRef owners remain visible; payload references still require resolution before context preparation.
- Zero/invalid limits, skip/defer reducer application and attempt accounting, and unchanged eager default behavior/order.
- Eager/bounded result and full graph equivalence for duplicate-valued, source-ordered batches.
- Context prepared before readiness uses the latest coordinator state; duplicate application does not duplicate output or change the graph.
- Rule matchable activation traversal and dynamic addition of a Step.
- Exact FanOut event sequence across multiple emitted facts and downstream nodes.

Shared timing, sampled process memory, heap/flat envelope sizes, and transport estimates are collected by the root agent with the unchanged `bench/issue19/run.exs` harness, serially across baseline and experiment worktrees. Those comparative measurements belong to the shared report; this document does not substitute earlier diagnostic timings for measurements of this implementation.

## Compatibility and recommendation

Integrate the compact context, linear event construction, and graph-index fixes together after the shared measurements and tests. The new descriptor/prefix API can remain opt-in. No event migration is required, and older prepared FanIn runnables containing the removed extra map fields remain usable because execution/finalization already ignored them. Direct consumers of undocumented `fan_in_context.ready`, `sister_values`, `expected_list`, `seen_map`, or `already_completed` must use current workflow coordination instead.

Do not wire the prefix limit into Worker indiscriminately: FlowBatch and other schedulers require the complete candidate frontier to build dispatch units. A later scheduler contract could accept descriptors and explicitly declare whether it requires global grouping or supports incremental selection. That would move context preparation after scheduling without sacrificing dynamic composition or pure Core ownership.
