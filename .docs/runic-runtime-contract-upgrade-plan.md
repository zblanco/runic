# Runic Runtime Contract Upgrade Plan

**Status:** Proposed near-term breaking upgrade
**Date:** 2026-07-31
**Updated:** 2026-08-02
**Target baseline:** Runic `0.1.0-alpha.8` at `75ed26f`
**Companion plans:** [Distributed Durable Runtime Core](distributed-durable-runtime-core-plan.md), [Distributed Adapter Portfolio](distributed-adapter-portfolio-plan.md), [Runic PostgreSQL Library](runic-postgres-library-implementation-plan.md), [Runic Ra Journal and Native Profile](runic-raft-native-runtime-plan.md), [Runic CASPaxos Execution-Cell Journal and Registration Profile](runic-caspaxos-native-runtime-plan.md)
**Implementation references:** Infinite Isekai, RunicAI, Compendium

## Executive decision

Put the managed execution system in the main Runic package under `Runic.Runtime`. Do not extract a separate `runic_runtime` library, and do not preserve the current `Runic.Runner.Store` and zero-arity-function `Runic.Runner.Executor` contracts merely because they already exist.

Runic is still alpha. The right near-term move is one intentional breaking contract upgrade:

1. Keep `Runic.Workflow` as the topology-free, functional graph VM.
2. Make `Runic.Runtime` the small public facade that manages durable executions of that VM.
3. Make Runic's versioned, chronological construction and lifecycle event stream the canonical rebuild, persistence, replication, and audit protocol.
4. Replace `RunnableDispatched` with `RunnableDispatchRequested`, a portable, pre-execution, journal-committed intent. The recorded request may cross a node or broker boundary; the live `%Runnable{}` remains an authority/worker-local execution projection.
5. Replace `Runner.Store` with a deep `Runic.Runtime.Journal` behaviour whose smallest required operation is an atomic, conditional event transaction—not a collection of snapshot and append conveniences.
6. Replace the current local-only Executor contract with one structured `Runic.Runtime.ExecutionBackend` behaviour used by Task, GenStage, direct distributed BEAM, Broadway, and other delivery implementations.
7. Keep dependency-heavy implementations in consuming applications or separate packages. The runtime contracts, coordinator, event codec, local implementations, and conformance suites belong in Runic.

The objective is not to expose every distributed-systems mechanism as a port. It is to hide admission, event ordering, persistence failure, replay, dispatch recovery, retries, and completion validation behind a small runtime API while preserving extension points at boundaries that genuinely vary.

## 1. Why change the contracts now

The existing behaviours were good scaffolding for proving local Runner composition, but their shapes now leak the implementation choices of that prototype:

- `Runner.Store` requires full-log `save/load`, makes incremental events optional, and selects semantics through `function_exported?` checks.
- `Runner.Executor` accepts a zero-arity closure and requires Task-shaped Erlang messages and reference handles.
- `RunnableDispatched` is constructed inside execution and returned with the result, so it is persisted after the work it claims was dispatched; its name would be false for the new write-ahead meaning.
- the Worker mutates first, appends later, and can clear uncommitted buffers after an ignored store error;
- lifecycle status, snapshots, projections, and retry behavior are spread across the Worker, PolicyDriver, Store adapters, and consumer callbacks;
- `execution_mode: :durable` currently selects lifecycle event emission, not a complete durability guarantee.

These are not contracts worth stabilizing. A compatibility bridge would make every future adapter implement or emulate two models and would leave correctness dependent on which optional callbacks happen to exist.

The known consumers are few, accessible, and already contain useful migration fixtures. A breaking alpha release is cheaper than years of conditional branches around a shallow storage interface.

## 2. Design philosophy: deep runtime, narrow public surface

The runtime should follow four abstraction rules.

### 2.1 Hide mechanisms that callers should not coordinate

A caller should not separately:

- append input events;
- discover the current writer;
- plan Runnables;
- persist dispatch intent;
- publish work;
- remember retry timers;
- correlate completion;
- append graph events;
- update terminal status;
- decide whether a timeout means committed or not.

`Runic.Runtime.submit/3` and `Runic.Runtime.complete/3` should hide those sequences and return explicit confirmed, rejected, unavailable, or unknown outcomes.

### 2.2 Keep the functional VM independently usable

The managed runtime does not replace:

- `Workflow.prepare_for_dispatch/1`;
- `Invokable.execute/2`;
- chronological `Workflow.apply_event/2`;
- direct `Workflow.react/2` and `react_until_satisfied/2` usage.

Users who want a custom process model can continue to drive the three phases themselves. `Runic.Runtime` is the first-party imperative shell, not a mandatory topology.

### 2.3 Make optional callbacks optimize, not redefine, semantics

An optional callback is safe when Runic has a correct fallback, such as a snapshot accelerator or indexed pending-dispatch query. An optional callback is unsafe when its presence silently changes whether input is durable or writers are fenced.

Correctness-critical callback sets are advertised through capabilities and validated when the runtime starts. A requested `:clustered` profile fails to start if the Journal lacks fencing; it never falls back to local best effort.

### 2.4 Keep one semantic model across local and distributed execution

Local Task execution, a Broadway worker, and a Ra-native worker all consume the same committed dispatch semantics and return the same attempt-result command. The fast path can retain an in-memory prepared Runnable cache, but it cannot invent a second lifecycle protocol.

## 3. Evidence from implemented consumers

### 3.1 Infinite Isekai: PostgreSQL event and fact storage

Infinite Isekai implements `Runic.Runner.Store` directly in [`PostgresStore`](../../infinite_isekai/lib/infinite_isekai/workflows/postgres_store.ex). It persists construction and lifecycle events as ordered ETF rows, stores fact values separately, resumes through `Runner.resume`, and rebuilds administrative views through `Workflow.from_events/2`.

Useful evidence:

- real PostgreSQL event-stream and cold-fact decomposition;
- broad use of macro-captured bindings, demonstrating the value of Closure AST plus explicit binding reconstruction;
- workload-specific checkpoint and batching policies;
- persisted construction events already rebuilding workflows.

