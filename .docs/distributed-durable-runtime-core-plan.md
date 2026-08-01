# Distributed Durable Runtime Core Plan

**Status:** Proposed implementation plan
**Date:** 2026-07-31
**Updated:** 2026-08-01
**Target baseline:** Runic `0.1.0-alpha.8` at `75ed26f`
**Companion plans:** [Runtime Contract Upgrade](runic-runtime-contract-upgrade-plan.md), [Distributed Adapter Portfolio](distributed-adapter-portfolio-plan.md), [Runic Ra Journal and Native Profile](runic-raft-native-runtime-plan.md), [Runic CASPaxos Execution-Cell Journal and Registration Profile](runic-caspaxos-native-runtime-plan.md)
**Consumer research:** `~/wrk/libbit/.docs/runic-clustered-durable-execution-architecture.md`

## Executive decision

Runic should support clustered durable execution without turning the graph VM into a distributed-systems framework or imposing a runtime topology on every user.

The proposed boundary is:

1. Keep `Runic.Workflow` the topology-independent, lazy, forward-chaining graph VM.
2. Put the first-party managed execution system in this package as `Runic.Runtime`. It owns durable input acceptance, journal-fenced coordination, activation/passivation, dispatch, completion application, timers, cancellation, and conformance tests without adding infrastructure dependencies.
3. Treat Runic's versioned chronological events as the canonical rebuild, persistence, replication, and audit protocol. Construction and lifecycle events form one logical history, even when a reusable construction artifact and an execution tail are stored separately.
4. Intentionally replace the alpha `Runic.Runner.Store` and local-closure `Executor` contracts with deeper Runtime behaviours. Do not carry a permanent legacy bridge or add a parallel distributed executor beside the old one.
5. Replace `RunnableDispatched` with a truthful portable, pre-execution `RunnableDispatchRequested` event that crosses the delivery boundary. A live `%Runnable{}` remains the local prepared/executed projection; workers return an attempt-result command which the authority validates before recording completion events.
6. Put Ecto, Postgrex, Broadway, Ra, RocksDB, cloud SDKs, Group, Khepri, EKV, Horde, and similar dependencies in consuming applications or separate adapter libraries. Packaging isolates dependencies; it does not create a second runtime architecture.

The clustered guarantee is **durable input plus one accepted state transition per activation attempt**, with at-least-once work delivery. It is not a claim that arbitrary external side effects execute exactly once.

## 1. Why this is consistent with Runic

Runic's existing architecture already supplies the difficult semantic seam:

- A workflow is a lazy, composable graph whose facts and ancestry encode causal computation.
- Components can be composed or added at runtime; managed execution must not freeze that expressiveness into a static workflow language.
- [`Invokable`](../lib/workflow/invokable.ex) separates prepare, execute, and apply.
- [`Runnable`](../lib/workflow/runnable.ex) carries the node, triggering fact, and minimal [`CausalContext`](../lib/workflow/causal_context.ex), rather than a copy of the full workflow.
- Execution produces typed events which [`Workflow.apply_event/2`](../lib/workflow.ex) folds back into graph state.
- Construction and lifecycle events already rebuild persisted workflows in Infinite Isekai, RunicAI, and Compendium; the distributed protocol should strengthen that event model rather than duplicate it with an adjacent state machine.
- [`Closure`](../lib/closure.ex) stores normalized AST, captured bindings, environment metadata, and a content hash so macro-built components can be reconstructed.
- `context/1,2` intentionally injects run-scoped values without including those values in workflow identity or the definition log.
- `FactRef`, separate fact storage, full/hybrid/lazy rehydration, stream replay, and snapshot-tail resume already define a useful memory-disaggregation model.
- Scheduler and Executor behaviours already keep _what runs_ separate from _how local compute is invoked_.

Distribution should therefore extend the execution gap between prepare and apply. It should not replace the graph with an imperative orchestration DSL, require deterministic re-execution from the top, or make a broker the source of workflow truth.

## 2. Architectural invariants

The following are constraints, not preferences:

1. **The pure Workflow API remains independently useful.** `Workflow.prepare_for_dispatch/1`, `Invokable.execute/2`, and chronological event application must remain usable without starting `Runic.Runtime`.
2. **Durability is opt-in.** A local reaction does not pay for consensus, database transactions, envelopes, or queue round trips.
3. **The Runic event stream is the managed execution truth.** It is the authoritative ordered representation from which graph and Runtime projections rebuild; a Journal is its commit mechanism, not a second workflow model.
4. **Prepare and apply are authority-side operations.** Remote compute receives only a versioned executable and its captured causal inputs. It never mutates the authoritative workflow directly.
5. **No route registry is a write fence.** `:pg`, Group, Horde, `ra_registry`, Khepri projections, and similar systems may locate a likely owner. The authoritative journal must reject stale writers.
6. **Queues deliver work; they do not own workflow state.** Redelivery and duplicate completion are normal inputs to the protocol.
7. **Runtime composability remains durable.** Graph additions, removals, rewrites, and hook-driven changes must become replayable commands/events rather than being forbidden in clustered mode.
8. **Stateful noncommutative nodes are serialized at their state key.** Parallel compute is permitted; acceptance of conflicting state transitions is not.
9. **Code is versioned data.** A recorded dispatch event identifies the workflow artifact and code version against which it was prepared.
10. **Trusted BEAM portability comes first.** Cross-language or untrusted-code execution is a separate operation protocol, not a weakened version of `Runic.Closure`.
11. **Requested guarantees never silently downgrade.** A missing capability fails Runtime startup/submission rather than falling through to local best effort.

## 3. Current baseline and the real gaps

Several older plans describe work that is now implemented. The clustered project should build on the current checkout, not repeat it.

