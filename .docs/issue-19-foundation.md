# Issue 19: foundation fixes for allocation and graph-operation costs

This change advances the compact-dispatch and partition-local Multigraph implementations from the issue #19 comparison. The production source and tests match the tested foundation (`ea82d5b`) exactly. It targets main's `a9407d6` baseline; batch-obligation and source-window implementations remain separate experiments.

## Approach

1. **Prepare only the FanIn information execution needs.** Mapped FanIn preparation used to rebuild expected/seen sets and an ordered sibling-value list for each arriving item. Execution did not consume those snapshots: the coordinator already checks the current workflow and folds in source order during application. Preparation now carries the five stable coordination fields, preserving hooks, runtime context, ancestry, occurrence identities and coordinator ownership. A context prepared before the last arrival can still finalize against current state.
2. **Construct FanOut activation events in linear time.** Prepend event groups and reverse once instead of copying an ever-growing list prefix. Preserve event order and remove redundant enumeration. FanOut still emits the complete collection before application.
3. **Make the existing graph index determine query work.** Filtered incoming/outgoing/incident queries start with indexed endpoint-pair candidates in the requested semantic partition. They no longer materialize unrelated adjacency first. Relabeling changes the affected endpoint memberships instead of rebuilding an entire partition. No graph fields, additional index partitions, ETS tables or processes are introduced.
4. **Expose optional selection before preparation.** `Workflow.activation_descriptors/1` lazily yields activation identities. `prepare_for_dispatch/2` accepts a limit and an in-flight exclusion predicate before resolving contexts. The existing one-argument API and empty-options form retain eager behavior and ordering; Worker and scheduler grouping are unchanged.

The graph changes also repair index consistency for shared custom partitions, parallel labels, properties/weights and relabel collisions. Directed/undirected queries and self loops use the same candidate helper. A changed-ID `replace_vertex/3` bug in the original dependency remains outside this change; filtered queries defensively skip its stale candidates. Valid existing graph storage has the same shape. Previously stale custom indexes require rebuilding from canonical records before relying on completeness.

These changes apply beyond map/reduce: rules, joins, activation transitions and dynamically composed workflows use the same graph operations. Semantic edge roles remain distinct (`:flow`, runnable/ran, production/causality and component associations), while the physical index avoids visiting unrelated roles.

## Results from the serialized comparison

The figures below are the original comparison measurements, not a new benchmark campaign for this PR. Raw samples are preserved without modification in [issue-19-foundation-results](issue-19-foundation-results/), with the [complete subset table](issue-19-foundation-results/summary.csv) and [provenance](issue-19-foundation-results/provenance.json).

For an inline map/collect over **2,048 items**:

| Implementation | Median time | Sampled peak process-tree memory |
|---|---:|---:|
| Baseline | 6,275.748 ms | 111.103 MiB |
| Compact dispatch only | 2,909.840 ms | 26.708 MiB |
| Graph fixes only | 4,086.500 ms | 92.626 MiB |
| **Integrated foundation** | **174.246 ms** | **15.607 MiB** |

The combination is approximately **36× faster** with **7.1× lower sampled peak memory**. Both baseline and foundation retain exactly **4,098 facts and 8,203 edges**. This improvement removes auxiliary work/allocation; it does not reclaim workflow history. At 8,192 collected items, foundation takes 901.925 ms and peaks at 47.223 MiB.

Other cases at n=512 show that the improvement is broader than one shallow pipeline:

| Case / execution | Baseline median | Foundation median |
|---|---:|---:|
| Four mapped stages, inline | 689.834 ms | 101.543 ms |
| Four retained batches, inline (512 per batch) | 2,481.772 ms | 160.975 ms |
| Collect, eight per-runnable Tasks | 548.293 ms | 42.538 ms |
| Collect, second local VM over peer TCP | 1,472.380 ms | 221.063 ms |
| Distinct 1 KiB binary items, local peer TCP | 1,830.511 ms | 249.151 ms |

At n=512 binary items, estimated standalone request encoding falls from **370.087 MiB to 8.663 MiB**; responses fall from **375.901 MiB to 14.478 MiB**. Those are uncompressed external-term encoding totals, not captured network traffic. Reference-counted local binary sharing does not remove transmission costs between VMs.

The isolated graph probe holds selected query degree at one while unrelated history grows. At n=2,048, 500 filtered incoming queries drop from 292.363 ms / 16.1 million BEAM reductions to 0.196 ms / 52 thousand reductions. Relabeling all 2,048 activations drops from 167.753 ms / 21.4 million reductions to 5.998 ms / 398 thousand reductions. See [graph-summary.csv](issue-19-foundation-results/graph-summary.csv); short elapsed timings fluctuate, so reduction counts provide useful corroboration.

### Measurement boundaries