Contract pressure exposed by the implementation:

- sequence allocation is count-based and has no expected-position compare, writer epoch, or transaction ID;
- run status is patched as an adapter projection outside the canonical event transition;
- raw ETF rows and fact hashes have no schema version, integrity, namespace, or collision contract;
- local Registry ownership remains unsafe on multiple connected application nodes;
- durable steps publish PubSub effects directly and can duplicate them on retry;
- [`WorkflowComposer`](../../infinite_isekai/lib/infinite_isekai/workflows/workflow_composer.ex) can silently fall back from Runner execution to a local reaction, weakening the apparent guarantee.

### 3.2 RunicAI: workspace SQLite plus a parallel application runtime

RunicAI's [`RunnerStore`](../../runic_ai/lib/runic_ai/persistence/runner_store.ex) uses one workspace SQLite database for ordered Runic events, facts, snapshots, runnable projections, definitions, artifacts, and product read models. [`Replay`](../../runic_ai/lib/runic_ai/persistence/replay.ex) proves the event stream is the execution reconstruction contract.

It also had to create its own [`Runtime.Backend`](../../runic_ai/lib/runic_ai/runtime/backend.ex), [`Runtime.Scheduler`](../../runic_ai/lib/runic_ai/runtime/scheduler.ex), session server, Runner support, polling loop, and separate prepare/execute/apply executor. This is direct evidence that the missing coordinator belongs in Runic rather than in every consumer.

Useful patterns:

- immutable workflow definition revisions and exact compiled-artifact pins;
- SHA-256 child invocation keys, attempt lineage, and completed-result reuse;
- `context/1,2` for worker-local sinks, policies, workspaces, and credentials;
- distinct authoritative event rows and queryable lifecycle projections;
- one tiny public runtime facade hiding several application processes.

Warnings:

- the current Store callback cannot express conditional commit, fencing, dedupe, or unknown-result recovery;
- the adapter must filter construction events and recompile a pinned IR before replay when artifacts contain direct functions;
- a child-workflow component captures a `%SQLite.Store{}` with process-local ownership data, illustrating a value that must be diagnosed as local-only and moved to runtime context;
- its nominal persistence behaviour is mostly optional while real code pattern-matches the SQLite store, demonstrating that a shallow “extensible” interface can hide nothing.

### 3.3 Compendium: local SQLite and construction-time graph expansion

Compendium's [`SQLiteStore`](../../compendium/lib/compendium/runic/sqlite_store.ex) separates managed definitions, concrete run UUIDs, ordered events, snapshots, facts, and artifact references. Its tests exercise event reconstruction and a controlled process restart after confirmed event appends. They do not prove recovery from a crash during execution, dispatch, an ambiguous append, or the completion gap.

Container ingestion expands the graph during workflow construction, adding explicit branch and fan-in edges with deterministic names. This is evidence for graph-native causal joins and reproducible constructed topology, not yet for runtime graph mutation or a continuously evolving journal.

Useful patterns:

- SQLite as an executable local Journal specification;
- separate event, fact, snapshot, and external-artifact tables;
- deterministic string identities for construction-time branches;
- graph-native causal completion;
- event paging and bounded SQLite busy retries.

Warnings:

- correctness-sensitive Store calls resolve “the latest run” behind a reusable workflow key instead of carrying an immutable execution ID;
- raw `%Workflow{}` snapshots are not wired to Runner's snapshot callbacks and actual resume replays the full stream;
- terminal status and read-model refresh occur in an ephemeral completion callback after final event persistence;
- runtime resources are embedded in ordinary workflow input instead of `context` requirements;
- `on_complete` checkpointing for large effectful fan-out can repeat a large amount of work after a crash;
- its own plan correctly describes the guarantee as local and best effort, not cluster-safe.

### 3.4 Cross-consumer conclusion

All three consumers independently added:

- run/execution metadata;
- lifecycle projections;
- event encoding;
- fact storage;
- restart orchestration;
- completion callbacks or polling;
- product-specific status repair;
- implicit durability profiles.

That repetition is the strongest argument for `Runic.Runtime` in the main package. The reusable semantics are not PostgreSQL, SQLite, Ecto, or a particular process tree; they are the event transaction, execution identity, dispatch lifecycle, replay, and public coordinator API.

## 4. One canonical chronological event protocol

### 4.1 Construction and lifecycle events form one logical history

Runic's construction events are not merely diagnostics. They rebuild the graph. Runtime events rebuild graph memory, activations, state, and execution lifecycle. The authoritative stream therefore contains, in original order:

- workflow/component construction and mutation;
- input acceptance and signals;
- fact and activation transitions;
- dispatch attempts;
- accepted completion/failure/cancellation;
- timers and retries;
- terminal lifecycle state.

`Workflow.from_events` must become a strict chronological fold. It must not split structure/lifecycle from runtime events and later merge partial projections.

For reusable definitions, this is one **logical** history and need not be one physical stream. An immutable, content-addressed construction-event stream becomes the workflow artifact. The execution stream begins by pinning its exact digest/cursor, then contains input, lifecycle, and runtime graph-mutation events. `Replay` resolves the pinned construction prefix first and folds the execution stream in order. Product authoring IR can coexist, but it is not a second Runic execution truth and adapters may not perform ad hoc event filtering.

### 4.2 Add a storage and replication envelope

Domain event structs remain ergonomic. Persistence and replication use a core-owned wrapper:

```elixir
%Runic.Runtime.RecordedEvent{
  schema_version: 1,
  event_id: event_id,
  stream_id: execution_id,
  position: position,
  transaction_id: transaction_id,
  authority_epoch: epoch,
  causation_id: causation_id,
  correlation_id: correlation_id,
  committed_at: committed_at,
  data: %Runic.Workflow.RunnableDispatchRequested{...}
}
```

The Journal assigns position and commit metadata. Runic owns envelope and built-in event codec versions, safe decode rules, and upcasters. An adapter may store opaque encoded bytes, structured columns, or both, but does not invent the Runic schema lifecycle.

