# Runic PostgreSQL Journal, Store, Projection, and Managed Workflow Library Implementation Plan

**Status:** Proposed implementation plan
**Date:** 2026-08-02
**Target baseline:** Runic 0.1.0-alpha.8 at 7f440d3
**Package:** `runic_postgres`
**Depends on:** [Distributed Durable Runtime Core Plan](distributed-durable-runtime-core-plan.md), [Runic Runtime Contract Upgrade Plan](runic-runtime-contract-upgrade-plan.md)
**Portfolio context:** [Distributed Adapter Portfolio Plan](distributed-adapter-portfolio-plan.md)
**Earlier exploration:** [Runic Ecosystem Integration Evaluation](ecosystem-integration-evaluation.md)
**Consumer references:** Infinite Isekai and Libbit

## Executive decision

Build `runic_postgres` as the first broadly deployable clustered implementation of Runic's planned Runtime contracts. It should be a PostgreSQL-specific package using Ecto for configuration, schemas, changesets, migrations, and transaction composition, with Postgrex or `Ecto.Adapters.SQL` for the PostgreSQL primitives on the hot path.

The package should expose independently selectable facilities:

- `RunicPostgres.Journal`, implementing `Runic.Runtime.Journal` with atomic recorded-event transactions, expected-position checks, command and transaction receipts, fenced authority, recoverable dispatches, durable timers, snapshots, and work discovery;
- `RunicPostgres.PayloadStore`, the PostgreSQL **store** profile for immutable facts, results, artifacts, and checkpoint/snapshot bytes under `Runic.Runtime.PayloadStore`;
- `RunicPostgres.ExecutionBackend` and `DispatchSource`, with optional default `runic_broadway` wiring for bounded, at-least-once activity delivery from the Journal's pending-dispatch index;
- `RunicPostgres.Projector`, a rebuildable, idempotent read-model framework that preserves per-stream order without pretending a database sequence is commit order;
- `RunicPostgres.ManagedWorkflows`, generic definition, immutable revision, artifact pin, default-launch, desired-deployment, and run-projection support, plus independently selectable schedules;
- migrations, Igniter installers/upgraders, health checks, telemetry, maintenance helpers, integration tests, and conformance fixtures.

The default full profile uses one regional PostgreSQL primary as the execution authority and PostgreSQL-backed Broadway delivery. Users may install only the Journal, only the store/fact/checkpoint tables, only management/projection support, or any valid composition. Another broker may replace PostgreSQL dispatch. Another Journal may remain authoritative while PostgreSQL supplies payloads, managed models, and query projections.

The central design rule is:

> Keep canonical workflow truth, high-churn delivery state, immutable payload bytes, management metadata, and analytical read models physically and semantically distinct, even when one PostgreSQL database hosts all of them.

Oban is the strongest Elixir reference for PostgreSQL work claiming, queue supervision, installation, telemetry, testing, and operational maturity. Runic should reuse those lessons without copying the single mutable job-row abstraction. A queued Runic item represents one bounded execution **attempt**; a potentially years-long workflow remains durable as recorded events, timers, receipts, and compact projections.

## 1. Terminology and contract boundary

The current alpha `Runic.Runner.Store` combines full-log persistence, optional append, facts, and snapshots. The distributed plans intentionally replace it. In this plan, “Store” means the forward payload/fact/checkpoint role, not a permanent implementation of the legacy behaviour.

| User-facing idea | Forward implementation | Correctness role |
|---|---|---|
| workflow event/run persistence | `RunicPostgres.Journal` | Canonical ordered execution truth |
| fact/value store | `RunicPostgres.PayloadStore` | Immutable content-addressed bytes |
| checkpoint/snapshot bytes | `RunicPostgres.PayloadStore` | Replay acceleration; referenced by a Journal event |
| snapshot selection | `RunicPostgres.Journal` | Chooses a compatible snapshot at a committed position |
| PostgreSQL work queue | `RunicPostgres.ExecutionBackend` and Broadway | At-least-once attempt delivery |
| managed workflow | `RunicPostgres.ManagedWorkflows` | Definition/revision/artifact management, not run authority |
| lifecycle/reporting model | `RunicPostgres.Projector` | Rebuildable query model |
| current `Runic.Runner.Store` | superseded alpha contract | Not capable of clustered Journal guarantees |

The Igniter flag `--store` is a friendly alias for `--payload-store --facts --snapshots`. The preferred module name remains `RunicPostgres.PayloadStore`, because it states the stable Runic behaviour precisely.

Do not build a permanent parallel `RunicPostgres.Store` around the old callbacks. If a short migration aid is necessary, isolate it as `RunicPostgres.LegacyStore`, mark it non-cluster-safe, emit deprecation warnings, and remove it on the contract migration schedule. New production work targets `Runic.Runtime` directly.

## 2. Goals and explicit non-goals

### 2.1 Goals

- Make one PostgreSQL transaction the atomic boundary for a Runic transition and all correctness-coupled indexes.
- Support several application nodes without distributed Erlang as a correctness dependency.
- Make accepted input, pending work, timers, cancellation, snapshots, and terminal state recoverable after process or node loss.
- Provide stable command and transaction identities with resolvable ambiguous outcomes.
- Offer expert control over database load, queue demand, tenancy fairness, retention, partitioning, and pool allocation.
- Preserve one Runic event/replay model across PostgreSQL, SQLite, Ra, CASPaxos, and external-log adapters.
- Make managed definitions, schedules, startup recovery, and read models useful out of the box without importing Libbit or Infinite Isekai product concerns.
- Generate adjustable application code where domain policy belongs while keeping invariant-sensitive SQL inside the package.
- Support an end-to-end CQRS/process-manager style in which each execution is an event-sourced aggregate and cross-aggregate work is explicit, durable, and idempotent.

### 2.2 Non-goals

- exactly-once execution or exactly-once arbitrary external effects;
- treating `LISTEN/NOTIFY`, Broadway, process registration, or a queue claim as workflow authority;
- holding a PostgreSQL transaction open while user code executes;
- a generic `runic_ecto` adapter that claims identical SQLite/PostgreSQL guarantees;
- transparent CockroachDB compatibility under a PostgreSQL name;
- putting the full `%Workflow{}`, complete event history, or large fact graph in one mutable row;
- making asynchronous user projections part of the Journal commit;
- using read replicas for fencing, deduplication, dispatch claims, timer claims, or transaction resolution;
- automatically starting every historical execution at server boot;
- making one database table serve immutable history, work queue, facts, definitions, and reporting.

## 3. Evidence from implemented consumers

### 3.1 Infinite Isekai: useful PostgreSQL fixture, insufficient protocol

Infinite Isekai's [`PostgresStore`](../../infinite_isekai/lib/infinite_isekai/workflows/postgres_store.ex) and migrations prove a practical decomposition into run rows, ordered event rows, and fact bytes. It also proves that construction events can rebuild real workflows and that queryable administrative views matter.

The implementation is a migration fixture, not a clustered design:

- it allocates the next event position with `COUNT`, so concurrent writers can choose the same position;
- it inserts events one row at a time rather than bulk inserting an already validated batch;
- it has no expected-position comparison, writer epoch, command receipt, transaction receipt, or unknown-outcome resolution;
- it stores raw ETF with no core-owned codec version, safe decode policy, digest, or upcaster;
- fact identity is a global non-cryptographic bigint rather than a tenant-qualified digest;
- it derives product meaning by parsing colon-delimited workflow IDs;
- status is patched outside the canonical event transition;
- recovery occurs when specific application processes start, without cluster-wide claim/fencing;
- its durable composer may silently fall back to local execution.

`runic_postgres` should retain the normalized PostgreSQL starting point and reject all of those protocol shortcuts. Position allocation comes from a locked/conditional stream head, never `COUNT` or `MAX`.

### 3.2 Libbit: workspace SQLite is authoritative for workspace models

Libbit's actual workspace definitions, drafts, triggers, run summaries, and subscription state live in workspace-scoped SQLite through [`Core.WorkspaceRepo`](../../libbit/apps/core/lib/core/workspace_repo.ex). Its central PostgreSQL workflow-management code is legacy for workspace features; central PostgreSQL remains appropriate for global/cross-workspace platform and community aggregation.

Reusable shapes from the workspace-local implementation include:

- managed definition identity, status, publishing lifecycle, policy, runtime configuration, and construction log;
- webhook, schedule, event-listener, form, and manual trigger types with type-specific validation;
- run and step query projections;
- projector configuration, retry state, and durable delivery bookkeeping;
- Ecto.Multi-based projector writes followed by explicitly non-transactional post-commit effects.

The new package must improve the durability boundary:

- local process timers are not durable scheduling;
- reloading active definitions does not discover active executions;
- best-effort lifecycle hooks cannot be the only source of a run projection;
- `on_conflict: :nothing` followed by an unconditional counter increment is not idempotent;
- an `after_commit` trigger that starts a workflow needs a durable occurrence/command receipt;
- local registration does not prevent two cluster nodes from resuming the same execution.

Libbit-specific node positions, embeddings, chat associations, transform rules, and builder state remain application code. The package generalizes immutable revision pins, schedule occurrences, projector receipts, and startup work discovery.

### 3.3 Earlier ecosystem evaluation

