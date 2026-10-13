# Issue 34: child invocation decision

Decision recorded before child invocation code on 12 October 2026.
Base: upstream/main, 976ea2318ef30022642fd7066090cb28c4eb09f2.

## Port evidence first

The public `connections:` option already handles Steps, one-input custom nodes,
all-input joins, and declared nested workflows. The added port checks pass with
37 tests. The missing cases are per-port custom endpoints, distinct nested
output producers, explicit any-input groups, and named multi-port input maps for
non-Step components. Custom components can declare `from: internal_name` on an
output port. These declarations select output ownership edges at construction.

Jido's reviewed compiler (jido_action 5e52df8, compiler.ex 607-645) can replace
its nested-workflow Join and `component_endpoint/2` branches with one public
connection group. Dispatch can declare its finished gate as its output port.
Jido still chooses dependencies, order, and the explicit Flow output.

## Alternatives

1. Keep direct dynamic `Workflow.add/3` calls. This already persists additions
   made in the apply phase. Each consumer must still build input, completion,
   and return wiring and prevent repeated target identities from merging.
2. Run a child workflow inside one callback. This hides accepted child progress
   and puts checkpoint recovery at the entire child boundary.
3. Add a data request and a Call component. Select this option. Lower a request
   into ordinary graph nodes during parent apply. Reuse ComponentAdded events,
   native task ownership, SingleOutput, and accepted runtime events.

## Contract

`ChildInvocation.new(target: component, input: value, output: port)` is data.
A `Call` has a request-producing Step. The request is private coordination data.
Its public `out` endpoint forwards accepted values from the selected producer. Steps still
return tuples and other data unchanged. No tuple implicitly means failure.
SingleOutput custom targets keep their explicit Result conversion.

The parent owns the child occurrence. The occurrence key is derived from the
Call activation (Call identity and input Fact occurrence), not target identity.
Repeated calls with the same value need separate input occurrences, as in the
existing Execution API. Retry of the same activation keeps the same child key.
Each target graph node gets an occurrence identity. The target definition stays
reusable. A child's explicit selected output feeds the Call's output endpoint.
There is no early public placeholder and no consumer completion Condition.

The first version supports Steps, ordinary SingleOutput custom components,
and stateless declared workflows built from these nodes, InputBinding, and
Join. Reject other readiness/state models at request validation. An arbitrary
custom composite can use the port contract, but it does not thereby promise
that its graph can be copied into an independent child occurrence. Hooks, child-local policies, and
runtime-only state are not part of a durable target definition. Graph mutation
hooks, stateful components, and collection coordination need their own instance
contract. Do not silently copy them.

Child failure uses the parent's existing halt/skip policy and accepted failure
observation. A selected producer failure emits no value for that attempt. An
independent branch failure can coexist with selected output under skip policy.
Accepted selected output is not retracted. Other input
occurrences and reusable graph structure remain available. All child tasks are
normal parent executor units. Parent cancel/deadline/shutdown applies the
merged owned-task contract. No separate executor or detached child process is
created. Cancellation is an executor observation, not proof that external work
did not occur.

## Checkpoints and cancellation

- Before attachment: an unaccepted request has no child. Its parent activation
  remains retryable. Parent cancellation cannot leave a child task behind.
- At attachment: the accepted request Fact, occurrence ComponentAdded event,
  and child activation are one normal apply segment. The existing Store must
  acknowledge that segment. Local acceptance is separate from acknowledgement.
- During child execution: the checkpoint records construction and accepted
  child progress. Recovery runs only pending child work. An admitted task that
  has no accepted result is uncertain and can run again under existing recovery
  rules. Cancellation must confirm native task termination before owner exit.
- After completion: replay restores the accepted child and Call output Facts
  and consumed activations. It does not repeat accepted child callbacks.
  Unaccepted external effects remain outside this guarantee.

## Compatibility cost

This is additive. Call is optional. Existing Steps, custom Result conversion,
and direct dynamic construction remain valid. Old ComponentAdded events default
to all-input mode. Existing positional InputBinding identities are retained.
The new named-map form has its own identity. Per-endpoint output projection
fixes distinct-producer boundaries without changing shared-producer projection.

Call/occurrence source must reconstruct the chosen target. The first version
uses existing component build events and workflow Definition data. Persistence
has the same code/binding compatibility limits as other construction events.
The parent graph retains completed occurrence nodes. This costs memory in long
sessions. Retention/compaction is separate work. This API does not make external
effects exactly once or transact with Jido Agent state.

