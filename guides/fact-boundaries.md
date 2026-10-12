# Fact values and runtime resources

Decision for [issue #36](https://github.com/zblanco/runic/issues/36): retain the
existing boundary. Use portable fact values and the existing run context for
live resources. A consumer can keep an explicit local wrapper for immediate
execution. This decision does not add a native `Fact` mode.

The comparison uses upstream `976ea2318ef30022642fd7066090cb28c4eb09f2` and the
Jido adapter at `5e52df87d8114a1c8f805ead3c278c47f9f869a4`. This replaces the
older Runic integration-fork baseline in the issue. The decision uses the
merged task ownership, `SingleOutput`, failure admission, suppression, and
execution observation contracts. Their task and acceptance rules stay in
their present layers.

## Why retain this boundary

A native local mode would remove wrapper construction and value conversion
from consumers. It would also need a separate identity contract through every
fact producer, collection, causal reference, replay event, Store callback, and
executor. A field in `Fact.meta` would not supply that contract. Native Steps
replace output metadata, and identity construction does not inspect it.

The selected design has no Fact, FactRef, event, snapshot, or identity version
migration. It removes zero lines from Jido. This is a deliberate decision to
retain the adapter, not a completed Jido migration. The measured possible
removal is 103 nonblank lines in Jido's `lib/jido_exec/fact.ex`, with 26 call-site
substitutions: one `local_root/1`, thirteen `value/1`, and twelve `child/2`
calls. These counts include the wrapper and its projection. They are an upper
bound; a native design would still need local/portable selection at admission.
Jido's 57 nonblank lines in `lib/jido_exec/portable.ex` and its input/output
schemas and effect checks would remain.

For comparison, the executable example probes a raw root with an explicitly
supplied payload digest. It is not a native mode. A native child with the same
raw value still raises `Runic.Identity.CanonicalError`. Supplying a digest at
one constructor does not establish inheritance or a storage guarantee.

## Identity and inheritance

The canonical codec continues to reject PIDs, ports, references, and functions.
It also rejects structs without an explicit identity projection. Default Fact
construction hashes the canonical value. A legacy `hash` does not bypass that
check. Supplied digests are a caller trust boundary; do not use them to label a
live term as a portable payload.

`Runic.Identity.Projectable` encodes an identity document. A projection can
omit fields. Successful canonical encoding of that document does not prove
that the raw struct can be stored or recovered. A local wrapper uses this
extension deliberately and must remain subject to its consumer's local gate.

The local wrapper in `examples/fact_modes/` uses SHA-256 of deterministic ETF
bytes. Its digest has meaning only for the exact term in the current live VM
and compatible code. It is not a promise that a PID, port, reference, or
function remains usable after a restart, after resource closure, or on another
node. The digest does not describe the changing contents of a resource.

The consumer must retain the wrapper through each local child, including a
child whose value has become an integer. Native containers preserve wrappers
as values; they do not propagate a mode to new raw outputs. The Jido adapter
uses its local metadata and detection of nested wrappers for this purpose.
A native scalar child can lose that metadata. Therefore, consumers must gate
the whole local execution before persistence or remote dispatch. Checking
only its last scalar output is insufficient.

Nested execution gets local values only when the caller passes the wrapper
explicitly. Do not assume that a new child workflow inherits a fact mode or a
context map from its parent. Nested async work uses Runic's existing owned task
scope. It does not need an adapter task supervisor.

Equal local terms have equal local payload digests in the same VM. Plain
`Fact.new/1` can therefore produce the same default occurrence. Use
`Workflow.execute/3` or `Runner.start_execution/4` for repeated equal inputs
that need distinct execution and root occurrence IDs. Reusing an explicit
execution ID is a caller correlation choice. It does not make external effects
exactly once. A consumer that needs a different resource session identity must
include an explicit session token in its data or admission record.

## Persistence and remote dispatch

Reject a local execution before a Store write or remote dispatch. Do not
convert it implicitly to portable identity. To export a result, the application
must select and validate new portable data, then admit that data as a new
portable input. Keep the relation to the earlier local execution as explicit
application provenance.

For portable work, check raw saved or dispatched fields: input, output,
metadata, effects, captured bindings, and component configuration. A data gate
must identify the field and nested path. For example:

```elixir
{:error, %{
  field: :input,
  path: [:input, :requests, 0, :reply_to],
  reason: {:unsupported, :pid}
}}
```

`Runic.Examples.FactBoundary.check/2` shows a small data gate. It checks raw
fields before canonical projection and rejects the example local wrapper,
even for a scalar. `Runic.Examples.JidoFactBoundary.check/2` shows the matching
gate for Jido's local metadata; Jido retains its own raw-value validator.
These modules are example code, not new public Runic APIs. Production adapters
must define their schemas and bounds and check all fields they save or send.
A remote executor must obtain fresh resources on the target node from that
node's runtime context. Do not send a prepared Runnable with local context.

The current core Store, event ETF serializer, and raw snapshot encoder do not
apply this consumer gate. ETF can encode live handles and wrappers. Encoding
or Store acknowledgement cannot make these values portable or usable on
resume. Runic does not promise to reject every unsafe raw snapshot. Applications
that choose this profile must apply the gate before admission and validate
outputs before acceptance into their durable or remote path. A Store or
executor must reject any unsupported data that can reach its own boundary.
An output check after an external operation cannot undo that operation.

Keep three separate results: computation, local graph acceptance, and Store
acknowledgement. Immediate execution reports `:not_managed` persistence.
A Store acknowledgement reports that Store's guarantees. It does not prove
exactly-once external effects. Existing failed-persistent-stop behavior and
native cancellation still apply.

## Runtime context, replacement, and resume

Use `Workflow.put_run_context/2` or the `:run_context` option for resources.
Context is resolved by component name, with `:_global` defaults. Component
keys override global keys. It is excluded from fact identity and construction
events. `SingleOutput.Context.runtime` uses this same context system.

`put_run_context/2` performs a shallow top-level merge. A new map for a component
replaces that component's whole prior map. Omitted component names remain.
To clear every name, start from a definition or restored workflow with empty
context, or explicitly replace the workflow's `run_context` field with `%{}`.
Context is captured when a Runnable is prepared. A later workflow context
change does not modify a Runnable that is already prepared or running.

Event replay and `Runner.encode_snapshot/1` omit top-level run context.
`Runner.resume/3` accepts fresh `:run_context` before it prepares pending work.
Replaying accepted values does not call the resource callback again. Pending
work needs fresh resources; an omitted resource follows the component's normal
missing-context failure. A local execution cannot use this portable resume
contract. Start it again with new local values. Cancellation stops Runic-owned
work; the application remains responsible for the resources it supplies.

Do not copy resources into fact metadata, policies, component bindings, or
outputs. Top-level context removal does not sanitize those fields. It also
does not guarantee that an external resource still represents the same data.

## Executable evidence and costs

Run the non-Jido cache example and wrapper/root comparison from the Runic root:

```sh
MIX_ENV=test mix run examples/fact_modes/check.exs
mix test test/fact_boundaries_test.exs
```

The cache example puts a live lookup callback in run context. Its request is
an invoice key, and its result is a portable amount. The local example carries
a reply PID, request reference, and function through two wrapped stages.

One sample on Elixir 1.20.4 / OTP 29 used 5,000 root constructions:

| Measurement | Wrapper | Raw native root probe |
| --- | ---: | ---: |
| Root construction, total microseconds | 63,411 | 50,593 |
| ETF bytes for the value | 280 | 177 |

These are observations for one small term in one VM. They are not a benchmark
of a complete native mode. The probe excludes all inheritance, Store, replay,
and remote checks. ETF bytes include a local function, so code and VM changes
can change the result. The script prints new measurements for each run.

The wrapper adds an ETF pass and a SHA-256 digest for each wrapped value, plus
canonical hashing of its projection. Jido recursively wraps local leaves;
the small non-Jido example wraps the whole value. A native local mode could
avoid the wrapper object and value conversions, but would still hash the raw
term and maintain scoped identities. It would also need a distinct storage
profile or complete rejection at each storage and dispatch path. A process
handle has no generic recovery representation.

The optional Jido check uses the exact review baseline and current Runic. It
does not change the shared Jido checkout:

```sh
MIX_INSTALL_DIR="$PWD/_build/fact_modes_install" \
  elixir examples/jido_action/fact_check.exs
```

It tests the real Jido wrapper, native containers, local scalar inheritance,
portable-parent rejection, and field errors. The default Runic tests also
check repeated and nested execution, failure followed by graph reuse, context
replacement, pending-work replay, snapshots, accepted replay, and cancellation.

Reconsider a native mode when a consumer needs live values through arbitrary
native producers and demonstrates a material total adapter reduction. Require
a proposal for all producer and collection paths, mixed local/portable inputs,
resource lifetime, fact references, storage rejection, and version migration
before adding it. The examples and root probe alone do not justify that change.