- Elixir 1.19.5, OTP 28, 16 origin schedulers. Timing uses three independent-process samples after warmup; the table reports medians. Runs across implementations were serialized.
- Timing includes construction, admission, execution, exact output/multiplicity validation and final cardinality queries. Compilation and peer startup are excluded.
- Memory is a separate approximately 2 ms sampled pass over owner and live descendant process memory. It can miss short peaks; off-heap referenced binaries are recorded separately. Remote VM heaps are excluded.
- `peer_tcp` uses a real second BEAM with two schedulers and OTP peer alternative RPC over localhost TCP. It is neither a WAN nor native distributed-Erlang benchmark.
- Cheap steps often favor inline placement. With a requested 2 ms wait on every mapped item, foundation n=512 instead takes 1,570.773 ms inline, 224.553 ms with eight Tasks, and 393.099 ms through the local peer. Waiting work can amortize dispatch costs; this is not a CPU-throughput claim.

## Complexity, compatibility and deliberate limits

For n arrivals and q simultaneously prepared FanIn runnables, the removed ready-batch lists accounted for Θ(qn) list cells/work; the coordination fields now take O(q) records. Payloads, node closures, hooks and resolved runtime context still count toward envelope size. Event accumulation becomes linear in emitted event count.

Graph query work follows selected candidate pairs and their labels rather than total incident history. Index mutation touches the affected endpoints and persistent-map paths. This is not a universal constant-time claim: custom partition functions, parallel-label multiplicity, map/set costs and selected degree still matter.

The optional preparation limit bounds selected attempts, including skip/defer, rather than total retained memory or worst-case traversal work. It does not reserve work; asynchronous callers must exclude in-flight descriptors and resolve FactRef payloads before preparation. A descriptor stream retains its immutable snapshot, and an empty returned runnable list does not establish completion. Selection order is unspecified when options are provided.

**Keep bounded preparation opt-in.** For n=512 collect, limit 64 is slower than eager preparation (97.389 versus 37.395 ms), with the same sampled 7.284 MiB peak. Interleaving mapping and early FanIn attempts exposes repeated expected/seen-set reconstruction still present in the legacy coordinator. This change removes the diagnosed eager-path quadratic terms, not every possible quadratic term under arbitrary schedules. Schedulers that need the whole frontier for grouping continue using the eager API.

Default reduction order, output ancestry, events, full provenance and replay contracts are preserved. No event migration is introduced. Previously prepared contexts with extra ignored fields remain usable; external consumers of undocumented removed `fan_in_context` snapshot fields must consult current workflow coordination instead. Full-history storage, materialized input/output and growing accumulators retain their space lower bounds. This change does not make FanOut demand-driven, move the legacy fold out of coordinator application, assume associative reducers, or alter empty-batch/failure semantics.

The comparison also implemented one-fold batch obligations and source windows. They demonstrate useful follow-up directions, but change ancestry, lifecycle or retention contracts. Their additional memory claims are not attributed to this PR. A reusable completion/liveness abstraction needs explicit sealing, per-occurrence terminal outcomes, consumer versions and retry ownership before it can safely drive general reclamation.

## Dependency review and release prerequisite

The existing locked Multigraph 0.16.1-mg.4 source is vendored under its original MIT license so the complete tested implementation is reviewable and runnable. A pristine-import commit is followed by the focused algorithm patch and regression hardening. See [PROVENANCE.md](../vendor/multigraph/PROVENANCE.md).

The path override is temporary for this **draft**. Upstream the graph changes and select a released Multigraph dependency before releasing Runic, unless maintenance and packaging of a vendored dependency are explicitly adopted. Do not publish Runic with this experimental path dependency. No dependency release, package publication or unrelated experimental implementation is part of this PR.

## Validation and reproduction

The extracted branch passes **157 doctests and 1,441 tests, zero failures, 13 existing skips**. The graph contract suite compares partition queries with an independent canonical-edge oracle after deterministic mutation sequences and includes 102 upstream doctests. Dispatch tests cover constant-size coordination fields, prefix/exclusion behavior, FactRefs, skip/defer accounting, late completion, duplicate application, dynamic composition and event order. A fresh six-case harness smoke also passes; its single samples are validation, not replacements for the comparison medians. See the [fresh test log](issue-19-foundation-results/pr-tests.txt), [smoke log](issue-19-foundation-results/pr-smoke.txt), [dispatch details](issue-19-compact-dispatch-results.md) and [graph details](issue-19-graph-indexes-results.md).

The issue's public `plan_eagerly` → `react_until_satisfied` reproduction also passes exact ordered-output checks at 512, 2,048 and 8,192 items; [its log](issue-19-foundation-results/pr-public-api.txt) records single-run validation timings.

```sh
mix test
mix run bench/issue19/public_api.exs
mix run bench/issue19/run.exs --label foundation --sizes 128,512 --cases collect,sum
mix run bench/issue19/run.exs --label foundation --sizes 2048,8192 --cases collect,sum
mix run bench/issue19/run.exs --label foundation --preparation bounded --limit 64 --execution task
mix run bench/issue19/run.exs --label foundation --execution peer_tcp --cases collect,binary --pass timing
mix run bench/issue19/graph.exs 128 512 2048 8192
```

To reproduce the control, create a separate worktree at `a9407d6`, install its locked dependencies and invoke this PR's `bench/issue19/run.exs` by absolute path from that worktree. Use separate build/dependency directories. `matrix.py` invokes the common harness this way and refuses to overwrite prior evidence. The original raw sample commits identify the comparison worktrees; their production implementation maps to main or the equivalent foundation commits in this PR. The broader comparison campaign is preserved locally on `issue-19/compare`.