| Area | Present now | Clustered gap |
|---|---|---|
| Causal execution | Prepare → execute → apply; typed apply events; activation events | No storage-fenced transition acceptance |
| Program reconstruction | Macro-built components retain `Closure` AST, explicit captured bindings, and metadata | No canonical portable dispatch-event export/import or code fingerprint validation |
| Event reconstruction | Construction and runtime events rebuild Workflow state; three consumers persist and replay them | Replay is not one strict chronological projector and events lack a versioned storage/replication envelope |
| Runner persistence | `Store.append/3`, stream replay, snapshot read, separate fact callbacks | Snapshot and stream modes compete; no expected position, epoch/fence, transaction deduplication, or atomic event transaction |
| Input | `Runner.run/4` casts to a local Worker; `plan_eagerly/2` immediately mutates/activates the graph | No durable acceptance acknowledgement or input event before planning/dispatch |
| Dispatch lifecycle | `RunnableDispatched`, `Completed`, and `Failed` events in durable policy mode | Dispatch is returned only after execution and persisted after core result events; it is neither write-ahead intent nor chronological lifecycle history |
| Persistence errors | Store callbacks return errors in their contracts | Worker clears buffers after append attempts and ignores fact-write failures |
| Recovery | Event replay and snapshot-tail resume | Current “in-flight recovery” does not reconstruct a pending attempt from durable intent, and abnormal Worker restart can use supplied in-memory state rather than committed truth |
| Retry | PolicyDriver retries with backoff | `Process.sleep/1` is process-local, not a durable timer |
| Identity | Content-oriented `phash2` hashes and Runnable IDs | 32-bit hashes cannot serve as distributed command, occurrence, fencing, or idempotency identities |
| Hooks and policies | Flexible local functions and apply closures | Arbitrary functions are not canonical replayable mutation or wire representations |
| Runtime context | `context/1,2` values are resolved during prepare from mutable workflow-global run context | Overlapping inputs can bleed context across causal lines; values need invocation-scoped references and worker-side provider resolution |
| Memory | Fact references and hot/cold rehydration | Raw Workflow snapshots can include live functions, policies, hooks, and run context; no portable snapshot IR, clustered activation/passivation, or object lifecycle protocol |

Two distinctions are especially important.

### 3.1 A reconstructable component is not the same as the live Runnable struct

The user's intended guarantee is valid: Runic's macro lifecycle preserves the anonymous function's program as AST plus explicit captured bindings, and can reconstruct the component later. A blanket statement that an anonymous Runic component is non-serializable is wrong.

However, the current live `%Runnable{}` is not the canonical wire object:

- a `Step` contains both the reconstructable `closure` and a compiled `work` function;
- `CausalContext.hooks` may contain functions;
- `run_context` may contain secrets, PIDs, repositories, ports, or connections;
- policies may contain matcher or fallback functions;
- completed Runnables may contain `hook_apply_fns`, arbitrary errors, and arbitrary results.

The correct operation is **prepare Runnable → emit portable dispatch event → commit → transport → validate → rebuild local Runnable**, not `term_to_binary(runnable)` and hope every live field remains meaningful.

### 3.2 Captured bindings and runtime context are complementary

- Explicit macro captures such as `^multiplier` become serializable bindings in `Runic.Closure` and contribute to the program/content identity.
- `context(:api_key)` is a runtime requirement resolved during prepare or on the compute worker. It intentionally does not become part of workflow definition identity.

The portable format must retain both mechanisms without persisting runtime resources indiscriminately.

### 3.3 Event chronology and replay must be repaired before clustering

Wrapping the current Worker with a distributed registry would preserve several local-only correctness gaps:

- `plan_eagerly(input)` takes the direct Root/match path, mutates the graph, and dispatches before a durable input transition exists;
- lifecycle events are accumulated after result application, and full input/result facts in those events bypass the existing FactStore value-stripping path;
- structural/lifecycle events are separated from runtime events during `from_events`, losing their original chronology; structural tail changes on top of a base snapshot are not fully folded into that base;
- failed and skipped execution performs some terminal/downstream graph mutations directly, without a complete typed event representation for replay;
- normal stateful scheduling can prepare two Accumulator activations from the same prior state, while the existing `mergeable` boolean does not implement conflict detection or a merge algebra;
- a sequential Promise applies Runnables to a task-local workflow to discover the next step and the coordinator applies them again, which is unsuitable for authoritative mutation hooks and distributed batch semantics;
- the present in-flight test completes work before stop/resume and therefore does not establish crash-in-the-execution-gap recovery.

Phase 1 treats these as prerequisites. The goal is not to make every local optimization journaled; it is to ensure the durable path has one chronological fold and no hidden authoritative mutation.

### 3.4 The event is the distributed semantic boundary

The implemented consumers confirm that Runic's event log is already more than observability:

- Infinite Isekai stores construction/lifecycle events and facts in PostgreSQL and rebuilds with `Workflow.from_events/2`;
- RunicAI projects `RunnableDispatched` as durable running state and uses its SQLite event stream for resume;
- Compendium rebuilds from ordered SQLite events and separates facts, snapshots, and artifact references.

The correction is therefore not to introduce a second `ExecutionEnvelope` lifecycle beside Runic events. Replace the misleading past-tense event with `RunnableDispatchRequested`: it is committed before work, versioned, portable, and sufficient to reconstruct an attempt. A local backend consumes the recorded event directly. A broker wrapper may carry that event or an integrity-checked reference to it, but adds only delivery metadata. RunicAI's existing `RunnableDispatched` projection migrates from `:running` to `:dispatch_pending`; delivery and worker start remain distinct observations.

A worker result is initially a command/proposal. The authority validates it and emits `RunnableCompleted` or `RunnableFailed`; only the recorded lifecycle event is historical truth. This prevents a worker from declaring an unaccepted graph transition authoritative.

Reusable workflow construction need not be copied into every execution stream. Runic may content-address an immutable construction-event stream as a workflow artifact; an execution records the exact artifact digest/cursor it pins, then appends its input, lifecycle, and runtime graph-mutation events. Logical replay is the pinned construction history followed by the execution history in order. This keeps events—not a parallel IR—the executable reconstruction protocol while allowing artifact reuse.

## 4. Guarantee vocabulary

Every runtime and adapter must state which guarantees it provides. Avoid a single `durable: true` flag that hides materially different behavior.

### 4.1 Required clustered contract

For an execution key within one authoritative journal partition:

1. **Durable input acceptance:** success is returned only after a caller-known command ID and its input are committed. Resubmitting the same ID and request digest within the published command horizon returns the original receipt; outside it the result is explicitly expired/indeterminate, never falsely “not committed.”
2. **Single accepted transition:** at most one terminal outcome is accepted per attempt, and its Journal transaction commits only when expected position, authority epoch, activation identity, and transaction identity are valid.
3. **At-least-once attempt delivery:** a scheduled attempt may be delivered or executed more than once after ambiguous publish, worker loss, visibility expiry, or coordinator failover.
4. **Duplicate-safe completion:** repeated, late, or out-of-order attempt results are either recognized as already committed or rejected as stale without applying graph changes twice.
5. **Replay equivalence:** rebuilding from a snapshot plus committed tail events yields the same authoritative graph state and pending durable work as uninterrupted execution.
6. **Fenced ownership:** after a new epoch is issued, the journal rejects every mutation from an older authority even if its process is alive and reachable.
7. **Atomic durable consequences:** accepted input/completion, emitted graph events, new activations/dispatch intents, timer changes, cancellation state, and the new stream head commit together. Journal indexes derived from those events update in the same transaction.

### 4.2 Explicitly excluded claim

The runtime cannot promise exactly-once arbitrary external effects. A step can call an API and lose connectivity before recording its result. The system may have to retry.

Effects need one of:

- a stable Runic idempotency key accepted by the target;
- a target-side conditional write or fence;
- an outbox transaction in the target database;
- a compensating action with explicitly accepted semantics;
- operator resolution for an unknown outcome.

Documentation and telemetry should say **attempt**, **accepted transition**, and **effect outcome**, rather than overloading “execution.”

Terminology is deliberately layered: a **command/proposal** requests change; the pure VM **decides a semantic transition** as ordered domain events; a Journal **transaction** conditionally commits that batch once; the Journal returns authoritative **RecordedEvents**. Client `command_id`, storage `transaction_id`, and event identity solve different deduplication problems.

## 5. Package and responsibility boundary

```text
runic
  Runic.Workflow
    Graph VM, components, closures, causal execution, event decisions/projector
  Runic.Runtime
    Durable coordinator, recorded events, Journal/ExecutionBackend/PayloadStore,
    context resolution, activation lifecycle, timers, completion, conformance
       │
       ├── runic_sqlite / runic_postgres / runic_raft / runic_caspaxos / ...
       ├── runic_broadway
       ├── runic_rocksdb
       ├── runic_blob_s3
       └── runic_group / runic_horde / bounded metadata adapters
```

`Runic.Runtime` lives in the main package and should not depend on Ecto, Postgrex, Broadway, Ra, RocksDB, a cloud SDK, or a particular cluster library. It includes dependency-light local implementations and the imported conformance kits.

Dependency-heavy integrations may be application-local modules or separate packages. They implement the same in-package behaviours and may compose where useful; separate packaging is justified by dependency/release/operations concerns, not by a different coordinator or event model.

Because Runic is alpha, replace `Runic.Runner` with the `Runic.Runtime` facade and move its internal Worker behind that facade. A short compile-time deprecation window is acceptable, but do not keep two execution paths with different durability semantics. The exact breaking sequence is specified in [Runic Runtime Contract Upgrade](runic-runtime-contract-upgrade-plan.md).

## 6. Identity and version model

Distributed correctness needs unique occurrences in addition to Runic's content identity.

### 6.1 Identity hierarchy

| Identity | Meaning | Required property |
|---|---|---|
| namespace | Tenant/application isolation boundary | Supplied, validated, included in every key |
| workflow artifact ID | Content/version of a reusable graph program | Cryptographic, versioned digest |
| execution ID | One long-lived evolving workflow instance | Globally unique within namespace |
| input command ID | Semantic idempotency identity for submitted input/signal/cancel | Caller supplied for durable calls, or preallocated before submission; retained with request digest and receipt |
| activation ID | One causal occurrence prepared for a node | Unique even when node and fact content repeat |
| attempt ID | One delivery/execution attempt for an activation | Unique; retry number is metadata, not identity |
| transaction ID | Idempotency identity for one journal mutation | Unique and queryable after ambiguous commit |
| authority epoch | Monotonically fenced owner generation | Issued and enforced by authority store |
| journal position | Ordered revision of the execution/partition | Compared atomically during commit |

### 6.2 Content digests

Current graph hashes use `phash2` with a 32-bit range. They may remain a private graph-local lookup optimization if measurement justifies them, but they do not appear as the sole identity or integrity key in the new durable event schema. Do not carry dual public IDs merely for alpha compatibility; migrate known persisted fixtures deliberately.

Add a versioned content digest scheme for closures, components, facts, artifacts, payloads, recorded events, and transport wrappers:

- canonical deterministic encoding;
- SHA-256 or another explicitly named cryptographic digest;
- a scheme/version prefix;
- collision verification by comparing stored canonical bytes when appropriate;
- known alpha fixtures receive a one-time migration/upcast rather than permanent dual-hash semantics.

Whether repeated identical root input is memoized or treated as a distinct occurrence must become an explicit ingress policy. Activation identity must not accidentally inherit that choice from content hashing.

Fan-out multiplicity makes this more than a collision-hardening exercise: equal values at two collection indexes are two causal occurrences even when their payload bytes are identical. A deterministic model is:

- `activation_id` identifies the scheduled logical occurrence;
- `attempt_id = H(activation_id, attempt_number)` identifies retry attempts;
- `fact_occurrence_id = H(activation_id, output_port, output_index)` preserves multiplicity and is stable across retry;
- `payload_digest = H(canonical_payload_bytes)` deduplicates equal value storage.

Do not use the payload digest as the graph occurrence ID.

## 7. Portable program and recorded dispatch protocol

### 7.1 Portability profiles

| Profile | Intended use | Allowed representation |
|---|---|---|
| `:local` | Direct Workflow or local Runtime backend | Live functions, local hooks, runtime resources |
| `:beam_portable` | Trusted homogeneous BEAM cluster | Versioned safe ETF, reconstructable Runic closure/artifact, matching code fingerprint |
| `:durable_beam` | Journaled remote attempts and replay | `:beam_portable` plus stable identities, replayable mutations, portable outcomes, and context policy |
| `:external_operation` | Language-neutral or untrusted workers | Explicit operation name/version and schema-defined inputs/outputs; no arbitrary AST evaluation |