The direct PostgreSQL section in [Runic Ecosystem Integration Evaluation](ecosystem-integration-evaluation.md#34-postgres-via-postgrex--ecto-directly) correctly identified Ecto/Postgrex and normalized event/fact tables as pragmatic. Its sample schema and generic `runic_ecto` conclusion predate the Runtime contract work. The sample resets positions per call and lacks fencing, receipts, pending-work atomicity, and ambiguity resolution. Treat it as exploration, not executable design.

## 4. Package architecture

~~~text
                         Runic.Runtime
        commands / results / replay / activation / passivation
                              |
             +----------------+----------------+
             |                                 |
             v                                 v
 RunicPostgres.Journal              selected ExecutionBackend
 atomic event transaction           +-------------------------+
 heads, receipts, authority          | Postgres + Broadway     |
 pending work, timers, outbox        | external broker         |
             |                       | direct/local backend     |
             |                       +-------------------------+
             |
      one PostgreSQL primary
             |
   +---------+-----------+------------------+----------------+
   |                     |                  |                |
   v                     v                  v                v
immutable payloads   projector work   managed definitions  telemetry/admin
facts/snapshots      and read models  revisions/schedules  maintenance
RunicPostgres.       RunicPostgres.   RunicPostgres.       Health/Telemetry
PayloadStore         Projector        ManagedWorkflows
~~~

The package contains one correctness model with multiple optional facilities. Installing fewer components removes dependencies, migrations, and supervised processes; it does not invent weaker meanings for the same callback.

### 4.1 Primary modules

| Module | Responsibility |
|---|---|
| `RunicPostgres.Journal` | `Runic.Runtime.Journal` adapter and capability manifest |
| `RunicPostgres.Journal.Transaction` | Commit/resolve protocol and closed error mapping |
| `RunicPostgres.Journal.Authority` | Authority acquisition, renewal, release, and fencing |
| `RunicPostgres.Journal.Work` | Active scans, dispatch claims, timer claims, reconciliation |
| `RunicPostgres.PayloadStore` | Immutable PostgreSQL payload implementation |
| `RunicPostgres.ExecutionBackend` | PostgreSQL pending-dispatch backend facade |
| `RunicPostgres.DispatchSource` | PostgreSQL claim/notification primitives for the generic `runic_broadway` source contract |
| `RunicPostgres.Projector` | Projector behaviour/DSL and worker runtime |
| `RunicPostgres.ManagedWorkflows` | Definition, immutable revision, artifact-reference, and managed launch APIs |
| `RunicPostgres.Schedules` | Typed start targets, occurrence materialization, admission, and submission |
| `RunicPostgres.Triggers` | Generated target/ingress contracts for manual, form, webhook, and event-subscription triggers |
| `RunicPostgres.ManagedDeployments` | Optional desired-residency reconciliation through idempotent Runtime commands |
| `RunicPostgres.Ingress` | Same-database durable Runtime ingress and `Ecto.Multi` insertion helpers |
| `RunicPostgres.InfrastructureSupervisor` | Readiness/notifier infrastructure that may start before Runtime |
| `RunicPostgres.WorkerSupervisor` | Selected queue, schedule, projection, and maintenance workers bound to a Runtime handle |
| `RunicPostgres.Migrations` | Component-versioned migration functions |
| `RunicPostgres.Health` | Readiness, schema, primary, lag, and backlog checks |
| `RunicPostgres.Telemetry` | Stable spans and bounded metadata |

Ecto schemas for correctness tables remain package-owned. Raw SQL is private and tested through public adapter semantics. Application code never needs to coordinate row locks itself.

### 4.2 Dependency policy

Required runtime dependencies are Runic, Ecto SQL, Postgrex, and `:telemetry`. The separate `runic_broadway` package is an optional integration and brings Broadway only for the PostgreSQL queue profile. Igniter is optional and used only by installation and upgrade tasks; it is not part of production supervision. Oban is research evidence, not a package dependency. Phoenix and broker/cloud SDKs are not required.

Select concrete compatible version ranges when the package is scaffolded. Keep ordinary queries behind Ecto so applications retain Repo configuration, telemetry, and sandbox support; use Postgrex directly only where Ecto does not provide the needed primitive, notably a dedicated `Postgrex.Notifications` session for `LISTEN`.

## 5. Independent installation profiles

| Profile/components | What starts | Valid composition |
|---|---|---|
| `journal` | Journal and optional reconciliation processes | Any certified ExecutionBackend and PayloadStore |
| `store` | PostgreSQL PayloadStore only | Any Journal/backend |
| `facts,snapshots` | Selected PayloadStore uses/tables | Any Journal; snapshots still require journaled references |
| `managed_workflows` | Definition/revision context | May exist before Runtime; creating launchable revisions requires a configured PayloadStore or verified external artifact receipt |
| `schedules` | Durable occurrence planner/submission outbox | Requires a typed start target/resolver and Runtime ingress; managed definitions are optional |
| `triggers` | Trigger target schemas plus manual/form/webhook/event-subscription ingress scaffolds | Active submission requires `ingress`; provider event loops remain connector adapters |
| `ingress` | Same-PostgreSQL durable command inbox and submitter | Requires a named Runtime handle; may submit to any Journal |
| `deployments` | Desired-resident deployment intent and bounded reconciler | Requires Runtime ingress plus a StartSpec/resolver; managed definitions are optional |
| `projections` | Projection router/workers | PostgreSQL Journal or an explicit external feed adapter |
| `postgres_queue,broadway` | PostgreSQL DispatchSource and `runic_broadway` pipeline | Requires the PostgreSQL Journal's atomic pending-dispatch index |
| full `postgres_runtime` | All above | Recommended regional PostgreSQL profile |

`postgres_queue` cannot silently attach to an unrelated Journal because it would lose the atomic event-plus-dispatch-write invariant. A future certified handoff adapter may copy another Journal's dispatch intents into PostgreSQL, but it must define its own durable receipt and replay boundary.

Conversely, users may select `journal` without `postgres_queue` and publish its pending dispatches to RabbitMQ, Kafka, SQS, GCP Pub/Sub, or another backend. The event and attempt schema remains Runic-owned.

## 6. Ownership: library, generated, and application code

### 6.1 Package-owned invariant surface

- Journal Ecto schemas, SQL, constraints, locks, receipt protocol, and error classification;
- authority/work-scope semantics and database-clock lease rules;
- recorded-event encoding integration and replay paging;
- dispatch/timer claim algorithms and reconciliation;
- PayloadStore digest verification and immutable insert semantics;
- projection routing, claim, receipt, gap detection, and rebuild machinery;
- schedule occurrence identity/submission bookkeeping and concurrency-key admission;
- same-database Runtime ingress rows and transactional insertion helper;
- migration version registry and invariant-sensitive DDL;
- telemetry event names, health contract, test helpers, and conformance adapters.

Users configure these facilities but do not fork their algorithms merely to add a domain field.

### 6.2 Igniter-generated, contract-bound customization surface

- selected migrations with schema/table prefix and physical profile embedded in source;
- Repo configuration or an optional dedicated `MyApp.RunicRepo`;
- supervision wiring after the Repo;
- `MyApp.RunicPostgres` facade/config module;
- managed definition, immutable revision, deployment intent, trigger, schedule, and run-projection schemas using required-field macros;
- base contexts that inject authorization/namespace policy;
- projector modules, tests, and optional effect-outbox handlers;
- schedule input builder and misfire-policy modules;
- operational configuration with explicit pool and concurrency budgets.

Generated code is intentionally editable. Required field macros and behaviours let the package validate compatibility without owning domain associations.

### 6.3 Application-owned domain surface

- authentication, authorization, and namespace derivation;
- domain metadata, associations, builder IR, component catalogs, and approval workflow;
- domain authoring IR, catalog policy, and compiler inputs; Runic still owns the canonical portable construction artifact and replay contract;
- projector logic and user read-model tables;
- schedule calendars, input construction, and business misfire policy;
- context providers, credentials, secrets, and external effect handlers;
- broker selection and connector-specific infrastructure;
- effect idempotency, domain inbox/outbox, and cross-aggregate compensation.

## 7. Runic prerequisites before package implementation

The current checkout has no implemented `Runic.Runtime` or `Runic.Runtime.Journal`; `Runic.Runner.Store` and the Task-shaped Executor are still present. A production `runic_postgres` must follow these gates rather than claiming durable coordination through the old callbacks.

### RP0 — identities, outcomes, and capabilities

Runic must land:

- `StreamRef`, `AuthorityRef`, `WorkScopeRef`, portable `StartSpec`, and serializable Runtime handles;
- `RecordedEvent`, `Transaction`, `Commit`, `CommandReceipt`, and retention proof types;
- stable command, transaction, event, activation, attempt, occurrence, and artifact identities;
- capability manifests, limits, closed adapter errors, and requested guarantee profiles;
- affirmative `committed`, `not_committed`, `unknown`, and `expired` meanings.

### RP1 — chronological event and portability protocol

- one strict construction-prefix plus execution-tail replay model;
- core-owned event codecs, schema versions, safe decode, and upcasters;
- write-ahead `RunnableDispatchRequested`;
- portable `AttemptResult` and accepted completion/failure/cancellation events;
- artifact, graph revision, payload, context, and code compatibility references;
- portable snapshot IR rather than raw `%Workflow{}` ETF.

### RP2 — Journal and reference model

- the actual `Runic.Runtime.Journal` behaviour;
- expected-position commit, command/transaction dedupe, and unknown resolution;
- authority and work-scope capability groups;
- active-stream, dispatch, timer, snapshot, and retention semantics;
- typed direct-dispatch claim/renew/release plus external publication claim/ack callbacks, each advertised by capability rather than assumed by every Journal;
- pure in-memory reference Journal and a reusable conformance/fault suite.

### RP3 — Runtime coordinator

- decide, commit, then apply;
- acknowledged ingress with caller-stable IDs;
- activation, passivation, drain, takeover, and committed-truth replay;
- durable timer/cancellation/signals;
- no silent downgrade or local fallback from a durable profile.

### RP4 — structured ExecutionBackend

- the replacement for zero-arity Task functions;
- `Runic.Runtime.Worker.execute/2`;
- typed dispatch outcome, completion sink, batch, cancel, and drain semantics;
- duplicate/stale attempt-result handling.

### RP5 — PayloadStore and projection feed decisions

- immutable payload types, durability receipts, integrity/hydration outcomes;
- snapshot reference/selection semantics;
- decide whether Runic standardizes a minimal projection feed or lets `runic_postgres` own the first implementation;
- define administrative snapshot/compaction callbacks or keep them package-specific until proven.

Prototype schema and SQL work may proceed before all gates land, but the package cannot claim `cluster_safe` until it compiles against and passes the real contracts.

## 8. Logical schema groups

Use a configurable PostgreSQL schema, default `public`, and a stable table prefix, default `runic_`. Every logical correctness identity includes namespace and immutable StreamRef; high-volume physical child keys may use constrained `namespace_pk`/`stream_pk` surrogates that resolve uniquely back to it. No query derives tenancy from an arbitrary payload document.

### 8.1 Coordination hot path

| Table | Purpose | Key design |
|---|---|---|
| `runic_namespaces` | Compact internal namespace key mapped to bounded external identity | Small tenant/control table; unique external namespace identity |
| `runic_work_scopes` | Stable virtual shards and placement generation | Small, rarely updated control table |
| `runic_authorities` | Epoch, owner incarnation, lease deadline | One row per advertised authority scope |
| `runic_streams` | Position, lifecycle, artifact/snapshot head, active/due hints | One narrow mutable row per execution |
| `runic_events` | Append-only versioned RecordedEvents | Composite stream/position primary key |
| `runic_transactions` | Positive/negative transaction outcome and reuse guard | Unique transaction identity within scope |
| `runic_commands` | Request digest and original semantic receipt | Unique command identity within StreamRef scope |

### 8.2 Recoverable work indexes

| Table | Purpose | Lifecycle |
|---|---|---|
| `runic_dispatches` | Pending/claimed `RunnableDispatchRequested` attempts | Inserted with event; removed/archived after accepted completion horizon |
| `runic_dispatch_publications` | Optional external-backend publish claim and acceptance receipt | Separate from consumer completion; one row per dispatch/backend target |
| `runic_timers` | Scheduled/claimed durable timer occurrences | Inserted/changed with event transition |
| `runic_ingress` | Optional package-owned same-PostgreSQL Runtime command inbox | Inserted through a public `Ecto.Multi` helper; consumed idempotently into Runtime |
| `runic_schedule_occurrences` | Authoritative occurrence identity, pinned StartSpec, admission, and submission outcome | Retained/compacted by control-state policy, never inferred from a query projection |
| `runic_concurrency_occupancy` | Optional overlap/concurrency-key admission state | Updated through fenced occurrence/Runtime transitions |

These tables are transactionally derived indexes. The corresponding recorded events remain semantic truth. A row may wake work but cannot authorize a graph mutation.

### 8.3 Payload and replay acceleration

| Table | Purpose |
|---|---|
| `runic_payloads` | Immutable inline facts/results/artifacts/snapshot bytes by cryptographic digest |
| `runic_snapshots` | Stream position, artifact/digest compatibility, and PayloadRef metadata |
| `runic_payload_gc_marks` | Optional collector generations/reachability proof, never ad hoc refcount truth |

### 8.4 Projection and management plane

| Table | Purpose |
|---|---|
| `runic_projection_outbox` | One durable routing item per committed Journal transaction |
| `runic_projection_deliveries` | Per-projector leased/idempotent work |
| `runic_projection_streams` | Per-projector/per-stream applied position and status |
| `runic_projection_effects` | Durable post-projection effects, when selected |
| generated workflow definitions/revisions | Authoring identity and immutable artifact revisions |
| generated schedules/trigger targets | Editable intent and target-resolution policy; may reference managed revisions or external catalogs |
| generated occurrence/run/step projections | Rebuildable lifecycle query models, distinct from authoritative occurrence rows |

Correctness tables and user query tables may share a database, but use separate modules, prefixes where appropriate, pool roles, retention, and indexes.

## 9. Coordination table design

### 9.1 `runic_streams`

Directionally:

~~~sql
CREATE TABLE runic_streams (
  work_scope          integer      NOT NULL,
  stream_pk           bigint       GENERATED BY DEFAULT AS IDENTITY,
  namespace_pk        bigint       NOT NULL,
  stream_kind         smallint     NOT NULL,
  stream_id           uuid         NOT NULL,
  position            bigint       NOT NULL DEFAULT 0,
  lifecycle           smallint     NOT NULL,
  artifact_digest     bytea,
  graph_revision      bigint       NOT NULL DEFAULT 0,
  snapshot_position   bigint,
  snapshot_digest     bytea,
  next_due_at         timestamptz,
  active              boolean      NOT NULL DEFAULT true,
  inserted_at         timestamptz  NOT NULL,
  updated_at          timestamptz  NOT NULL,
  PRIMARY KEY (work_scope, stream_pk),
  UNIQUE (work_scope, stream_pk, namespace_pk),
  UNIQUE (work_scope, namespace_pk, stream_kind, stream_id)
);
~~~

The exact Runic identity type is an RP0 decision; UUID is the default external stream-ID physical profile, not permission to reinterpret application strings. `runic_namespaces` maps a bounded external namespace identity to compact `namespace_pk`; `stream_pk` is a storage surrogate and never escapes as Runic identity. Sequences are safe for surrogate allocation because neither value claims commit order. High-volume child tables use `(work_scope, stream_pk, ...)`, while the unique external StreamRef constraint remains on `runic_streams`.

Use `bigint` positions. Bound and validate external namespace/identity bytes before transaction checkout. Keep this row narrow and avoid arbitrary JSONB or reporting columns. Benchmark both lookup joins and aggregate index/WAL footprint; a deployment with already compact UUID namespace identities may select a certified no-mapping profile only if every constraint and query retains the same tenancy semantics.

Indexes:

- partial active scan on `(work_scope, namespace_pk, stream_kind, stream_id)` where active;
- partial due hint on `(work_scope, next_due_at, namespace_pk, stream_kind, stream_id)` where active and `next_due_at IS NOT NULL`;
- optional lifecycle/admin index outside the highest-write profile.

Do not index every updated head field. Preserve HOT-update opportunities where they matter, subject to the indexes actually required by scans.

### 9.2 `runic_events`

Required columns:

- work scope, compact `stream_pk`, constraint-backed denormalized `namespace_pk` for RLS/routing, and `bigint` position;
- core event ID, Journal transaction ID, and zero-based event index inside that transaction;
- event type, codec, and schema version;
- causation/correlation/authority metadata in typed bounded columns;
- canonical encoded `bytea` and digest;
- diagnostic `recorded_at` from the database statement/transaction boundary.

Constraints:

- primary key `(work_scope, stream_pk, position)` and composite foreign key `(work_scope, stream_pk, namespace_pk)` to the matching unique stream-head key;
- unique `(work_scope, event_id)` in the initial physical profile;
- unique `(work_scope, transaction_id, transaction_event_index)`;
- positive positions and bounded encoded size.

Replay resolves the full StreamRef to its compact key, then queries `position > cursor ORDER BY position LIMIT n`. Return an owned ReplayPage; never leak an Ecto stream tied to a checked-out connection.

`recorded_at` is useful diagnostics, not PostgreSQL commit order: it is assigned before the transaction actually commits. No projector, cursor, retention rule, or conflict resolver may sort transactions by that timestamp.

Any high-volume child that denormalizes `namespace_pk` for routing/RLS—events, dispatches, timers, or projection-feed work—uses that same composite foreign key (or an equivalent constraint-backed immutable stream reference). A child can never claim a tenant namespace different from its stream. Profiles that omit the duplicate field resolve namespace through `runic_streams` and do not advertise namespace-only child indexes.

Store event bytes, not a broad GIN-indexed JSON document. Put commonly filtered administrative metadata in typed columns and build domain queries from projections.

### 9.3 `runic_transactions`

One row records a terminal positive or negative storage outcome:

- transaction ID and canonical transaction digest when the commit request bytes were observed;
- full StreamRef and expected position when the commit request was observed;
- outcome `committed | not_committed`, matching `Journal.resolve`;
- optional closed reason/original command receipt inside the terminal receipt;
- first/last event positions for a commit;
- compact encoded receipt and details-expiry time;
- permanent/longer-lived ID-reuse guard after detailed receipt compaction.

The transaction digest is immutable and covers the semantically relevant request: target StreamRef, expected position, command identity/digest, authority/work-scope identity, typed storage preconditions, and ordered event/intention bytes. It never includes a mutable authority token, epoch, deadline, owner, retry count, or trace metadata. Reusing a transaction ID with different request bytes is always a transaction conflict.

A semantic duplicate command submitted under a fresh transaction ID receives a zero-event `committed` result carrying the original `CommandReceipt`, and its own terminal transaction row points to that receipt. A deterministic storage-precondition rejection is `not_committed` with a closed reason. These are not extra top-level `resolve` variants.

Resolution may reserve an absent transaction ID even though `resolve(StreamRef, transaction_id)` never received a request digest. Such a negative tombstone explicitly stores `request_digest = NULL` and `reservation_kind = resolve_absence`; it permanently rejects any later commit with that ID. This is distinct from a negative receipt created while processing known request bytes, which stores the digest. A later retry cannot fill or reinterpret a resolver tombstone.

Do not model “missing row” as a terminal result until the resolve protocol in Section 11 has serialized against the original attempt and chosen a negative row.

### 9.4 `runic_commands`

Command identity is scoped exactly as the Runtime contract defines, normally by StreamRef:

- command ID, command kind, and canonical request digest;
- first Journal transaction ID;
- original acceptance/outcome receipt;
- committed position and receipt-detail horizon;
- compact reuse guard retained after detail compaction.

A repeated command ID/digest returns the original receipt even if the caller supplies a new Journal transaction ID. The same ID with different digest is a command conflict. Database `UNIQUE` constraints, not a query plus hash advisory lock, enforce this invariant.

### 9.5 `runic_authorities` and `runic_work_scopes`

The default first profile advertises `authority_scope: :partition`:

- a fixed virtual work scope owns many execution streams;
- acquisition locks the authority row, checks expiry/release, increments `bigint` epoch, and stores an owner-incarnation UUID;
- renewal requires exact epoch/incarnation;
- takeover always increments epoch;
- the PostgreSQL clock decides lease deadlines;
- every Journal commit validates the token under a compatible row lock in the same SQL transaction.

Execution-scoped authority is a later selectable profile for workloads that need finer takeover domains. Capabilities must report the configured scope; Runtime never assumes they are interchangeable.

Work-scope identities and placement generations are stable paged discovery data. Rebalancing across databases is an explicit drain/copy/fence operation, not a changed hash function at runtime.

The reference fencing path uses the compatible row locks in Section 10, but one partition-authority tuple may receive a `FOR SHARE` lock for every commit in that work scope. Before certification, benchmark its tuple-lock WAL, MultiXact member consumption, latency, and vacuum impact against a second implementation: commits take `pg_advisory_xact_lock_shared(stable_authority_key)` and then validate the durable epoch row; takeover takes the matching exclusive transaction advisory lock, locks/updates the epoch row, and commits the increment. The advisory lock only serializes access—the durable epoch/incarnation row remains the authority proof, hash collisions cause contention only, and failover tests must show stale tokens still fail. Publish which implementation each certified profile uses.

## 10. Atomic Journal commit protocol

Use Ecto.Multi where it makes the operation inspectable, but allow one private SQL function/CTE path when it measurably reduces round trips. Both paths implement the same reference transition.

Lock order is fixed:

1. transaction-resolution key;
2. authority row;
3. stream head;
4. command receipt row/unique insertion;
5. derived dispatch/timer rows in stable identity order.

Conceptual transaction:

~~~text
BEGIN at READ COMMITTED
  SET LOCAL bounded lock_timeout and statement_timeout
  acquire transaction-scoped serialization for transaction_id
  resolve existing positive/negative transaction receipt
  SELECT authority ... FOR SHARE; validate epoch/incarnation/deadline
  SELECT stream ... FOR UPDATE
  insert or resolve command ID + request digest
  if semantic duplicate, write zero-event committed transaction receipt and return original command receipt
  validate expected position, typed storage preconditions, payload receipts, and adapter limits
  if deterministic rejection, INSERT not_committed transaction receipt + closed reason, COMMIT, return
  assign contiguous positions from locked stream.position
  bulk INSERT versioned RecordedEvents
  apply library-owned active/dispatch/timer/snapshot indexes
  when projection-feed capability enabled, INSERT projection-outbox routing item
  UPDATE stream head and compact hints
  INSERT committed transaction receipt and command receipt
COMMIT
after known commit, ExecutionBackend/notifier emits a best-effort small wakeup hint
~~~

The Runtime coordinator—not PostgreSQL—decides graph lifecycle, runnable/read-set validity, artifact compatibility, and whether an attempted transition is semantically legal. A Runtime-owned `Transaction` may carry typed adapter-independent witnesses (expected artifact/graph revision, payload durability receipt, or other RP2 precondition); the Journal compares those declared storage values atomically but never re-runs the workflow decision model. Derived index mutations are core-typed intentions or deterministic consequences of recorded event kinds, not adapter-authored graph logic.

Expected-position conflict, typed storage-precondition failure, command-digest conflict, or a known adapter-limit rejection commits a small `not_committed` transaction receipt before returning the terminal negative. Rolling back and returning an unrecorded terminal negative is forbidden because a later `resolve` could not prove it. SQL/connection failures whose outcome is not proven still return `unknown`/error under the Section 11 protocol.

Stream creation follows the same protocol rather than a separate check-then-insert path. A create command conditionally inserts the stream head with its pinned artifact/reference, locks the resulting row, and applies command deduplication under the same constraints. Repeating the same start command returns its original receipt; a different command that races for the same StreamRef receives a closed stream-already-exists conflict.

Once the stream row is locked, command deduplication is evaluated before expected-position rejection. This ordering lets a retried command return its original receipt even when the stream has advanced since the first commit, while a new command with a stale expected position still fails. Concurrent inserts rely on the scoped unique constraint and retry the lookup path after the losing insert is rolled back to a savepoint or the transaction is retried under the documented SQLSTATE policy.

Why `FOR SHARE` on the partition authority row: many stream commits may hold compatible share locks concurrently, while authority takeover uses `FOR UPDATE` and must wait for those in-flight commits. After takeover, an old token cannot acquire the share lock and pass validation. Do not use `FOR KEY SHARE`; a non-key epoch update may not conflict strongly enough.

The stream `FOR UPDATE` lock serializes one execution's noncommutative transitions. Different streams remain concurrent. `READ COMMITTED` plus explicit predetermined-row locks is the default commit profile; `SERIALIZABLE` commit is an optional separately tested profile, not a substitute for IDs, constraints, and lock discipline. Transaction resolution remains the fresh-statement `READ COMMITTED` protocol in Section 11 under every profile.

Never:

- allocate position with `COUNT`, `MAX`, or an unrelated sequence;
- perform user code or external I/O inside this transaction;
- acknowledge before event, head, receipts, and pending-work indexes commit;
- blindly retry a connection error whose commit status is unknown;
- let a projector failure roll back the canonical Journal transaction;
- hold the authority row with an exclusive lock for the lifetime of a coordinator.

## 11. Ambiguous commit and transaction resolution

PostgreSQL makes a transaction atomic, but a caller can still lose the reply after the server commits. A connection timeout can also occur while the backend remains capable of committing. Therefore, a fresh query that sees no transaction row is not immediately an affirmative non-commit proof.

The first implementation uses a transaction-scoped advisory lock only to serialize operations by transaction ID:

1. `commit` begins a transaction and calls `pg_advisory_xact_lock(stable_transaction_key)` before checking/inserting the transaction receipt.
2. `resolve` begins another transaction and acquires the same lock.
3. If the original backend is still running, resolution waits up to its bounded timeout or returns `unknown`.
4. Once resolution holds the lock, it reads the receipt.
5. A positive/negative receipt is terminal.
6. If no receipt exists, resolution inserts the digest-less `resolve_absence` `not_committed` tombstone and permanent ID-reuse guard before returning `not_committed`.
7. A delayed/retried original commit later sees that negative receipt and cannot apply.

The resolver is pinned to a fresh `READ COMMITTED` transaction. Lock acquisition is one SQL statement and the receipt lookup is a subsequent statement, so the lookup receives a new statement snapshot after any original committer that held the advisory lock finishes. Do not combine the wait and lookup into one statement/CTE, and do not use a `REPEATABLE READ` or `SERIALIZABLE` snapshot opened before the wait; either can continue seeing pre-commit absence after the lock becomes available.

Use a stable library-defined 64-bit digest of the transaction UUID, not Erlang `phash2`. An advisory-key collision may serialize unrelated transactions but cannot conflate their separately constrained receipt rows. Advisory locks are not used as workflow authority.

If lock acquisition or insertion of the negative receipt is itself ambiguous, `resolve` returns `unknown`. After detail retention expires it returns `expired` with the advertised retention description, while the compact guard continues to prevent unsafe ID reuse.

Receipt/guard retention is a capacity and security contract. `resolve` is an internal authenticated Runtime operation authorized for the complete namespace/StreamRef; untrusted clients never receive a raw Journal tombstone API. Transaction IDs have cryptographic entropy, and each namespace has rate, outstanding-resolution, storage-byte, and guard-row quotas so guessed IDs cannot consume unbounded primary storage. Telemetry reports positive, negative, detail, and compact-guard bytes/transition.

Before `cluster_safe`, select and publish one exact long-term scheme: retain compact per-ID guards with a costed capacity/archive policy, or make the core transaction identity carry an authenticated/validated issuance generation so closed generations are categorically rejected after their receipt horizon. Never simply prune a guard while an old delayed commit could still be accepted, and never use a probabilistic structure with false negatives. The installer exposes the detailed receipt horizon, guard layout, quota response, and recovery promise rather than calling retention “permanent” without a storage budget.

Retry automatically only when PostgreSQL proves the transaction aborted, such as selected serialization, deadlock, or lock-timeout SQLSTATEs. A dropped connection after a commit request first goes through `resolve`; it is never converted into a blind new transaction.

## 12. Dispatch and timer tables

### 12.1 `runic_dispatches`

One row is a materialized delivery obligation for one committed dispatch event:

- immutable dispatch ID derived from the recorded dispatch event/attempt identity;
- work scope plus compact `stream_pk`/`namespace_pk`, resolving uniquely to the complete StreamRef;
- recorded dispatch event ID/position;
- activation ID, attempt ID/number, graph/artifact revision;
- queue, resource class, tenant-fairness key, priority, and `available_at`;
- encoded-byte estimate and PayloadRefs, not large payload bytes;
- direct-queue delivery state `scheduled | retryable | available | claimed | paused` when that profile is selected;
- claim owner/incarnation, random claim token, monotonically increasing claim generation, and claim deadline;
- bounded failure diagnostics and attempt-delivery count.

Suggested indexes:

- `(work_scope, queue, priority, available_at, dispatch_id)` where state is available;
- `(work_scope, state, available_at, dispatch_id)` where state is scheduled or retryable;
- `(work_scope, claim_deadline, dispatch_id)` where state is claimed;
- optional `(work_scope, namespace_pk, attempt_id)` for bounded administration when that denormalized compact key is justified; external namespace/name searches belong in a projection.

Keep completed history in recorded events and projections. Resolve an outstanding live delivery only in the Journal transaction that accepts completion or cancellation. A compact terminal delivery receipt may remain for a configured horizon and then be removed, but an unresolved scheduled, retryable, available, claimed, or paused row is never deleted merely because it is old. This keeps the hot table bounded without sacrificing the durable obligation.

`paused` is a durably discoverable operational hold, not a terminal workflow decision. Automated poison protection may pause repeated transport failures, but health/backlog scans still surface the row and only an explicit operator release or committed Runtime cancellation/failure transition resolves it. The ExecutionBackend cannot silently choose the workflow's retry policy.

### 12.2 Direct queue versus external-broker state machines

Do not overload one acknowledgment with two meanings.

For the direct PostgreSQL/Broadway queue:

~~~text
Journal commit: pending dispatch row
  -> scheduled/retryable stager promotes due work to available
  -> direct claim (token/deadline)
  -> execute using DispatchContext completion sink
  -> Runtime committed/duplicate completion removes pending row atomically
  -> Broadway ack records local transport success/metrics
~~~

For an external broker, the canonical pending dispatch remains until Runtime accepts completion. An optional `runic_dispatch_publications` row tracks the separate producer handoff:

~~~text
ready -> publishing(claim token/deadline)
      -> published(broker/backend receipt)
      -> consumer delivery/redelivery
      -> Runtime committed/duplicate completion
      -> consumer ACK; canonical dispatch already resolved by Runtime
~~~

The Journal/connector `claim_dispatch_publications` and `ack_dispatch_publication` operations cover PostgreSQL-outbox claim through broker publish acceptance only. Publish timeout/ambiguity remains `publishing` until backend-specific resolution or lease expiry causes an idempotent republish with the same dispatch/attempt identity. A broker publish confirm does not mean the runnable completed. Conversely, broker consumer ACK waits for a committed/known-duplicate Runtime completion; acknowledgement loss may redeliver and safely repeat that completion route.

The publication receipt is keyed by dispatch event plus configured backend target and may be compacted after the semantic dispatch resolves. A backend without a publish-resolution API advertises at-least-once publication, never exactly-once handoff.

### 12.3 Claim algorithm

Adapt Oban's proven bounded CTE pattern:

~~~sql
WITH claim_clock AS MATERIALIZED (
  SELECT clock_timestamp() AS now
), candidates AS MATERIALIZED (
  SELECT d.work_scope, d.dispatch_id
  FROM runic_dispatches AS d
  WHERE d.work_scope = $1
    AND d.queue = $2
    AND d.state = 'available'
  ORDER BY d.priority, d.available_at, d.dispatch_id
  LIMIT $3
  FOR UPDATE OF d SKIP LOCKED
)
UPDATE runic_dispatches AS d
SET state = 'claimed',
    claim_owner = $4,
    claim_token = gen_random_uuid(),
    claim_generation = d.claim_generation + 1,
    claim_deadline = t.now + ($5::bigint * interval '1 millisecond')
FROM candidates AS c
CROSS JOIN claim_clock AS t
WHERE d.work_scope = c.work_scope
  AND d.dispatch_id = c.dispatch_id
RETURNING d.*;
~~~

The exact SQL should follow supported PostgreSQL versions and verified query plans. `$5` is a validated bounded lease duration, never a caller-supplied wall-clock deadline; one database clock sample controls the deadline. The CTE is an optimization fence so a planner rewrite cannot update beyond the bounded candidate set. `SKIP LOCKED` intentionally yields an inconsistent queue view suitable for concurrent consumers. It is not a general read API or a writer fence. Return/join the complete physical key, as shown, so hash-partitioned children do not rely on unsupported global uniqueness.

Future and backed-off rows do not live in the claimable partial index. A bounded stager uses the same materialized-CTE/`SKIP LOCKED` shape and one database time sample to promote due `scheduled`/`retryable` rows to `available`. Claim queries therefore never scan through an arbitrarily large population of future high-priority work.

A bounded reaper selects expired `claimed` rows and makes them `available` or `retryable` according to transport policy. Renew, release, pause, and reaper updates compare state **and** the exact `(work_scope, dispatch_id, claim_token, claim_generation)` returned by claim; stale workers cannot mutate a later claim. `claim_generation` is transport state, not Journal authority. The later Runtime completion independently validates activation/attempt identity and its current authority token.

Locks are released before user execution. Durable claim identity, deadline, and Journal validation protect the later completion. Expiry makes the same attempt visible again; it does not prove the previous worker stopped. A late worker result must pass current activation/attempt and authority validation.

### 12.4 `runic_timers`

Timer rows contain timer/occurrence identity, StreamRef, due time, policy version, state, and claim fields. A partial `(work_scope, due_at, timer_id)` index serves scheduled timers; a separate claimed-deadline index serves recovery.

Timer claiming uses the same bounded CTE/lease pattern. Firing is a Journal command with stable timer occurrence ID. The event transition atomically records the fire/cancellation and removes or advances the timer row. Duplicate/early wakeups are harmless.

PostgreSQL time is the authority for due/lease comparisons. Elixir monotonic time remains appropriate only for local duration/telemetry.

## 13. PostgreSQL PayloadStore: facts, artifacts, and checkpoints

`RunicPostgres.PayloadStore` implements immutable content-addressed storage, not an updateable arbitrary key/value database.

### 13.1 Payload row

Required fields:

- namespace;
- digest algorithm and cryptographic digest;
- payload domain/kind: fact, result, artifact, snapshot, segment, or opaque;
- codec/schema version;
- encoded bytes or external-storage reference;
- byte size, compression, encryption/key metadata, and integrity status;
- insertion time and optional retention class.

Primary identity is `(namespace, digest_algorithm, digest)`, where the digest preimage is canonically domain-separated by payload kind, codec, schema version, and logical encoded bytes. `put` recomputes and verifies it, then uses constraint-backed insert-if-absent. A duplicate insert must match every immutable semantic field as well as the bytes; otherwise it is corruption, not an overwrite. Storage compression/encryption metadata may vary only through an explicit new storage-generation/reference protocol, never by mutating what an existing PayloadRef means.

### 13.2 Inline versus external bytes

Offer explicit profiles:

- `:inline_postgres` for bounded payloads below a configured byte ceiling;
- `:hybrid` where PostgreSQL keeps metadata and small bytes while S3/GCS/Azure/another PayloadStore holds large content;
- `:catalog_only` when another PayloadStore is authoritative; this is a metadata/reference catalog capability and does **not** advertise PostgreSQL PayloadStore durability or accept authoritative `put` calls.

TOAST is useful, but it is not a reason to put arbitrary multi-megabyte facts in the coordination database. Enforce inline row and transaction byte ceilings before checkout/insert. Large payload upload must meet its configured durability policy before the Journal commits a reference.

### 13.3 Fact identity

Runic owns fact **occurrence** identity and records occurrence-to-PayloadRef association in events. Equal values may share immutable bytes while remaining distinct causal facts. Do not use one bigint hash as both content identity and causal occurrence.

### 13.4 Snapshots/checkpoints

Snapshots are immutable portable Runtime snapshot IR with:

- StreamRef and exact event position;
- artifact/graph revision and codec versions;
- materialized runtime roots/state references;
- payload manifest and integrity digest;
- creation profile and compatibility metadata.

The bytes enter PayloadStore first. A normal Journal transition then records `SnapshotCommitted` and updates the stream's snapshot hint. A failed pointer transaction leaves an orphan payload; it never produces a snapshot ahead of history.

Raw `%Workflow{}` ETF may be an explicitly local, same-release cache only. It is not the clustered checkpoint format.

### 13.5 Deletion and garbage collection

There is no public blind `delete(ref)` in v1. Facts, artifacts, snapshots, and event segments may share bytes. A later collector uses Journal/snapshot/artifact manifests, retention policy, orphan grace, namespace authorization, and a mark generation. Reference counts updated by independent adapters are not sufficient correctness proof.

## 14. Broadway execution integration

### 14.1 Why Broadway is the PostgreSQL default

Broadway supplies demand, bounded processors, batching, partitioning, supervision, telemetry hooks, and acknowledger integration. The adapter portfolio keeps generic `Runic.Runtime.Worker` invocation, completion-sink handling, and Broadway acknowledgement in `runic_broadway`. This package supplies `RunicPostgres.DispatchSource` claim/release/renew/notification primitives and the default installer wiring. That turns Runtime's durable pending-dispatch index into load-controlled work without making Broadway the Journal or duplicating common worker plumbing.

The default full profile is:

~~~text
Journal commits RunnableDispatchRequested + pending row
                |
        NOTIFY hint / polling
                |
 RunicBroadway.Producer
 source: RunicPostgres.DispatchSource
 bounded CTE claim with durable token
                |
   Broadway processors/batchers
 Runic.Runtime.Worker.execute/2
                |
 DispatchContext completion sink
 fenced event transaction
                |
 RunicBroadway acknowledger observes committed/duplicate,
 releases retryable failures, or leaves claim to expire
~~~

The work message references the committed RecordedEvent and payloads. It does not carry a second workflow schema.

The adapter boundary is explicit: `RunicPostgres.ExecutionBackend.dispatch/3` verifies that the referenced dispatch event and live obligation are committed, then emits or coalesces only a wakeup hint. The PostgreSQL row is the durable delivery receipt. If wakeup delivery fails, polling still discovers the row; `dispatch_batch/2` coalesces hints by work scope and queue. Because the obligation already committed, local demand or broker backpressure cannot retract it—the backend reports degraded promptness while the Runtime leaves the row pending.

Directionally the callback returns the following outcomes (omitting the threaded adapter state shown in the core behaviour for readability):

- `{:accepted, delivery_receipt}` when the same durable dispatch identity is pending, including an idempotent repeat;
- `{:backpressure, retry_after}` when the backend cannot accept prompt handoff yet; the already committed Journal obligation remains the durable retry source;
- `{:unknown, dispatch_ref}` only when the database result cannot be resolved yet;
- `{:error, closed_reason}` only when the adapter can prove no compatible obligation exists or the reference/profile is invalid.

Backpressure never asks Runtime to append another dispatch event; reconciliation retries the same RecordedEvent/dispatch identity. A completed dispatch called again resolves to its compact prior delivery/command receipt within the advertised horizon; after that it returns the contract's expired/unknown-safe result rather than recreating work.

`DispatchContext` contains the serializable attempt/event references and a typed Runtime completion sink/handle. `runic_broadway` invokes that sink with the portable `AttemptResult`; neither it nor an external broker looks up a process by local PID or calls an ambient global Runtime. This preserves the completion route across asynchronous delivery and node boundaries.

### 14.2 Delivery semantics

- Claims and execution happen in separate transactions.
- Delivery is at least once.
- A message is acknowledged only after Runtime returns committed or known duplicate.
- Worker crash, acknowledgement loss, or claim expiry may redeliver the same attempt ID.
- An expired claim does not cancel a worker or make its side effects safe.
- Runtime acceptance, not Broadway acknowledgement, decides graph state.
- External effects need application idempotency, an inbox/outbox, reconciliation, or a shared domain transaction.

A runnable-produced success or failure is a semantic `AttemptResult`; both go through the completion sink and are transport-acknowledged only after the resulting Runtime transition is committed/known duplicate. A pipeline crash, payload hydration failure, lost database connection, or executor infrastructure error before a valid AttemptResult is a delivery failure and follows release/expiry policy instead of inventing a workflow failure event.

If completion returns `unknown`, `runic_broadway` resolves the same completion transaction ID. It does not acknowledge the broker message or release the direct claim into concurrent execution while resolution is pending; it renews where supported or lets the bounded claim expire. A definite `not_committed` follows the closed reason's retry/reject policy. On direct success the Journal transaction has already removed/resolved the canonical dispatch row, so the Broadway acknowledger never performs a second success deletion; it records local disposition/metrics and treats the known completion receipt as proof. Retryable pre-completion transport failures release only the exact live claim token.

Batching optimizes claim queries, payload prefetch, execution scheduling, and acknowledgement SQL. It does not imply one atomic completion across unrelated execution streams.

### 14.3 PostgreSQL producer controls

Expose and validate together:

- work scopes and queues served by this pipeline;
- processor concurrency and partitioning function;
- Broadway `max_demand`, `min_demand`, batch size, and timeout;
- claim row limit and total encoded-byte limit;
- maximum in-flight per node, queue, namespace, execution, and resource class;
- claim lease, heartbeat/extension policy, and maximum extension;
- dispatch cooldown, idle polling backoff, and jitter;
- database checkout/statement/lock timeouts;
- transport-failure pause threshold plus explicit release/escalation policy;
- Broadway acknowledgement grouping/batch size with synchronous token-fenced disposition;
- drain deadline and shutdown behavior.

Every producer fetch is bounded by the minimum of current Broadway demand, row limit, encoded-byte limit, and remaining local in-flight capacity. `partition_by` orders work only within that pipeline instance; it is not cluster serialization or workflow authority.

The installer computes a pool-budget warning from the complete topology: producer stages, processor concurrency times `max_demand`, batcher buffers, acknowledgement groups, database operations per message/batch, and node count. It never assumes `pool_size: 10` can sustain hundreds of processors completing simultaneously.

Claim heartbeat uses the RP2 `renew_delivery_claim` callback and requires the exact claim token/generation; it is not an unadvertised package-private mutation. A profile that does not implement renewal must set a bounded lease policy compatible with its maximum attempt duration and accept possible redelivery. Renewal extends transport ownership only—it never extends Runtime authority or proves a worker is alive enough to make external effects safe.

The acknowledger may use the message grouping Broadway already supplies, but it never returns success before a required release/pause/failure disposition is durably CAS-applied. There is no independent asynchronous “flush later” timer that can lose token-fenced disposition after Broadway believes acknowledgement finished.

### 14.4 Fairness and global limits

FIFO ordered by priority/time can let one tenant dominate. Provide measured claim policies built from typed insert-time columns:

- simple queue FIFO;
- virtual-work-scope partitioning;
- tenant/resource fairness using a stable claim partition key;
- per-execution maximum in-flight;
- optional cluster budgets leased to producers in batches.

Avoid one queue, PostgreSQL partition, or Broadway pipeline per tenant at high cardinality. Global concurrency/rate limits are explicit capabilities with durable token accounting or leased budgets, not the sum of uncoordinated local limits. Burst/fairness behavior must be documented and benchmarked.

### 14.5 Other messaging systems

When RabbitMQ, Kafka, SQS, GCP Pub/Sub, NATS, or another backend is configured:

- do not start the `RunicPostgres.DispatchSource` Broadway pipeline/notifier;
- a publisher claims or reads the same committed pending-dispatch obligation;
- publish-confirm ambiguity keeps the obligation recoverable;
- the broker message uses the same attempt ID and RecordedEvent reference;
- broker acknowledgement still waits for committed/duplicate Runtime completion;
- connector-specific limits remain in `runic_broadway` or the connector adapter.

## 15. Notifications, polling, and startup recovery

PostgreSQL `NOTIFY` is a wakeup hint:

- notifications appear only after commit and disappear on rollback;
- identical notifications may coalesce within a transaction;
- payloads are limited, so send a small scope/queue key;
- a stalled listener can retain server notification-queue space;
- notifications are not durable history;
- PgBouncer transaction/statement pooling cannot carry a session `LISTEN` connection.

The Journal never calls `pg_notify` inside its correctness transaction: a full PostgreSQL notification queue can make a notifying transaction fail at commit, and notifications from separate transactions are not coalesced for us. After a known successful Journal receipt, `ExecutionBackend.dispatch` sends a best-effort hint through a dedicated notifier process. That process coalesces scope/queue keys, reports notification failure as degraded promptness, and relies on durable-row polling to close the crash gap. A future optional dirty-wakeup table may improve coalescing, but it cannot replace the pending dispatch row.

Provide modes:

- `:hybrid` — dedicated Postgrex.Notifications connection plus polling backstop; default;
- `:poll` — jittered adaptive polling only;
- `:notify` — notification-driven promptness but still periodic reconciliation;
- `:disabled` — when another backend owns delivery.

Coalesce notifications per work scope/queue rather than notifying for every event. Monitor notification reconnects and queue usage. Never put event/payload bytes in a notification.

### 15.1 Bounded boot recovery

On application start:

1. validate schema/component versions and configured capabilities;
2. verify the connection is to a writable primary for correctness roles;
3. page `list_work_scopes`;
4. let Runic Runtime start bounded authority-acquisition/recovery demand per assigned scope through Journal callbacks;
5. page `scan_active`, pending dispatches, and due timers;
6. activate only work that needs an in-memory coordinator;
7. leave idle durable executions passivated;
8. continue periodic reconciliation after the initial scan.

Do not start all definitions or every row with a historical “running” status. The Journal's active/pending/due indexes discover work; managed run projections aid humans and may be repaired from events.

### 15.2 Boot semantics: recover, launch-enable, or reconcile residency

Keep three meanings separate:

1. An **unfinished durable execution** is discovered from Journal active/pending/due state and recovered as in Section 15.1.
2. A **launch-enabled definition** may accept new commands, but enabling or selecting a default revision does not itself create an execution.
3. A **desired resident deployment** asks the system to maintain a singleton or bounded set of continuously evolving executions. This is optional managed intent, not inferred from either of the first two states.

For the third case, generated `ManagedDeployment` code records namespace, stable deployment identity, desired state/cardinality, concurrency key, target policy, generation, and restart policy. A bounded boot/periodic reconciler resolves and pins a concrete StartSpec, then issues a caller-stable idempotent `start_execution` command derived from deployment identity and generation. Runtime admission or a package-owned concurrency-key record prevents two reconcilers from creating competing residents. Stopping/replacing a deployment is a durable command sequence with observable outcome; process registration or one elected scanner is only an optimization.

This deliberately does not copy a local registry plus “start every active definition” loop. Definitions are catalogs, Journal indexes are execution truth, and deployment intent is the only source of desired residency.

## 16. Managed workflow definitions and revisions

### 16.1 Generic lifecycle

The reusable model is:

~~~text
WorkflowDefinition
  identity, namespace, name, launch_eligibility, default_launch_revision, lock_version
        |
        +-- WorkflowRevision 1 (immutable source/IR + ArtifactRef)
        +-- WorkflowRevision 2 (immutable source/IR + ArtifactRef)
        +-- ...
        |
        +-- Triggers / Schedules
        +-- generated domain metadata and associations
~~~

Required semantics:

- stable tenant-qualified definition identity;
- immutable launch revisions and retained execution pins;
- exact Runic construction-artifact digest/cursor and code/catalog compatibility;
- compare-and-swap selection using `lock_version` or expected default-launch revision;
- explicit launch eligibility and retirement without rewriting a pinned revision;
- execution creation always pins a concrete revision/artifact;
- retirement prevents new default launches while preserving existing execution replay and history.

Drafts, publishing approval, “active”, “enabled”, and “archived” are optional application vocabulary layered over those primitives; Infinite Isekai demonstrates that a Runic consumer need not install a managed catalog at all. Use `default_launch_revision`, not `active_revision`, so catalog selection cannot be confused with an active execution.

Artifact ownership is split deliberately. The application owns domain authoring IR, component catalogs, compiler inputs, and policy. Runic owns the canonical portable construction-event envelope, captured-binding/context rules, versioning, and replay compatibility. `runic_postgres` verifies and stores immutable artifact references and management metadata; it does not define a second workflow encoding.

Creating/selecting a revision follows durability-first ordering:

1. build the canonical Runic artifact and put its bytes through the selected PayloadStore;
2. verify the returned durability/integrity receipt;
3. insert the immutable revision referring to that artifact;
4. compare-and-swap the definition's default launch pointer and eligibility if requested.

A failure before step 3 may leave a safe unreferenced payload for later GC. A failed CAS leaves a valid non-default revision. Artifact/revision GC must prove no execution, schedule occurrence, deployment StartSpec, or retained command receipt still pins the revision.

The generated schemas use library macros for required fields and allow domain fields/associations in the user's `schema` block. The package context is configured with those schema modules rather than assuming one fixed product schema.

### 16.2 What remains application-specific

- visual builder nodes/positions and editing commands;
- descriptions, tags, embeddings, sharing/community state;
- approval roles and publication workflow;
- domain component catalog and compilation;
- generated input forms and webhook authentication;
- policy vocabulary and user-facing status names.

Store arbitrary authoring documents in appropriate generated columns or PayloadStore. Do not add them to `runic_streams`.

## 17. Durable scheduling and triggers

### 17.1 Schedule model

A generated schedule supplies:

- namespace and schedule ID;
- a typed target: fixed StartSpec/ArtifactRef, managed default-revision policy, or application resolver module plus versioned data;
- cron/calendar expression, IANA timezone, and policy version;
- enabled state and next due time;
- misfire policy and maximum catch-up count;
- stable input-builder module/config reference or a pinned Runic artifact;
- concurrency/overlap policy;
- optimistic lock version.

`StartSpec` is a Runtime-owned portable value containing the concrete artifact/revision reference, normalized input PayloadRefs, execution identity/admission data, and compatibility requirements. A managed workflow revision is the default generated target but is not required; an application may resolve against another catalog.

This restriction is about schedule configuration, not Runic closure portability. A closure constructed through Runic macros may remain serializable inside the pinned canonical artifact with captured bindings and `context` declarations. Environment resources and secrets are resolved through Context at execution time; the schedule row never stores a live resource-bearing function.

Each authoritative package-owned occurrence has a unique `(namespace, schedule_id, occurrence_at)` constraint, stores the selected policy version and pinned StartSpec/digest immutably, and derives its stable Runtime command ID from that occurrence identity alone. Changing schedule policy cannot produce a second command for an already materialized occurrence. An intentional administrative replay uses a separately modeled replay generation/identity rather than smuggling policy version into the same occurrence. User-facing occurrence history may be projected separately.

### 17.2 Fire protocol

1. A bounded scanner uses a short transaction and `SKIP LOCKED` to assign due schedule rows a claim token, generation, and database-clock deadline, then releases row locks.
2. Outside that transaction it computes occurrences under the configured timezone/misfire policy and invokes any application/external resolver. The retry-safe resolver returns a self-contained immutable StartSpec plus source identity/version proof; no user code or I/O runs while a schedule row is locked.
3. A second short transaction locks the exact schedule claim, CAS-validates claim token/generation, schedule policy version, and expected `next_due_at`, then inserts authoritative occurrence rows and durable launch-outbox commands containing the exact specs/digests and advances `next_due_at`. For a same-database managed target it reads and pins the default revision in this transaction. If local schedule/mirrored-source state changed, it releases/retries resolution. A later default-revision change cannot alter an existing occurrence.
4. A submitter calls `Runic.Runtime.start_execution` with the occurrence command ID and concrete revision/artifact.
5. Duplicate submission returns the original command receipt.
6. The occurrence records execution identity/outcome through an idempotent update or projection.

This works even when the authoritative Journal is not PostgreSQL. There is a durable outbox gap, not a best-effort `after_commit` call. In the same-PostgreSQL profile, a future optimized path may join occurrence and Journal ingress in one transaction only if it preserves the same public semantics and does not execute workflow code inside the scheduler transaction.

A certified pure local resolver may use one short claim/materialization transaction, but only when it performs bounded deterministic database reads and no application callback, network call, artifact build, or payload upload. This is an optimization of the same CAS protocol, not the default extension interface.

An external proof has one of two explicit semantics. A locally mirrored immutable catalog revision may participate in the second transaction's CAS. Otherwise the occurrence uses **snapshot-at-resolution** semantics: the proof pins exactly what the resolver returned, but PostgreSQL does not pretend it atomically established that an external service still considered it “latest.” Resolver retries for the same claim/occurrence must return the same proof/spec or cause an explicit conflict/re-resolution; they may not silently retarget an already materialized occurrence.

### 17.3 Misfires and overlap

Generated policy explicitly chooses:

- skip missed occurrences;
- fire once now;
- catch up a bounded number;
- fail/pause for operator review.

Overlap may allow, skip, queue, replace, or serialize by a domain key. A single scheduler process is only an efficiency optimization and never the enforcement mechanism.

Occurrence uniqueness alone cannot enforce overlap across different occurrences. When a policy is not `allow`, materialization/ingress uses Runtime's concurrency-key admission contract or a package-owned `runic_concurrency_occupancy` row keyed by namespace and normalized policy key:

- `skip` records a terminal skipped occurrence when occupancy is live;
- `queue` retains ordered admitted intent and launches after the occupying execution reaches the policy's release state;
- `serialize` admits exactly one execution and one next transition under the fenced occupancy row;
- `replace` first issues a durable idempotent cancel command, waits for the configured accepted/terminal boundary, and then admits the new StartSpec.

Replacement never claims to undo an old worker's external side effects. Occupancy stores the owning execution/activation, generation, deadline/reconciliation state, and release condition; all mutations are constraint-backed and retryable after scanner failure.

### 17.4 Other trigger ingress

Manual, form, webhook, and event-subscription triggers share the same typed StartSpec, stable ingress command ID, Runtime admission, and deduplication path. Generated manual/form helpers require the caller to supply or derive a domain-stable idempotency key. Generated webhook scaffolding owns route shape and signature/idempotency plumbing, while the application owns authentication, authorization, rate policy, and payload-to-input mapping.

An event-listener trigger is not a callback that forgets progress after restart. Its connector must maintain a durable source cursor/receipt, map source event identity to a stable ingress command ID, and advance its cursor only under the connector's documented publish/inbox semantics. The base package supplies the ingress contract and optional same-PostgreSQL inbox; broker- or vendor-specific subscription loops remain separate adapters. PG7 delivers these primitives and examples, not every provider connector.

## 18. Read-model projections

### 18.1 Projection classes

Keep four classes distinct:

1. **Journal invariant indexes** — stream head, active marker, pending dispatch, due timer, command/transaction receipts. Package-owned and updated in the Journal transaction.
2. **Management control state** — authoritative schedule occurrences, launch outbox, concurrency occupancy, deployment intent, and optional same-database ingress. Package-owned or generated under a required contract and never reconstructed from a dashboard projection during normal operation.
3. **Operational read models** — run/step summaries, current progress, and occurrence/deployment query views. Rebuildable and normally asynchronous.
4. **Domain/analytical projections** — user-owned schemas, reporting, search, metrics, materialized views, warehouse export.

Only the first class participates in a Journal append. The second has its own scheduling/ingress transactions and correctness invariants; it never becomes workflow graph truth. The final two classes are disposable query state subject to their declared source-retention floor.

### 18.2 Why not a `BIGSERIAL` global cursor

PostgreSQL sequences are allocated outside transaction commit ordering and are not rolled back. Transaction A can allocate ID 10, transaction B allocate/commit ID 11, and A commit later. A projector that advances to 11 can permanently skip 10.

The base projector therefore uses durable work, not a naïve high-water ID:

1. Journal commit inserts one `runic_projection_outbox` row referencing its stream position range.
2. A router claims unrouted rows without assuming ID order.
3. It inserts unique per-projector delivery rows, then marks/deletes the routing item atomically.
4. Projector workers claim bounded deliveries.
5. Each projector maintains expected applied position per stream.
6. A gap is deferred/repaired from Journal pages; independent streams may proceed concurrently.
7. Projector writes, applied-position update, and delivery receipt commit in one database transaction when the target is the same PostgreSQL database.

Router crash before marking routed is harmless because delivery uniqueness makes routing idempotent. A new projector performs an explicit rebuild/bootstrap and then joins live routing; it does not infer safety from the newest serial ID.

Journal commits insert routing items only when the configured/certified projection-feed capability is installed. Enabling the feed or adding a projector later is an explicit bootstrap operation: register a new projector generation, establish per-work-scope stream-position barriers under the Journal's discovery contract, replay retained history through those barriers, route all later feed items to the generation, catch up gaps, and only then mark it live. Installation never flips an option and assumes the preexisting history appeared in an outbox table.

### 18.3 Ordering guarantees

Projectors declare:

- `:stream` — default; strict order within each execution, concurrency across executions;
- `:partition` — optional partition-local commit order with an explicitly serialized partition commit cursor and measured throughput cost;
- `:global` — not supplied by the base polling profile; use a deliberately serialized feed or a future logical-decoding adapter.

Most run/read models need `:stream`, not a global order.

### 18.4 Generated projector contract

Directionally:

~~~elixir
defmodule MyApp.RunicProjectors.WorkflowRun do
  use RunicPostgres.Projector, ordering: :stream

  @impl true
  def interested?(recorded_event), do: ...

  @impl true
  def project(recorded_event, multi, context) do
    # Add deterministic Ecto operations only.
    multi
  end
end
~~~

The library adds the projection receipt and expected-position mutation. User code adds only database operations; it performs no external side effect inside the transaction.

Post-commit effects are at least once. When they matter, write `runic_projection_effects` in the projection transaction and deliver that outbox separately. A callback invoked after commit without a durable effect row is observational/best-effort only.

The generated reference run projector must model execution, activation, and attempt identities separately. It keeps immutable attempt rows plus an explicitly derived current-step summary, and distinguishes waiting, passivated/idle, cancelled, failed, and completed states. Duplicate delivery is tested to leave counters unchanged; an upsert conflict cannot be followed by an unconditional increment. `on_idle` is not projected as completion unless a recorded terminal event says so.

### 18.5 Rebuild and repair

- pause a projector generation;
- create shadow tables or clear only user-approved data;
- page work scopes and streams from the Journal;
- replay each stream in position order through the projector;
- compare checksums/counts and catch up live delivery;
- atomically swap/activate the new generation;
- retain a rollback window.

User projections may run on a read replica only from a replication/logical feed designed for that purpose. Projection receipts that control delivery remain on the writable primary.

“Rebuildable” is a retention contract, not an aspiration. Every projector registers its earliest required source position and whether it can bootstrap from a compatible projector checkpoint. Event compaction may pass that floor only after an authoritative archive/segment store or verified checkpoint plus tail can supply every required position. V1 either retains complete Journal history for installed projectors or refuses the trim; PG9 archived segments may relax that physical-retention requirement without relaxing logical availability.

## 19. CQRS and event-sourced domain composition

The PostgreSQL profile should feel natural to a team building aggregates, process managers, and read models without collapsing all domain state into the workflow Journal.

### 19.1 Execution as an event-sourced aggregate

One Runic execution has:

- stable StreamRef identity;
- ordered RecordedEvents and optimistic expected position;
- fenced authority for deciding transitions;
- pure decision followed by atomic commit and replayable application;
- query projections derived from history;
- commands with stable IDs and original receipts.

That is an aggregate boundary. Concurrent noncommutative changes to one execution serialize at its stream head. Separate executions communicate through durable commands/events and do not receive an invented cross-stream transaction.

### 19.2 Domain transaction into a workflow

When the domain transaction and `runic_postgres` ingress share one PostgreSQL Repo/database, use the package-owned `runic_ingress` schema plus a public helper that adds only the constrained insertion to the application's `Ecto.Multi`:

~~~text
domain Ecto.Multi
  update aggregate rows
  RunicPostgres.Ingress.put(command_id, StartSpec/input refs)
COMMIT
        |
Runic ingress worker submits stable command_id
        |
Journal duplicate returns original receipt
~~~

This supplies atomic domain-write-plus-durable-intent, even if the ingress worker later submits to a different selected Journal. When the package table cannot share the domain transaction/database, the application instead owns a domain outbox in that database and a connector advances its durable delivery receipt only after known Runtime acceptance/duplicate. That external outbox is not `runic_ingress`, and calling Runtime after commit without either durable record is insufficient.

The same-PostgreSQL worker may consume the inbox efficiently, but application code cannot inject arbitrary `Ecto.Multi` operations into the Journal's invariant transaction. That would make workflow semantics adapter-specific, enlarge locks, and let slow domain code destabilize execution authority.

### 19.3 Workflow output into the domain

Use one of:

- an idempotent projector transaction for a same-database read model;
- a durable projection/effect outbox for commands to another aggregate/system;
- an effect handler with a stable attempt/idempotency key plus reconciliation;
- a domain-specific transaction when the external system supports it.

The Journal proves at most one accepted Runic transition for an attempt. It cannot prove that an arbitrary payment, email, HTTP call, or game mutation happened exactly once.

### 19.4 Sagas and continuously evolving workflows

Runic process-manager, Saga, state-machine, join, accumulator, map/reduce, and runtime graph-mutation events remain normal graph/runtime semantics. Long waits are timers/signals in the Journal; no queue row, DB connection, or BEAM process remains active for the workflow lifetime.

Runtime graph changes commit as declarative construction/mutation events pinned to graph revision. User projectors can expose their domain meaning without becoming the only durable copy.

## 20. PostgreSQL physical and DBA design

### 20.1 Supported database profile

Initial certification should target supported PostgreSQL major versions selected during package scaffolding, with a conservative floor that supports modern declarative partitioning and `MATERIALIZED` CTEs. Test every declared major in CI. PostgreSQL-compatible products require their own profile; syntax compatibility is not durability/concurrency equivalence.

All correctness tables are permanent WAL-logged tables. Never use `UNLOGGED` for Journal events, heads, authorities, receipts, work, timers, payloads, schedules, or projection delivery state.

### 20.2 Durability and failover

Publish named durability modes:

| Mode | Required database behavior | Adapter claim |
|---|---|---|
| `development` | Local/default settings | No production durability claim |
| `regional_primary` | WAL durability, `synchronous_commit = on`, tested backups/PITR | Durable on acknowledged primary commit |
| `regional_ha` | Synchronous/managed failover policy that does not lose acknowledged commits within stated envelope | Cluster-safe regional profile after failover tests |
| `async_throughput` | Explicit asynchronous commit/replica policy | Lower durability; never inherits HA label |

The adapter cannot infer a managed provider's failover RPO from a successful SQL connection. Installation/config requires a declared deployment profile, and health/admin output reports that declaration. Certification verifies it independently.

A declaration alone is insufficient. Define the PostgreSQL durability order `off < local < remote_write < on < remote_apply`. At the start of every correctness transaction, read `current_setting('synchronous_commit')`, choose the stronger of that value and the profile minimum (`on` for base regional-primary, a separately certified value such as `remote_apply` for an HA envelope), and issue `SET LOCAL` using a whitelisted literal. Thus a pooled connection left at `off` is raised while a session already at `remote_apply` is never downgraded to `on`. Unknown values/profile mismatches fail closed. Readiness verifies this behavior plus `fsync = on`, `full_page_writes`/WAL settings required by the selected profile, `transaction_read_only = off`, `pg_is_in_recovery() = false`, and that the chosen local setting can be applied. Provider replication/failover guarantees still require external certification evidence.

Correctness reads and writes go to the writable primary. Replicas may serve historical replay exports, projections, dashboards, or analytics only when their staleness is explicit. Never acquire/renew authority, resolve a transaction, claim work, or decide absence from a replica.

After primary failover, connection errors remain `unknown` until transaction IDs resolve on the promoted primary. If the provider can lose acknowledged WAL, the selected guarantee is not cluster-safe regardless of adapter code.

### 20.3 Connection-pool roles

Support one Repo for simplicity but recommend role-isolated pools under load:

| Role | Workload |
|---|---|
| coordination | short Journal commit/authority transactions |
| queue/timer | bounded SKIP LOCKED, acknowledgements, and lease maintenance |
| replay | paged event reads and snapshot metadata |
| payload | bounded payload reads/writes, physically isolatable from coordination |
| management/schedule | authoring, occurrence, deployment, and ingress transactions |
| projection | query models, delivery, and rebuilds |
| notification | one direct Postgrex.Notifications session |

Repo roles are pool assignments, not permission to break atomicity. Resolve them to this topology before startup:

| Role | Physical placement rule | Migration owner |
|---|---|---|
| coordination | Authoritative writable primary for one installation/schema/prefix | Namespaces, work scopes, authorities, streams, events, transaction/command receipts, dispatches/publications, timers, snapshot references, optional projection-feed outbox |
| queue/timer | Separate pool allowed, but must match coordination installation ID, database, schema, prefix, and writable primary | None; consumes coordination-owned tables |
| replay | Runtime recovery pool must match coordination installation/primary; a separate stale observer is an explicitly different capability | None; consumes coordination-owned tables |
| payload | May be the coordination database or a different certified PostgreSQL PayloadStore installation because Journal references it only after a durability receipt | Payload bytes/catalog/GC tables; snapshot pointer metadata remains coordination-owned |
| management/schedule | May be separate; must share the domain Repo/database when `RunicPostgres.Ingress.put/3` participates in that domain `Ecto.Multi` | Definitions/revisions, schedules, occurrences, concurrency occupancy, deployments, and same-database ingress |
| projection | May be separate only through the declared projection feed/delivery protocol; same-database atomic apply requires the exact target Repo | Projection delivery/control tables and generated user read models |
| notification | Direct session to the coordination database/installation | None |

Each physical installation has a prefix-qualified marker UUID and schema-version registry. Readiness compares that marker plus `current_database()`, schema/prefix, writable-primary state, and required component versions for every correctness role; it refuses to start a queue, timer, notifier, or recovery reader pointed at a different installation. Server addresses are diagnostic only because managed failover may change them.

Igniter assigns each component migration to the table's migration-owner Repo in this matrix. A second Repo that is merely another pool to the same database does not rerun DDL. Cross-database payload, management, or projection installations receive their own marker/registry and explicit handoff configuration; no Ecto transaction is claimed across them.

Generated configuration calculates an explicit connection budget:

~~~text
total application pool connections
+ Runic coordination pools per node
+ queue/timer pools per node
+ replay/payload pools per node
+ management/schedule pools per node
+ projector pools per node
+ notifier/direct sessions
+ migration/admin allowance
<= database/proxy budget with failover headroom
~~~

Queue processor concurrency is not database pool size. Completion and acknowledgement batches amortize checkouts. Pool checkout latency is a first-class saturation signal.

### 20.4 PgBouncer and prepared statements

- Transaction pooling may serve ordinary short Ecto transactions when prepared-statement mode is configured compatibly.
- Session `LISTEN`, session locks, and session-local state require a direct/dedicated connection.
- The transaction-resolution advisory lock is transaction-scoped and acquired/used inside one checked-out transaction.
- RLS/session tenant context must use `SET LOCAL` in the same transaction; never leak a session setting through a pool.
- Readiness identifies whether notifier configuration is compatible with the actual connection path and falls back to polling rather than losing work.

Document named versus unnamed prepare behavior for each supported proxy/provider. Test rolling deploys where old/new query shapes coexist.

### 20.5 Table-specific storage tuning

| Table class | Write pattern | Initial tuning direction |
|---|---|---|
| `runic_events` | insert-only append | Default/high fillfactor; explicit insert-vacuum/analyze thresholds; narrow B-tree indexes |
| `runic_streams` | frequent narrow head update | Lower fillfactor such as 80 after measurement; avoid indexes on changing columns |
| dispatch/timer/delivery | insert, claim update, delete/retry | Lower fillfactor such as 70–80; aggressive table-specific autovacuum; small partial indexes |
| command/transaction receipts | insert plus retention compaction | Separate detail from permanent guard if compaction churn warrants it |
| payloads | insert-only, potentially large | Byte ceilings; separate tablespace/profile if measured; no broad GIN index |
| projections | application-specific | User-owned indexes/partition/retention; isolate from coordination |

Numbers are presets to benchmark, not universal magic constants. The installer can emit commented recommendations but should not alter server-wide settings.

Autovacuum must be tuned per table before millions of dead claim tuples or insert-only unfrozen pages accumulate. Publish starting guidance for `autovacuum_vacuum_threshold`/scale factor, `autovacuum_vacuum_insert_threshold`/insert scale factor on supported majors, `autovacuum_analyze_threshold`/scale factor, and XID/MultiXact freeze ages. Monitor dead/live/insert counts, last vacuum/analyze, `relfrozenxid`, `relminmxid`, index/TOAST size and bloat, vacuum duration, and MultiXact member pressure. Periodic bounded pruning is preferable to unbounded deletes.

HOT updates are possible only when indexed columns are not modified and space remains on page. Queue state changes necessarily touch partial indexes; keep the row/index set narrow and retain no terminal history there.

### 20.6 Index discipline

- Every hot claim query has one matching partial B-tree index and an `EXPLAIN (ANALYZE, BUFFERS)` baseline.
- Do not add GIN indexes to canonical event/payload JSON by default.
- Use `INCLUDE` only when index-only scans measurably avoid heap I/O without bloating every write.
- Keep administrative indexes opt-in for write-heavy profiles.
- Create large new indexes concurrently, with partition-aware rolling procedures. `CREATE INDEX CONCURRENTLY` cannot run inside Ecto's ordinary transactional migration; generated operational migrations set `@disable_ddl_transaction true` and `@disable_migration_lock true` only with an explicit runbook. PostgreSQL cannot build a partitioned-parent index concurrently: create child indexes concurrently, validate them, attach them to the parent, detect/drop or resume invalid indexes, and make every step repeat-safe.
- Reindexing is maintenance, not a substitute for bounded hot tables and healthy autovacuum.
- Track query-plan regressions by supported PostgreSQL major and representative cardinality/skew.

Projection rebuilds, archive copies, and other whole-table jobs page through short transactions. They do not keep one snapshot/transaction open for the entire run and pin vacuum horizons.

### 20.7 Partitioning

Partitioning is a scale profile, not the default.

1. Start unpartitioned for operational simplicity.
2. When measured index/cache/vacuum limits justify it, hash-partition coordination/history tables by stable `work_scope`.
3. Include the partition key in every primary/unique constraint as PostgreSQL requires.
4. Keep the number of physical partitions bounded; more partitions can increase planning/session memory.
5. Use time partitions primarily for disposable projection/metric/receipt-detail history, where detach/drop matches retention.
6. Do not time-partition canonical events if ordinary stream replay would scan many partitions without a demonstrated plan.
7. Store permanent ID-reuse guards in a layout that survives detail partition removal.

The generated v1 `hash_partitioned` profile is concrete:

| Parent table | Partition key | Local key/constraint direction |
|---|---|---|
| streams | `work_scope` | PK `(work_scope, stream_pk)`; external StreamRef unique includes `work_scope` |
| events | `work_scope` | PK `(work_scope, stream_pk, position)`; event/transaction-event uniqueness includes `work_scope` |
| transactions and commands | `work_scope` | transaction/command uniqueness includes `work_scope` and command scope/stream key |
| dispatches and dispatch publications | `work_scope` | every claim/publication key and partial index begins with `work_scope` |
| timers and snapshot-reference metadata | `work_scope` | occurrence/reference keys and FKs include `work_scope` |
| projection outbox/deliveries/stream positions, when installed | `work_scope` | routing/delivery/projector-stream keys include `work_scope` |

`runic_namespaces`, work-scope placement, authority, installation/schema-version, and other small global control tables remain unpartitioned. Payload bytes/catalogs, managed definitions, schedules/occurrences/deployments/ingress, and user projections are not silently work-scope partitioned; each has a separate measured physical profile because its natural key/routing domain differs.

Generate every parent/child foreign key and unique constraint explicitly, create/attach child indexes as in Section 20.6, and verify all hash remainders `0..partitions-1` exist before readiness. Hash partitioning has no default partition; a missing remainder is a broken installation. The captured migration source owns the fixed modulus/remainder set, so runtime configuration cannot reinterpret it.

The installer accepts a physical profile and fixed partition count only at initial creation. Repartitioning is an explicit online migration project, not a mutable config edit.

### 20.8 Multi-database scale path

When one primary reaches its measured ceiling:

- retain a large fixed virtual-work-scope space;
- map scopes to PostgreSQL clusters in durable placement metadata;
- route a StreamRef deterministically to one database;
- drain/fence/copy/verify a scope before changing placement generation;
- keep cross-scope operations asynchronous;
- aggregate analytics outside coordination databases.

Do not use Ecto dynamic repos or a changed hash ring alone as a migration protocol. Runtime handles and work-scope generations must detect stale placement.

## 21. Admission control and tunable load profile

Runic should provide more control than “queue concurrency = N”. Apply limits at four boundaries.

### 21.1 Before durable acceptance

- maximum command/payload/event bytes;
- maximum events and new dispatches/timers per transition;
- per-namespace outstanding work and storage quotas;
- per-execution pending activation/dispatch ceiling;
- database saturation and maintenance/drain admission state.

A command not yet accepted may receive typed retryable overload. A confirmed accepted input is never dropped to relieve load.

### 21.2 Journal commit

- pool checkout and transaction concurrency;
- bounded lock/statement timeouts;
- maximum Ecto.Multi/parameter/batch size;
- deterministic lock ordering;
- bounded automatic retries only for known-aborted outcomes;
- per-scope hot-key detection and tenant fairness.

### 21.3 Delivery and compute

- claim rows **and bytes** per batch;
- max in-flight per node/queue/tenant/execution/resource class;
- adaptive cooldown and jitter;
- Broadway demand/processor/batcher limits;
- result submission/ack batch limits;
- explicit transport pause/release and circuit-breaking policy that leaves canonical work discoverable.

### 21.4 Projection and maintenance

- projector concurrency by stream/scope;
- maximum lag/backlog work per transaction;
- replay/rebuild rate limits;
- autovacuum/reindex/partition maintenance windows;
- separate analytics pools and replicas.

An optional adaptive controller may lower claim demand when pool checkout, commit p95, WAL rate, replication lag, dead tuples, disk queue, or projection backlog cross configured thresholds. It may improve promptness/availability; it cannot change correctness or silently discard accepted work.

Publish presets such as `:small`, `:balanced`, and `:throughput`, but expose their resolved numeric configuration and require production teams to benchmark their workload.

## 22. Multi-tenancy, authorization, and security

- Namespace is present in every stream, command, receipt, payload, managed definition, schedule, and projection key.
- Adapter entrypoints receive validated StreamRef/namespace from Runtime; they do not trust a payload map to select tenancy.
- Parameterize values and validate identifiers/prefixes at initialization; never interpolate user input into SQL identifiers.
- Separate database roles for migrations, runtime coordination, projection writers, and read-only analytics when practical.
- Encrypt connections and storage according to deployment profile; payload encryption metadata remains versioned.
- Do not decode untrusted ETF. Runic codecs validate size/version/type and use safe decoding.
- Keep secrets in ContextRefs/providers, not RecordedEvents, queue rows, schedules, or read models.
- Bound error text and metadata; never place workflow inputs or high-cardinality tenant IDs in telemetry labels.
- Audit authority takeover, migration, retention, restore, schedule changes, and administrative retries.

Optional PostgreSQL RLS is a supported profile only after tests prove every query, bulk operation, background worker, and migration behaves correctly. Shared pooled connections must use transaction-local tenant context. Explicit namespace predicates and constraints remain present even with RLS as defense in depth.

Schema-per-tenant can suit a small number of isolated installations, but it is not the high-cardinality SaaS default because migrations, catalog size, prepared plans, and pool routing scale poorly. A Libbit workspace may still select a dedicated database/schema as an application deployment choice.

## 23. Igniter installer and upgrade plan

Declare Igniter in `runic_postgres` as `optional: true` (not `only: :dev`) so the published installer task can compile when a consuming project makes Igniter available; consuming applications normally include Igniter only in development. No production-supervised module depends on it. Guard installer entrypoints with `Code.ensure_loaded?(Igniter)` and provide a direct-task/manual-template fallback with a clear message when it is absent.

Expose an installer recognized by `mix igniter.install runic_postgres`. That outer command adds `runic_postgres` before invoking its installer; `runic_postgres.install` adds only selected companion dependencies such as `runic_broadway`, never a second copy of itself.

### 23.1 Proposed command

~~~text
mix igniter.install runic_postgres \
  --repo MyApp.Repo \
  --components journal,store,facts,snapshots,managed_workflows,projections,schedules,triggers,ingress,deployments,postgres_queue \
  --artifact-store postgres \
  --executor broadway \
  --notifier hybrid \
  --prefix runic \
  --module-prefix MyApp.Runic
~~~

Equivalent direct task:

~~~text
mix runic_postgres.install ...
~~~

### 23.2 Options

| Option | Meaning |
|---|---|
| `--components` | Repeat-safe validated component set |
| `--repo` | Existing Ecto Repo; required when several are discovered |
| `--dedicated-repo` | Generate a role-specific Repo/config rather than reuse |
| `--repo-role ROLE=MODULE` | Repeatable typed override for `coordination`, `queue`, `replay`, `payload`, `management`, `projection`; omitted roles fall back to `--repo` |
| `--schema` | PostgreSQL schema/prefix namespace |
| `--prefix` | Stable table-name prefix |
| `--module-prefix` | Destination for generated application modules |
| `--artifact-store` | `postgres | external | none`; external requires a configured PayloadStore module, while none disables launchable-revision creation |
| `--artifact-store-module` | Module implementing `Runic.Runtime.PayloadStore`; required with `--artifact-store external` |
| `--artifact-store-config-mfa` | Editable `Module.function/arity` reference returning initialization options at startup; generated stub/default, never raw CLI secrets |
| `--executor` | `broadway | external | none` |
| `--notifier` | `hybrid | notify | poll | disabled`, matching runtime mode atoms exactly |
| `--authority-scope` | `partition` initially; later `execution` when certified |
| `--work-scopes` | Fixed virtual-scope count |
| `--physical-profile` | `unpartitioned | hash_partitioned` |
| `--partitions` | Initial physical partition count when selected |
| `--identity-type` | Only if RP0 permits more than the default |
| `--example-projector` | Generate sample query model and tests |

Feature validation examples:

- `postgres_queue` requires `journal` and defaults `executor=broadway`;
- `schedules` requires a Runtime ingress plus a fixed StartSpec, managed-revision target, or configured resolver; `managed_workflows` is optional;
- `triggers` generates target schemas/helpers; enabling manual/form/webhook submission requires `ingress`, while event-subscription triggers additionally require an explicit connector implementing the durable cursor contract;
- `ingress` requires a named Runtime handle and starts its idempotent submitter unless manual mode is selected;
- `deployments` requires ingress plus a StartSpec/target resolver and starts the bounded boot/periodic reconciler;
- `managed_workflows --artifact-store postgres` selects the PostgreSQL artifact PayloadStore component; `external` requires a module/config; `none` permits metadata/authoring management but `create_launch_revision` and default-launch selection fail with a typed missing-capability error;
- `snapshots` may use PostgreSQL or another PayloadStore but require Journal snapshot references at runtime;
- `projections` with an external Journal requires an explicit feed adapter;
- `store` expands to payload/fact/snapshot components without starting Journal processes.

External artifact-store installation never guesses among modules. Igniter requires `--artifact-store-module`, verifies the behaviour when the module is available, and generates an editable `MyApp.RunicArtifactStoreConfig` (or the requested MFA) that returns non-secret initialization options from application/runtime configuration. The resolved management configuration is `{payload_store_module, initialized_state}` and is passed directly to `RunicPostgres.ManagedWorkflows`; it does not require a `Runic.Runtime` process. If the external adapter needs supervised clients, the application/adapter child spec starts them before management APIs. Missing module, invalid capability, or unavailable durability receipt disables launchable-revision creation at readiness while leaving metadata queries explicit and safe.

### 23.3 Generated changes

When Igniter is loaded, the task should:

1. discover and validate Ecto/Postgres Repo(s);
2. add selected optional companion dependencies (the outer install already added `runic_postgres`);
3. create component-versioned migrations through `Igniter.Libs.Ecto`;
4. create/merge Runtime and package configuration idempotently;
5. add supervision children after the chosen Repo(s);
6. generate the application facade and selected editable schemas/contexts;
7. generate projector/schedule modules and tests when requested;
8. update formatter/import configuration where necessary;
9. print migration, validation, and production-tuning next steps;
10. never execute production migrations automatically.

When more than one Repo exists, require a deterministic flag or prompt. Root umbrella support remains opt-in until tested; otherwise instruct users to run in the target child application.

### 23.4 Migration ownership and idempotency

Invariant-sensitive tables are migrated by versioned `RunicPostgres.Migrations.up/2` calls embedded in generated migration source. The migration captures selected components and physical options; it never reads mutable runtime config.

Create an installation-scoped, schema/prefix-qualified registry such as `<prefix>_schema_versions`, keyed by component/version and installation identity. A fixed `runic_postgres_schema_migrations` name would collide when several prefixes share one PostgreSQL schema. Do not rely only on table comments that backup tooling may strip.

Rerunning the installer:

- makes no duplicate config/supervision changes;
- inspects existing project migrations/config to detect generated components without requiring a database connection; runtime migration/readiness code consults the database registry;
- generates a **new** migration when adding a component later;
- refuses incompatible prefix/partition/identity changes with a migration-plan explanation;
- can add generated application modules without overwriting user edits;
- applies repeat-safe `Igniter.Project.Config.configure` updaters for incremental components rather than `configure_new` or `on_exists: :skip`;
- uses an explicit `mix runic_postgres.upgrade FROM TO`/Igniter upgrader path because old versions cannot be inferred reliably for path dependencies.

Every historical `RunicPostgres.Migrations` implementation referenced by generated application migrations remains callable indefinitely; package refactors may delegate but cannot delete that versioned DDL. Generate `down` only when rollback is genuinely safe. Irreversible correctness migrations raise with a forward-repair/runbook explanation rather than destructively approximating rollback.

Test clean install, reinstall, add-component, custom schema/prefix, multi-Repo, dedicated Repo, umbrella child, no-Igniter fallback, upgrade, and dry-run. Generate installer documentation from the actual task/options so examples cannot drift from defaults.

### 23.5 Rolling schema and codec evolution

Every package release publishes, per component, the minimum/maximum schema versions it can read and write. Readiness permits mixed old/new nodes only inside that declared overlap; workers stop before claiming work when the database version is outside it.

Use an expand/backfill/validate/contract sequence:

1. **Expand** with additive nullable/default-safe columns, tables, indexes, or duplicate representations that old nodes ignore.
2. **Deploy compatible code** that reads both shapes and dual-writes only when the transition requires it.
3. **Backfill** in resumable keyset pages and short transactions with progress/checksum state in the component registry.
4. **Validate** new invariants, using `NOT VALID` then `VALIDATE CONSTRAINT` where PostgreSQL supports it, and build large indexes through the nontransactional concurrent procedure in Section 20.6.
5. **Flip** the component write version/capability only after all data and nodes are ready.
6. **Drain old nodes**, observe a rollback window, then generate a later release's contract migration that removes the old representation.

No release both introduces and requires a destructive shape while old nodes may still run. RecordedEvent/payload codec upgrades follow the same reader-before-writer rule and preserve upcasters for retained history. Upgrade/rollback tests exercise every supported adjacent-version overlap, interrupted backfill, validation failure, and old-node readiness refusal.

## 24. Supervision and runtime configuration

Directionally:

~~~elixir
postgres =
  RunicPostgres.Config.new!(
    repos: [
      coordination: MyApp.RunicCoordinationRepo,
      queue: MyApp.RunicQueueRepo,
      payload: MyApp.RunicPayloadRepo,
      management: MyApp.Repo,
      projection: MyApp.RunicProjectionRepo
    ],
    notifier: :hybrid
  )

children = [
  MyApp.Repo,
  MyApp.RunicCoordinationRepo,
  MyApp.RunicQueueRepo,
  MyApp.RunicPayloadRepo,
  MyApp.RunicProjectionRepo,
  {RunicPostgres.InfrastructureSupervisor, config: postgres},
  {Runic.Runtime.Supervisor,
   name: MyApp.RunicRuntime,
   journal: {RunicPostgres.Journal, config: postgres},
   payload_store: {RunicPostgres.PayloadStore, config: postgres},
   execution_backend: {RunicPostgres.ExecutionBackend, config: postgres},
   authority: [scope: :partition, work_scopes: 128]},
  {RunicPostgres.WorkerSupervisor,
   config: postgres,
   runtime: MyApp.RunicRuntime,
   components: [:projections, :schedules, :ingress, :deployments, :postgres_queue],
   queue: [pipelines: MyApp.RunicQueues],
   managed_workflows: [
     schemas: MyApp.RunicSchemas,
     payload_store: {RunicPostgres.PayloadStore, config: postgres}
   ],
   projections: [projectors: MyApp.RunicProjectors]}
]
~~~

This is illustrative: one Repo may fill every role, and generated child order must de-duplicate identical Repo modules. The actual API should use typed option validation and a resolved configuration struct. Avoid reading application environment throughout hot modules.

Runic Runtime—not the adapter—owns execution activation, passivation, authority acquisition/renewal, recovery demand, and reconciliation of active Journal state. `RunicPostgres.Journal` supplies passive authority/discovery/commit callbacks. The adapter-owned worker supervisor only runs selected PostgreSQL delivery and management workers against the named Runtime.

Adapter supervision starts only selected components:

- migration/schema readiness check;
- dedicated notification connection when enabled;
- Broadway pipelines when PostgreSQL delivery is selected;
- same-PostgreSQL ingress submitter when selected;
- schedule planner/submitter when selected;
- desired-resident deployment reconciler when selected;
- explicitly configured event-subscription connector children; the base `triggers` component itself starts no provider-neutral polling loop;
- projection router/workers when selected;
- maintenance plugins/helpers explicitly configured.

A maintenance process may use soft database leadership to reduce duplicate scans, following Oban's useful pattern. Table constraints, claims, and receipts still make concurrent copies safe. Process singularity is never the only invariant.

Provide manual mode for tests/administration: schemas and APIs work, but the adapter starts no queue scanner, ingress submitter, schedule planner, deployment reconciler, notifier, projector, or maintenance worker. Runtime authority/coordination is independently set to its own manual mode.

## 25. Telemetry, health, and operations

### 25.1 Telemetry

Standard spans should cover:

- Journal init/load/commit/resolve with records/bytes/positions;
- authority acquire/renew/release/takeover and stale-fence rejection;
- claim query, rows/bytes claimed, empty/skipped polls, and claim expiry;
- timer lateness and fire outcome;
- Broadway queue time, execution duration, result/ack outcome, memory/reductions where available;
- payload put/fetch/stat, inline/external bytes, corruption/defer;
- projection route/apply/retry/gap/rebuild and lag;
- schedule scan/occurrence/submit/misfire lateness;
- transaction retry/deadlock/serialization/lock-timeout/unknown outcome;
- Ecto pool checkout and SQL duration;
- notifier send/receive/reconnect/fallback;
- prune/vacuum advisory/reindex/partition/checkpoint/backup verification.

Metadata uses bounded adapter, role, queue, work scope, event kind, and outcome dimensions. Execution/tenant IDs belong in traces/log fields under policy, not metric-cardinality labels.

### 25.2 Readiness and health

Readiness for a clustered profile fails when:

- schema/component versions are missing or incompatible;
- configured capability/limits cannot be provided;
- the correctness Repo is read-only or connected to a replica;
- any coordination/queue/timer/recovery/notifier role disagrees on installation marker, database, schema, prefix, primary state, or compatible component version;
- durable profile prerequisites are not acknowledged/configured;
- work-scope/authority tables are corrupt or placement generation is unknown;
- notifier-only mode lacks a listener and no polling backstop exists;
- disk/database rejects writes or pool saturation exceeds a fail-safe policy.

Health reports, without turning every warning into process death:

- database version/recovery state and selected durability declaration;
- pool utilization/checkout latency;
- oldest active/dispatch/timer/projection/schedule backlog;
- Runtime resolution-work count/age when a durable tracker is configured, plus process/trace unknown-outcome telemetry; the terminal receipt table alone cannot reveal which callers currently lack an answer;
- WAL/replication lag for configured observers;
- dead tuples, vacuum/analyze age, table/index bytes;
- transaction ID and MultiXact freeze age, including authority-table `relminmxid`/member pressure;
- notification queue usage;
- schema migration and codec compatibility.

### 25.3 Backup, restore, and disaster recovery

Certify:

- base backups plus WAL/PITR covering every correctness table;
- consistent inclusion of migration/configuration metadata;
- PayloadStore backup or independently durable external references;
- clean restore to a new instance without stale owner processes;
- post-restore authority epoch/takeover procedure;
- resolution/reuse-guard retention across restore;
- replay verification from artifact plus events and snapshots;
- pending dispatch/timer/schedule/projection reconciliation;
- read-model rebuild rather than trusting inconsistent analytical backups.

Restore health verifies referenced payload digests and reports missing objects before activating affected work. RPO/RTO are published separately for primary loss, regional loss, payload loss, and projection rebuild.

## 26. Failure behavior

| Failure | Required behavior |
|---|---|
| process dies before commit | Transaction rolls back; stable command/transaction may retry |
| reply lost after commit | Return/retain unknown; resolve returns original positive receipt |
| resolver races original backend | Shared transaction-ID lock waits or returns unknown; never false negative |
| resolver proves absence | Inserts negative receipt/reuse guard before returning not_committed |
| stale authority remains alive | Every later commit fails epoch/incarnation validation |
| primary unavailable | Consistent operations stop; no replica/fallback consistency downgrade |
| acknowledged WAL lost on failover | Deployment violated selected durability profile; fail closed and surface incident |
| notification lost/coalesced/server queue full | Journal commit is already known; notifier reports degraded promptness and poll/reconciliation finds durable work |
| Broadway worker crashes | Claim expires; same attempt redelivers |
| old worker finishes after retry/takeover | Runtime accepts only a still-valid attempt/result; otherwise stale |
| external effect happens before worker crash | May repeat; application idempotency/reconciliation required |
| dispatch/timer claim query races | `SKIP LOCKED` yields disjoint current claims; durable tokens fence acknowledgements |
| projector receives later stream position first | Defer gap and fetch/retry predecessor; do not advance past it |
| projection transaction commits but ack is lost | Unique delivery receipt makes retry idempotent |
| schedule scanner crashes after occurrence insert | Durable launch outbox submits same occurrence command later |
| payload put commits but Journal fails | Orphan retained for later safe collection |
| Journal references missing/corrupt payload | Fail/defer closed; never execute with substituted bytes |
| full disk, lock storm, pool exhaustion | Typed unavailable/overloaded; accepted work remains durable |
| migration mismatch | Readiness fails before claiming authority/work |
| read replica is stale | Only explicitly stale queries affected; never correctness decisions |

## 27. Testing, benchmarks, and certification

### 27.1 Package tests

- Ecto changeset/schema and codec unit tests;
- SQL error-class mapping by SQLSTATE;
- installer/upgrader tests with Igniter.Test;
- generated module compilation and customization tests;
- migration up/safe-down-or-refusal/upgrade and custom schema/prefix tests, including resumable invalid concurrent indexes;
- multi-Repo migration ownership and startup rejection of mismatched installation/database/prefix roles;
- supported PostgreSQL-major matrix.

### 27.2 Journal conformance

- atomic batch/head/index update;
- expected-position conflict under many writers;
- command duplicate versus command-content conflict;
- positive/negative transaction resolution and expiry;
- ambiguous connection loss after every SQL boundary;
- authority acquire/renew/takeover/fence;
- active scan cursor completeness under concurrent inserts;
- dispatch/timer stage, claim, renew, expiry/reaper, duplicate, release, pause, and stale token/generation;
- direct-queue versus external publish/consumer two-ack state-machine conformance;
- snapshot plus tail replay and corrupt payload failure;
- backup/restore/codec migration.

### 27.3 Multi-connection and fault tests

- dozens of writers to one stream and many independent streams;
- authority takeover while commits hold share locks;
- deadlock and serialization retry injection;
- pool exhaustion and bounded overload;
- database restart and primary failover at each commit phase;
- delayed/lost/saturated-queue `NOTIFY` and listener reconnect, proving a Journal commit never depends on notification success;
- worker crash before effect, after effect, after result, and after committed result;
- timer/schedule duplicate and DST/misfire cases, including resolver slowness, claim expiry, and policy CAS change;
- projection router/apply crash, out-of-order commit, and gap repair;
- stale replica accidentally configured for a correctness role;
- rolling old/new adapter/codec versions.
- rolling expand/backfill/validate/contract interruption and mixed-node schema-range gates.

Ecto sandbox tests are insufficient for locks, notifications, and failover. Run dedicated unsandboxed integration suites with several real connections and disposable PostgreSQL clusters.

### 27.4 Benchmark workloads

Publish configuration and distributions, not one headline number:

- independent short workflows at several event-batch sizes;
- one hot workflow under conflicting writers;
- mixed active and millions of idle executions;
- large fan-out/fan-in with batched delivery;
- timer/schedule storms;
- small versus externalized payloads;
- noisy-neighbor tenant skew;
- projection fan-out and rebuild;
- queue backlog catch-up with millions of future scheduled/retryable rows outside the claimable index;
- primary failover and recovery scan;
- retention/vacuum pressure over sustained runs, including compact-guard quotas and authority MultiXact age.

Measure throughput and p50/p95/p99 commit, claim, queue age, completion, replay, and projection lag; pool checkout; WAL bytes; CPU/I/O; locks/deadlocks; dead tuples/vacuum; index/table bytes; unknown outcome rate; and fairness.

Compare at least:

- unpartitioned versus measured hash partitioning;
- PostgreSQL Broadway versus one external broker profile;
- shared versus dedicated pools;
- authority-row `FOR SHARE` versus shared/exclusive advisory-lock fencing under hot-scope load;
- notify/poll/hybrid;
- inline PostgreSQL versus external payloads;
- RunicPostgres against the migrated Infinite Isekai workload and reference Runtime model.

### 27.5 Maturity gates

- `experimental`: schemas/API may change; development only.
- `compatible`: Journal/PayloadStore/Backend contracts and replay pass.
- `cluster_safe`: fencing, ambiguity, failover, backup/restore, rolling upgrade, and sustained fault tests pass for a published PostgreSQL profile.
- `certified_profile`: full Runtime + PostgreSQL + Broadway/external broker composition passes at published scale and failure envelope.

## 28. Implementation phases

### PG0 — semantic model and Runic prerequisites

- land RP0–RP2 contract types and reference Journal;
- define PostgreSQL receipt, authority, projection, and schedule state machines;
- model commit/resolve races and authority lock compatibility;
- close identity, horizon, snapshot, and projection-feed decisions.

Gate: every callback/outcome maps to one PostgreSQL proof; missing receipt is never misreported as non-commit.

### PG1 — package, installer, and schema foundation

- create `~/wrk/runic_postgres` with Runic path dependency during development;
- Ecto/Postgrex configuration and test Repo;
- component-versioned migrations and schema registry;
- Igniter install task/options/idempotency tests;
- capabilities, health, telemetry, manual mode.

Gate: clean/repeated/incremental installs compile and migrate on every supported PostgreSQL major.

### PG2 — PayloadStore and replay pages

- immutable payload put/fetch/stat;
- cryptographic digest, size, codec, corruption paths;
- inline/external threshold and snapshot metadata;
- Journal event paging against a provisional/reference schema.

Gate: payload conformance, snapshot reference ordering, corruption, and restore tests pass.

### PG3 — core Journal transaction

- streams/events/transactions/commands;
- expected-position/authority validation;
- bulk event insert and stream head update;
- positive/negative resolve protocol;
- command/transaction horizons and compact guards;
- strict error mapping and retry policy.

Gate: concurrent writers, every ambiguous boundary, and property/reference histories pass.

### PG4 — authority, discovery, dispatch, and timers

- fixed virtual work scopes and partition authority;
- active scans with concurrency-safe cursors/reconciliation;
- dispatch/timer derived indexes, scheduled/retryable staging, token-fenced renew/reap/release, direct claims, and external publication receipts;
- notification/poll hybrid and bounded boot recovery;
- passivation/drain/failover integration with Runtime.

Gate: node kill/takeover cannot lose accepted input/work or admit a stale owner.

### PG5 — Broadway PostgreSQL integration

- PostgreSQL `DispatchSource` plus `runic_broadway` source/acknowledger conformance;
- bounded row/byte claims, batching, leases, release/explicit pause;
- fairness and per-execution/tenant limits;
- drain and manual testing helpers;
- optional dependency/config generation.

Gate: crash at every work/effect/result/ack boundary with no duplicate accepted Runic transition.

### PG6 — projector framework

- projection outbox/router/deliveries/stream heads;
- generated projector contract and transactional receipt;
- gap detection/repair and rebuild generations;
- durable effect outbox;
- run/step reference projector with distinct execution/activation/attempt identity, idle/terminal states, and duplicate-safe counters.

Gate: deliberately reversed transaction commits and repeated delivery never skip/double-apply a stream position.

### PG7 — managed workflows and schedules

- generated definition/revision/artifact schemas/context;
- default-launch CAS, eligibility/retirement, durability-first artifact pinning, and launch semantics;
- independently installable StartSpec-based schedule and trigger templates;
- authoritative occurrence/outbox/misfire/concurrency-key admission logic;
- manual/form/webhook ingress examples and durable event-subscription cursor contract;
- same-PostgreSQL ingress submitter, configuration, recovery, and manual-mode APIs;
- desired resident deployment model and idempotent boot/periodic reconciliation;
- startup/admin query APIs that distinguish recovery, launch eligibility, and desired residency.

Gate: every launch pins a revision and every schedule occurrence has one stable command outcome under duplicate scanners/crashes.

### PG8 — production scale and operations

- role-isolated pools, topology-aware admission/backpressure presets, query-plan baselines;
- table-specific autovacuum/fillfactor guidance and health;
- enforced transaction-local durability settings and row-lock/advisory-authority MultiXact benchmarks;
- optional hash-partitioned migrations/profile;
- resumable nontransactional concurrent-index runbooks and short-transaction rebuild tooling;
- backup/PITR/restore/failover/rolling-upgrade runbooks;
- security/RLS and proxy/provider test profiles;
- sustained benchmarks and chaos artifacts.

Gate: publish the first `cluster_safe` envelope; do not graduate based only on happy-path throughput.

### PG9 — multi-database and specialist features

- durable work-scope placement and migration;
- logical-decoding projection feed if demanded;
- execution-scoped authority profile;
- cluster/global rate-budget leasing;
- analytical export and archived event segments.

Each feature graduates independently and cannot weaken PG3–PG8 semantics.

## 29. Proposed package layout

~~~text
runic_postgres/
  lib/
    runic_postgres.ex
    runic_postgres/config.ex
    runic_postgres/infrastructure_supervisor.ex
    runic_postgres/worker_supervisor.ex
    runic_postgres/journal.ex
    runic_postgres/journal/transaction.ex
    runic_postgres/journal/authority.ex
    runic_postgres/journal/work.ex
    runic_postgres/journal/replay.ex
    runic_postgres/payload_store.ex
    runic_postgres/execution_backend.ex
    runic_postgres/dispatch_source.ex
    runic_postgres/projector.ex
    runic_postgres/projector/router.ex
    runic_postgres/projector/worker.ex
    runic_postgres/managed_workflows.ex
    runic_postgres/managed_deployments.ex
    runic_postgres/schedules.ex
    runic_postgres/schedules/admission.ex
    runic_postgres/triggers.ex
    runic_postgres/ingress.ex
    runic_postgres/migrations.ex
    runic_postgres/health.ex
    runic_postgres/telemetry.ex
    runic_postgres/schema/...
    mix/tasks/runic_postgres.install.ex
    mix/tasks/runic_postgres.upgrade.ex
  priv/
    templates/...
  test/
    conformance/...
    integration/...
    installer/...
    support/...
  guides/
    installation.md
    architecture.md
    postgres-operations.md
    projections.md
    managed-workflows.md
    tuning.md
~~~

One top-level module per file. Keep SQL fragments close to the responsible invariant module and exercise them through real PostgreSQL tests.

## 30. Recommended first delivery posture

1. Finish Runic RP0–RP4 before publishing Journal/execution integration; finish RP5 before publishing PayloadStore, portable-snapshot, or projection-feed claims. The full package profile requires RP0–RP5.
2. Use Infinite Isekai as the first PostgreSQL migration/conformance fixture, replacing its count-based allocator and unsafe local recovery.
3. Build PayloadStore and core Journal before managed product models.
4. Default the full PostgreSQL profile to partition-scoped authority, hybrid notify/poll, and Broadway bounded attempts.
5. Keep physical tables unpartitioned first; add hash partitioning only after sustained evidence.
6. Generate management/projection code into applications while keeping correctness SQL package-owned.
7. Treat Libbit's SQLite workspace models as domain-shape evidence, never as evidence that its legacy global PostgreSQL path is authoritative.
8. Certify one regional primary/HA profile before multi-database routing or logical decoding.
9. Publish tuning inputs and resolved budgets, not a universal concurrency setting.
10. Preserve adapter composition: no selected component starts or claims guarantees for roles it does not own.

## 31. Open decisions

1. Exact Runic canonical identity types and their PostgreSQL encodings.
2. Initial supported PostgreSQL major floor and Ecto/Postgrex version ranges.
3. Whether `Runic.Runtime` standardizes a projection-feed contract in RP5.
4. Default partition-scoped work-scope count and authority lease policy.
5. Exact stable 64-bit transaction-lock digest construction and cross-language test vectors.
6. Detailed command/transaction receipt horizons and permanent guard encoding.
7. Inline payload byte ceiling and whether payload metadata/bytes split into two tables.
8. Snapshot creation/compaction administrative callback shape.
9. Active-scan cursor algorithm under concurrent insertion and work-scope movement.
10. Dispatch claim fairness algorithm and cluster-global budget implementation.
11. Whether batch acknowledgements use `UPDATE ... FROM (VALUES ...)` in v1.
12. Projector registration/bootstrap barrier for joining a live feed.
13. Whether partition-order projection is worth its serialized cursor cost.
14. Managed schema required-field macro shape and configurable module registry.
15. Cron/calendar parser dependency and canonical timezone/misfire representation.
16. Same-PostgreSQL optimized schedule/ingress transaction after the generic outbox path works.
17. RLS certification scope and supported proxy/provider profiles.
18. Online conversion from unpartitioned to hash-partitioned tables.
19. Multi-database work-scope placement control plane.
20. Whether a temporary `RunicPostgres.LegacyStore` is needed for migration at all.

## 32. Primary sources and audited evidence

### Runic and consumer code

- [Runic Runtime Contract Upgrade Plan](runic-runtime-contract-upgrade-plan.md)
- [Distributed Durable Runtime Core Plan](distributed-durable-runtime-core-plan.md)
- [Distributed Adapter Portfolio Plan](distributed-adapter-portfolio-plan.md)
- [Runic Ecosystem Integration Evaluation](ecosystem-integration-evaluation.md)
- [Checkpointing Implementation Plan](checkpointing-implementation-plan.md)
- [Full-Breadth Runner Scheduling Considerations](full-breadth-runner-scheduling-considerations.md)
- [Infinite Isekai PostgreSQL Store](../../infinite_isekai/lib/infinite_isekai/workflows/postgres_store.ex) and [workflow migrations](../../infinite_isekai/priv/repo/migrations)
- [Libbit WorkspaceRepo](../../libbit/apps/core/lib/core/workspace_repo.ex), [workspace-local managed workflow](../../libbit/apps/core/lib/core/schemas/workspace_local/managed_workflow.ex), [trigger](../../libbit/apps/core/lib/core/schemas/workspace_local/workflow_trigger.ex), and [projector contract](../../libbit/apps/core/lib/core/workspace_projector.ex)
- [Libbit Clustered Durable Execution Architecture](../../libbit/.docs/runic-clustered-durable-execution-architecture.md), including its corrected workspace SQLite versus global PostgreSQL boundary

### Elixir ecosystem

- Oban 2.23.0 [Job schema](https://github.com/oban-bg/oban/blob/v2.23.0/lib/oban/job.ex), [PostgreSQL migrations](https://github.com/oban-bg/oban/tree/v2.23.0/lib/oban/migrations/postgres), and [Basic engine claim implementation](https://github.com/oban-bg/oban/blob/v2.23.0/lib/oban/engines/basic.ex)
- Oban [scaling](https://oban.hexdocs.pm/scaling.html), [operational maintenance](https://oban.hexdocs.pm/operational_maintenance.html), [clustering](https://oban.hexdocs.pm/clustering.html), [testing](https://oban.hexdocs.pm/testing.html), [PostgreSQL notifier](https://oban.hexdocs.pm/Oban.Notifiers.Postgres.html), and [Lifeline](https://oban.hexdocs.pm/Oban.Plugins.Lifeline.html)
- Oban [installation guide](https://oban.hexdocs.pm/installation.html) and [Igniter installer source](https://github.com/oban-bg/oban/blob/v2.23.0/lib/mix/tasks/oban.install.ex)
- Broadway [core documentation](https://hexdocs.pm/broadway/Broadway.html) and [Acknowledger](https://hexdocs.pm/broadway/Broadway.Acknowledger.html)
- Ecto [Multi](https://hexdocs.pm/ecto/Ecto.Multi.html), [Repo transactions](https://hexdocs.pm/ecto/Ecto.Repo.html#c:transact/2), and [PostgreSQL adapter](https://hexdocs.pm/ecto_sql/Ecto.Adapters.Postgres.html)
- Igniter [home/library-author guidance](https://hexdocs.pm/igniter/readme.html), [writing generators](https://hexdocs.pm/igniter/writing-generators.html), [upgrades](https://hexdocs.pm/igniter/upgrades.html), [`Igniter.Mix.Task`](https://hexdocs.pm/igniter/Igniter.Mix.Task.html), and [`Igniter.Libs.Ecto`](https://hexdocs.pm/igniter/Igniter.Libs.Ecto.html)

### PostgreSQL

- [Transaction isolation](https://www.postgresql.org/docs/current/transaction-iso.html)
- [`SELECT` locking and `SKIP LOCKED`](https://www.postgresql.org/docs/current/sql-select.html#SQL-FOR-UPDATE-SHARE)
- [Explicit and advisory locks](https://www.postgresql.org/docs/current/explicit-locking.html)
- [`NOTIFY`](https://www.postgresql.org/docs/current/sql-notify.html) and [`LISTEN`](https://www.postgresql.org/docs/current/sql-listen.html)
- [Constraints](https://www.postgresql.org/docs/current/ddl-constraints.html) and [`INSERT ... ON CONFLICT`](https://www.postgresql.org/docs/current/sql-insert.html)
- [Declarative partitioning](https://www.postgresql.org/docs/current/ddl-partitioning.html)
- [`CREATE INDEX` and concurrent-index restrictions](https://www.postgresql.org/docs/current/sql-createindex.html)
- [WAL and durability settings](https://www.postgresql.org/docs/current/runtime-config-wal.html)
- [Routine vacuuming](https://www.postgresql.org/docs/current/routine-vacuuming.html), [automatic vacuum settings](https://www.postgresql.org/docs/current/runtime-config-autovacuum.html), and [HOT updates](https://www.postgresql.org/docs/current/storage-hot.html)
- [`pg_class` freeze/MultiXact metadata](https://www.postgresql.org/docs/current/catalog-pg-class.html)
- [Index types and index-only scans](https://www.postgresql.org/docs/current/indexes.html)
- [Continuous archiving and point-in-time recovery](https://www.postgresql.org/docs/current/continuous-archiving.html)