`position`, `event_id`, and `transaction_id` are authoritative. `committed_at` is diagnostic metadata and must never affect replay, scheduling, deduplication, or another deterministic projection. A consensus Journal receives a timestamp as command data or normalizes it at the boundary; replicated code never reads a node-local clock while applying an event transaction.

### 4.3 Replace `RunnableDispatched` with a truthful portable intent

Use the alpha window to rename the event rather than overload an observation in the past tense:

> `RunnableDispatchRequested` means that an attempt was durably accepted for dispatch and is recoverably visible to the configured ExecutionBackend. It does not claim that a backend accepted it, a broker delivered it, or user code started.

The event is committed before `ExecutionBackend.dispatch/3`. It contains or references everything a compatible worker needs:

```elixir
%Runic.Workflow.RunnableDispatchRequested{
  schema_version: 1,
  activation_id: activation_id,
  attempt_id: attempt_id,
  attempt_number: attempt_number,
  graph_revision: graph_revision,
  node: %{name: node_name, digest: node_digest},
  executable: executable_ref,
  input: input_occurrence_or_payload_ref,
  causal_context: portable_causal_context,
  context: %{ref: invocation_context_ref, requirements: context_manifest},
  policy: one_attempt_policy,
  resource_class: resource_hints,
  code: code_manifest,
  deadline_at: deadline
}
```

Remove local monotonic timestamps, raw arbitrary policy functions, and ambiguous content-hash identity from the durable form. Diagnostic timestamps belong in `RecordedEvent.committed_at` or telemetry.

The recorded event may be transported directly between BEAM nodes. A broker adapter may wrap it or send an event reference plus checksum and completion route. That transport wrapper contains delivery mechanics only; it is not a parallel workflow-lifecycle model. Optional delivery/worker-start observations belong in telemetry or separately named audit events; they never replace the write-ahead request.

### 4.4 Keep `%Runnable{}` as an execution projection

`%Runnable{}` remains valuable:

- authority-side prepare produces it;
- a local backend can retain it in a transient cache keyed by activation ID;
- a remote worker rebuilds it from the recorded dispatch event and artifact/context providers;
- `Invokable.execute/2` produces typed candidate events/result data.

The live struct is not itself the journal record because it may contain compiled functions, local hooks, resources, and post-execution fields. This is not a rejection of Runnable portability; it is a separation between portable semantic data and a locally executable projection.

### 4.5 Results cross as commands, then become events

A worker sends a portable `%Runic.Runtime.AttemptResult{}` carrying execution, activation, attempt, recorded-dispatch event/epoch, artifact/revision, outcome, payload references, portable error, metrics, and checksum.

It is a command/proposal, not yet an authoritative historical fact. The coordinator validates it against the committed dispatch, activation, attempt, graph/state revision, cancellation state, and payload integrity, then commits with the coordinator's current authority token. An attempt scheduled under the prior owner may still be accepted after failover if it remains pending; the dispatch epoch is correlation data, not permission for the worker to write. Only an accepted decision emits and commits `RunnableCompleted`, `RunnableFailed`, retry/timer, fact, activation, and terminal events.

This preserves a precise distinction:

- `RunnableDispatchRequested` is recorded before work and can drive delivery;
- `AttemptResult` is untrusted/retryable ingress;
- `RunnableCompleted` or `RunnableFailed` means the result was accepted into Runic history.

Use the same terms throughout implementation: a **command/proposal** requests change; `Workflow.decide` produces a semantic **transition** as ordered domain events; a Journal **transaction** conditionally commits that batch once; the Journal assigns authoritative **RecordedEvents**. A client `command_id` deduplicates semantic ingress, while `transaction_id` resolves one possibly ambiguous storage mutation.

## 5. Public `Runic.Runtime` facade

Separate the supervised Runtime service from creation and lifecycle of an execution. `start_link/1` follows OTP conventions and does not leak a one-process-per-workflow topology:

```elixir
Runic.Runtime.start_link(runtime_opts) # => GenServer.on_start()
Runic.Runtime.start_execution(runtime, %Runic.Runtime.StartExecution{}, opts)
Runic.Runtime.open_execution(runtime, %Runic.Runtime.ExecutionRef{}, opts)
Runic.Runtime.submit(runtime, handle, %Runic.Runtime.InputCommand{}, opts)
Runic.Runtime.signal(runtime, handle, %Runic.Runtime.SignalCommand{}, opts)
Runic.Runtime.complete(runtime, attempt_result, opts)
Runic.Runtime.cancel(runtime, handle, %Runic.Runtime.CancelCommand{}, opts)
Runic.Runtime.query(runtime, handle, query, opts)
Runic.Runtime.passivate(runtime, handle, admin_opts)
```

`passivate/3` is an administrative optimization that quiesces an in-memory projection; it is not cancellation and does not change durable lifecycle state. Ordinary Runtime process shutdown remains an OTP supervision operation.

Creation returns a serializable handle containing stable identity and routing information, not a Journal module or coordinator PID that becomes stale after migration:

```elixir
{:ok, %Runic.Runtime.Handle{
  namespace: namespace,
  execution_id: execution_id,
  runtime_ref: runtime_ref,
  profile: :durable_single_node
}}
```

`open_execution/3` activates or routes to existing durable state; recovery belongs to Runtime rather than individual adapters or consumer managers.

Every durable creation, input, signal, and cancellation command carries a caller-stable command ID and canonical request digest. A typed `%CommandReceipt{command_id, transaction_id, position, outcome, recovery}` is returned only after the Journal confirms acceptance. If the reply is lost, resubmitting the same command ID and digest returns that receipt; reusing the ID with different content is a conflict. Runtime-generated IDs are allowed only for an explicitly best-effort call or through a preallocation API that gives the ID to the caller before submission.

The API never silently downgrades a requested guarantee. A handle reports the selected profile, while the concrete adapter composition remains observable through administration/telemetry rather than becoming part of the application data model.

The internal coordinator follows one sequence:

```text
command -> decide events -> conditional Journal commit -> apply recorded events
        -> deliver pending dispatch events -> accept result command -> repeat
```

The in-memory Workflow is a projection of committed events. It is never advanced past the Journal and then treated as authoritative after an append failure.