“Serializable” is therefore a capability result with a diagnostic path, not a boolean inferred from whether ETF accepts a term.

### 7.2 Executable reference

Support two first-class forms:

1. `{:closure, closure_descriptor}` for a self-contained macro-built component. Decode validates the closure and rebuilds the component with `Closure.eval/1`.
2. `{:artifact, artifact_digest, node_digest}` for a workflow artifact already available from an artifact store or deployment. This is preferable for composite components and large graphs.

Custom `Invokable` implementations opt in through a protocol such as:

```elixir
defprotocol Runic.PortableComponent do
  @spec export(struct(), keyword()) :: {:ok, descriptor()} | {:error, diagnostic()}
  def export(component, opts)

  @spec import(descriptor(), keyword()) :: {:ok, struct()} | {:error, diagnostic()}
  def import(descriptor, opts)

  @spec requirements(struct()) :: map()
  def requirements(component)
end
```

The final name is less important than these properties:

- built-in implementations cover every executable Runic primitive and composite;
- directly constructed components that contain only a compiled `work` function and no reconstructable closure/artifact descriptor report `:local_only` unless their implementation supplies an explicit portable codec;
- no fallback silently serializes arbitrary live fields;
- validation walks nested maps, lists, tuples, structs, and closure metadata rather than accepting a shallow ETF round trip;
- errors identify the exact nonportable field and remediation;
- a clean-node round trip is part of the contract suite;
- artifact and component versions can be upcast or rejected explicitly.

### 7.3 Recorded dispatch event

The canonical outbound work intent is a versioned `RunnableDispatchRequested` inside a core-owned recorded-event envelope:

```elixir
%Runic.Runtime.RecordedEvent{
  schema_version: 1,
  event_id: event_id,
  stream_id: execution_id,
  position: position,
  transaction_id: transaction_id,
  authority_epoch: epoch,
  committed_at: utc_datetime,
  correlation_id: invocation_id,
  data: %Runic.Workflow.RunnableDispatchRequested{
    schema_version: 1,
    activation_id: activation_id,
    attempt_id: attempt_id,
    attempt_number: 0,
    graph_revision: graph_revision,
    executable: executable_ref,
    input: {:fact_occurrence, occurrence_id, payload_ref},
    causal: portable_causal_context,
    context: %{ref: context_ref, requirements: context_manifest},
    policy: one_attempt_policy,
    resource_class: resource_hints,
    code: %{release: release_id, digest: code_digest},
    deadline_at: utc_datetime
  }
}
```

This event is committed before `ExecutionBackend.dispatch/3` and is itself recoverable pending work. A local backend consumes it directly. A queue message may carry the recorded event or a durable event reference plus checksum and completion route; that wrapper contains transport mechanics only and does not duplicate Runic lifecycle semantics.

`position`, `event_id`, and `transaction_id` are the authoritative ordering and identity fields. `committed_at` is informational metadata assigned or normalized by the Journal and must never influence replay, scheduling, deduplication, or another deterministic projection. A consensus Journal receives any timestamp as command data; its replicated state machine does not consult a node-local clock.

Do not persist a BEAM reference as the attempt handle. Do not use a monotonic timestamp as a cross-node deadline. Do not embed a whole secret-bearing run context by default. `RunnableDispatchRequested` means “durably exposed for dispatch,” not “broker delivery was proven” or “user code began.”

### 7.4 Context resolution

Compile `context/1,2` usage into a context manifest:

- key and component/global scope;
- required versus defaulted;
- expected portability class (`:inline_value`, `:secret_ref`, `:resource_ref`, `:local_only`);
- optional schema/type hint;
- provider name and version when resolution is deferred.

The compute worker resolves references just before invocation. Values may be inlined only when the caller explicitly marks them transportable. Credentials should be short-lived and scoped to the attempt. Connection pools, repositories, PIDs, ports, and similar resources are reconstructed locally from provider configuration.

Every accepted input receives an invocation/causal-lineage ID and a context reference. Descendant activations inherit that reference even when other inputs arrive concurrently. Context must not be read later from one mutable workflow-global map, because a downstream activation from input A could otherwise observe input B's tenant, secret, or configuration. Retention and revocation of the referenced context become explicit lifecycle policy.

### 7.5 Attempt result command

A worker returns `%Runic.Runtime.AttemptResult{}` with the same execution, activation, attempt, artifact, recorded-dispatch event ID, and dispatch epoch plus:

- `:completed`, `:failed`, `:cancelled`, or `:unknown` status;
- typed outcome data and bounded candidate events or content-addressed payload references;
- a bounded portable error descriptor rather than an arbitrary exception term;
- attempt timing and resource metrics;
- result checksum and worker incarnation;
- an effect/idempotency report when applicable.

The result is a command/proposal, not a recorded event. Candidate events are untrusted data: the authority validates or re-derives them against the committed activation/read set and never applies an arbitrary worker-supplied graph mutation. It emits `RunnableCompleted`, `RunnableFailed`, and corresponding graph events only when the semantic transition is accepted.

### 7.6 One explicit payload-reference model

`nil` is valid workflow data and must not double as “the value was stripped.” Introduce a tagged payload representation used consistently by facts, state events, fan-out/fan-in/join events, lifecycle events, snapshots, recorded dispatch events, and attempt results:

```elixir
%Runic.PayloadRef{
  digest_scheme: :sha256_v1,
  digest: digest,
  codec: :etf_v1,
  byte_size: size,
  namespace: namespace,
  location: opaque_location,
  encryption: encryption_metadata
}
```

Inline values and external references must be distinct variants. Hydration returns explicit `{:ok, value}`, `{:defer, reason}`, or `{:error, reason}` outcomes; an unresolved `FactRef` is never passed to user work as if it were a value. Resolution errors participate in backpressure and retry policy rather than being logged and ignored.

All value-bearing event types use the same externalization rules. Upload content-addressed bytes first, then commit references. Integrity is checked on read, and unreferenced successful uploads are reclaimed by orphan GC.

### 7.7 Security boundary

