# Runic Ra Journal and Native Profile Plan

**Status:** Proposed research and implementation plan
**Date:** 2026-07-31
**Updated:** 2026-08-01
**Package:** provisional `runic_raft`
**Alternative native design:** [Runic CASPaxos Execution-Cell Journal and Registration Profile Plan](runic-caspaxos-native-runtime-plan.md)
**Depends on:** [Distributed Durable Runtime Core Plan](distributed-durable-runtime-core-plan.md)
**Contract migration:** [Runic Runtime Contract Upgrade Plan](runic-runtime-contract-upgrade-plan.md)
**Portfolio context:** [Distributed Adapter Portfolio Plan](distributed-adapter-portfolio-plan.md)

## Executive decision

Build `runic_raft` as a vertically integrated implementation of the in-package `Runic.Runtime.Journal`, not as a separate Runtime, a distributed registry wrapped around RocksDB, or a Khepri-backed compatibility implementation of `Runner.Store`.

The native profile should use:

- RabbitMQ's Ra library for ordered replicated commands and deterministic partition state machines;
- fixed logical virtual partitions grouped into a manageable number of physical Ra groups;
- three or five stable, durable storage members per group, independent of the autoscaling coordinator/compute fleet;
- the same versioned chronological Runic events used by every Runtime profile;
- compact replicated projections for heads, epochs, client-command and transaction dedup, activations, pending dispatch, timers, and segment/snapshot manifests;
- immutable external segments/snapshots and content-addressed payload storage for unbounded history and values;
- optional local RocksDB materializations/caches outside the deterministic Ra state machine;
- the common `Runic.Runtime.ExecutionBackend` contract with direct execution or Broadway/brokers for elastic attempts;
- Group or `:pg` as a non-authoritative route/capability cache;
- a small direct-Ra control group by default, with Khepri/EKV/`ra_registry` optional and bounded rather than mandatory.

The target guarantee is at most one accepted terminal outcome per attempt, with each conditional Journal transaction committed at most once inside its published dedupe horizon, plus at-least-once work delivery. Ra does not make arbitrary external effects exactly once.

## 1. Why Ra fits this profile