## Consumer code removed

For ordinary Action targets and supported stateless Flow targets, Jido Dispatch
can replace target attach, Finish attach, target-specific endpoint resolution,
and the finished Condition with Call and ChildInvocation. Jido must still
resolve/validate Instructions, compile the target, convert Action results, and
combine Frame results and effects. A later Jido adoption change must test that
conversion against the real Action package. This Runic change includes an
adapter fixture and a small non-Jido consumer; it does not edit Jido.

## Implementation notes for review

The Call uses SingleOutput for the request attempt and an Activator for dynamic
attachment. The Activator returns the existing ComponentAdded event before its
RunnableActivated event. It uses no detached child executor. Call is excluded
from ChainBatching so its structural suppression edge cannot be treated as an
early completion path. Children keep their authored names for policy and runtime
context lookup, while their hashes identify separate occurrences.

Private occurrence nodes are not in the public component registry. Explicit
output ownership takes precedence over internal ownership for production lookup.
InputBinding keeps application metadata from its one input Fact; a Join does not
merge several parents' application metadata. The Call strips native binding
annotations when it copies the child's selected application metadata.

A request policy fallback can return already interpreted output without a child.
An explicit ChildInvocation fallback uses the same dynamic construction path.
No new durable event type or second task owner is added.

Execution observation includes the Call's accepted request computation and the
child's later work. A completed request Runnable is not accepted selected-port output.
Use the Call's declared output port/component results for that boundary.

## Astra review contract corrections

Call forwards each accepted value from one selected producer. Producer identity
is unambiguous, but output cardinality is not limited to one value. The public
port therefore declares `:many`. There is no whole-child success barrier.
Execution scope quiescence remains the observation for the end of admitted work.
Independent sibling failure can coexist with selected output; halt and cancel
still control pending admission. This decision retains native graph behavior.

Snapshot-tail replay now applies all construction, lifecycle, and runtime events
to the supplied snapshot in order. Grouped public construction records its Join
with `ComponentAdded.join_parents`; missing/false markers retain the earlier
connection behavior. New explicit grouped records do not undergo legacy group
coalescing. Lost wiring in an old or manually edited target definition cannot
be inferred safely. Request construction rejects a saved graph that does not
preserve the original graph coordinates and declarative edge data.

Custom Activator/Coordinator nodes have no general occurrence contract and are
rejected, including when they appear inside a Workflow. Native Join and binding
references remain the only explicit address fields that occurrence lowering
changes. Application config values are not treated as graph addresses.

A static boundary can export a Call's one public producer. Re-exporting a
component with several distinct public producers requires a forwarding node
connected to the selected public port. `from:` has no general inner-port selector.
Positional Rules use declared positional input order; unrelated runtime context
must not turn a positional predicate into an input-plus-context call.

## Opus review decisions

Whole-component `to:` and workflow pipeline connections use the declared public
producer. Replay records the authored parent. Source Workflows without a declared
producer reject this form; target inline composition remains compatible. Call
inside Map is rejected until a collection instance contract exists. It cannot
leave an accepted request-node edge with no delivery.

Mixed explicit/implicit export mappings reject at construction. Output projection
requires a non-nil matching port index. A single-producer re-export inherits source
cardinality unless the boundary explicitly chooses one or many. All Fact/raw
production and result APIs select the same output ownership.

Child suppression is bounded by the activating request Fact. A skipped child does
not suppress sibling occurrences under the same root. Halt remains a parent
admission policy and can leave ready delivery unaccepted. Downstream all-input
Joins receive no synthetic completion. Their native partial contributions remain
if a required producer produces no value. A caller can discard an incomplete
runtime and reuse its definition; this change does not impose a transaction or
new Join failure protocol.

Occurrence/entry definitions contain no input. Construction keeps target/return
identity and occurrence/request coordinates. Input stays in the request Fact,
which the entry reads and which existing full/hybrid/lazy recovery hydrates.
Private additions still emit audit construction events but no logical connects_to.

A Call uses an internal SingleOutput work adapter to prepare its execution graph
before native completion and success hooks. The graph travels only on transient
Runnable.execution_data. Facts, result projection, lifecycle events, and occurrence
source contain no compiled graph. The owner performs only graph installation.
Fallback preparation runs in work and returns an explicit failed Runnable on
construction faults. No process-global cache is used. Ordinary targets rebuild
once per attempt; Workflow requests additionally perform one saved-graph check.
Replay keeps the trusted compatible-source requirement and rebuilds each saved
occurrence once. Native Fact/history retention remains a separate cost.