`Code.eval_quoted/3` is arbitrary code execution. ETF `[:safe]` protects atom creation; it does not make code safe.

The first distributed profile is for trusted workflow authors and authenticated workers. It requires:

- signed or authenticated recorded events and transport wrappers;
- digest and size validation before decode;
- code/artifact allowlists and release compatibility checks;
- no code-on-demand from an untrusted coordinator;
- bounded AST, bindings, errors, and payload metadata;
- tenant-qualified authorization at journal, blob, and broker boundaries;
- secret references rather than secrets in logs and queue messages.

## 8. Journal: the event authority contract

Replace the existing optional-callback `Runic.Runner.Store`. It makes full-log snapshots required, event streaming optional, and the selected semantics depend on `function_exported?` branches. That is the wrong center for a managed event-sourced runtime.

`Runic.Runtime.Journal` lives in the main package and is used by local, SQLite, PostgreSQL, EventStore, and Ra implementations. The behaviours and coordinator are not a separate library; only dependency-heavy implementations need separate packaging.

### 8.1 Required operations

Conceptually:

```elixir
init(opts)
capabilities(state)
load(%StreamRef{namespace: ..., kind: ..., id: ...}, %LoadRequest{after: ..., limit: ...}, state)

commit(
  stream_ref,
  expected_position,
  authority_token,
  %Runic.Runtime.Transaction{
    id: transaction_id,
    ingress: command_dedup_or_nil,
    events: ordered_events,
    payload_assertions: receipts
  },
  state
)

resolve(stream_id, transaction_id, state)
list_work_scopes(cursor, limit, state)
```

Clustered authority acquisition/renewal/release, work-scope enumeration, active-stream scanning, pending-dispatch claims, due-timer claims, snapshots, compaction, and health checks are declared callback groups. A clustered profile requires fencing callbacks; passivation requires work-scope plus active-stream discovery; recoverable delivery and timers require work-scope enumeration plus their claim groups. A small local profile may declare one bounded scope and a bounded full scan. Replay is a correctness fallback only after a stream has been discovered—it cannot discover an unknown dormant stream by itself.

Authority callbacks receive a tenant-qualified `AuthorityRef` whose execution/partition granularity matches `Capabilities.authority_scope`. Discovery and claim callbacks separately receive a `WorkScopeRef` identifying a storage shard that may contain many authority domains; Runtime pages them through `list_work_scopes/3`. This avoids forcing per-execution CAS Journals to pretend a shard-registration key atomically fences every execution, while allowing SQL/Ra Journals to expose partition authority.

The behaviour must define confirmed conflict, stale authority, duplicate command with original receipt, command-ID/content conflict, known committed, known rejected, unavailable, expired proof, and **unknown outcome** separately. Retrying a transaction after a timeout without resolving its transaction ID is incorrect.

### 8.2 Atomic event-transaction contents

One transaction commits an ordered event batch that may represent:

- an optional client-command dedupe assertion `(namespace, command_id, request_digest, acceptance_receipt)`;
- accepted input, signal, cancellation, or completion command;
- ordered Runic graph/runtime events;
- consumed and newly scheduled activations, including portable `RunnableDispatchRequested` events;
- delivery acknowledgements when their retention is semantically required;
- durable timer scheduling/firing/cancellation events;
- cancellation and workflow lifecycle changes;
- snapshot and payload-manifest events/assertions;
- terminal lifecycle events.

The Journal assigns `RecordedEvent` positions and atomically advances the stream head. It atomically claims any client command ID with its request digest and original receipt. A repeated command ID is semantic dedupe even when submitted through a new journal transaction; `transaction_id` separately identifies one storage mutation and resolves its ambiguous outcome. SQL or Ra implementations may maintain active-stream, inbox, pending-dispatch, timer, dedupe, and projection indexes from the same event batch inside the transaction. Those indexes are acceleration/recovery structures; they do not become a parallel semantic history.

Large payload bytes are uploaded before the event transaction and referenced by digest. If the transaction fails, those objects are harmless orphans collected later. Never commit a reference before the object has met the configured durability policy.

### 8.3 Capabilities are explicit

Adapters expose a versioned manifest rather than relying only on `function_exported?`:

```elixir
%Runic.Runtime.Capabilities{
  adapter: journal_module,
  contract_version: 1,
  roles: [:journal],
  authority_scope: :partition,
  capabilities: MapSet.new([
    :atomic_event_transaction,
    :expected_position,
    :fenced_authority,
    :command_dedup,
    :transaction_dedup,
    :work_scope_enumeration,
    :active_stream_index,
    :pending_dispatch_index,
    :durable_timers,
    :snapshot_refs
  ]),
  limits: %{
    max_transaction_bytes: ...,
    max_events: ...,
    command_resolution_horizon: ...,
    transaction_resolution_horizon: ...
  }
}
```

A named clustered profile fails at startup if a mandatory capability is absent. One adapter's capabilities do not claim an end-to-end guarantee; Runtime validates the whole selected profile. “Best effort” must be selected explicitly. Once a receipt/proof falls outside its advertised horizon, resolution returns `:expired`, never `:not_committed`; archived indexes must still prevent unsafe ID reuse.

### 8.4 Decide, commit, then project

The durable coordinator needs a pure decision boundary rather than mutating its authoritative in-memory projection before storage accepts the change:

```elixir
Workflow.decide(command, projection)
# => {:ok, transition_events, metadata}
#  | {:defer, reason}
#  | {:error, reason}

Workflow.apply_events(projection, committed_events)
# => {:ok, new_projection} | {:error, replay_error}
```

The exact public naming can change, but ordering cannot: decide against a pinned projection, commit the events/side records conditionally, then apply only the committed records. Root input, matching, skip/defer, failure propagation, state transitions, downstream activation, and graph mutation all need complete event forms in the journaled path. Local APIs may fuse these stages for speed while preserving equivalent semantics.

## 9. Durable coordination lifecycle