[RabbitMQ Ra](https://github.com/rabbitmq/ra) is a production-used Multi-Raft library with leader election, replicated logs, dynamic membership, snapshots, shared WAL infrastructure, state-machine versioning, and ongoing Jepsen testing. It is designed to host many Ra clusters in one Erlang system.

That gives Runic unusually direct control over:

- the exact command/state transition that is replicated;
- conditional head and epoch checks;
- client-command/transaction deduplication and explicit retention horizons;
- co-sharding of recorded events, activation state, pending-delivery indexes, and timers;
- batching and fairness across execution keys;
- snapshot/checkpoint release decisions;
- leader-local effects used as wakeups;
- rolling state-machine upgrades.

The trade is equally direct: Runic becomes responsible for topology, persistent volume correctness, membership changes, backup/restore, capacity, upgrades, observability, and partition testing. This profile must earn a stronger maturity label than “the demo survived a node restart.”

## 2. Scope and non-goals

### In scope

- regional, strongly coordinated Runic execution;
- stable replicated storage nodes and elastic coordinator/compute clients;
- virtual-partition ownership and fencing;
- durable inputs/signals, transitions, attempts, dispatch delivery, retries, timers, and cancellation;
- activation/passivation and owner failover;
- bounded replicated state and disaggregated payload/history storage;
- rolling code/state-machine upgrades;
- backup, restore, partition movement, and chaos validation.

### Non-goals for the first production profile

- one Ra group per workflow execution;
- compute workers as Ra voters;
- global active-active execution of one workflow across distant regions;
- storing all Runic facts, closures, event history, or blobs in the Ra machine state;
- Khepri as an unbounded history/fact database;
- Group, Horde, `ra_registry`, or EKV as the final writer fence;
- exactly-once arbitrary external effects;
- cross-language arbitrary Runic AST execution;
- transparent online partition splitting before a fixed virtual-partition model is proven.

### Consumer-derived constraint

Infinite Isekai's PostgreSQL store and RunicAI/Compendium's SQLite stores all persist Runic construction/lifecycle events and reconstruct Workflow state. None has clustered fencing, atomic dispatch intent, or unknown-outcome resolution. The Ra implementation must therefore pass the same `Runic.Runtime.Journal` and event-replay contract as those SQL migrations; it must not introduce a Ra-only lifecycle or require consumers to rebuild workflows differently when changing Journals.

## 3. Logical architecture

```text
                         gateways / clients
                                 │
                       Group/:pg route hints
                                 │
                                 ▼
                 ┌────────────────────────────┐
                 │ partition coordinator fleet│  elastic clients
                 │ active Runic projections   │
                 └──────────────┬─────────────┘
                                │ fenced commands / queries
                ┌───────────────▼────────────────┐
                │ physical Ra Journal groups     │  stable storage nodes
                │ compact state + ordered log    │
                └───────┬──────────────┬─────────┘
                        │              │
          pending-dispatch wake/poll   segment/snapshot manifests
                        │              │
              ┌─────────▼──────┐  ┌────▼─────────────────┐
              │ direct/Broadway│  │ object/segment store │
              │ compute fleet  │  │ + optional RocksDB   │
              └─────────┬──────┘  │ materializations     │
                        │         └──────────────────────┘
                        ▼
                 `AttemptResult` ingress
                        │
                        ▼
             Runic.Runtime coordinator validates/decides
                        │ current-epoch CommitEventTransaction
                        └───────────────────────────────► Ra Journal
```

The Ra members do not run user workflow functions. They replicate deterministic coordination commands and maintain bounded authority state. Coordinator and compute nodes may autoscale, roll, and use heterogeneous resources without changing the voter set.

## 4. Partition model

### 4.1 Virtual partitions first

Hash the tenant-qualified `execution_id` to a fixed logical virtual partition. Map many virtual partitions to each physical Ra group.

Benefits:

- stable placement keys independent of current node count;
- several executions share one consensus group and WAL batching;
- movement/rebalance operates on bounded logical units;
- no process/group explosion proportional to workflow count;
- the execution key retains strict order while unrelated keys can progress concurrently;
- hot virtual partitions can later move to a less loaded physical group.

The number of virtual partitions and physical groups is a capacity decision determined by benchmark, not a constant embedded in Runic. The mapping is versioned metadata.

### 4.2 Why not one group per workflow

Ra is intentionally capable of many groups, but a group per long-lived workflow multiplies leaders, replicas, snapshots, membership, metrics, recovery work, and small random I/O. Most Runic executions do not need independent consensus membership.

One physical group should multiplex ordered per-execution streams while preserving a total Ra command order for deterministic replication.

### 4.3 Hot-key limit

One execution's noncommutative state has a serial acceptance point and cannot be scaled by adding consumers to its queue. Scale comes from many executions/virtual partitions, parallel activity execution, batching, and moving hot partitions—not from applying two conflicting completions to the same graph state.

## 5. Storage and node topology

### 5.1 Stable voters

Use three voting storage members for the ordinary regional HA profile and consider five only when the failure-domain requirement justifies the latency and write amplification. Spread members across independent zones/failure domains with persistent volumes and stable node identities.

Ra's own documentation requires connected distributed Erlang nodes and permits one membership change at a time. Treat member replacement as a controlled storage operation:

1. provision stable identity and empty/validated storage;
2. add one member;
3. wait for catch-up and health;
4. remove one old member;
5. verify quorum, snapshots, and backup coverage before the next change.

Do not put frequently autoscaled or preemptible compute nodes in the voter set.

### 5.2 Elastic clients

Gateways, partition coordinators, dispatch publishers, timer drivers, Broadway consumers, and direct compute workers are Ra clients. They may use ordinary service discovery, Group, DNSCluster/libcluster, Kubernetes discovery, or provider networking.

Their PIDs and node names are ephemeral route/incarnation data, not durable execution identity.

### 5.3 Ra systems and I/O isolation

Use explicit Ra systems and data directories. Benchmark:

- physical groups per Ra system/shared WAL;
- WAL batch size, sync mode, segment/checksum settings;
- coordinator command batching;
- snapshot/checkpoint pressure;
- leader distribution across storage nodes;
- noisy-neighbor isolation between hot groups;
- disk queue depth, fsync latency, and recovery throughput.

Configuration becomes part of the published certified profile.

## 6. Replicated state model

The `ra_machine` state is a compact projection/index of committed Runic events, authority, and pending durable consequences—not a second Workflow model or the complete graph/history. `CommitEventTransaction` carries the same versioned event batch accepted by every `Runic.Runtime.Journal` implementation; deterministic event application updates the compact Ra state.

Conceptually, one physical group holds:

```elixir
%RunicRaft.PartitionState{
  machine_version: 1,
  shard_id: shard_id,
  mapping_version: mapping_version,
  virtual_partitions: %{
    virtual_partition_id => %{
      epoch: epoch,
      owner: owner_incarnation,
      owner_deadline: deadline,
      executions: %{
        execution_id => %ExecutionHead{
          stream_position: stream_position,
          graph_revision: graph_revision,
          lifecycle: :active | :idle | :cancelled | :complete,
          snapshot_ref: snapshot_ref,
          last_archived_stream_position: stream_position,
          last_transaction_id: transaction_id
        }
      },
      activations: %{activation_id => compact_activation_state},
      command_dedup: command_receipts_and_request_digests,
      transaction_dedup: transaction_receipts_or_archived_proofs,
      pending_dispatches: ordered_recorded_dispatch_events,
      timers: due_timer_index,
      segment_manifests: committed_segments,
      unarchived_raft_ranges: retained_log_coverage
    }
  }
}
```

Exact representation should be optimized after model tests, but it must satisfy:

- deterministic `apply/3` with no database, filesystem, clock, network, random, or user-code call;
- bounded retained entries per execution/partition through snapshots, archival, and published dedupe horizons;
- enough retained or archived proof to reject unsafe reuse after an in-memory receipt is evicted;
- enough state to reject stale epoch/position/activation/transaction commands;
- enough pending state to recover dispatch/timers after leader/client loss;
- versioned schema and explicit upgrade path.

## 7. Command set

Every client mutation is a versioned command with namespace, shard/mapping version, command/transaction ID, and caller incarnation as applicable.

### 7.1 Authority

```text
AcquirePartitionOwner(vpartition, owner_incarnation, observed_time, lease)
RenewPartitionOwner(vpartition, epoch, owner_incarnation, observed_time, lease)
ReleasePartitionOwner(vpartition, epoch, owner_incarnation)
ExpirePartitionOwner(vpartition, epoch, observed_time)
```

Acquisition/renewal returns an epoch. Every execution mutation includes that epoch. Replacing an owner increments the epoch; all older commands are rejected even if a route cache still points at the old process.

A lease expiry is an availability mechanism, not the safety fence. Safety comes from epoch validation. Clock observations are command data supplied by the runtime's time authority and compared deterministically; skew policy and early-expiry rejection need explicit tests.

### 7.2 Event transaction

```text
CommitEventTransaction(
  execution,
  epoch,
  expected_stream_position,
  transaction_id,
  command_dedup_assertion_or_nil,
  ordered_runic_event_data,
  payload_manifest_assertions
)
```

The optional command assertion contains a client command ID, kind, canonical request digest, and acceptance receipt. It is atomically unique in the execution/namespace even when a retry arrives in a different journal transaction. The event batch may contain input acceptance, graph transitions, `RunnableDispatchRequested`, accepted completion/failure, timers, cancellation, terminal lifecycle, graph mutation, or continue-as-new events. The Ra machine wraps them with authoritative per-execution stream positions/commit metadata and applies them to its compact projections in the same deterministic command.

The state machine validates epoch, expected stream position, client-command dedup, transaction dedup, activation/attempt state, graph revision policy, configured size/limit, payload assertions, and cancellation state. It advances the stream head and records all derived compact consequences atomically. Reusing a command ID with the same digest returns the original command receipt; reuse with different content is rejected. `raft_log_index` comes from Ra apply metadata; per-stream positions come from the execution head; event IDs are deterministically derived from namespace/stream, transaction, position, and batch offset.

Recorded timestamps are explicit replicated command data and are diagnostic only. The documented Ra apply metadata supplies Ra index/term, not a portable wall-clock contract, so the state machine never consults a local clock or derives ordering from `committed_at`. Ordering comes from the Ra log and assigned event positions; R0 locks the timestamp validation/normalization rule as part of the command schema.

If the client times out, it queries by `transaction_id`. It never assigns a new ID and blindly retries an ambiguous transaction. Duplicate transaction IDs return the original receipt while retained. Each profile publishes command- and transaction-resolution horizons; after a compact receipt is evicted, an archived digest/index must still reject unsafe reuse, and resolution returns `:expired` rather than falsely claiming `:not_committed`.

### 7.3 Dispatch delivery projection

Applying a recorded `RunnableDispatchRequested` event adds a pending delivery entry. Operational commands claim and acknowledge that derived entry without defining another workflow lifecycle:

```text
ClaimDispatch(attempt_ids, publisher_incarnation, claim_deadline)
AckDispatch(attempt_id, publisher_incarnation, delivery_receipt)
ReleaseDispatchClaim(attempt_id, publisher_incarnation)
```

The event-derived pending set is semantic; claim/ack/deadline fields are an operational delivery projection. Rebuilding without retained operational state conservatively resets an unresolved request to pending and may duplicate delivery safely. Only accepted completion, cancellation, expiry/supersession, or another recorded lifecycle event removes canonical work. An acknowledgement that must suppress delivery across projection rebuild/compaction is retained in the Ra snapshot or recorded explicitly as an event.

### 7.4 Attempt result

`AttemptResult` enters through `Runic.Runtime`, not directly as a trusted Ra event. The coordinator validates and decides the `RunnableCompleted`/`RunnableFailed` plus graph event batch, then uses `CommitEventTransaction`. Expiry/retry follows the same command → decide events → commit path. There is no second `AcceptCompletion` state-machine semantics.

### 7.5 Timers

```text
ClaimDueTimer(timer_id, observed_time, driver_incarnation)
ReleaseTimerClaim(timer_id, driver_incarnation)
```

Timers are created/cancelled by recorded events. A claimed due timer causes Runtime to decide and commit timer-fired/input/activation events; duplicate or early claims are no-ops/rejections with stable receipts.

### 7.6 Segments and snapshots

```text
BeginSegment(raft_log_range, exporter_incarnation)
CommitSegment(raft_log_range, per_stream_ranges, digest, object_ref, durability_receipt)
AbortSegment(raft_log_range, exporter_incarnation)

AdvanceRetentionCursor(raft_log_index, required_manifest_digests)
```

Snapshot metadata is committed as a normal fenced, expected-position `SnapshotCommitted` event through `CommitEventTransaction`, including snapshot stream position, artifact/code/schema versions, digest, object reference, and payload durability receipt. This avoids a second unfenced snapshot mutation path and rejects stale snapshots naturally.

Segment commands are idempotent by Ra range/digest and require the active exporter claim. The state machine advances Ra log-retention eligibility only after the configured storage authority's durability assertion is recorded; reads and restores still verify object presence and checksum.

## 8. Fencing and completion correctness

Ra leadership and Runic partition ownership are related but distinct:

- the Ra leader orders commands for a physical group;
- an elastic Runic coordinator owns a virtual partition/execution projection and submits commands;
- the Ra state machine issues and validates the Runic owner epoch.

This avoids requiring the Ra leader process to execute arbitrary graph logic while still fencing coordinators.

A completion is accepted only when:

- namespace/execution and virtual-partition mapping match;
- the coordinator submitting the event transaction holds the current owner epoch;
- activation and attempt IDs are known and pending, and the result matches their recorded dispatch event/epoch;
- the result's artifact, graph revision, and code policy are valid;
- expected execution/state-cell versions still match;
- transaction ID is new or known duplicate;
- cancellation/deadline policy permits it;
- referenced payloads meet configured durability/integrity policy.

One accepted completion may create several Runic events and downstream activations, but they become visible as one committed transition.

An attempt committed by the previous owner can remain valid across coordinator failover. Takeover policy may wait, expire, or supersede it explicitly. Safety comes from the new coordinator committing with the current epoch; the worker's recorded dispatch epoch does not grant write authority.

## 9. Unbounded history, snapshots, and compaction

### 9.1 Do not keep history in machine state

Khepri's documented memory limitation illustrates the same general concern: replicated coordination state should remain bounded. A map of every workflow event or fact would be copied, queried, snapshotted, and recovered on every member.

Recorded event batches inside committed Ra commands are authoritative while retained. Before compaction removes required history, export the recorded events to immutable checksummed segments and/or produce a portable Runic snapshot with a committed manifest.

### 9.2 Segment protocol

Keep three index domains explicit:

- `raft_log_index` orders commands in one physical group;
- `stream_position` orders `RecordedEvent`s for one tenant-qualified execution;
- `segment_frame_index` locates an encoded frame inside one immutable object.

A segment manifest records its covered Ra log range plus a map from execution ID to covered stream-position ranges and frame-index ranges. Raw pre-envelope Ra command data is not sufficient to reconstruct canonical bytes later because per-stream positions and commit metadata are assigned during deterministic apply.

The R0/R2 design spike must prove a supported effect/auxiliary materializer path that captures the exact **post-apply** `RecordedEvent` frames and retains their Ra-index association before the source entries can be reclaimed. State retains unarchived Ra ranges until `CommitSegment` succeeds. One safe sequence is:

1. An exporter discovers a committed Ra index range not yet archived.
2. It obtains exact staged post-apply frames through the proven effect/auxiliary path while the associated Ra entries remain retained.
3. It writes an immutable segment of versioned `RecordedEvent` frames with per-frame checksums, Ra coverage, per-execution stream-position/frame indexes, and an overall digest.
4. It verifies the configured durability target (for example, object-store success or enough local replicas).
5. It submits `CommitSegment` with the Ra range, per-stream ranges, digest, reference, and provider receipt.
6. The state machine records the manifest and only then emits/permits an appropriate release cursor.
7. Duplicate exports and commits are idempotent by range/digest.

Ra's `release_cursor` is a snapshot hint, not proof that an external segment exists. The deterministic machine can record only the configured provider's durability assertion/receipt. Every load and restore rechecks object presence, length, digest, frame checksums, and range continuity and fails closed if the assertion is no longer true.

### 9.3 Snapshot protocol

A partition coordinator creates a sanitized portable Runic snapshot at a committed execution version, uploads it, and commits its reference. The snapshot contains graph/runtime projection and payload references, not local PIDs, hooks, connections, secret values, or compiled functions.

On activation/failover:

1. read the execution head and snapshot/segment manifests from Ra;
2. fetch and verify the newest compatible snapshot;
3. replay segment and live-tail transitions strictly in order;
4. reconstruct portable components against the pinned artifact/code policy;
5. acquire/confirm the current owner epoch before dispatch.

### 9.4 Ra checkpoints versus snapshots

Ra supports checkpoints that preserve recovery state without immediately truncating old log entries, followed later by promotion/release. This is useful while segment export still needs log indexes. The adapter should use conditional release cursors so an index is durably written before snapshot eligibility.

The exact checkpoint/release algorithm must be validated against the Ra version used; do not depend on log entries after a release cursor has made them reclaimable.

## 10. Recorded dispatch delivery

### 10.1 Effects are wakeups, not durable dispatch state

Ra state-machine effects cleanly separate deterministic state from leader-local actions, but a `send_msg` effect is intentionally nonblocking and may use `no_connect`/`no_suspend`. Effects can be lost or repeated around leadership changes.

Therefore:

- committed `RunnableDispatchRequested` events and their derived pending-delivery index live in replicated state;
- a leader/client effect may wake a publisher;
- publishers also poll/query, so a lost wakeup cannot strand work;
- publish uses the stable recorded event/attempt ID and broker confirmation when available;
- acknowledgement is a Ra command;
- failed/expired claims become publishable again;
- duplicate broker messages are expected and deduplicated at completion.

### 10.2 Direct execution

For homogeneous BEAM clusters, a dispatch publisher may pass the recorded event directly to a Runic compute service. The attempt is still durably recorded first. A direct message/remote Task is a low-latency delivery path, not the record of work.

### 10.3 Broadway/broker execution

`runic_broadway` consumes the same recorded event or a reference-only transport wrapper. The native Journal dispatch publisher uses a connector-specific outbound client. In v1, compute result acknowledgement follows the same rule as the managed profile: ack only after `Runic.Runtime.complete/3` reports Journal commit or known duplicate. A future durable completion handoff requires an explicit certified ingress contract.

The in-package Runtime and native Journal must remain usable without Broadway.

## 11. Durable timers and retry scheduling

Persist absolute UTC due times and timer IDs in the replicated timer index. Use a timer driver to:

1. query the next due bucket;
2. schedule a local wakeup;
3. submit `ClaimDueTimer(timer_id, observed_time, incarnation)`;
4. let the deterministic state machine reject early/duplicate/cancelled claims;
5. let Runtime decide and atomically commit timer-fired/input/activation/dispatch events.

Ra timer effects may optimize the next wakeup, but they are reissued on leader entry and cannot be the only durable representation. The [Ra state-machine guide](https://github.com/rabbitmq/ra/blob/main/docs/internals/STATE_MACHINE_TUTORIAL.md) explicitly notes that timers and monitors are invalidated on leader change and should be reissued from `state_enter/2`.

Retry backoff is a new durable timer producing a new attempt ID. A worker never holds the durable retry state in `Process.sleep/1`.

## 12. Route discovery and process lifecycle

### 12.1 Default route path

1. A coordinator that acquires virtual-partition authority publishes `{partition, epoch, incarnation, capabilities}` to Group or `:pg`.
2. Gateways use the local replicated cache for the fast path.
3. A missing/stale/multiple route triggers a query/activation attempt against the Ra mapping.
4. Even if traffic reaches an old coordinator, its stale epoch command is rejected.

### 12.2 Group

Group is a strong fit for high-volume route reads, capability groups, named compute clusters, and lifecycle subscriptions. Its eventual consistency is acceptable precisely because route correctness is verified by Ra.

### 12.3 `ra_registry`

`ra_registry` is useful prior art for unique registration, leader monitoring, and `:via` APIs. It should not be a second authority layer in the default native profile. The Runic state machine already has to own epoch and transition fencing; another consensus-backed PID registry adds recovery and liveness coupling without making completion commits safer.

### 12.4 Khepri and EKV

Possible bounded uses:

- Khepri: desired physical group configuration, operator-visible topology, small adapter configuration tree;
- EKV CAS: blue/green placement, node incarnation, or desired assignment records when CAS-only from creation.

Default: keep the physical-group mapping in a small dedicated Ra control group and the live route in Group/`:pg`. Adopt Khepri/EKV only when measured operational or API value exceeds the extra coordination surface.

### 12.5 Horde

Horde may supervise/restart coordinator processes for users who value its placement lifecycle. It still obtains authority from Ra after start and may run a duplicate process transiently without compromising journal correctness.

## 13. RocksDB and local state

RocksDB can improve the native profile as:

- a local projection/materialization of committed transition streams;
- a hot fact/result cache;
- an index for queries and activation recovery;
- staging for immutable event segments;
- a local single-node fallback Journal.

It must not perform filesystem I/O from deterministic `ra_machine.apply/3`. Materialization happens after committed commands through an auxiliary/publisher process and is rebuilt or verified from Ra manifests/history.

If RocksDB acknowledges a projection update and crashes before Ra records any related marker, Ra remains authoritative. If Ra commits and RocksDB has not updated, the materializer catches up. This one-way relationship must remain obvious in APIs and telemetry.

## 14. Flow control and overload

Backpressure must exist at every plane:

- input admission per namespace/virtual partition;
- maximum transition bytes/events;
- maximum pending activation/dispatch/timer entries;
- coordinator active-execution and memory limits;
- per-resource-class attempt quotas;
- Ra command queue and publisher demand;
- segment-export lag and object-store health;
- snapshot/replay backlog.

When segment/object durability falls behind and retained log/state reaches a safety threshold, stop accepting work for the affected partition or shed according to an explicit lower guarantee. Never compact required data just to remain available.

Use fair queues/batches so one hot execution cannot monopolize a physical group's command processing.

## 15. Failure behavior

| Failure | Required behavior |
|---|---|
| Coordinator process/node dies | Higher epoch acquired; snapshot/segment/tail replay; pending dispatch/timers resume |
| Old coordinator remains partitioned | Every mutation rejected after epoch replacement |
| Ra leader changes | Clients redirect/retry by same command ID; publishers/timer/monitor effects reestablished |
| Minority of storage members isolated | Minority cannot commit; majority continues if available |
| Quorum lost | Inputs/transitions do not acknowledge success; reads state their consistency; no unsafe local writes |
| Command reply lost after commit | Resolve transaction ID; return original receipt or known state |
| Outbox wakeup lost | Polling finds committed pending entry |
| Publish confirmation ambiguous | Republish the same recorded event/attempt ID; completion dedup handles duplicate |
| Compute dies before result | Attempt expires/retries according to durable timer policy |
| Compute completes after retry/cancel | Stale result rejected or recorded without graph mutation |
| Object upload succeeds, transition fails | Orphan object retained through grace period then collected |
| Object/segment unavailable | Activation/replay defers or fails closed; never passes unresolved payload to user work |
| RocksDB materializer lost | Rebuild from snapshot/segments/tail; authority unaffected |
| Storage member disk lost | Replace one member at a time; restore/catch up under quorum |
| Whole region lost | Restore/promote according to explicit backup/RPO plan; no implied zero-RPO active-active |

## 16. Membership, rebalance, and partition movement

### 16.1 Compute rebalance

Moving a virtual partition between elastic coordinators is cheap:

1. mark old owner draining;
2. stop/redirect new input at its gateway;
3. commit or leave durable all pending work;
4. release/expire owner epoch;
5. acquire higher epoch on new coordinator;
6. replay hot execution state and publish new route hint.

In-flight attempts may finish, but acceptance is governed by the current activation/attempt and epoch policy.

### 16.2 Storage member replacement

Use Ra membership operations one member at a time, with catch-up and health gates. Automate but do not make uncontrolled autoscaling decisions from transient CPU metrics.

### 16.3 Moving virtual partitions between physical groups

This is a later protocol because two Ra groups cannot atomically share authority by accident. A safe design needs:

1. freeze or version-fence the virtual partition at source;
2. export a portable partition snapshot/manifests at a source barrier;
3. initialize target state with a transfer ID;
4. atomically change the versioned control mapping;
5. issue a new target epoch;
6. leave a source tombstone/forwarding record for a retention window;
7. reject commands using the old mapping version;
8. prove duplicate/ambiguous transfer recovery.

Do not implement online movement before static mapping, coordinator rebalance, backup/restore, and load measurements are stable.

## 17. Versioning and rolling upgrade

Implement Ra's `version/0` and `which_module/1` state-machine callbacks from the first release, even at version zero.

Maintain separate versions for:

- Ra machine state and command schema;
- Runic transition/event schema;
- portable workflow artifact/closure schema;
- recorded-event and attempt-result schemas;
- segment and snapshot formats;
- adapter capability contract.

Rolling process:

1. deploy code that can read old formats and includes prior machine modules/upcasters;
2. upgrade storage members one at a time;
3. allow Ra to commit machine-version activation when a capable quorum/leader exists;
4. transform bounded state deterministically at the version boundary;
5. keep old command/segment/snapshot readers through the supported retention horizon;
6. only then allow coordinators to emit new recorded-event/attempt-result versions.

Test mixed-version leaders/followers, old coordinators, delayed old results, snapshot restore, and rollback limits.

## 18. Backup, restore, and disaster recovery

A backup is not just a copy of a running Ra data directory.

The portable backup set includes:

- control-plane virtual-to-physical mapping and version;
- per-group portable coordination snapshot/barrier metadata;
- Runic execution snapshots;
- immutable event segment manifests/objects;
- all reachable payload objects and encryption metadata;
- machine/event/artifact/schema version manifests;
- tenant and retention metadata;
- checksums and a restore verification report.

Restore into a clean cluster with new stable member identities:

1. validate complete object/manifests and compatible code;
2. start the control group and physical groups without accepting clients;
3. import state at recorded barriers;
4. rebuild/verify materializations;
5. run consistency scans over heads, segments, snapshots, activations, pending dispatches, timers, and payload reachability;
6. issue new ownership epochs/node incarnations;
7. open gateways and observe replay/backlog SLOs.

Run scheduled restore drills. Backup success without a tested restore is not a graduation gate.

## 19. Multi-region posture

The first certified profile is one region across multiple failure zones. Ra commit latency includes a quorum round trip; stretching voters across distant regions directly increases every transition latency and expands partition operations.

Near-term cross-region options:

- replicated object segments/snapshots plus periodic control snapshots for disaster recovery;
- warm standby with explicit RPO/RTO and promotion fencing;
- tenant/execution home-region placement;
- asynchronous read/analytics materializations.

Active-active ownership of one execution across regions is a separate research project. Do not imply it from “distributed Ra.”

## 20. Security and multi-tenancy

- tenant/namespace is present in every hash/key, command, route, object prefix, metric, and authorization decision;
- authenticate Ra clients and BEAM distribution; do not rely on a shared cookie as the only production boundary;
- separate storage-voter and compute network policies;
- sign/authenticate recorded events and transport wrappers, and verify artifact/code digests;
- store secret references, never secret-bearing `run_context`, in Ra commands/segments/snapshots;
- limit command, AST, binding, result, error, and metadata sizes before replication;
- enforce per-tenant active execution, transaction rate, pending dispatch/timer, storage, and compute quotas;
- encrypt volumes/object storage and retain key-version metadata in manifests;
- audit authority changes, stale-writer rejections, cancellation, operator repair, restore, and schema upgrade.

## 21. Observability and SLOs

Required metrics by physical group and virtual partition:

- leader/term/member health and quorum availability;
- Ra commit and fsync latency, command backlog, redirects/timeouts;
- last written/commit/applied/snapshot/checkpoint/segment indexes;
- state size, dedup/pending-dispatch/timer/activation counts;
- owner epoch, renewal latency, stale command rejection;
- input acceptance and transition latency;
- pending-dispatch age, publish ambiguity, duplicate delivery/result;
- timer lateness and retry backlog;
- snapshot/segment export lag, object failures, compaction safety headroom;
- active/passivated execution counts and replay/hydration latency;
- RocksDB/materializer lag and rebuild status;
- per-tenant quota saturation and hot partitions.

SLOs must distinguish Journal availability, input-accept latency, transition commit latency, attempt start latency, timer lateness, replay RTO, and effect outcome. A single workflow latency percentile hides the actual bottleneck.

## 22. Benchmark and chaos program

### 22.1 Workloads

- many small independent executions;
- one hot execution and one hot virtual partition;
- mixed small/large transition batches;
- large fan-out with equal duplicate payload values;
- stateful noncommutative accumulators;
- long idle timers and retry storms;
- high churn of active/passivated coordinators;
- large externalized facts and snapshot restore;
- multi-tenant noisy-neighbor skew;
- rolling artifact and Ra machine upgrades.

### 22.2 Faults

- kill coordinator before/after every Ra command and publish boundary;
- pause/partition old owner while issuing a new epoch;
- kill/change Ra leader during command, effect, timer, segment, and snapshot work;
- isolate minority/majority storage members;
- corrupt/lose one local materializer or payload object;
- fill disk, delay fsync, throttle object store, and delay broker acknowledgements;
- replace members and restore full groups;
- inject ambiguous client replies and repeated commands/results;
- restart mixed-version clusters and delayed old workers.

### 22.3 Required assertions

- no stale epoch mutates state;
- no transaction ID applies twice;
- live projection equals replay for every committed prefix;
- every accepted input is terminal, pending, or intentionally retained—not lost;
- every pending dispatch/timer is eventually visible after recovery;
- equal payload values retain distinct fact occurrences;
- state-cell conflicts never silently lose nonmergeable updates;
- compaction never removes the only recoverable copy;
- backups restore to the same committed heads and reachable payload set.

## 23. Implementation phases

### R0 — deterministic model

Deliver:

- pure partition state/command model independent of Ra;
- epoch, expected-position, client-command/transaction dedup and retention, activation, pending-dispatch, timer, and segment invariants;
- a Ra API spike proving how exact post-apply RecordedEvent frames retain Ra-index association for export before log release;
- model/property tests and fault state machine;
- capacity model for retained state.

Gate: exhaustive/model traces cannot produce two accepted conflicting transitions or strand an accepted durable consequence.

### R1 — one physical Ra group

Deliver:

- `ra_machine` v0 with explicit version callbacks;
- three local/`:peer` members on separate storage directories;
- synchronous and pipelined command clients with ambiguous-outcome resolution;
- input/transition/owner APIs and telemetry;
- restart, leader change, minority partition, and member replacement tests.

Gate: reference-model equivalence across randomized command/failure histories.

### R2 — portable history and payload disaggregation

Deliver:

- versioned RecordedEvent frames with distinct Ra-log, stream-position, and segment-frame indexes;
- segment export/commit/release protocol;
- portable execution snapshots;
- PayloadStore integration and explicit PayloadRef;
- optional RocksDB materializer prototype;
- compaction, missing object, and restore tests.

Gate: bounded Ra machine state and successful clean-cluster restore after log compaction.

### R3 — durable execution loop

Deliver:

- activation owner using in-package `Runic.Runtime`;
- pre-execution recorded `RunnableDispatchRequested` events and derived delivery index;
- direct serialized backend;
- duplicate-safe completion commit;
- durable retry/timer/cancel;
- passivation/resume and drain.

Gate: kill at every input/dispatch/effect/result boundary with no lost accepted input or duplicate accepted graph transition.

### R4 — virtual partitions and elastic fleet

Deliver:

- fixed virtual partition mapping across several physical groups;
- Group/`:pg` route driver and node incarnations;
- coordinator autoscaling, hot activation, passivation, and rebalance;
- quota/fairness/admission controls;
- Broadway/broker profile integration.

Gate: route divergence and coordinator churn affect latency/availability but never journal safety.

### R5 — operations and upgrade

Deliver:

- storage member lifecycle automation;
- backup/restore tooling and drills;
- machine/recorded-event/attempt-result rolling upgrades;
- dashboards, alerts, runbooks, repair tools;
- sustained chaos and soak tests on realistic persistent volumes.

Gate: published regional `cluster_safe` evidence and recovery objectives.

### R6 — measured scale-out

Only after profiling:

- command/fairness batching;
- virtual-partition movement between groups;
- mergeable state delta path;
- portable execution batches;
- deeper disaggregated/object-native materialization;
- regional standby/failover automation.

Gate: optimized path preserves reference-model semantics and improves a published workload materially.

## 24. Graduation criteria

`runic_raft` remains `experimental` until all are true:

1. The same in-package `Runic.Runtime.Journal` conformance suite passes as SQLite/PostgreSQL.
2. Three-member restart, leader-change, partition, disk-loss, and one-at-a-time replacement tests pass repeatedly.
3. State remains bounded under a multi-day long-running workflow/history workload.
4. Segment/snapshot compaction and clean-cluster restore are proven.
5. Duplicate/ambiguous input, dispatch, completion, timer, and owner operations are safe.
6. Rolling machine/recorded-event/attempt-result upgrades are tested with delayed old clients/results.
7. Route caches can be wrong without compromising safety.
8. External effect documentation and fixtures demonstrate idempotency/unknown-outcome handling rather than claiming Ra solved it.
9. Capacity, persistent-volume, backup, and alerting runbooks exist.
10. Sustained chaos/soak results and the tested configuration are published.

## 25. Open decisions

1. Initial virtual-partition count and physical groups per Ra system, based on target workloads.
2. Authority granularity: virtual partition only, or optional per-execution epoch for very hot/long migrations.
3. Maximum event-transaction/pending-dispatch/timer/dedup state and eviction/retention policy.
4. Synchronous `process_command` versus pipelined batching mix and fairness algorithm.
5. Segment format, frame indexing, compression, encryption, and durability receipt.
6. First payload/object adapter and minimum local-only mode.
7. Whether the first materializer uses RocksDB, immutable segment indexes, ETS, or a combination.
8. Time authority/skew policy for owner expiry and durable timers.
9. Snapshot granularity: execution, virtual partition, or hybrid.
10. Control mapping implementation: direct Ra group by default versus a bounded Khepri/EKV option.
11. Whether Group is an optional direct dependency of `runic_raft` or composed through `runic_group`.
12. Restore semantics for command-dedup horizons and delayed results after disaster recovery.
13. Minimum cryptographic/authentication layer for Ra clients, recorded events, and transport wrappers.
14. Regional RPO/RTO before any multi-region marketing or API commitment.

## 26. Prior-plan corrections

This plan retains the useful Ra exploration in [Phase 8 Distribution Primitives](phase-8-distribution-primitives.md) and [Ecosystem Integration Evaluation](ecosystem-integration-evaluation.md), with these corrections:

- remote Task execution follows durable intent; it is not the first correctness layer;
- Ra provides ordered accepted transitions, not exactly-once arbitrary work/effects;
- Khepri is bounded metadata, not a whole event list/fact store;
- Ra effects are wakeups requiring a durable state/ack protocol;
- monitors/timers must be reissued on leader entry;
- stable storage voters are separate from elastic compute;
- Group/`:pg` route; they do not own authority;
- `ra_registry` is optional prior art, not required consensus on top of consensus;
- RocksDB is a materialization/segment/local-Journal option, not distributed ownership;
- macro-built Runic closures are portable under the trusted compatible-BEAM profile, through a validated recorded dispatch event rather than a raw live Runnable.

## 27. Primary sources

- RabbitMQ Ra: [project, maturity, features, and configuration](https://github.com/rabbitmq/ra)
- Ra state machine: [apply/effects/checkpointing/versioning tutorial](https://github.com/rabbitmq/ra/blob/main/docs/internals/STATE_MACHINE_TUTORIAL.md)
- Ra API and membership: [`ra` HexDocs](https://ra.hexdocs.pm/ra.html)
- Khepri: [fundamental assumptions and limitations](https://github.com/rabbitmq/khepri)
- Phoenix Group: [consistency model and architecture](https://github.com/phoenixframework/group)
- EKV: [SQLite storage, LWW/CAS modes, and unknown outcomes](https://github.com/chrismccord/ekv)
- `ra_registry`: [project](https://github.com/eliasdarruda/ra-registry)
- RocksDB: [architecture](https://github.com/facebook/rocksdb/wiki/RocksDB-Overview), [WriteBatch](https://github.com/facebook/rocksdb/wiki/Basic-Operations), [checkpoints](https://github.com/facebook/rocksdb/wiki/Checkpoints)
- Broadway: [core](https://hexdocs.pm/broadway/Broadway.html), [acknowledgers](https://hexdocs.pm/broadway/Broadway.Acknowledger.html)
- Restate: [cluster architecture](https://docs.restate.dev/references/architecture), [first-principles engine design](https://www.restate.dev/blog/building-a-modern-durable-execution-engine-from-first-principles/)