## Focused re-review corrections

Joins that have Call flow ancestry now select and consume joined contributions
only from the incoming Fact's local input root. This applies in preparation,
coordination, and direct invocation. Other native Joins are unchanged. The rule
prevents both stale-independent/new-Call and stale-Call/new-independent pairing.
Sibling Call contributions in one root remain eligible under native producer
selection; incomplete protected contributions can remain but cannot contaminate
later inputs. Replay uses ancestry coordinates, including FactRefs.

Occurrence failures also use same-root suppression for independent contributions,
while protecting other request Fact lineages from the same Call. A failed Call
request preserves already attached sibling lineages. Upstream non-Call failure
retains native root suppression. Halt still controls parent admission.

Cardinality lookup is soft for missing/contract references. Inheritance is limited
to Call and nested boundary re-exports. Map and ordinary source exports retain
last-value defaults. Custom composites keep mixed-mapping rejection; nested
Workflows can retain contract-only ports alongside real exports.

The owner validates completed ChildInvocation results before completion events
and deferred hooks. Missing or stale transient data fails the activation with
child_preparation_missing; the Worker's outcome and lifecycle record are failed,
not completed. Plain fallback values are unchanged. This is a local acceptance
failure, not proof that external work did not happen.

Fresh runtime reuse must start from the original unexecuted definition or its
original build log. An executed audit build log includes old occurrence additions.
Old dead-edge logs that lack a public producer require an authored definition
update; this revision does not infer an automatic migration. The Jido fixture
covers ordinary Actions only. A consumer with unconditional downstream skipping
must adopt scoped application before claiming the same Call isolation.

## Round 3 lineage and export corrections

A completed Join with a particular Call in its flow ancestry is classified as
that Call's lineage. Root-scoped completion consumed contributions from that
input root, so the last triggering Fact is not a complete lineage description.
This keeps pending joined sibling output independent of contribution arrival
order under child skip and pre-attachment request skip. Independent ordinary
activations and incomplete Join contributions retain the documented same-root
suppression rule. Cross-root selection remains unchanged and bounded to Call
flow ancestry. Join completion now records its downstream activations, preserving
checkpoint frontiers through event replay.

Nested boundary cardinality considers only actual exports/compiled ports.
Adding a contract-only audit port does not convert a one-producer Call re-export
from many to one. Soft missing lookup and ordinary Map last-value behavior remain.
The tests also cover invalid transient data in a parallel Promise, repeated
managed execution roots, and a lazy FactRef-only retained contribution followed
by new inputs. Unsupported child/collection scope and the compatible-source
replay profile are unchanged.

## Round 4 exact contribution provenance

Static flow ancestry and the last trigger are both insufficient for Join-result
lineage. JoinCompleted now has an additive defaulted contribution_fact_hashes
field. Live completion records only selected inputs, in declared producer order.
Production-edge metadata binds those IDs to that specific result. Both direct
Join invocation and coordination use the same exact provenance. Surplus inputs
relabelled by native completion are discarded, not claimed as result parents.
Repeated same-root completions have separate contribution lists; historical
join_satisfied edges are never used as an exact parent set.

Both occurrence ancestry and Call-lineage protection traverse actual contribution
coordinates. Own failed-occurrence output is suppressed in either arrival order.
A good sibling remains protected; purely independent values are not protected
merely because an any-input graph has a Call ancestor. Existing cross-root Join
selection is unchanged. Full/ref replay keeps the same provenance.

Old events default to unknown provenance. No exact parent set is fabricated.
Pending unknown Join output affected by a failure in the same root is treated
conservatively and receives no Call-lineage exemption. Accepted historical values
are not rewritten. Compatible source/replay and unsupported scope bounds remain.

Cardinality inheritance groups real exports by distinct compiled producer. Aliases
of a Call output do not change many inheritance. One explicit alias override is
honored; conflicting alias overrides resolve to the existing one-value default.
An explicit outer override still wins. Worker stream and snapshot-tail tests
restore a pending Join consumer exactly once. Invalid Promise preparation has
persisted failure/completion assertions and does not install the rejected child
on resume.