## 6. Behaviour interfaces

Only boundaries with independently varying failure and deployment semantics become behaviours in the first upgrade.

### 6.1 `Runic.Runtime.Journal`

This replaces `Runic.Runner.Store`; there is no permanent legacy bridge.

```elixir
defmodule Runic.Runtime.Journal do
  @callback init(keyword()) :: {:ok, state()} | {:error, adapter_error()}
  @callback capabilities(state()) :: Runic.Runtime.Capabilities.t()

  @callback load(Runic.Runtime.StreamRef.t(), Runic.Runtime.LoadRequest.t(), state()) ::
              {:ok, Runic.Runtime.ReplayPage.t(), state()}
              | {:not_found, state()}
              | {:error, adapter_error(), state()}

  @callback commit(
              Runic.Runtime.StreamRef.t(),
              expected_position(),
              authority_token(),
              Runic.Runtime.Transaction.t(),
              state()
            ) ::
              {:ok, Runic.Runtime.Commit.t(), state()}
              | {:duplicate_command, Runic.Runtime.CommandReceipt.t(), state()}
              | {:command_conflict, command_id(), state()}
              | {:conflict, actual_position(), state()}
              | {:stale_authority, state()}
              | {:unknown, transaction_id(), state()}
              | {:error, adapter_error(), state()}

  @callback resolve(Runic.Runtime.StreamRef.t(), transaction_id(), state()) ::
              {:committed, Runic.Runtime.Commit.t(), state()}
              | {:not_committed, state()}
              | {:unknown, state()}
              | {:expired, Runic.Runtime.Retention.t(), state()}
              | {:error, adapter_error(), state()}
end
```

`StreamRef` is tenant qualified (`namespace`, stream kind, immutable ID). `LoadRequest` names an exclusive event position, optional compatible snapshot, and bounded page size; `ReplayPage` owns decoded records and the next cursor, never an adapter-owned lazy enumerable tied to an open connection.

The transaction is declarative:

```elixir
%Runic.Runtime.Transaction{
  id: transaction_id,
  ingress: %Runic.Runtime.CommandDedup{
    scope: stream_ref,
    id: command_id,
    kind: :input,
    request_digest: request_digest,
    receipt: acceptance_receipt
  },
  events: ordered_domain_events,
  payload_assertions: durability_receipts
}
```

`ingress` is optional for internal transitions. When present, the Journal atomically asserts command-ID uniqueness with event append. The same ID and digest returns the original receipt even if a retry uses a new transaction ID; the same ID with a different digest is a conflict. Transaction ID instead identifies one conditional storage mutation and resolves its ambiguous outcome. `Commit` contains assigned recorded events and any command receipt. These identities must not be conflated.

A Journal may atomically maintain active-stream, pending-dispatch, timer, dedupe, or query indexes derived from events, but the event stream remains the canonical semantic record.

Required semantics:

- atomic batch append;
- expected-position comparison;
- transaction-ID dedupe and unknown-outcome resolution for the advertised horizon;
- atomic client-command dedupe and original acceptance receipts for the advertised command horizon;
- authoritative positions returned by storage;
- explicit errors that cannot be discarded;
- versioned event bytes/envelopes.

All adapters use the same closed error classes: retryable unavailable/overloaded, unauthorized, invalid, corrupt, unsupported capability, and internal adapter failure. `:unknown` is reserved for an operation whose commit status cannot yet be established; it is never a generic error.

Capability groups add exact optional callbacks to the same deep Journal behaviour rather than creating parallel persistence interfaces:

```elixir
@callback acquire_authority(Runic.Runtime.AuthorityRef.t(), owner_incarnation(), authority_opts(), state()) ::
            {:ok, authority_token(), state()} | {:busy, retry_at(), state()} | {:error, adapter_error(), state()}
@callback renew_authority(authority_token(), authority_opts(), state()) ::
            {:ok, authority_token(), state()} | {:stale_authority, state()} | {:error, adapter_error(), state()}
@callback release_authority(authority_token(), state()) :: :ok | {:error, adapter_error()}

@callback list_work_scopes(cursor(), pos_integer(), state()) ::
            {:ok, [Runic.Runtime.WorkScopeRef.t()], next_cursor(), state()} | {:error, adapter_error(), state()}
@callback scan_active(Runic.Runtime.WorkScopeRef.t(), cursor(), pos_integer(), state()) ::
            {:ok, [Runic.Runtime.StreamRef.t()], next_cursor(), state()} | {:error, adapter_error(), state()}
@callback claim_deliveries(Runic.Runtime.WorkScopeRef.t(), claimant(), lease_duration(), pos_integer(), state()) ::
            {:ok, [Runic.Runtime.DeliveryClaim.t()], state()} | {:error, adapter_error(), state()}
@callback renew_delivery_claim(Runic.Runtime.DeliveryClaim.t(), lease_duration(), state()) ::
            {:ok, Runic.Runtime.DeliveryClaim.t(), state()} | {:stale_claim, state()} | {:error, adapter_error(), state()}
@callback release_delivery_claim(Runic.Runtime.DeliveryClaim.t(), delivery_disposition(), state()) ::
            :ok | {:stale_claim, state()} | {:error, adapter_error(), state()}

@callback claim_dispatch_publications(Runic.Runtime.WorkScopeRef.t(), backend_target(), claimant(), lease_duration(), pos_integer(), state()) ::
            {:ok, [Runic.Runtime.PublicationClaim.t()], state()} | {:error, adapter_error(), state()}
@callback ack_dispatch_publication(Runic.Runtime.PublicationClaim.t(), delivery_receipt(), state()) ::
            :ok | {:stale_claim, state()} | {:error, adapter_error(), state()}
@callback release_dispatch_publication(Runic.Runtime.PublicationClaim.t(), state()) ::
            :ok | {:stale_claim, state()} | {:error, adapter_error(), state()}
@callback claim_due_timers(Runic.Runtime.WorkScopeRef.t(), claimant(), observed_time(), pos_integer(), state()) ::
            {:ok, [Runic.Runtime.TimerClaim.t()], state()} | {:error, adapter_error(), state()}
@callback release_timer(Runic.Runtime.TimerClaim.t(), state()) :: :ok | {:error, adapter_error()}
```