```text
client
  │ submit(command_id, input)
  ▼
journal ── commit input/inbox ──► accepted
  │                                  │ route hint / wakeup
  ▼                                  ▼
authority owner ── replay/prepare ── commit RunnableDispatchRequested event
                                                 │
                                                 ▼
pending-event publisher ─ at-least-once ─ ExecutionBackend ─ compute worker
                                                              │
                                     decode + context + execute one delivery
                                             (same attempt may redeliver)
                                                              │
                                                              ▼
AttemptResult ingress ─── duplicate-safe ── authority owner
                                                 │
                                   fenced commit events + next work
                                                 │
                                                 ▼
                                         acknowledge delivery
```

### 9.1 Input acceptance

Replace fire-and-forget durable input with an acknowledgement API. For a durable call, the caller supplies a stable command ID or obtains it from a preallocation call before submission. If the acceptance reply is lost, only that already-known ID makes retry unambiguous. The runtime returns a typed receipt only after journal commit; a separate cast with a runtime-generated ID may remain as an explicitly best-effort convenience.

The submit path also performs admission control. An unbounded `GenServer.cast` cannot communicate journal saturation, tenant quota, payload rejection, or drain state to the caller.

### 9.2 Activation and authority

The runtime maps an execution key to a logical journal partition, acquires an authority token/epoch, loads snapshot plus tail, and activates an in-memory coordinator. Registry lookup only avoids unnecessary activation attempts; the journal decides who may write.

### 9.3 Prepare and write-ahead dispatch

The owner prepares Runnables using normal Runic semantics and atomically commits portable `RunnableDispatchRequested` events **before** execution is submitted. The Journal may materialize a pending-delivery index from the same transaction, but the event remains the canonical dispatch intent.

The direct local fast path may execute immediately after that commit without a broker. It still uses the same durable attempt identity.

### 9.4 Work execution

An attempt worker:

1. validates the recorded dispatch event and code/artifact compatibility;
2. resolves payload and context references;
3. rebuilds a local Runnable and runs one attempt through `Runic.Runtime.Worker`;
4. writes large results to the configured PayloadStore;
5. submits an `AttemptResult` through the Runtime completion API;
6. acknowledges the work message only after Runtime reports the result durably committed or a known duplicate.

The first contract version has no unnamed durable completion transport. A later result-ingress adapter must define and pass its own durable receipt, dedupe, replay, and ordering conformance before a worker may acknowledge on handoff alone.

Retries, durable backoff, and attempt numbering are coordinator-owned. A remote worker does not sleep across a durable retry policy.

### 9.5 Completion acceptance

The owner validates execution ID, activation ID, attempt ID, artifact revision, the committed dispatch event/epoch, current activation state, and state preconditions. The coordinator uses its own **current** authority token to commit all accepted graph changes and downstream activations atomically.

A failover need not reject every result scheduled by the prior owner. It may accept an old-epoch attempt when the result matches a still-pending committed dispatch and takeover policy has not expired or superseded it. The old coordinator still cannot commit because its writer epoch is fenced.

A duplicate returns the prior commit outcome. A stale attempt is recorded or metered, but cannot mutate the graph.

### 9.6 Failover

After owner loss:

1. another process acquires a higher epoch;
2. it replays committed state and reconstructs pending dispatch events and timers;
3. stale old-owner commits fail;
4. unacknowledged dispatch events are redelivered with the same attempt IDs;
5. in-flight attempts are allowed to finish or expire, but only a valid completion can be accepted;
6. unknown commit outcomes are resolved by transaction ID before any follow-up action.

## 10. Stateful nodes, conflicts, and batching

### 10.1 Read-set preconditions

A prepared activation should carry the state/materialization versions it read. Completion acceptance validates those versions.

- Nonmergeable Accumulators, FanIn, joins, and other stateful nodes serialize acceptance at their logical state key.
- A stale result is rejected and re-prepared or handled by explicit conflict policy.
- `mergeable: true` is an optimization hint, not proof. Later versions may accept commutative deltas after conformance tests establish associativity, commutativity, and idempotence for that component.

### 10.2 Promise and Flow batches

The first durable remote profile records and dispatches one activation per event. Local Promise/Flow optimizations may remain during migration.

A later recorded batch-dispatch event must declare commit semantics:

- `:atomic` — all pure results become one transition or none;
- `:incremental` — each activation has its own result and retryable suffix;
- `:fan_out` — independent occurrence IDs and completion order.

Never infer durable atomicity merely because several operations ran in one process.

## 11. Continuously evolving workflows

Runtime graph evolution is a defining Runic capability and must work in the durable profile.

### 11.1 Replace mutation closures with commands/events

Today a hook may return `{:apply, fn workflow -> ... end}` and a Runnable may carry `hook_apply_fns`. This is useful locally but not a replayable distributed mutation.

Add a declarative path:

- hook execution emits typed hook outcomes/effects;
- graph edits are versioned commands such as add/remove/connect/relabel/update-component;
- commands validate against a graph revision;
- applying a command produces ordinary structural and activation events;
- structural events commit in the same transition as the result that caused them.

Legacy function hooks remain `:local`. Coordinator-local observational hooks may run after commit, but cannot be the only source of authoritative graph state.

### 11.2 Artifact and graph revisions

Each activation records the graph/artifact revision and node digest used at prepare time. A completion from an older revision is accepted only if its activation remains valid under the committed graph history. It must never be reinterpreted using the newest component code by accident.

Long histories need segment rollover or “continue as new” semantics that retain causal linkage while bounding replay and deduplication state.

## 12. Timers, retries, cancellation, and signals

Durable time is journal state, not a sleeping process.

- Persist absolute UTC deadlines plus the scheduling policy/version.
- Maintain a journal-indexed due-timer queue.
- Claim/fence timer firing and record the resulting input/activation atomically.
- Rebuild timers after passivation or failover.
- Treat early/duplicate timer delivery as harmless.
- Keep monotonic time only for local duration measurements.

Cancellation is a committed command. It prevents future activation acceptance, cancels pending dispatch/timer state through events, and causes late completion to be rejected or recorded according to policy. Whether a running external effect can be interrupted is capability-specific.

Signals are ordinary durable inputs with command IDs and optional correlation keys. Query APIs may read a materialized view; they do not mutate state.

## 13. Activation, passivation, and disaggregated memory

An active coordinator is a cache of committed journal truth plus hot facts, not the sole owner of durable state.

Passivate when idle, memory-pressured, rebalanced, or draining:

1. stop accepting new local work;
2. commit/resolve outstanding event transactions;
3. publish or leave committed pending-dispatch events discoverable;
4. optionally save a snapshot;
5. release authority and remove route hints;
6. discard in-memory graph/materializations.

Stopping or migrating an active execution uses an explicit quiesce/drain state machine: reject or redirect new submissions, wait for or expire in-flight attempts according to policy, resolve pending commits, leave dispatch/timer state durable in events and Journal indexes, save an optional snapshot, release the authority token, and only then terminate local backends. A plain process stop is not a migration protocol.

Resume from snapshot plus tail, choose full/hybrid/lazy fact rehydration, and resolve only the values needed by newly prepared work. Fact/blob garbage collection uses committed manifests, snapshot reachability, retention, and an orphan grace period; it must not depend on one process's memory.

The clustered snapshot is a sanitized, versioned snapshot IR containing artifact/graph revision, journal cursor, durable runtime state, payload references, schema/code digest, and integrity metadata. A raw `%Workflow{}` ETF snapshot may remain an explicitly local, same-release optimization, but it is not the portable format: it can contain compiled functions, hooks, policies, and secret-bearing run context. Portable decode uses safe term handling and validates its schema before reconstruction.

## 14. Intentional alpha API replacement

### 14.1 Preserve

- `Workflow` pure APIs and protocols;
- prepare → execute → event-apply semantics;
- `EventApplicator`, `Invokable`, and portable component extensibility;
- local function hooks and policies in the explicitly `:local` portability profile;
- the useful scheduling strategies and Task/GenStage implementations after adapting them to the new contracts.

### 14.2 Replace, not parallelize

- `Runic.Runner` becomes the `Runic.Runtime` public facade and a private coordinator;
- `Runic.Runner.Store` becomes the event-first `Runic.Runtime.Journal` contract; required full-log `save/load` and callback-probing modes are removed;
- `Runic.Runner.Executor` becomes one structured `Runic.Runtime.ExecutionBackend`; local and remote implementations consume committed dispatch events;
- Scheduler moves under `Runic.Runtime.Scheduler` and returns typed plans, while remaining authority-side;
- per-node `execution_mode: :durable` becomes an explicit Runtime guarantee profile;
- completion callbacks become event-driven projections/subscribers rather than lifecycle authority.

### 14.3 Add

- `RecordedEvent`, event codec/upcasters, `Transaction`, `Commit`, and `AttemptResult`;
- content digest and occurrence identity APIs;
- portable component/Runnable validation and codecs;
- transition proposal/read-set data from prepare/apply;
- in-package Journal, ExecutionBackend, PayloadStore, ContextResolver, and Scheduler behaviours;
- durable input/signal/query/cancel APIs;
- capability manifests and profile validation;
- adapter conformance modules.

### 14.4 Remove during the alpha migration

- using `phash2` IDs as durable idempotency identities;
- using `nil` as an implicit externalized-payload marker;
- presenting per-node `execution_mode: :durable` as a run-level durability guarantee when it currently means lifecycle-event emission;
- describing post-execution lifecycle logging as write-ahead durable dispatch;
- clearing uncommitted events on failed/unknown append;
- treating arbitrary hook apply functions as distributable;
- silent fallback from a requested durable profile to local execution;
- calling a broker or process registry the workflow authority.

Known SQLite and PostgreSQL consumers migrate on the contract branch and provide integration fixtures. A short compile-time warning period is reasonable; indefinite dual semantics are not. See [Runic Runtime Contract Upgrade](runic-runtime-contract-upgrade-plan.md).

## 15. Correctness and conformance plan

### 15.1 Core model tests

- Same commands applied to the reference state machine always produce the same transition/state.
- Duplicate input, dispatch, result, timer, cancel, and delivery acknowledgement are idempotent.
- Stale epoch and stale expected-position commits never change state.
- Unknown commit outcome is resolved by transaction ID before retry.
- Identical content with distinct occurrence IDs follows the configured ingress semantics.
- Stateful stale-read completion is rejected or re-prepared.
- Runtime graph mutation replay is equivalent to uninterrupted application.

### 15.2 Portable execution tests

Use `:peer` to decode on a clean BEAM node:

- anonymous macro-built component with explicit captured bindings;
- `context/1,2` manifest and provider resolution;
- rules, conditions, maps, reduces, accumulators, state machines, joins, and custom `Invokable`s;
- artifact/code mismatch rejection;
- PID, port, reference, local-only function, connection, and secret-policy diagnostics;
- oversized/corrupt/untrusted recorded-event rejection;
- old recorded-event/attempt-result upcasting.

### 15.3 Adapter fault suite

The in-package `Runic.Runtime` conformance kit injects faults at:

- before journal write, after durable write/before reply, and during retry;
- after `RunnableDispatchRequested` commit/before delivery, after delivery/before acknowledgement;
- before side effect, after side effect/before result, after result/before work acknowledgement;
- owner pause, kill, restart, network partition, and epoch replacement;
- payload upload success with event-transaction failure and a committed reference with simulated missing object;
- snapshot creation, compaction, restore, and rolling version upgrade.

At least the reference model and each clustered Journal adapter need state-machine/property testing. Consensus/native profiles additionally need multi-node partition and long-running chaos tests; a few happy-path `:peer` tests are insufficient.

## 16. Implementation phases and gates

### Phase 0 — freeze semantics and build a reference model

Deliver:

- guarantee ADR and terminology;
- identity hierarchy and event-transaction schema;
- pure in-memory Journal state machine/reference model;
- fault matrix and model-based test harness;
- final Runtime behaviour shapes and capability profiles.

Gate: every ambiguous outcome has a specified recovery action; no API claims arbitrary exactly-once effects.

### Phase 1 — repair local durability correctness

Deliver:

- propagate append/fact errors and retain uncommitted data;
- explicit Worker error/retry state;
- durable acknowledged input API with caller-known command IDs and atomic command receipts;
- pre-execution dispatch intent in a reference durable path;
- abnormal restart loads committed truth;
- one chronological structural/runtime/lifecycle event fold, including failure and skip projections;
- serialize nonmergeable state preparation/acceptance and define stale-read behavior;
- explicit payload references and fail/defer hydration behavior;
- stable transaction/activation/attempt IDs independent of graph-local hashes;
- tests that kill the process at every persistence boundary.

