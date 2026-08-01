# Distributed Adapter Portfolio Plan

**Status:** Proposed package and delivery plan
**Date:** 2026-07-31
**Updated:** 2026-08-01
**Depends on:** [Distributed Durable Runtime Core Plan](distributed-durable-runtime-core-plan.md)
**Contract migration:** [Runic Runtime Contract Upgrade Plan](runic-runtime-contract-upgrade-plan.md)
**Native designs:** [Runic Ra Journal and Native Profile Plan](runic-raft-native-runtime-plan.md), [Runic CASPaxos Execution-Cell Journal and Registration Profile Plan](runic-caspaxos-native-runtime-plan.md)
**Research context:** `~/wrk/libbit/.docs/runic-clustered-durable-execution-architecture.md`

The Libbit reference is a consumer case study, not Runic's persistence model. Libbit's workspace-scoped workflow definitions and management context use SQLite repositories; PostgreSQL is reserved there for global cross-workspace/platform aggregation and global components. That reinforces the SQLite adapter's importance without making it the only Runic deployment profile.

## Executive recommendation

Put the dependency-light coordinator and behaviour contracts in the main package as `Runic.Runtime`. Build dependency-heavy adapters around those contracts; do not build a second runtime library or a monolithic “distributed Runic” package that bundles a database, broker, registry, object store, and cluster manager.

An adapter can live in a consuming application, as Infinite Isekai, RunicAI, and Compendium demonstrate. Publish a separate library when it carries a substantial dependency, has an independent release/operations surface, or is broadly reusable. Separate packaging is not permission to invent different event or coordination semantics.

The balanced delivery order is:

1. `runic_sqlite` — executable reference Journal and the most natural embedded/BYOC profile.
2. `runic_postgres` — first managed clustered Journal and recommended broad production baseline.
3. `runic_broadway` — generic bounded work-consumer/result bridge with certified broker profiles.
4. `runic_blob_s3` — content-addressed large facts, snapshots, and immutable segments for AWS and S3-compatible infrastructure.
5. `runic_rocksdb` — high-throughput embedded Journal/materializer, with replication explicitly out of scope.
6. `runic_group` — high-volume route and capability cache; never journal authority.
7. `runic_eventstore` — compatibility/history adapter for EventStore/Commanded users.
8. `runic_horde` — optional distributed lifecycle/placement integration, always fenced by the Journal.
9. `runic_raft` — vertically integrated virtual-partition authority for users who want Runic to control the coordination peak.
10. `runic_caspaxos` — experimental per-execution ExecutionCell Journal plus immutable history, with a bounded registration profile available earlier.
11. Bounded control-plane experiments for Khepri, direct EKV integration, and `ra_registry`; promote only when a concrete role beats the simpler alternatives.
12. An external-log-native Journal/backend profile for Kafka/Pulsar-scale workloads after the transition model and managed profile are proven.
13. Cloud-native Journals such as DynamoDB, Spanner, and Cosmos DB when user demand justifies their separate semantic and operational surface.

This order balances likelihood of use and implementation leverage. It is not a claim that SQLite has a higher peak than Ra or Kafka. Three explicit rankings appear below.

## 1. Keep the extension surface deep

### 1.1 Three initial infrastructure contracts

The first stable Runtime upgrade should expose only three infrastructure behaviours:

| Behaviour | Owns | Does not own |
|---|---|---|
| `Runic.Runtime.Journal` | Ordered recorded events, conditional atomic commit, client-command and transaction dedup, authority/fence and work-discovery capabilities, snapshots/index accelerators | Work execution and large payload bytes |
| `Runic.Runtime.ExecutionBackend` | At-least-once delivery of committed `RunnableDispatchRequested` events, backpressure, delivery receipts | Workflow truth, retry policy, result acceptance, or fencing |
| `Runic.Runtime.PayloadStore` | Immutable content-addressed values, snapshots, segments, integrity receipts | Event ordering or ownership |

Scheduler and ContextResolver remain in-package policy behaviours. Route directories, materializers, and telemetry exporters are secondary facilities, not first-wave stable ports:

- route caches can begin as internal drivers and must never grant write authority;
- materializers consume recorded events through ordinary projection/subscription APIs;
- telemetry uses the existing `:telemetry` ecosystem;
- a directory behaviour should be standardized only after `:pg`, Group, and Horde integrations demonstrate a shared deep interface.

An adapter may implement several contracts or compose another adapter when that genuinely hides operational complexity. A profile/metapackage may assemble implementations but adds no competing correctness semantics.

### 1.2 Capability manifests

Packages publish machine-readable capabilities and limits:

```elixir
%Runic.Runtime.Capabilities{
  adapter: RunicPostgres.Journal,
  contract_version: 1,
  roles: [:journal],
  authority_scope: :partition,
  capabilities: [
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
  ],
  limits: %{
    max_transaction_bytes: ...,
    max_events: ...,
    command_resolution_horizon: ...,
    transaction_resolution_horizon: ...
  }
}
```

This is the same capability type used by the in-package contracts, not a second adapter-only model. Primitive capabilities do not by themselves imply an end-to-end guarantee tier. Named deployment profiles validate the complete composition and fail fast if it cannot provide the advertised guarantee.

