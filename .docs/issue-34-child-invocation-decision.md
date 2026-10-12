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
Its public `out` endpoint produces only a completed child value. Steps still
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
observation. Only a completed child activates public return wiring. Other input
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
child's later work. A completed request Runnable is not completed child output.
Use the Call's declared output port/component results for that boundary.