Gate: no accepted input or committed transition is lost under injected local process crashes and Journal errors.

### Phase 2 — portable Runic execution

Deliver:

- component/artifact export-import protocol;
- recorded `RunnableDispatchRequested` event and attempt-result command v1;
- built-in component codecs and custom `Invokable` opt-in;
- context manifest/provider API;
- invocation-scoped context lineage and overlapping-input isolation tests;
- code/artifact fingerprints, checksums, limits, and upcaster registry;
- graph-mutation commands replacing distributed apply functions.

Gate: clean-node round trips cover all built-in executable component families, including captured bindings and runtime context.

### Phase 3 — dependency-light in-package `Runic.Runtime`

Deliver:

- Journal, ExecutionBackend, PayloadStore, ContextResolver, and typed Scheduler/PlanningView behaviours;
- durable coordinator and completion applier;
- client-command/transaction dedupe plus active-stream/pending-dispatch/timer projections derived from events;
- direct local durable backend;
- capability/profile validation and public conformance suites.

Gate: two coordinators racing on one execution cannot both commit, and duplicate work/results do not duplicate graph transitions.

### Phase 4 — durable timers, cancellation, activation lifecycle

Deliver:

- timer index and durable retry scheduling;
- signals, cancellation, heartbeat/attempt expiry;
- activation/passivation and drain/rebalance;
- snapshot write/prune policy and fact/blob lifecycle.

Gate: passivation and owner loss at every lifecycle point replay to equivalent state with no stuck durable work.

### Phase 5 — distributed optimization

Deliver only after measurement:

- recorded batch-dispatch events and partial completion;
- mergeable state deltas;
- data-locality scheduling and fact caching;
- partition split/move protocol;
- continue-as-new/segment rollover;
- external-operation/cross-language profile.

Gate: each optimization passes the same reference semantics and chaos suite as the unoptimized path.

## 17. Decisions to close before implementation

1. Which optional audit events, if any, should distinguish broker acceptance and worker start from the canonical `RunnableDispatchRequested` intent without becoming correctness inputs?
2. Is authority per execution, per virtual partition, or configurable? The default recommendation is virtual partitions with per-execution ordered streams.
3. Which cryptographic digest and canonical encoding become content-address version 1?
4. Does a repeated identical root fact default to memoized content or a distinct ingress occurrence?
5. Which graph mutation commands are required to replace existing hook apply closures?
6. What minimum code fingerprint is required: release, module set, artifact digest, or all three?
7. How long are command IDs, attempt records, and completion dedupe entries retained after continue-as-new or archival?
8. Which runtime-context classes may be inlined, encrypted, or resolved only on workers?
9. What is the first snapshot/compaction policy compatible with long-lived evolving graphs?
10. Which effect patterns become first-class after the base transition protocol is correct?

## 18. Relationship to prior plans

| Prior document | Retained | Superseded/clarified here |
|---|---|---|
| [Runtime Contract Upgrade](runic-runtime-contract-upgrade-plan.md) | Concrete breaking behaviour/API sequence and consumer migrations | This document owns the broader distributed correctness model |
| [Causal Runtime Architecture](causal-runtime-architecture.md) | Causal ancestry and prepare → execute → apply | Adds storage-fenced distributed acceptance |
| [Three-Phase Summary](three-phase-summary.md) | Implemented three-phase seam | Runnable portability is capability-based; macro closures are reconstructable |
| [Full-Breadth Runner Scheduling](full-breadth-runner-scheduling-considerations.md) | Local scheduling strategies and process-agnostic execution seam | One structured ExecutionBackend replaces the local `work_fn` contract for both local and remote implementations |
| [Phase 8 Distribution Primitives](phase-8-distribution-primitives.md) | Remote compute, capability discovery, `:peer` testing | Journal authority precedes remote dispatch; `:pg`/`:global` are not durable fences; Ra/CASPaxos do not mean exactly-once effects |
| [Ecosystem Integration Evaluation](ecosystem-integration-evaluation.md) | Adapters remain separate packages | Updated ranking, Group/EKV/`ra_registry`, certified profiles, bounded Khepri role |
| [Checkpointing Plan](checkpointing-implementation-plan.md) and [Snapshot Policy](snapshot-checkpoint-policy-implementation-plan.md) | Stream replay, facts, snapshot-tail recovery | Clustered snapshot writes, compaction, manifests, and error semantics become runtime requirements |
| Libbit clustered research | Journal fence, outbox, broker independence, stable storage voters | Runic closures are not categorically nonportable; Libbit persistence details do not define Runic's package boundary |

## 19. Primary research references

- Restate: [architecture](https://docs.restate.dev/references/architecture) and [durable execution engine from first principles](https://www.restate.dev/blog/building-a-modern-durable-execution-engine-from-first-principles/)
- Temporal: [service architecture](https://github.com/temporalio/temporal/blob/main/docs/architecture/README.md)
- DBOS: [architecture](https://docs.dbos.dev/architecture) and [workflow recovery](https://docs.dbos.dev/production/workflow-recovery)
- RabbitMQ Ra: [project](https://github.com/rabbitmq/ra) and [state-machine tutorial](https://github.com/rabbitmq/ra/blob/main/docs/internals/STATE_MACHINE_TUTORIAL.md)
- CASPaxos: [paper, protocol, membership, deletion, and safety proof](https://arxiv.org/abs/1802.07000)
- Phoenix Group: [features and consistency model](https://github.com/phoenixframework/group)
- EKV: [storage and CAS consistency](https://github.com/chrismccord/ekv)
- Khepri: [architecture and limitations](https://github.com/rabbitmq/khepri)
- Broadway: [core documentation](https://hexdocs.pm/broadway/Broadway.html) and [acknowledger contract](https://hexdocs.pm/broadway/Broadway.Acknowledger.html)
- PostgreSQL: [transaction isolation](https://www.postgresql.org/docs/current/transaction-iso.html)
- Kafka: [design](https://kafka.apache.org/41/design/design/)