## 2. Ranking method

Scores are directional (`1` low to `5` high) and are evaluated **within the adapter's role**. A route cache with scale `5` is not a durable Journal.

- **Adoption likelihood:** fit with infrastructure users already operate, ease of use, Elixir ecosystem availability, and applicability across Runic deployments.
- **Capability/scale:** attainable throughput, partitionability, HA, tenant isolation, payload size, and operational ceiling for that role.
- **Vertical control:** how much Runic can tune batching, data layout, fencing, placement, compaction, and failure behavior rather than inheriting a managed abstraction.
- **Delivery priority:** learning value and prerequisite order as well as adoption.

## 3. Ordered portfolio

| Delivery rank | Package / option | Primary role | Adoption | Scale | Control | Recommended status |
|---:|---|---|---:|---:|---:|---|
| 0 | `Runic.Runtime` in `runic` | Coordinator, events, behaviours, conformance | 5 | 5 | 5 | Required in-package foundation, not an adapter package |
| 1 | `runic_sqlite` | Embedded Journal | 5 | 2 | 4 | First executable reference and BYOC profile |
| 2 | `runic_postgres` | Clustered Journal | 5 | 4 | 4 | First production clustered authority |
| 3 | `runic_broadway` | Work/result transport bridge | 5 | 4 | 2–3 | First elastic compute adapter |
| 4 | `runic_blob_s3` | Blob/fact/snapshot store | 4 | 5 | 2 | First disaggregated payload adapter |
| 5 | `runic_rocksdb` | Embedded Journal/materializer | 4 | 3 local / 5 cache | 5 | High-throughput local and native-profile building block |
| 6 | `runic_group` | Route/capability directory | 3 | 4 | 3 | Preferred high-volume BEAM route cache |
| 7 | `runic_eventstore` | Event history/compatibility Journal | 2–3 | 3–4 | 2–3 | Demand-led compatibility adapter |
| 8 | `runic_horde` | Lifecycle/placement | 2–3 | 3 | 2 | Optional; not the default directory or authority |
| 9 | `runic_raft` | Native clustered Journal | 2 | 5 | 5 | Native implementation track; graduate after full chaos gate |
| 10 | `runic_caspaxos` | Native per-execution Journal/registry | 1–2 | 5 across keys / 1 hot key | 5 | Experimental alternative; immutable history and static voters first |
| 11 | `runic_khepri` | Bounded metadata/directory | 1–2 | 3 | 4 | Experimental bounded role only |
| 12 | `runic_ekv` | Bounded CAS placement/config or prototype substrate | 1–2 | 3 | 4 | Experimental; CAS-only keyspaces from birth |
| 13 | provisional `runic_stream_journal` | External-log authority/materializer | 3 enterprise | 5 | 2–3 | Later integrated adapter/profile, not a second Runtime |

`ra_registry`, built-in `:pg`, and Syn remain evaluated directory implementations rather than automatic first-party packages. Their recommendation is in Section 9.

## 4. Three ranking views

### 4.1 Likelihood of use

1. SQLite
2. PostgreSQL
3. Broadway with an existing broker
4. S3-compatible object storage
5. RocksDB
6. Group
7. EventStore / Horde
8. Ra-native Journal/profile
9. CASPaxos registry/full-Journal experiment
10. Khepri / direct EKV / `ra_registry`
11. External-log-native authority profile

This is why the managed PostgreSQL profile should ship before either native profile is declared production-ready, even when the native designs offer more vertical control.

### 4.2 Peak capability and scale

There is no honest single scalar winner. By clustered coordination/event throughput, the likely ceiling is:

1. External log-native Kafka/Pulsar Journal profile with partition-local materialization and object storage.
2. Sharded Ra virtual partitions or sharded CASPaxos acceptor sets with bounded ExecutionCells and external payload/history storage; their order depends on hot-key contention, batching, and many-key concurrency.
3. Sharded/managed PostgreSQL plus a broker; Spanner/DynamoDB/Cosmos-specific Journals may exceed it in their clouds.
4. Local RocksDB for one authority shard or materialized partition.
5. SQLite for a single writer.

Operational burden and workload skew can reverse practical results. The benchmark plan must measure hot execution keys, transitions per second, fan-out, result size, timer load, recovery, and rebalance—not only sequential append throughput.

### 4.3 Vertical control and tuning

1. Purpose-built Ra Journal plus Runic-controlled segments/materialization.
2. Purpose-built CASPaxos ExecutionCell Journal plus immutable history.
3. Embedded RocksDB.
4. Purpose-built PostgreSQL schema and transactions.
5. SQLite.
6. External Kafka/log Journal profile.
7. Broadway and managed queues.

CASPaxos earns this position only with bounded cells and disaggregated immutable history. Khepri and unmodified EKV remain bounded metadata/prototype options; neither should become an ever-growing workflow value merely to increase the “native” score.

### 4.4 Implemented consumer adapters as reference fixtures

Three current applications provide more useful evidence than a hypothetical generic Ecto adapter:

