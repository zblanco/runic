# Fact values and local identity

This draft implements an experimental native local fact mode for
[issue #36](https://github.com/zblanco/runic/issues/36), tracked by
[#30](https://github.com/zblanco/runic/issues/30). It is a first implementation
for evaluation, not a decision to land the API. The earlier wrapper-only
decision is the comparison baseline. Portable remains the default.

## Native local facts

A native local fact carries the original value. Callbacks do not wrap or
unwrap PIDs, references, ports, functions, or unprojected structs.

```elixir
local = Runic.Workflow.Fact.local(%{reply_to: self(), token: make_ref()})
local = Runic.Workflow.Fact.new(value: self(), identity_mode: :local)

{workflow, execution} =
  Runic.Workflow.execute(definition, input, identity_mode: :local, async: true)
```

`Fact` and `FactRef` have `identity_mode` and `local_scope`. Native Steps,
SingleOutput callbacks, Rule bindings/reactions, fan-out, joins, reducers,
accumulators, and policy fallback outputs inherit them. A scalar child is
still local. SingleOutput callbacks receive the bare value and get the profile
in `Context.identity_mode` and `Context.local_scope`. Low-level custom
Invokable implementations must construct their outputs with `Fact.child/2`
and supply their normal causal ancestry. A raw `Fact.new/1` does not infer a
mode from an ancestry ID and rejects local ancestry in portable mode.

## Scope and identities

A new local root gets a new `LocalScope`. Its VM token is random and kept in
the running VM; its session token is a reference. The VM token survives code
reloads but not VM restart. Scope validation also rejects a different node.
This is identity scope, not task ownership or a resource lease. Resources can
expire or change while a scope remains valid.

Local IDs use the explicit `:local_sha256` scheme. Payload identity hashes
scope plus deterministic ETF bytes. Causal identities derived from local IDs
keep the local tag. They are not portable canonical identity documents.
`Canonical.encode!/1` rejects local IDs and continues to reject raw PIDs,
ports, references, and functions. Existing portable identity bytes are unchanged.

Use a shared scope explicitly for a local session or a nested call:

```elixir
scope = Runic.Workflow.LocalScope.new()
{workflow, first} = Runic.Workflow.execute(definition, input,
  identity_mode: :local, local_scope: scope)
{workflow, second} = Runic.Workflow.execute(workflow, input,
  identity_mode: :local, local_scope: scope)
```

Equal values in the same scope have equal payload digests. Execution and root
occurrence IDs still distinguish repeated calls. A nested execution does not
inherit a mode from process state: pass it explicitly, using the callback's
input profile when appropriate. Existing native task ownership still applies.

A join or reducer cannot combine different local scopes. Accumulator state
keeps its scope, so repeated local state updates require a shared scope. A
scope conflict becomes a failed Runnable. Join and FanIn check the current
graph before acceptance. Reducers and hooks do not run for rejected parent
scopes. Direct invocation uses the same paths. Combining portable facts with
one local scope yields a local result. Promotion requires selecting new portable data and admitting it into
a new portable execution, not changing a local child's marker.

## Persistence, replay, and remote execution

Native local facts cannot be persisted. The Worker rejects the event batch
before `save_fact/3`, `save_payload/3`, or append/save callbacks. Built-in ETS
and Mnesia also check direct writes, including local identity keys. Encoded
payload bytes do not waive the identity profile. Errors identify the field:

```elixir
{:error, %Runic.Workflow.LocalFactError{
  field: :events, path: [:events, 0, :identity_mode], reason: :local_fact
}}
```

The exact path depends on the envelope. A local identity key can be rejected
before a Fact marker. Failed persistence retains pending data and preserves
the existing failed-persistent-stop behavior. Computation, local acceptance,
and Store acknowledgement remain separate results.

For a managed local computation, explicitly disable persistence:

```elixir
{:ok, worker} = Runic.Runner.start_workflow(runner, :local, definition,
  owner: self(), persistence: :disabled)
{:ok, id} = Runic.Runner.start_execution(runner, :local, input,
  identity_mode: :local)
```

This Worker makes no Store writes and reports `:not_managed`. Checkpoint
returns `{:error, :persistence_disabled}`. Normal stop and native cancellation
still work. There is no saved local execution to resume.

Event ETF serialization and workflow snapshot encoding reject native local
markers. Snapshot decoding and Runner recovery reject them too. Explicit
in-memory event replay uses `Workflow.from_events(events, nil,
allow_local: true)` and must use the same live VM. Local events must retain
their original mode, scope, and identities. Replay does not create a new scope
for an existing identity. The option applies to both the events and the base
workflow. Replay does not call accepted callbacks again.

Local FactRefs cannot load their values from a Store or resolver cache.
Reference and preload checks run before any Store read. `Rehydration.dehydrate/2`
and the fused rehydration path retain full native local Facts, including cold
history. They can still replace cold portable Facts with references. Native
local replay also retains full Facts when `fact_mode: :ref` is selected.
Local values therefore remain in memory until the workflow drops them. Raw
Erlang serialization and legacy low-level replay APIs are not portable codecs.

Custom remote executors must declare `locality/0` as `:remote`. The Worker
rejects a native local Runnable or Promise before dispatch. Existing executors
without this callback retain their local profile. The check includes the
policy captured for a Runnable and the full workflow and policies captured
for a Promise. Local history prevents remote Promise dispatch even when the
current input is portable. `Runnable.for_remote/1` and
`LocalBoundary.check/2` provide the same marker check for other adapters.
These checks do not serialize code or certify arbitrary legacy raw data,
captured bindings, hooks, or policies. A remote adapter must validate its
transport and install fresh resources on the target VM. There is no built-in
network executor in this prototype. External effects are not made exactly once.

## Runtime context and existing limits

Live resources that do not belong in data still use the existing run context.
`put_run_context/2` makes a shallow merge; a component map replaces its previous
map, and component keys override `_global`. Prepared Runnables keep their
captured context. Portable replay and snapshots omit top-level run context;
resume must supply fresh resources.

For named Steps and components whose runtime uses their own name, check fresh
keys with `validate_run_context/2` and check resource validity before dispatch
or resume. Explicit nil passes key-presence validation but resolves like an
absent key. A non-nil default applies at runtime; `default: nil` is required
for validation. Direct SingleOutput runtime resources also need callback checks.

Validation lists anonymous Rule condition keys under the Rule name, while
runtime uses a nil name. Reaction Steps use generated names. Use `_global`
for Rule resources, which makes them available to all components. This known
core limitation is recorded in the
[Rule context owner follow-up](../.docs/rule-context-owner-follow-up.md).

Legacy consumer wrappers and caller-supplied digests remain trust boundaries.
A projected identity does not prove raw-field portability. The old consumer
gate examples remain useful for those profiles; native marker rejection is
not a general production validation framework. Local ETF hashing allocates
serialized bytes and has no new size limit in this first implementation.

## Executable examples and comparison

```sh
MIX_ENV=test mix run examples/native_local_facts.exs
mix test test/native_fact_mode_test.exs test/native_fact_store_test.exs
MIX_INSTALL_DIR="$PWD/_build/fact_modes_install" \
  elixir examples/jido_action/native_check.exs
```

The non-Jido example passes a bare callback, keeps its scalar result local,
runs under an owned non-persistent Worker, and admits selected portable data
explicitly. The Jido example uses the existing SingleOutput adapter and real
Action input/output schemas and effects. Native mode needs no Jido value
wrapper or Jido child-fact factory. The shared Jido checkout is unchanged.
Its original low-level Invokable implementation still needs migration to use
native `Fact.child/2` or SingleOutput.

The Jido baseline at `5e52df87d8114a1c8f805ead3c278c47f9f869a4` has 103 nonblank
lines in its fact adapter and 26 call sites: one root, thirteen value, and
twelve child calls. Native support can replace those conversions. This PR
demonstrates the adapter shape; it does not claim a completed Jido migration
or actual removal of those files. Jido retains schemas and effect validation.

The earlier wrapper/root-digest comparison is still executable in
`examples/fact_modes/check.exs`. It is a historical baseline, not a native-mode
benchmark. Native local identity now pays for a VM/session scope and ETF
hashing throughout causal IDs. Portable ID bytes stay stable, while Fact,
FactRef, and event records gain optional fields. Legacy portable records use
portable defaults. Local records require the new code and remain unrecoverable.

The open design questions are mixed-scope coordination, the size/cost of local
ETF hashing, remote executor declarations, and the public scope/error API.
Keep this implementation in draft while evaluating those choices.