The eventual behaviour marks those callbacks optional, grouped by advertised capability. The `:clustered` profile requires authority callbacks and stale-epoch rejection. Any profile that passivates executions requires work-scope enumeration plus an active-stream discovery index. Any profile that promises recoverable outbox delivery or durable timers requires work-scope enumeration plus the corresponding claim group. A declared small/local profile may expose one bounded static scope and use a bounded full-stream scan, but “replay fallback” is not a discovery algorithm when no stream enumeration exists. A local Journal uses an explicit single-writer token rather than pretending to implement distributed leases.

Capability metadata advertises `authority_scope: :execution | :partition`. `AuthorityRef` is tenant qualified and identifies exactly the execution or partition domain fenced by one token. Runtime may reuse a partition token for several execution streams only when the Journal atomically validates that partition authority with every stream mutation. This keeps per-execution CAS/register Journals valid without pretending that a separate partition registration key can fence unrelated cells.

`WorkScopeRef` separately identifies the physical/logical storage shard over which active streams, pending dispatches, and due timers are enumerated. One work scope may contain many execution-scoped authority domains. Runtime obtains current scopes through paged `list_work_scopes/3` rather than overloading an authority reference as both an execution fence and a shard scan cursor. Scope identity and placement generation are stable cursor data; a topology change cannot silently drop a scope that still contains recoverable work.

Direct delivery and external publication are separate capability groups. `claim_deliveries/5` leases canonical attempts to an in-process/direct queue; semantic Runtime completion resolves the pending obligation, while renewal/release use the exact claim token. `claim_dispatch_publications/6` leases an outbox handoff to a selected external backend, and `ack_dispatch_publication/3` records broker/backend acceptance without claiming the consumer completed. A Journal may implement either or both groups.

Those claim callbacks and `claim_due_timers/5` return bounded collections of individually durable claims; no callback promises one all-or-nothing transaction across several execution streams. Lease inputs are durations and the authoritative adapter clock computes deadlines. SQL/Ra adapters may batch atomically when co-located. Per-key adapters may claim candidates independently and return only successful claims, while preserving stale-claim rejection and eventual recovery visibility.

`scan_active/4` guarantees durable eventual completeness for its declared work scope, not necessarily a linearizable multi-stream snapshot. Cursor semantics must not permanently miss a concurrent marker inserted behind the current page: adapters use monotonic inventory revisions, repeatable generations, or a documented reconciliation pass.

Snapshots are referenced by ordinary committed events and surfaced in replay pages. Snapshot creation, compaction, and health callbacks may be optional accelerators, but each optional callback has either a defined bounded fallback or an explicit profile requirement.

Capability metadata also publishes transaction and command-resolution horizons. After proof is evicted, `resolve` returns `:expired`—never `:not_committed`. A clustered execution retains accepted command receipts for at least the active execution lifetime plus its published retry/archive window; compact transaction receipts may use a shorter published horizon if archived indexes still prevent unsafe reuse.

`:not_committed` is an affirmative authoritative exclusion proof inside that horizon, not absence from a local/current value. A CAS/register adapter may need to choose a receipt-only negative record before returning it; SQL/Ra adapters may prove it through their authoritative transaction/dedup state. If that proof mutation is ambiguous, `resolve` remains `:unknown`.

### 6.2 `Runic.Runtime.ExecutionBackend`

This replaces the current zero-arity work-function and Task-message Executor contract.

```elixir
defmodule Runic.Runtime.ExecutionBackend do
  @callback init(keyword()) :: {:ok, state()} | {:error, adapter_error()}
  @callback capabilities(state()) :: Runic.Runtime.Capabilities.t()

  @callback dispatch(
              Runic.Runtime.RecordedEvent.t(),
              Runic.Runtime.DispatchContext.t(),
              state()
            ) ::
              {:accepted, delivery_receipt(), state()}
              | {:backpressure, retry_at(), state()}
              | {:unknown, delivery_id(), state()}
              | {:error, adapter_error(), state()}

  @callback dispatch_batch(
              [{Runic.Runtime.RecordedEvent.t(), Runic.Runtime.DispatchContext.t()}],
              state()
            ) :: {[Runic.Runtime.DispatchOutcome.t()], state()}
  @callback cancel(delivery_receipt(), state()) :: {:ok, state()} | {:error, adapter_error(), state()}
  @callback drain(deadline(), state()) :: {:ok, Runic.Runtime.DrainReport.t(), state()}

  @optional_callbacks dispatch_batch: 2, cancel: 2, drain: 2
end
```

The callback receives a committed `RunnableDispatchRequested` record. `DispatchContext` contains a typed completion sink established at backend initialization/routing, tracing data, and bounded delivery controls; it cannot grant Journal authority. A backend is responsible for outbound submission/delivery, not workflow truth or retry policy. Capability checks determine whether batch, cancel, or drain may be called.

Every backend reports completion through the same non-reentrant sink after `dispatch/3` returns. Inline and Task backends therefore enqueue an `%AttemptResult{}` to Runtime rather than calling a coordinator recursively inside `dispatch/3`. In v1 a broker message is acknowledged only after `Runic.Runtime.complete/3` reports committed or known duplicate. A future durable completion-ingress transport would need its own certified receipt/dedupe contract; it is not an unnamed escape hatch in this contract.

An unknown publish can cause redelivery of the same attempt ID without duplicating an accepted Runic transition. It does **not** make arbitrary external effects inside a step exactly once.

Built-in implementations:

- `Runic.Runtime.ExecutionBackend.Inline`;
- `Runic.Runtime.ExecutionBackend.Task`;
- the existing GenStage implementation upgraded to the structured event contract if its dependency remains in Runic.

External implementations include direct distributed BEAM, an Oban enqueue adapter, connector-specific Kafka/RabbitMQ/SQS/Pub/Sub publishers, or a native Ra delivery path. Broadway supplies inbound demand, worker, and acknowledgement plumbing; because it is not itself an outbound publisher, `runic_broadway` composes one of those publisher implementations to satisfy `ExecutionBackend`.