| Consumer | Implemented shape | What to reuse | What the new contracts must fix |
|---|---|---|---|
| Infinite Isekai | Application-local PostgreSQL `Runner.Store`; ordered ETF events, fact table, Runner resume | PostgreSQL schema/transaction starting point, construction-event rebuild, real workload policies | Count-based sequence allocation, no CAS/fence/dedupe, lifecycle projection mixed into store, direct retryable PubSub effects |
| RunicAI | Workspace-scoped Ecto SQLite `RunnerStore`; event/fact/snapshot/runnable tables; immutable definition/artifact pins | Dynamic-repo ergonomics, exact artifact pinning, child invocation identities, context-based resources | Current Store cannot express authority; application duplicated Runtime/backend/scheduler; resume filters/recompiles around VM-local artifacts |
| Compendium | Application-local Ecto SQLite `Runner.Store`; runs/events/facts/snapshots/artifact refs | Simple embedded schema, event paging, construction-time graph expansion with deterministic branch/fan-in edges | “Latest run” indirection, raw snapshots, ephemeral terminal callback, product resources embedded in workflow input |

Reference paths:

- [Infinite Isekai PostgreSQL store](../../infinite_isekai/lib/infinite_isekai/workflows/postgres_store.ex)
- [RunicAI SQLite Runner store](../../runic_ai/lib/runic_ai/persistence/runner_store.ex)
- [RunicAI application Runtime backend](../../runic_ai/lib/runic_ai/runtime/backend.ex)
- [Compendium SQLite store](../../compendium/lib/compendium/runic/sqlite_store.ex)

These implementations should become migration and conformance fixtures. They support separate `runic_sqlite` and `runic_postgres` packages because concurrency and dependency semantics differ, while also proving that application-local behaviour implementations must remain first-class. None supports keeping a separate runtime package or preserving the current Store contract.

## 5. `runic_sqlite`

### Role

- `Runic.Runtime.Journal` with atomic event transactions, client-command/transaction dedup, active-stream plus pending-dispatch/timer indexes, snapshot references, and immutable per-execution heads;
- local materialized queries and reference conformance fixtures.

### Why first

- It matches the embedded/per-organization profile used by Libbit and the implemented RunicAI/Compendium adapters without importing any consumer's product architecture into Runic.
- One database transaction can express the complete Runic transition invariant.
- It is easy to fault-inject and inspect, making it a better executable specification than ETS.
- It can support a very capable single-machine runtime before users need a cluster.

### Boundaries

SQLite WAL improves reader/writer coexistence, but SQLite remains a single-writer authority. This adapter must never advertise clustered fencing simply because the database file sits on network storage. Use a dedicated writer process, bounded busy handling, explicit synchronous/durability modes, migrations, and corruption/recovery tests.

### Initial gate

Power-loss tests must prove that events, head, dedupe, pending-dispatch, and timer indexes are atomic and that an unknown transaction result is resolved by transaction ID.

