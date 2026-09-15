# Issue 19 track B: partition-local graph operations

## Implementation and review

Branch: `issue-19/graph-indexes`. The baseline is the experiment charter's commit.
The first track commit vendors the exact locked Multigraph `0.16.1-mg.4` package
with its MIT license and source checksums. The following commit contains the
actual algorithm changes, dependency contract tests, and graph scaling probe.
The dependency source is reviewable and reproducible rather than an ignored
`deps/` patch. See `vendor/multigraph/PROVENANCE.md` for upstreaming/publishing limits.

No Runic source changes occur on this branch. Track A should use
`Multigraph.in_edges(workflow.graph, fan_in, by: :fan_in)` for the structural
association. Existing `Workflow.next_steps/2` already requests the flow partition.
A caller asking for *all* incident edges still pays for all incident history.

## Fundamental representation

The same pure multigraph keeps multiple meanings of edges: structure, pending
activation, consumed activation, causal production, and component association.
The existing `edge_index[partition][endpoint]` contains endpoint-pair keys.
Filtered incoming, outgoing, and incident queries now begin with those keys,
check direction before materializing edges, and use the stored canonical
endpoints. Unrelated historical adjacency is never converted into a temporary
set. One helper implements all three query directions. Undirected queries select
both incident orientations and self loops appear once.

Removing an endpoint-pair key updates only its one or two endpoint sets and
deletes empty maps. Other endpoints remain structurally shared. Because this
index stores *pairs*, two labels may contribute the same membership. Removing
one label now preserves partitions owned by surviving labels. Replacing edge
metadata refreshes only that pair's memberships, including property/weight-based
custom partitions and relabeling into an existing label.

Deletion cleans corresponding properties so reinsertion cannot silently revive
old custom-partition state. These small correctness repairs are necessary to
make the index a faithful derived projection of canonical edge records.

## Complexity and limits

Let `H` be unrelated incident history, `C` the number of distinct endpoint pairs
incident in requested partitions, `L` the labels on those pairs, `P` partition
memberships per label, and `K` total endpoint entries in an affected partition.
Persistent map/set operations have their normal hash/trie costs; these are not
claims of universal worst-case constant time.

| Operation | Before | After |
|---|---|---|
| Filtered incident/in/out query | Materialize `O(H + C)` adjacency then intersect | Visit `O(C)` candidate pairs and their `L` labels; no unrelated history scan |
| Remove one pair membership | Rebuild `O(K)` partition entries | Update at most two endpoint maps/sets |
| Relabel a pair with bounded labels/partitions | Includes global partition rebuild | Work local to pair labels/partitions and touched persistent paths |
| Repeated activation consumption | Global shrinking-partition scan creates a quadratic term | Linear number of local mutations, with persistent-map/set factors |

Direction is not a second index: incoming queries also inspect opposite-direction
candidates in the **same selected partition**. Many labels sharing a pair must
still be examined, and a custom partition function's own cost counts. Relabel
refresh deliberately visits all parallel labels on the changed pair to handle
replacement collisions correctly; very high label multiplicity is a separate
trade-off. Adding a directional or per-label reference-count index could reduce
those visits but increases graph state, mutation obligations, copying, and
serialization. This experiment does not add that state.

The optimization applies to eager and lazy evaluation because both use the same
functional graph operations. It reduces temporary allocation and owner-process
work. It does not shrink retained facts, edges, histories, prepared FanIn envelopes,
source inputs, or collection outputs. Thus it alone cannot bound total memory or
remove the quadratic FanIn-context problem. Inline execution retains structural
sharing; sending entire graph states to another process still copies ordinary
terms. Network encoding contains the same graph fields as before, so no network
byte reduction follows directly from this track. Compact dispatch and bounded
preparation are complementary.

## Validation

Final validation during the agreed functional-test window:

- `ERL_FLAGS='+S 4:4' mix test`: **157 doctests, 1431 tests, 0 failures,
  13 skipped**. This includes 20 new contract tests and 102 published examples
  from the original package's Multigraph and Edge modules. Skips belong to the
  existing suite. Seed: 264628; completion: 6.1 seconds (test phase only).
- Earlier isolated runs passed the initial 18 contract tests and all 102
  upstream doctests; the final full suite includes the two vertex-replacement
  regressions added in review.

The contract oracle enumerates canonical edge records and reconstructs expected
partition membership independently. It compares complete structs returned by
all filtered directions and global queries after each operation. Directed and
undirected coverage includes self loops, reverse edges, overlapping custom
partitions, parallel labels, properties, same-label updates, overwrite collisions,
deleting one/all labels, deleting vertices, reinsertion, custom identifiers,
missing partitions, and two fixed-seed 180-operation mutation traces.

The original package already mishandles shared custom-partition deletion,
property/weight reindexing, filtered incident endpoint construction, and opposite
orientations in filtered undirected queries; these are correctness repairs,
not optional Runic semantics. Same-ID vertex replacement (used by Runic's conjunction composition) is covered
and reads current vertex values. Upstream changed-ID `replace_vertex/3` leaves
its index stale; this experiment does not repair that separate operation. A
regression test ensures stale candidates are skipped without introducing a new
exception. Other unrelated upstream graph APIs have not been audited exhaustively. Graph storage shape is unchanged; valid existing graphs
need no format migration. Previously stale custom indexes would need rebuilding
from canonical records before relying on their completeness.

## Reproducible measurements

Root coordinates the common unchanged harness and raw results; no competing
benchmark is run by this agent. For graph-specific asymptotic evidence, run the
same `bench/issue19/graph.exs` script against baseline and this branch:

```sh
ERL_FLAGS='+S 4:4' mix run bench/issue19/graph.exs 128 512 2048 8192
```

It warms each job once, measures three isolated worker invocations, and reports
wall time, BEAM reductions, post-GC process memory, and flattened result words.
Graph setup, initial process copy, GC, and flattened-size traversal are outside
timing. Fixed-degree incoming/outgoing/incident queries and repeated independent
single-edge relabels hold selected work constant while history/partition size
grows. `consume_all` relabels `n` distinct edges, preserving resulting history.
The post-GC memory includes worker-held graph/closure/result; it is not a sampled
peak or total allocated-byte metric. Graph process-copy and network-byte costs
are addressed by the shared harness; this probe does not claim to measure them.