Provide `Runic.Runtime.Worker.execute/2` as the shared worker-side helper for validation, artifact/Runnable reconstruction, context resolution, one-attempt execution, payload externalization, and `AttemptResult` construction.

### 6.3 `Runic.Runtime.PayloadStore`

This optional deep interface handles values too large or sensitive for the event stream:

```elixir
defmodule Runic.Runtime.PayloadStore do
  @callback init(keyword()) :: {:ok, state()} | {:error, adapter_error()}
  @callback capabilities(state()) :: Runic.Runtime.Capabilities.t()

  @callback put(Runic.Runtime.EncodedPayload.t(), put_opts(), state()) ::
              {:stored, Runic.Runtime.DurabilityReceipt.t(), state()}
              | {:already_present, Runic.Runtime.DurabilityReceipt.t(), state()}
              | {:unknown, upload_id(), state()}
              | {:error, adapter_error(), state()}

  @callback fetch(Runic.Runtime.PayloadRef.t(), fetch_opts(), state()) ::
              {:ok, Runic.Runtime.EncodedPayload.t(), state()}
              | {:not_found, state()}
              | {:corrupt, integrity_diagnostic(), state()}
              | {:defer, retry_at(), state()}
              | {:error, adapter_error(), state()}

  @callback stat(Runic.Runtime.PayloadRef.t(), state()) ::
              {:ok, Runic.Runtime.PayloadStat.t(), state()} | {:not_found, state()} | {:error, adapter_error(), state()}
end
```

`EncodedPayload` contains namespace, payload domain/kind, codec/schema version, expected cryptographic digest, bytes, and bounded metadata. Core defines a canonical domain-separated digest preimage over kind, codec, schema version, and logical bytes. `put` is idempotent by namespace/digest and verifies both the digest and immutable semantic metadata rather than trusting caller input. A durability receipt is an assertion by the configured storage authority; Journal commit records that assertion but cannot atomically observe an S3 object.

There is deliberately no general `delete(payload_ref)` callback. Content-addressed objects may be shared by facts, attempts, snapshots, and segments. Deletion belongs to a reachability/orphan collector with retention, lease, and authorization proof; it can become a separate optional capability after the reference model exists.

Runic owns `PayloadRef`, codecs, integrity checking, hydration outcomes, and the fact-occurrence → payload-reference association in recorded events/projections. The PayloadStore owns immutable bytes and durability receipts, not fact identity or reachability truth.

Do not fold payload storage into Journal solely because one SQLite implementation uses the same database. PostgreSQL plus S3 and Ra plus object storage need independent payload failure/lifecycle semantics.

### 6.4 Scheduler and context policies

Keep Scheduler extensible, but do not expose the mutable `%Workflow{}` as a third-party contract:

```elixir
defmodule Runic.Runtime.Scheduler do
  @callback init(keyword()) :: {:ok, state()} | {:error, scheduler_error()}
  @callback capabilities(state()) :: Runic.Runtime.Capabilities.t()
  @callback plan(
              Runic.Runtime.PlanningView.t(),
              [Runic.Runtime.Candidate.t()],
              Runic.Runtime.SchedulingPolicy.t(),
              state()
            ) ::
              {:ok, Runic.Runtime.DispatchPlan.t(), state()}
              | {:defer, reason(), state()}
              | {:error, scheduler_error(), state()}
  @callback feedback(Runic.Runtime.SchedulingFeedback.t(), state()) :: {:ok, state()}
  @optional_callbacks feedback: 2
end
```

`PlanningView` exposes stable topology, causal/read-set, resource, state-version, quota, and locality information without coupling adapters to graph internals. `Candidate` retains the current scheduler invariants: every candidate is accounted for exactly once as dispatch, explicit defer, or rejection, with no invented or duplicated activation. Scheduling occurs authority-side; only resulting dispatch-request events cross the boundary.

Adaptive feedback may tune non-semantic performance choices. A feedback-derived decision that affects correctness, ordering, retry, or reproducible scheduling must be represented by recorded policy/decision events.

Add an invocation-scoped `Runic.Runtime.ContextResolver` for `context/1,2` requirements:

```elixir
defmodule Runic.Runtime.ContextResolver do
  @callback init(keyword()) :: {:ok, state()} | {:error, resolver_error()}
  @callback capabilities(state()) :: Runic.Runtime.Capabilities.t()
  @callback resolve(
              Runic.Runtime.ContextRequirement.t(),
              Runic.Runtime.AttemptContext.t(),
              state()
            ) ::
              {:ok, term(), state()}
              | {:missing, diagnostic(), state()}
              | {:forbidden, diagnostic(), state()}
              | {:invalid_type, diagnostic(), state()}
              | {:unavailable, retry_at(), state()}
              | {:error, resolver_error(), state()}
  @callback resolve_many(
              [Runic.Runtime.ContextRequirement.t()],
              Runic.Runtime.AttemptContext.t(),
              state()
            ) :: {:ok, map(), state()} | {:error, resolver_error(), state()}
  @optional_callbacks resolve_many: 3
end
```

`ContextRequirement` carries key, component/global scope, required/default status, provider/version, portability class, and optional schema hint. The default resolver reads explicitly transportable invocation values. Trusted/local worker profiles may legitimately resolve secret references, repositories, pools, clients, PIDs, or local functions; these values remain outside the artifact and event stream. `resolve_many/3` avoids one network round trip per key.

### 6.5 Do not freeze speculative ports

Directory, materializer, and telemetry integrations are useful, but they do not need three more stable behaviours in the first contract release:

- route lookup can be an internal Runtime facility or later `Directory` behaviour once Group/`:pg`/Horde implementations prove a common contract;
- materializers consume recorded events and can start as ordinary subscribers/projectors;
- telemetry uses `:telemetry` events, not a custom exporter callback;
- timers are journal events plus a Runtime driver; the driver is not another source of truth.

This keeps the initial extension surface deep rather than producing many one-function ports.

## 7. Intentional breaking-change map