Sources: [SQLite WAL](https://www.sqlite.org/wal.html), [SQLite transactions](https://www.sqlite.org/lang_transaction.html).

## 6. `runic_postgres`

### Role

The recommended general clustered Journal:

- tenant/namespace-qualified execution streams;
- epoch/fenced authority and heartbeats;
- optimistic expected-position commit;
- client-command/transaction dedup, published horizons, and ambiguous-outcome lookup;
- versioned recorded events and head;
- active-stream and pending-dispatch claim indexes derived atomically from events;
- durable timers and cancellation;
- snapshot/blob references;
- partition assignment and rebalance metadata when desired.

All hot-path rows for a transition must be transactionally co-located. Use `SKIP LOCKED` only for scalable claim polling, not as proof that a stale owner cannot commit. `LISTEN/NOTIFY` is a wakeup hint, not durable state.

### Why not generic `runic_ecto`

Ecto can implement both packages internally, but SQLite and PostgreSQL do not have the same concurrency or clustered guarantees. A generic adapter would either understate PostgreSQL or overstate SQLite. Publish separate packages with shared private/conformance utilities if useful.

CockroachDB also deserves a distinct adapter/profile because serializable retry behavior, locality, changefeeds, and operational limits are not identical to PostgreSQL.

### Scale path

1. One regional primary with table/index partitioning.
2. Hash virtual partitions across several PostgreSQL clusters/databases.
3. Separate analytical/materialized queries from the coordination hot path.
4. Move only measured bottlenecks to Ra or an external log; do not preemptively split every service.

Sources: [PostgreSQL transaction isolation](https://www.postgresql.org/docs/current/transaction-iso.html), [`Ecto.Multi`](https://hexdocs.pm/ecto/Ecto.Multi.html).

## 7. `runic_broadway`

### Role

Broadway implements inbound demand, worker, and acknowledgement plumbing around the structured Runtime protocol:

- consume a recorded `RunnableDispatchRequested` event or an integrity-checked reference to it;
- bounded demand, partitioning, concurrency, and batching;
- invoke `Runic.Runtime.Worker.execute/2` for one attempt;
- upload externalized result payloads;
- submit an `AttemptResult` through the configured Runtime completion route;
- acknowledge only after `Runic.Runtime.complete/3` reports the result committed or a known duplicate.

Broadway is not itself the outbound publisher required by `ExecutionBackend`. `runic_broadway` composes a connector-specific publisher/backend with its consumer pipeline and maps Runtime commit outcomes to the inbound producer's acknowledgement semantics. It is not the Journal, retry policy authority, result-ingress authority, or lifecycle model.

### Packaging

Ship one generic `runic_broadway` package with connector conformance modules and configuration presets. Users add the official Broadway producer package they need. Split `runic_broadway_sqs`, `runic_broadway_rabbitmq`, and similar packages only if substantial connector-specific code or release cadence makes that necessary.

The Journal's committed pending-dispatch events still need an outbound publisher, supplied by an official client or connector-specific adapter. The transport message may wrap/reference the recorded event for broker mechanics, but it must not define a second dispatch schema. A separately durable result transport is outside v1 unless it earns an explicit receipt/dedupe/replay contract.

### First certified broker profiles

| Broker | Good fit | Important constraint |
|---|---|---|
| Amazon SQS | Common AWS activity queue; simple autoscaling | At-least-once duplicates; visibility is a bounded activity lease, not a place to park a long workflow |
| RabbitMQ quorum queues | BEAM/VPS/on-prem; manual ack and publisher confirms | Queue durability does not replace Journal dedup/fencing; configure DLX semantics intentionally |
| Kafka | Existing enterprise streaming; high partition throughput | Kafka transactions do not atomically include an external Runic Journal transaction |
| GCP Pub/Sub | Native GCP autoscaling | Exactly-once delivery has scope/mode constraints and still does not make workflow effects exactly once |
| NATS JetStream | Lightweight VPS/edge fleets | At-least-once consumer semantics; use pull-based flow control for scalable workers |

The work item represents a bounded **attempt**, not the lifetime of a potentially month-long workflow. Heartbeats/visibility extension are optional attempt capabilities; durable wait state belongs in the Journal.

Sources: [Broadway](https://hexdocs.pm/broadway/Broadway.html), [Acknowledger](https://hexdocs.pm/broadway/Broadway.Acknowledger.html), [SQS producer](https://hexdocs.pm/broadway_sqs/BroadwaySQS.Producer.html), [RabbitMQ producer](https://hexdocs.pm/broadway_rabbitmq/BroadwayRabbitMQ.Producer.html), [Kafka producer](https://hexdocs.pm/broadway_kafka/BroadwayKafka.Producer.html), [GCP Pub/Sub producer](https://hexdocs.pm/broadway_cloud_pub_sub/readme.html).

## 8. Payload, snapshot, and materialization adapters

### 8.1 `runic_blob_s3`

Use immutable content-addressed objects for large facts, results, snapshots, and exported event segments:

- checksum/digest in every `PayloadRef`;
- put-if-absent or safe duplicate upload;
- multipart/range support;
- optional envelope encryption metadata;
- upload-before-reference ordering;
- orphan and reachability garbage collection;
- namespace/tenant prefixes and IAM policy examples.

S3 compatibility covers AWS, MinIO, and many VPS/on-prem providers. `ReqS3` is a small candidate client; ExAws is a mature alternative. GCS/Azure packages can follow when demand justifies their SDK/auth differences. Blob storage never grants execution authority.

Sources: [`ReqS3`](https://hexdocs.pm/req_s3/), [`ExAws.S3`](https://hexdocs.pm/ex_aws_s3/ExAws.S3.html).

### 8.2 `runic_rocksdb`

Support two explicit modes:

1. **Local Journal:** atomic WriteBatch across column families for head, client-command/transaction dedup, recorded events, active-stream/pending-dispatch/timer indexes, and manifests; WAL sync policy is part of the advertised guarantee.
2. **Materializer/cache:** hot graph projection, fact cache, indexes, and native-Ra partition state rebuilt from authoritative history.

RocksDB supplies neither distributed ownership nor replication. A clustered profile must pair it with a certified Journal authority; merely adding a distributed registry on top is unsafe.

Checkpoints are a storage-engine primitive, not a complete backup protocol. Validate filesystem behavior, referenced SST lifecycle, upload completion, and restore before calling a checkpoint durable off-node backup.

Sources: [RocksDB overview](https://github.com/facebook/rocksdb/wiki/RocksDB-Overview), [basic operations and WriteBatch](https://github.com/facebook/rocksdb/wiki/Basic-Operations), [checkpoints](https://github.com/facebook/rocksdb/wiki/Checkpoints).

### 8.3 Other embedded engines

- **LevelDB:** smaller surface but no reason to prefer it over RocksDB for the primary high-throughput adapter unless its binding/operational simplicity wins a measured deployment.
- **BedrockDB:** interesting ordered/replicated SQL system, but it introduces a complete external database operational model rather than a low-level Runic building block. Treat as a future external Journal integration, not the native default.
- **Mnesia:** a possible adapter for controlled BEAM deployments; do not certify it as elastic-fleet authority without a much narrower topology and failure contract.
- **SlateDB/object-native LSMs:** valuable research for deeply disaggregated state, but not an immediate Elixir adapter or a substitute for the Journal transition protocol.

## 9. Directory, registration, and lifecycle options

Every option in this section is evaluated rigorously, but none can override the Journal fence.

| Option | Consistency / behavior | Best role | Why not authority | Package recommendation |
|---|---|---|---|---|
| built-in `:pg` | Eventually convergent process groups over connected BEAM nodes | Zero-dependency worker capability groups and route hints | Multiple members are normal; no persistent epoch or conditional journal write | Built-in `Runic.Runtime` driver |
| Phoenix Group | Local ETS writes with asynchronous replication; divergent partition views and conflict reconciliation | High-volume named route cache, process groups, metadata, lifecycle subscriptions | A losing duplicate may live until reconciliation; no storage-level fence | `runic_group`, preferred rich directory |
| Horde | Eventually consistent distributed registry/supervision with optional quorum-aware placement | Restart/relocation convenience when users already want Horde | Duplicate processes can exist; distribution quorum is not a journal epoch | `runic_horde`, optional Wave 2 |
| `ra_registry` | Registration commands serialized through Ra; process liveness and rebootstrap still depend on its manager/BEAM topology | Coarse `:via` names for a small number of owners/services | It does not atomically fence workflow history/completions and is not the work journal | Conformance experiment; no package by default |
| EKV | LWW by default; opted-in per-key CAS and consistent reads; ambiguous CAS has explicit unknown outcome | Bounded desired placement, owner epoch/config keys, especially with durable SQLite replicas | No general atomic multi-key event/pending-delivery/history contract; mixed LWW/CAS cutover is unsafe without quiescence | `runic_ekv` experimental, CAS keyspaces from birth |
| Khepri | Ra-backed hierarchical database; consistent writes and projections | Bounded cluster config, desired placement, adapter metadata | Entire data set is resident in memory as well as disk; unbounded history/facts are the wrong workload | `runic_khepri` experimental bounded role |
| Syn | Eventually consistent registry/groups with metadata | Existing Syn deployments | No durable writer fence or journal transaction | Community/user adapter unless demand exceeds Group |
| `:global` | Cluster-wide name protocol with partition conflict resolution | Sparse administrative singleton | Availability/partition behavior and process identity do not fence durable storage | Not a scale-path default |

### 9.1 Group recommendation

Group is the preferred first-party rich routing adapter because it is purpose-built for fast registry/group reads, metadata, subscriptions, named clusters, and sharded writes. Its documentation explicitly says operations are eventually consistent and partition views may diverge. That makes it a strong route cache and a deliberately wrong authority—which is the healthy separation.

Source: [Phoenix Group consistency and architecture](https://github.com/phoenixframework/group).

### 9.2 EKV recommendation

EKV deserves a real prototype for bounded assignment/epoch/config metadata. Its current CAS API is substantially stronger than default LWW, includes barrier reads, and exposes `:unconfirmed` ambiguity that callers must resolve. Any authoritative Runic key must be CAS-managed from creation; never allow ordinary LWW writers in the same keyspace.

Do not encode an ever-growing execution journal or pending-dispatch history as one CAS value without proving size, contention, compaction, and unknown-outcome behavior. That would rebuild a database inside a key.

The current member model uses one configured cluster size rather than a consensus-owned voter configuration, and ordinary full synchronization does not transfer tentative Paxos acceptor state. Use a stable voter set for prototypes; do not treat its rolling scale guidance as Runic's dynamic quorum-reconfiguration protocol. Current EKV shards partition local SQLite work while every durable member retains the data set, so they are not horizontal ownership shards.

Source: [EKV consistency modes and storage](https://github.com/chrismccord/ekv).

### 9.3 Khepri recommendation

Use Khepri only for bounded tree-shaped metadata. Do not reproduce the earlier proposal that reads an event list, appends in memory, and writes the whole list back. Khepri's own limitations state that the full data set is held in memory and large blobs belong elsewhere.

Khepri already uses Ra. A Runic native profile should not stack a second Ra authority underneath it by default.

Source: [Khepri assumptions and limitations](https://github.com/rabbitmq/khepri).

### 9.4 `ra_registry` recommendation

Treat `ra_registry` as prior art and an optional integration requested by users, not the native authority design. It is useful for testing consensus-backed unique registration and `:via` ergonomics. The Runic Ra Journal should own its own partition leadership/epoch and expose route hints to Group/`:pg`; duplicating authority in a second registration consensus group adds failure modes without strengthening the journal commit.

Source: [`ra_registry`](https://github.com/eliasdarruda/ra-registry).

## 10. `runic_eventstore`

There are two audiences:

- users of the Elixir `eventstore`/Commanded ecosystem on PostgreSQL;
- users of EventStoreDB as an existing organizational platform.

Keep the package name and supported backend explicit before implementation.

Expected-version append is a strong starting point for one stream, but a complete Runic Journal also needs an epoch/fence, client-command/transaction dedup, recorded dispatch/timer events, active-stream and claim indexes, and snapshot/payload references. It is cluster-safe only when those records participate in the same authoritative transaction or an equivalently proven single-stream state machine.

Persistent subscriptions or broker delivery do not make external effects exactly once.

Source: [Elixir EventStore API and expected-version append](https://hexdocs.pm/eventstore/EventStore.html).

## 11. Native Journal profiles

### 11.1 `runic_raft`

Ra is the best option when users want a self-contained BEAM-native control plane and Runic needs maximum control over:

- partitioning and co-sharding;
- transition command batching;
- fence/epoch semantics;
- compact hot state and dedup windows;
- pending-dispatch/timer scheduling derived from recorded events;
- snapshots/checkpoints and log segment lifecycle;
- stable storage membership independent of elastic compute.

It is not ninth in technical potential; it is ninth in broad adoption priority because it makes Runic responsible for storage operations, membership, recovery, upgrade, and chaos validation.

`runic_raft` must be independently useful. It may compose with RocksDB, S3, Group, and Broadway, but must not require them. The detailed state machine and delivery plan lives in [Runic Ra Journal and Native Profile Plan](runic-raft-native-runtime-plan.md).

Source: [RabbitMQ Ra](https://github.com/rabbitmq/ra).

### 11.2 `runic_caspaxos`

CASPaxos is the experimental alternative for many independent compact execution heads and multi-writer registration without a permanent leader. The full Journal design keeps authority epoch, stream head, receipts, pending work, and timer roots in one per-execution CASPaxos ExecutionCell, while immutable content-addressed bundles retain Runic's canonical RecordedEvents.

This is deliberately not an ever-growing EKV value. It needs:

- publish-before-pointer immutable history;
- exact unknown-outcome receipts;
- accept-time durable recovery markers;
- CAS-only keyspaces;
- stable acceptor membership before a separately proven reconfiguration protocol;
- identity/barrier reads for authoritative freshness;
- an explicit statement that quorum loss and perpetual proposer contention prevent unconditional wait-free completion.

The bounded registration profile may mature before the full Journal. A CAS-issued epoch fences an unrelated SQL/RocksDB Journal only when that Journal validates the epoch in its own atomic commit; route registration alone is not execution authority.

The detailed architecture and proof gates live in [Runic CASPaxos Execution-Cell Journal and Registration Profile Plan](runic-caspaxos-native-runtime-plan.md).

Source: [CASPaxos paper](https://arxiv.org/abs/1802.07000) and [EKV](https://github.com/chrismccord/ekv).

## 12. External-log-native Journal profile

Kafka, Redpanda, or Pulsar can provide very high partitioned append and replay throughput, but this is an integrated Journal/materializer/backend profile rather than a thin adapter. It still runs the in-package `Runic.Runtime` coordinator and canonical event model.

A credible design needs:

- execution/virtual-partition ownership;
- one ordered input/completion/transition command stream per key;
- deterministic state materialization and changelog/snapshot strategy;
- durable dispatch/result topics;
- rebalance handoff and fencing;
- transaction boundaries that do not pretend to include an unrelated external database;
- object storage for large facts and snapshots;
- query/read-model services.

Kafka exactly-once stream processing can atomically couple Kafka output records with consumed offsets inside Kafka. It does not make a PostgreSQL/Runic Journal transaction or an external API call atomic. Either make Kafka the full transition authority for this profile or keep it as work transport; do not split one invariant across both.

Sources: [Kafka design](https://kafka.apache.org/41/design/design/), [Pulsar architecture](https://pulsar.apache.org/docs/4.1.x/concepts-overview/).

## 13. Cloud-specific options and blueprints

### 13.1 AWS

Recommended general profile:

- `runic_postgres` on RDS/Aurora PostgreSQL;
- `runic_broadway` with SQS, MSK/Kafka, or RabbitMQ according to existing infrastructure;
- `runic_blob_s3`;
- ECS/EKS/EC2 elastic compute;
- optional Group inside the BEAM cluster for route hints.

Future high-scale Journal: `runic_dynamodb`, using execution/partition keys, conditional/transactional writes, explicit client-command/transaction dedup, and co-located recorded-event/active-stream/delivery/timer index items. This is a separate adapter, not a configuration of generic Ecto.

Native Ra voters require stable identities and durable volumes on EC2/EBS or Kubernetes StatefulSets; autoscaling/Fargate-style compute nodes are clients, not voters.

### 13.2 GCP

Recommended general profile:

- `runic_postgres` on Cloud SQL or AlloyDB;
- `runic_broadway` with Pub/Sub or Kafka;
- a GCS adapter or injected GCS client behind `Runic.Runtime.PayloadStore`;
- GKE/compute autoscaling;
- optional Group route hints.

Future very-high-scale Journal: `runic_spanner`, with its own transaction, hot-key, mutation, index, and cost conformance. It should not be promised by `runic_postgres` merely because both expose SQL.

### 13.3 Azure

Recommended general profile:

- `runic_postgres` on Azure Database for PostgreSQL;
- RabbitMQ/Kafka/Event Hubs or a dedicated Service Bus work-transport adapter;
- Azure Blob adapter through `Runic.Runtime.PayloadStore`;
- AKS/VM compute and optional Group.

Future Journal: `runic_cosmos`, co-locating a transition within one logical partition so transactional batches actually cover its invariant.

### 13.4 VPS, bare metal, and on-premises

Recommended choices:

- PostgreSQL + RabbitMQ or NATS JetStream + MinIO for the familiar operational profile;
- SQLite or RocksDB for a single durable node;
- `runic_raft` on three/five stable storage nodes + elastic compute + MinIO/S3-compatible storage for the vertically integrated profile;
- Kafka/Redpanda only when its operational footprint already makes sense.

### 13.5 Other datastore candidates

| Candidate | Potential | Why not first wave |
|---|---|---|
| CockroachDB | Regional/distributed SQL Journal | Different retry/locality semantics need dedicated tests |
| FoundationDB | Excellent transactional substrate and tuple/key design | Smaller Elixir/ops footprint; adapter work is substantial |
| TiKV | Distributed transactional KV | Separate client/ops ecosystem; profile needs proof |
| Cassandra/Scylla | Very high write scale | LWT/partition modeling and multi-record invariant are a less natural first fit |
| BedrockDB | Replicated SQL with ordered journal | Full external system and smaller managed-provider ecosystem |
| Spanner/DynamoDB/Cosmos | Cloud-native scale | Cloud lock-in and different transaction/partition constraints |

## 14. Certified deployment profiles

Certify whole profiles rather than imply every adapter combination has been tested.

| Profile | Authority | Compute | Payload | Route | Guarantee |
|---|---|---|---|---|---|
| local-dev | `Runic.Runtime.Journal.Memory` / ETS | Runtime Inline/Task | memory/local | local Registry | Volatile, process-local |
| embedded-portable | SQLite | Task/GenStage | local/S3 optional | local Registry | Durable single-node transitions |
| embedded-throughput | RocksDB | Task/Broadway | S3-compatible | local/Group hints | Durable single-authority transitions; no automatic HA |
| managed-cluster | PostgreSQL | Broadway + managed broker | S3/GCS/Azure | Group optional | Recommended regional clustered guarantee |
| native-cluster | Ra virtual partitions | direct/Broadway | segments + object store | Group/`:pg` hints | BEAM-native fenced clustered guarantee |
| external-log-native | Kafka/Pulsar | stream workers | object store | partition coordinator | Later high-scale profile |

An uncertified combination may still work through the behaviours, but its documentation must not inherit a certified profile's guarantee label.

## 15. Package quality and versioning rules

Every first-party adapter must include:

- supported `Runic.Runtime` contract version range;
- explicit schema/envelope/event migrations and upcasters;
- capability manifest and configured durability mode;
- production supervision and health/readiness APIs;
- standardized telemetry with namespace/execution/partition/adapter metadata;
- bounded retry/backoff and unknown-outcome handling;
- backup, restore, upgrade, and data-retention runbooks;
- benchmark harness and published workload/configuration;
- dependency/license/security review;
- imported conformance tests, not only adapter-specific happy paths.

Maturity labels:

- `experimental` — API/data format may change; no clustered guarantee claim;
- `compatible` — functional behaviour contract and replay tests pass;
- `cluster_safe` — fencing, unknown outcomes, crash/power-loss, backup/restore, rolling upgrade, and chaos gates pass;
- `certified_profile` — tested in a named end-to-end stack at published scale/failure envelope.

## 16. Conformance suites by role

### Journal

- atomic event group and head update;
- expected-position conflict;
- stale epoch/fence rejection;
- client-command and journal-transaction dedup after a timeout/unknown result, including published expiry horizons;
- cold discovery of active streams, pending dispatches, and due timers for profiles that passivate work;
- events/head/dedupe/pending-dispatch/timer-index atomicity;
- duplicate/out-of-order completion;
- pagination, snapshot-tail replay, pruning, and backup restore;
- process crash and storage power-loss simulation.

### Work transport

- publish-confirm ambiguity and redelivery;
- ack only after committed/known result;
- heartbeat/visibility extension and expiry;
- poison message and DLQ path;
- worker crash before/after effect/result;
- drain, consumer rebalance, and partition movement.

### Payload store

- content digest and immutable duplicate put;
- interrupted/multipart retry and range read;
- encryption/tenant authorization;
- missing/corrupt object detection;
- orphan and reachability GC.

### Route directory

- missing, stale, multiple, and partition-divergent routes remain safe because Journal fencing wins;
- capability churn and named-cluster isolation;
- node incarnation and drain visibility;
- no test treats lookup uniqueness as authority.

### Portable Runic execution

- anonymous macro closure plus captured bindings on a clean node;
- invocation-scoped `context` resolution with no cross-input bleed;
- artifact/code mismatch;
- PID/ref/port/resource/secret rejection or provider conversion;
- custom `Invokable` codec;
- large fact reference and hydration failure/defer behavior.

## 17. Delivery waves

### Wave 0 — contracts

- land `Runic.Runtime`, recorded lifecycle events, behaviour contracts, capability manifests, reference state machine, and conformance kit in the main `runic` package;
- intentionally replace `Runner.Store` and `Runner.Executor` as specified in the [contract upgrade plan](runic-runtime-contract-upgrade-plan.md).

### Wave 1 — broad production path

- migrate RunicAI and Compendium as two independent SQLite Journal fixtures;
- migrate Infinite Isekai as the PostgreSQL Journal fixture;
- extract reusable packages only after those implementations pass the same conformance suite;
- `runic_sqlite`;
- `runic_postgres`;
- `runic_broadway` with SQS/RabbitMQ/Kafka/Pub/Sub profiles;
- `runic_blob_s3`;
- embedded and managed certified profiles.

### Wave 2 — performance and ecosystem fit

- `runic_rocksdb`;
- `runic_group`;
- `runic_eventstore` according to actual user backend demand;
- `runic_horde` if lifecycle relocation is requested;
- benchmark-driven snapshot/materialization work.

### Native implementation track — after Wave 0

- prototype `runic_raft` against the same reference model and conformance suite;
- model and prototype `runic_caspaxos` first as bounded registration, then as one ExecutionCell plus immutable history;
- keep both experimental while Wave 1 validates the abstraction;
- graduate either only after its membership, backup/restore, upgrade, partition, ambiguity, recovery-discovery, and long-chaos gates;
- expose the certified native profile through ordinary `Runic.Runtime` configuration rather than a configuration-only package unless packaging later adds real value.

### Wave 3 — bounded native metadata experiments

- Khepri directory/config prototype;
- EKV CAS placement/epoch prototype;
- `ra_registry` conformance experiment;
- retain only packages with a measured advantage over Group plus Journal authority.

### Wave 4 — specialist scale/cloud packages

- external-log-native Journal/backend profile;
- DynamoDB, Spanner, Cosmos, CockroachDB, GCS, and Azure Blob adapters based on demand;
- deeply disaggregated/object-native state research.

## 18. Decisions to close

1. Final Hex/package names and organization ownership.
2. Whether `runic_eventstore` targets the Elixir EventStore library, EventStoreDB, or two explicitly named packages.
3. The first four Broadway connector certification order based on real users.
4. Whether `runic_blob_s3` uses ReqS3, ExAws, an injected client behaviour, or supports multiple clients.
5. Which RocksDB binding has acceptable maintenance, NIF, backup, and platform behavior.
6. Whether Group belongs in a package or a broader `runic_directory` package with `:pg` and optional drivers.
7. What measured workload would justify Khepri/EKV/`ra_registry` packages rather than examples.
8. Which native-Ra segment/materializer is first: Ra log indexes/checkpoints, RocksDB, immutable local segments, or a combination.
9. Which cloud-specific Journal reaches sufficient demand to enter the first-party support matrix.
10. Publication policy for benchmark and chaos evidence behind `cluster_safe`/`certified_profile` labels.

## 19. Relationship to prior adapter plans

- [Ecosystem Integration Evaluation](ecosystem-integration-evaluation.md) remains useful research on package candidates, but this plan supersedes its assumption that distributed execution belongs in a parallel runtime package.
- [Phase 8 Distribution Primitives](phase-8-distribution-primitives.md) remains evidence for OTP discovery and clean-node testing, but its registry-led ownership, remote closure dispatch, and Store contracts are superseded.
- [Runner Scheduling Implementation](runner-scheduling-implementation-plan.md) records how the current Task/GenStage seams were reached; its work-function Executor and exactly-once/Raft claims are not target contracts.
- [Runtime Contract Upgrade](runic-runtime-contract-upgrade-plan.md) owns the in-package behaviours. This portfolio decides where dependency-heavy implementations should live and in what order they should graduate.

## 20. Primary sources

- SQLite: [WAL](https://www.sqlite.org/wal.html), [transactions](https://www.sqlite.org/lang_transaction.html)
- PostgreSQL: [transaction isolation](https://www.postgresql.org/docs/current/transaction-iso.html), [`SKIP LOCKED`](https://www.postgresql.org/docs/current/sql-select.html)
- Broadway: [core](https://hexdocs.pm/broadway/Broadway.html), [acknowledgers](https://hexdocs.pm/broadway/Broadway.Acknowledger.html)
- RabbitMQ: [quorum queues](https://www.rabbitmq.com/docs/quorum-queues), [streams](https://www.rabbitmq.com/docs/streams)
- Amazon SQS: [visibility timeout and delivery behavior](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-visibility-timeout.html)
- GCP Pub/Sub: [exactly-once delivery](https://cloud.google.com/pubsub/docs/exactly-once-delivery)
- NATS JetStream: [consumer semantics](https://docs.nats.io/nats-concepts/jetstream/consumers)
- RocksDB: [overview](https://github.com/facebook/rocksdb/wiki/RocksDB-Overview), [basic operations](https://github.com/facebook/rocksdb/wiki/Basic-Operations)
- Ra: [project and maturity](https://github.com/rabbitmq/ra), [state-machine guide](https://github.com/rabbitmq/ra/blob/main/docs/internals/STATE_MACHINE_TUTORIAL.md)
- CASPaxos: [paper and safety proof](https://arxiv.org/abs/1802.07000)
- Khepri: [project, assumptions, and limitations](https://github.com/rabbitmq/khepri)
- Group: [consistency and architecture](https://github.com/phoenixframework/group)
- Horde: [project](https://github.com/derekkraan/horde)
- EKV: [storage, LWW, and CAS modes](https://github.com/chrismccord/ekv)
- `ra_registry`: [project](https://github.com/eliasdarruda/ra-registry)
- EventStore: [Elixir API](https://hexdocs.pm/eventstore/EventStore.html)
- Kafka: [design](https://kafka.apache.org/41/design/design/)
- Pulsar: [architecture](https://pulsar.apache.org/docs/4.1.x/concepts-overview/), [tiered storage](https://pulsar.apache.org/docs/4.1.x/tiered-storage-overview/)