| Current API/contract | Near-term replacement | Reason |
|---|---|---|
| `Runic.Runner` | `Runic.Runtime` | One public managed-execution concept |
| `Runic.Runner.Worker` | private Runtime coordinator | Hide process and transition mechanics |
| `Runic.Runner.Store` | `Runic.Runtime.Journal` | Conditional atomic event transactions, not snapshot/stream mode probing |
| required `save/load` callbacks | removed | Full-log persistence is not the durable semantic kernel |
| optional `append/stream` callbacks | required Journal load/commit/resolve | Event sourcing becomes the single managed-runtime model |
| `checkpoint/3` | snapshot/compaction policy | “Checkpoint” currently conflates append, snapshot, and lifecycle |
| `save_fact/load_fact` | `PayloadStore` and `PayloadRef` | Explicit codec, integrity, namespace, and hydration semantics |
| `Runic.Runner.Executor` | `Runic.Runtime.ExecutionBackend` | Structured committed dispatch event instead of closure/message coupling |
| `Runic.Runner.Scheduler` | `Runic.Runtime.Scheduler` | Typed plans and runtime-level capability context |
| `execution_mode: :durable` | Runtime guarantee profile | Durability is execution-wide, not lifecycle logging on one node |
| `RunnableDispatched` | `RunnableDispatchRequested` | A committed outbox intent must not claim delivery already happened |
| current lifecycle event fields | versioned portable event schemas | Cross-node replay and stable identities |
| `Workflow.from_events` split replay | strict chronological projector | One event history must produce one projection |
| raw Workflow snapshot as portable default | versioned Runtime snapshot IR | Exclude functions, PIDs, hooks, contexts, and secrets |

During one alpha transition release, compile-time deprecation messages may identify replacements. Avoid maintaining dual runtime semantics or automatic fallback paths. Known consumers should migrate as part of the contract branch and become integration fixtures.

## 8. Consumer migration strategy

### 8.1 Infinite Isekai

- migrate Postgres rows to versioned `RecordedEvent` bytes and immutable execution IDs;
- add stream-head expected-position update, authority epoch, client-command/transaction dedupe, work-discovery indexes, and outcome lookup in one Ecto transaction;
- move lifecycle status to an event projector;
- migrate large/environmental captures to payload or context references;
- convert PubSub/user-visible effects to idempotent effect commands or a durable outbox;
- remove silent fallback from durable Runtime to local Workflow execution.

This is the first PostgreSQL Journal proof.

### 8.2 RunicAI

- preserve the dynamic SQLite repo/store ergonomics while implementing Journal transactions;
- reuse immutable definition revision, compiled artifact pin, and SHA-256 child invocation patterns;
- replace construction-event filtering and ad hoc resume orchestration with Runtime replay;
- migrate the old `RunnableDispatched => :running` projection to `RunnableDispatchRequested => :dispatch_pending`;
- adapt the application Runtime facade/backends to the core facade, deleting duplicate polling and coordinator code;
- move captured SQLite handles to context-resolved workflow-task services;
- keep authoring IR and product projections outside Runic.

This is the first workspace-scoped SQLite and nested-invocation proof.

### 8.3 Compendium

- carry immutable run UUIDs into every Journal operation instead of resolving latest run by workflow key;
- adapt event/fact/artifact tables to RecordedEvent and PayloadRef;
- replace raw Workflow snapshot helpers with the Runtime snapshot contract;
- derive terminal status/read-model work from recorded terminal events and durable projector cursors;
- move repositories, HTTP modules, runner names, and process resources from input facts to context requirements;
- use activation-level commit for large fan-out rather than only on-complete checkpointing.

This is the second SQLite implementation and construction-time graph-expansion/causal-join proof.

## 9. Near-term implementation sequence

### C0 — semantic ADR and executable reference model

Deliver:

- event-versus-command terminology;
- `RecordedEvent`, `Transaction`, `Commit`, `AttemptResult`, `AuthorityRef`, `WorkScopeRef`, and stable identity types;
- guarantee profiles and capability validation;
- pure in-memory event transaction/reference coordinator;
- model tests for duplicate, conflict, stale epoch, and unknown outcome.

Gate: every public result has a defined recovery action and no path silently weakens guarantees.

### C1 — chronological event core

Deliver:

- strict one-pass `Workflow.from_events`;
- complete typed events for root/match/skip/failure/state/graph mutation paths;
- versioned core event codec and upcaster registry;
- cryptographic content and distinct occurrence IDs;
- new pre-execution `RunnableDispatchRequested` and accepted completion/failure events.

Gate: live projection equals replay for every prefix of randomized event histories, including snapshot tails and graph mutation.

### C2 — replace Store with Journal

Deliver:

- `Runic.Runtime.Journal` and capabilities;
- in-memory/ETS reference Journal;
- atomic expected-position commit, client-command/transaction dedupe, resolution horizons, and explicit persistence errors;
- paged replay plus work-scope enumeration and active-stream, pending-dispatch, and due-timer discovery/claim capabilities;
- Store removal from Worker paths.

Gate: append failure and ambiguous reply never discard events or advance authoritative Workflow state.

### C3 — introduce the core Runtime facade and coordinator

Deliver:

- OTP `start_link`, execution `start_execution/open_execution`, typed submit/signal/complete/cancel/query, and administrative passivation API;
- caller-stable durable command IDs and acknowledged receipts;
- decide → commit → apply loop;
- activation/passivation and committed-truth restart;
- guarantee-profile reporting and no silent downgrade;
- terminal lifecycle as events rather than callbacks.

Gate: killing the coordinator at every input and event-commit boundary loses no accepted command.

### C4 — replace Executor with ExecutionBackend

Deliver:

- structured backend behaviour;
- Inline, Task, and upgraded GenStage implementations with the same asynchronous typed completion sink;
- shared worker execute helper;
- committed dispatch recovery and duplicate result validation;
- one-attempt backend semantics; retries become Runtime timers/events.

Gate: local and cross-process backends pass the same dispatch/result conformance suite.

### C5 — portability, context, and payloads

Deliver:

- portable component/artifact protocol;
- deep closure binding validation;
- context manifest/resolver;
- payload codec/ref/store;
- safe portable snapshot IR;
- clean-node tests for all built-in Runic component families.

Gate: a macro-built workflow with captured bindings and context requirements reconstructs and executes on a clean compatible BEAM node; local-only fields produce actionable diagnostics.

### C6 — migrate reference consumers and adapters

Deliver:

- RunicAI and Compendium SQLite Journal migrations;
- Infinite Isekai PostgreSQL Journal migration;
- shared adapter conformance fixtures extracted from all three;
- benchmark/fault comparisons against the old implementations;
- removal of remaining Runner/Store compatibility branches.

Gate: all three applications resume existing supported test fixtures through the new Runtime and no consumer owns a duplicate generic coordinator.

### C7 — distributed adapters

After the core contract passes local fault injection:

- Broadway backend;
- PostgreSQL clustered profile;
- Group route hints;
- Ra Journal implementation;
- object payload adapters.

Gate: adapters vary infrastructure without changing Runic event or coordinator semantics.

## 10. Required contract tests

### Journal

- atomic ordered multi-event transaction;
- expected-position conflict;
- stale authority rejection;
- same transaction ID returns the original receipt;
- same client command ID and digest returns the original acceptance receipt even through a new transaction;
- same client command ID with different content is rejected;
- evicted proof returns expired rather than not-committed;
- timeout after commit resolves as committed;
- confirmed failed commit does not advance projection;
- snapshot plus chronological tail equivalence;
- cold active-stream discovery and pending dispatch/timer claim/rebuild;
- codec/upcaster and corrupt event handling.

### Execution backend

- dispatch receives only a committed `RunnableDispatchRequested` event;
- unknown publish can redeliver the same attempt safely;
- worker crash before/after result;
- duplicate, delayed, and reordered result ingress;
- backend drain/cancel capability behavior;
- broker/local backpressure and poison work;
- no backend can directly mutate Workflow state.

### Runtime

- input acknowledgement occurs after commit;
- lost input reply is recoverable with the caller-known command ID;
- coordinator crash before/after every commit and dispatch boundary;
- terminal status is reconstructable without callback delivery;
- repeated equal payload values keep distinct causal occurrences;
- overlapping inputs keep separate context lineage;
- nonmergeable state conflicts cannot lose updates;
- graph mutations replay in original chronology;
- requested guarantee profile cannot downgrade;
- long-idle timers survive passivation and restart.

### Portability

- macro AST plus captured binding clean-node rebuild;
- `context` worker-local resource resolution;
- direct function-only component reports local-only;
- nested PID/ref/port/repository handle detection;
- artifact/code mismatch rejection;
- legitimate `nil` distinct from missing payload;
- raw snapshots proven free of portable-profile assumptions.

## 11. Tradeoffs accepted

### Runtime in the main package

Cost: Runic owns more coordination code and must keep the package dependency-light.

Benefit: event semantics, graph projection, dispatch lifecycle, and correctness evolve together. Consumers do not build competing runtimes around internal structs. This is the better abstraction boundary.

### Breaking Store and Executor

Cost: known adapters must migrate together.

Benefit: removes snapshot-versus-stream branching, local Task message coupling, legacy bridges, and false durability claims before those contracts stabilize.

### Portable dispatch events

Cost: lifecycle event schemas become versioned public protocol earlier and need size/security discipline.

Benefit: the object used for replay and the object that drives work cannot drift semantically. Remote delivery becomes an adapter concern rather than a parallel execution model.

### Capability-based optional callbacks

Cost: profiles and conformance checks add explicit concepts.

Benefit: optional accelerations remain possible without making guarantees implicit. A simple SQLite adapter stays simple; a clustered Journal proves stronger callbacks.

### External adapter packages

Cost: several Hex packages or application-local modules still exist.

Benefit: Runic does not force Ecto, Postgrex, Broadway, Ra, RocksDB, or cloud SDK dependencies on pure graph users. Separate packaging is a dependency/release decision, not a separate runtime architecture.

## 12. Relationship to prior contract plans

- [Runner Implementation Plan](runner-implementation-plan.md) and [Runner Scheduling Implementation](runner-scheduling-implementation-plan.md) document the current alpha Runner, Store, Scheduler, and Executor. Their compatibility constraints and Task-message contracts are intentionally superseded here.
- [Port Contracts Implementation Plan](port-contracts-implementation-plan.md) remains useful evidence for pluggability, but capability-tested Journal, ExecutionBackend, PayloadStore, Scheduler, and ContextResolver contracts replace callback probing and shallow ports.
- [Phase 8 Distribution Primitives](phase-8-distribution-primitives.md) remains useful research on OTP topology and remote-node testing. Journal fencing, portable recorded events, and the in-package Runtime replace registry-led ownership and remote `work_fn` dispatch.
- [Causal Runtime Architecture](causal-runtime-architecture.md) and [Three-Phase Summary](three-phase-summary.md) remain the semantic foundation: prepare, isolated execute, and event application survive behind the upgraded managed shell.

## 13. Decisions to close in C0

1. Does `RecordedEvent` store encoded data plus decoded struct, or is encoded data only an adapter concern?
2. What canonical encoding and cryptographic digest define version 1?
3. Are capability callback groups declared directly on Journal or split into nested behaviour modules while retaining one Journal configuration?
4. Which snapshot, compaction, and administrative callbacks deserve inclusion after the three consumer migrations?
5. Is GenStage retained as a core dependency/backend or moved to an adapter package?
6. What is the minimum durable lifecycle event vocabulary for input, dispatch request, timer, cancellation, completion, and terminal state?
7. How are custom `EventApplicator` implementations versioned and validated for portable replay?
8. Which existing persisted fixtures from the three consumer repositories must be upcast versus intentionally migrated once?
9. What command- and transaction-dedupe horizons are required by each guarantee profile, and which archived index proves safe reuse after compaction?
10. Which delivery/worker-start observations deserve recorded audit events rather than telemetry only?

These decisions should be resolved against executable reference tests, not by extending the old callbacks incrementally.
