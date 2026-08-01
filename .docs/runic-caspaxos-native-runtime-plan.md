# Runic CASPaxos Execution-Cell Journal and Registration Profile Plan

**Status:** Proposed research and implementation plan
**Date:** 2026-08-01
**Target baseline:** Runic 0.1.0-alpha.8 at 75ed26f
**Package:** provisional runic_caspaxos, with a possible generic caspaxos dependency
**Alternative to:** [Runic Ra Journal and Native Profile Plan](runic-raft-native-runtime-plan.md)
**Depends on:** [Distributed Durable Runtime Core Plan](distributed-durable-runtime-core-plan.md)
**Contract migration:** [Runic Runtime Contract Upgrade Plan](runic-runtime-contract-upgrade-plan.md)
**Portfolio context:** [Distributed Adapter Portfolio Plan](distributed-adapter-portfolio-plan.md)
**Consumer research context:** [Libbit Clustered Durable Execution Architecture](../../libbit/.docs/runic-clustered-durable-execution-architecture.md)

## Executive decision

Develop CASPaxos as an experimental alternative implementation of the same in-package Runic.Runtime contracts, not as a second Runtime and not as a claim that a distributed registry alone makes workflow execution durable.

The strongest design is:

- one small CASPaxos register, called an ExecutionCell, per tenant-qualified workflow execution;
- any healthy proposer may contend to acquire or replace execution authority, while only the cell's current owner/epoch may commit workflow transitions;
- immutable, content-addressed TransitionBundles hold Runic's ordered RecordedEvents outside the register;
- a CASPaxos update atomically replaces the compact cell and its history/index roots only after every referenced object has a durability receipt;
- acceptors persist a recovery marker in the same local transaction as every accepted value; with fixed/intersecting configuration, lifetime-retained base markers, and an eventually complete quorum-union scan, proposer failure after phase two cannot strand pending work;
- pending dispatches, timers, command deduplication, and transaction resolution are persistent structures reached from the same cell root rather than independently updated CAS keys;
- stable three- or five-member acceptor sets form the storage plane, while proposers, coordinators, Broadway producers/consumers, and compute workers may autoscale freely;
- Group or :pg may accelerate routing and capability lookup, but a consistent CASPaxos read or a cell transition decides authority;
- the first implementation uses a dedicated CAS-only keyspace and two-round protocol; one-round proposer caches, hard deletion, online voter reconfiguration, and cross-key transactions remain out of scope until separately proven.

This architecture can provide linearizable, multi-writer/multi-reader protocol access per execution without a permanent consensus leader. Multi-writer means any authorized proposer can acquire a newer execution epoch and run the protocol; it does not mean several coordinators may bypass the current execution owner. The design remains a CP quorum system, serializes conflicting work on one execution, has no atomic transaction across execution keys, and requires a separate design for discovery because a collection of linearizable registers is not a linearizable directory scan.

The [CASPaxos paper](https://arxiv.org/abs/1802.07000) calls the register wait-free. Runic should not translate that label into an unconditional operational promise. The paper's safety proof establishes descendant ordering; it does not remove quorum loss, asynchronous delay, or repeated preemption between competing proposers. The public profile should say it is safe under arbitrary asynchrony, while successful mutation progress requires a configured quorum that eventually responds, eventual network/storage completion, fair proposer scheduling, and contention that is eventually resolved. Bounded retries produce a bounded attempt/result, not guaranteed acquisition. The profile should use randomized backoff, overload responses, and an optional preferred proposer, and never promise that every call succeeds during an arbitrary partition or infinite adversarial race.

## 1. Decision boundary: register, registry, and Journal

Three similarly named ideas must remain distinct.

| Idea | Meaning here | Correct role |
|---|---|---|
| CASPaxos register | One replicated state value changed by a side-effect-free transformation | Linearizable ExecutionCell or registration cell |
| distributed registry | Names mapped to owner/session/capability metadata | Route discovery, placement, and optionally bounded ownership |
| Runic Journal | Canonical ordered RecordedEvents plus conditional commit, dedupe, fencing, recovery discovery, timers, and dispatch claims | Durable workflow execution authority |

A CASPaxos registry is immediately useful for process registration. It is not by itself a Journal. In particular:

- a linearizable lookup of a known name does not enumerate unknown active executions;
- a registration epoch in one key cannot atomically fence a Journal update in another key;
- an owner heartbeat does not make failure detection accurate in an asynchronous network;
- a successful registry claim does not commit input, graph events, dispatch intent, and timer changes together;
- a CAS key does not retain Runic's chronological event history after its state is overwritten.

The plan therefore has two valid deployment levels:

1. **CAS registry profile:** use CASPaxos only for bounded route/registration metadata and use SQLite, PostgreSQL, Ra, or another Journal for workflow truth. The Journal must independently validate any authority token.
2. **CASPaxos Journal profile:** put authority, stream position, receipts, activation state, and every durable consequence of one transition behind the same per-execution CASPaxos cell. Store the immutable event history outside the cell but atomically publish its new root through that cell.

The second level is the real alternative to runic_raft. It is the focus of this plan.

## 2. Protocol model and exact guarantees

### 2.1 Core protocol

CASPaxos extends single-decree Paxos from choosing one immutable value to choosing a chain of states.

For one key:

1. A proposer chooses a unique, increasing ballot and sends prepare to acceptors.
2. Each acceptor durably promises not to accept a lower ballot and returns its highest accepted ballot/value.
3. After a prepare quorum replies, the proposer selects the value with the highest accepted ballot, applies a side-effect-free transformation, and sends the resulting whole value in accept messages.
4. Each acceptor that has not promised a higher ballot durably records the accepted ballot/value.
5. An accept quorum makes that state chosen; an acknowledgement to the caller is safe after this quorum.

The safety argument is that every prepare quorum intersects every earlier accept quorum that chose a state. The proposer selects the highest accepted state returned by phase one; that predecessor may itself have been accepted by only a minority and never acknowledged. If a descendant of that pending predecessor is later chosen, the predecessor becomes part of the canonical lineage. Chosen states and every adopted ancestor form one descendant chain even when no proposer received the phase-two replies.

Runic will not transmit arbitrary workflow closures to acceptors. A trusted proposer loads a versioned ExecutionCell, applies a closed Runic cell transformation locally, and sends encoded resulting state. Acceptors only compare ballots, persist opaque validated bytes and metadata, and acknowledge. Workflow planning and user code never execute in the storage plane.

Standard 2F + 1 deployments use majority prepare and accept quorums. Flexible quorums are possible because the safety proof requires every phase-one quorum to intersect every phase-two quorum, not same-phase intersection. That latency/availability tuning changes the failure envelope and is deferred until after the ordinary-majority profile is proven.

### 2.2 Guarantees this profile may claim

After conformance and fault testing, a regional profile may claim:

- **per-key linearizability:** every confirmed operation on one ExecutionCell appears at one point in a total order consistent with real-time order;
- **multi-writer/multi-reader protocol access:** no fixed leader is required for safety; any authenticated proposer may invoke the protocol, while a workflow mutation must also carry the cell's current execution epoch;
- **crash and omission fault tolerance:** 2F + 1 acceptors tolerate F stopped, unreachable, or delayed acceptors while a quorum remains;
- **durable conditional commit:** a transaction extends the highest accepted valid predecessor recovered by prepare and enters canonical history only through a chosen descendant whose Runic preconditions pass;
- **single terminal outcome:** at most one terminal semantic outcome per attempt appears in the chosen descendant chain, even if several protocol values are accepted by minority acceptors or the attempt executes more than once;
- **known ambiguity:** a timeout after the accept phase returns unknown, never a fabricated rejection; a later consistent transition resolves it;
- **partitioned scale:** unrelated execution keys and acceptor shards may progress independently.

The safety model assumes non-Byzantine nodes, durable acceptor writes before acknowledgement, unique ballots, protocol-compatible codecs, and correct quorum configuration.

### 2.3 Guarantees this profile must not claim

- availability without a responsive quorum;
- deterministic termination under unbounded proposer contention or arbitrary asynchronous delay;
- exactly-once execution or exactly-once external effects;
- one-copy serializability across several CASPaxos keys;
- a linearizable prefix scan or global active-execution snapshot;
- accurate crash detection from heartbeats;
- safe dynamic voter changes merely because every node has the same integer cluster size;
- safe deletion after a normal tombstone retention interval;
- higher throughput for one hot execution merely because there are many proposers.

### 2.4 Linearizable reads are consensus operations

A strict CASPaxos read is the identity transformation x -> x. It runs prepare and accept so it can recover an accepted-but-not-yet-observed value and establish a linearization point. It is not equivalent to reading a local acceptor.

The profile exposes distinct semantics:

- consistent Journal load, authority lookup, commit resolution, and ownership change use a CASPaxos barrier;
- local eventual reads may serve telemetry, materialized views, or route hints only;
- a cached cell may be used to prepare work, but commit revalidates against the highest accepted valid predecessor recovered by prepare;
- the optional one-round optimization is deferred because it introduces proposer cache affinity, invalidation, reconfiguration, and deletion obligations.

## 3. Fit with Runic's execution model

Runic is a lazily evaluated, forward-chaining graph virtual machine. Its event stream is the authoritative construction and lifecycle representation; the in-memory Workflow and Runnable are rebuildable projections. Macro-built components preserve AST and captured bindings, while context requirements are resolved at execution time.

Those properties fit CASPaxos only if the consensus value remains compact:

- a workflow transition is first decided as ordered Runic events;
- a portable RunnableDispatchRequested event, not a live PID-bound Runnable, crosses the durable delivery boundary;
- a worker returns an AttemptResult proposal and never writes the workflow cell directly;
- the authority validates the result against the current activation, attempt, artifact, read set, and cancellation state;
- event replay remains the common recovery path for CASPaxos, Ra, SQLite, and PostgreSQL Journals.

This does not classify Runnable as inherently unserializable. Runic's macros retain closure AST and captured bindings, and context declares runtime-resolved dependencies, so a compatible worker can usually rebuild the component and Runnable from recorded artifact, inputs, and context references. RunnableDispatchRequested remains the durable boundary because it also carries stable attempt identity, artifact version, authority correlation, and integrity metadata without persisting local PIDs/ports/resources.

The paper explicitly warns that copying a large monolithic state on every update is impractical. A complete Workflow, graph, event list, fact set, or unbounded receipt map must not become the CASPaxos value.

## 4. Logical architecture

~~~text
                     gateways / Runtime clients
                               |
                   Group/:pg and route caches
                         non-authoritative
                               |
                               v
              +-----------------------------------+
              | elastic CASPaxos proposer fleet  |
              | Runic coordinators / timer scans |
              +----------------+------------------+
                               |
                    prepare / accept / learn
                               |
              +----------------v------------------+
              | stable acceptor storage plane    |
              | ballots + compact cells + dirty  |
              | recovery and due-work indexes    |
              +----------------+------------------+
                               |
                         chosen cell roots
                               |
              +----------------v------------------+
              | immutable object/segment store   |
              | TransitionBundles, persistent    |
              | maps, snapshots, payloads        |
              +----------------+------------------+
                               |
                pending dispatch/timer discovery
                               |
              +----------------v------------------+
              | direct or Broadway compute fleet |
              +----------------+------------------+
                               |
                         AttemptResult command
                               |
                               +----> proposer reloads,
                                     decides, and commits
~~~

Storage voters and elastic compute are separate. Autoscaling a coordinator adds a proposer; it never silently changes a quorum.

## 5. The atomicity unit: ExecutionCell

### 5.1 One cell per execution

Every transition whose consequences must commit together is represented by one update of one ExecutionCell.

Conceptually:

~~~elixir
%RunicCASPaxos.ExecutionCell{
  schema_version: 1,
  transform_version: 1,
  namespace: namespace,
  execution_id: execution_id,
  generation: generation,
  stream_position: position,
  head_bundle_ref: bundle_ref,
  head_bundle_digest: digest,
  history_index_root: history_root,
  object_closure_manifest_ref: object_manifest_ref,
  object_durability_proof: durability_proof,
  snapshot_ref: snapshot_ref,
  artifact_ref: artifact_ref,
  graph_revision: graph_revision,
  lifecycle: lifecycle,
  authority: %{epoch: epoch, owner: owner_incarnation, deadline: deadline},
  activation_root: activation_root,
  command_receipt_root: command_root,
  transaction_receipt_root: transaction_root,
  pending_dispatch_root: dispatch_root,
  timer_root: timer_root,
  next_due_timer: next_due_timer,
  archive_root: archive_root
}
~~~

Exact fields may change after model testing. The invariants may not:

- namespace and execution identity are immutable;
- schema/transform versions are accepted only by an explicitly compatible proposer cohort;
- position increases by the exact number of committed RecordedEvents;
- every root refers to immutable, integrity-checked content;
- each candidate carries an independently verifiable object-closure manifest/durability proof transferable to a later proposer;
- all roots describe the same transition prefix;
- the mandatory execution-scoped authority epoch is checked in this cell rather than trusted from another registration key;
- unbounded collections live behind persistent roots, not inline in the cell;
- a cell has a strict encoded-size limit and versioned codec.

### 5.2 Why related state cannot be spread across CAS keys

CASPaxos provides atomicity for one register. It does not atomically update:

- execution head;
- client command receipt;
- transaction receipt;
- pending dispatch;
- due timer;
- active-stream index;
- owner registration;
- event-history pointer

when each is a separate key.

Using independent CAS operations would recreate dual-write failures. A coordinator could publish a completion but lose its downstream dispatch, or claim ownership without fencing the execution. Two-phase commit would add a distributed transaction protocol and recovery log, erasing much of the simplicity being evaluated.

The production rule is:

> Every semantic consequence of one Runic transition is either encoded in the same cell update or reached through immutable roots published by that update.

Cross-execution coordination uses durable messages, sagas, and idempotent commands. It is explicitly not one atomic transaction.

### 5.3 Persistent structures behind the cell

Command receipts, transaction receipts, activations, pending dispatches, timers, and history indexes grow over time. Use immutable content-addressed maps/trees:

1. Read the current root from a consistent cell.
2. Load and verify only the paths needed to decide the transition.
3. Create new leaf and branch objects without modifying old objects.
4. Durably put every new object.
5. Propose the new roots as part of the next cell.
6. Retain every object referenced by any value that an acceptor may have accepted, even if another proposal is later acknowledged.

This gives the CAS update one compact atomic root swap while allowing history and indexes to exceed memory. Candidate structures include a persistent Merkle B-tree, HAMT, or immutable sorted segments plus a persistent sparse index. Selection depends on range paging, write amplification, object count, and recovery benchmarks.

Object reachability is a protocol property, not a time delay. The GC root set includes every chosen cell, every accepted cell/recovery marker on every non-retired acceptor/configuration, and every candidate whose delayed accept message may still arrive. A prewrite may be reclaimed immediately only while the proposer retains durable proof that no accept send began. Before any background orphan collection is enabled, the adapter must durably publish a proposal pin to an eventually complete, failure-tolerant inventory before its first accept send; the acceptor's local recovery marker adds another root when an accept actually persists. Clear that pin only after a higher chosen barrier plus configuration/proposer fencing and acceptor reference accounting prove that the candidate can never be adopted. Until this pin and exclusion protocol is implemented, retain all candidate objects indefinitely.

## 6. Preserving the canonical Runic event history

### 6.1 TransitionBundle

One successful Journal transaction creates an immutable TransitionBundle:

~~~elixir
%RunicCASPaxos.TransitionBundle{
  format_version: 1,
  namespace: namespace,
  execution_id: execution_id,
  transaction_id: transaction_id,
  command_id: command_id,
  predecessor: %{position: old_position, head_digest: old_digest},
  first_position: old_position + 1,
  last_position: new_position,
  recorded_events: recorded_event_frames,
  index_updates_digest: index_updates_digest,
  previous_bundle_ref: previous_bundle_ref,
  created_objects: object_refs,
  digest: digest
}
~~~

The bundle contains the same versioned RecordedEvent envelopes used by other Journals. It is not a CASPaxos-specific workflow history. The predecessor and digest form a tamper-evident chain; a persistent history index supports forward paging without walking an unbounded reverse chain.

### 6.2 Publish-before-pointer protocol

The object write precedes consensus:

1. The coordinator consistently reads the current cell.
2. Runic decides the semantic transition and validates limits.
3. The proposer assigns candidate event positions from the predecessor position.
4. It encodes and uploads payloads, tree nodes, and the TransitionBundle by digest.
5. The PayloadStore/object store returns verified durability receipts.
6. The proposer durably records a proposal pin before any accept message can be sent; v1 instead disables candidate-object collection entirely.
7. The proposer runs CASPaxos with a transformation from the current cell to the candidate cell.
8. A chosen candidate publishes the new history root and head digest atomically.
9. A proven never-sent candidate is an ordinary orphan; every sent, in-flight, or accepted candidate remains a GC root until protocol evidence excludes future adoption.

The cell may never point at an object whose configured durability class was not acknowledged. This ordering makes never-accepted prewrites harmless garbage and keeps partially accepted lineages recoverable rather than misclassifying them as garbage.

An object store receipt is still an infrastructure assertion, not magic atomicity with consensus. Production profiles must state the object store's replication, checksum, versioning, and disaster-recovery guarantees. A regional CASPaxos profile is only as durable as both its acceptor quorum and its reachable history objects.

### 6.3 Load, snapshot, and archive

Runic.Runtime.Journal.load:

1. always performs a consistent barrier cell read for managed Runtime replay/resume/load;
2. selects a compatible snapshot at or before the requested position;
3. traverses the immutable history index in ascending position order;
4. verifies bundle, event, payload, predecessor, and root digests;
5. returns a bounded ReplayPage independent of an open storage cursor.

Snapshots are ordinary content-addressed Runic projections pinned by an event position and history digest. Archival may rewrite index shape or coalesce bundles, but it may not rewrite RecordedEvent identity or logical order.

Eventual local cell reads belong only to explicitly non-authoritative query/materializer/route APIs. Journal.load must never silently choose them, because it could miss a chosen-but-unpublished cell.

### 6.4 Construction artifacts and StreamRef kinds

Runic's reusable construction-event prefix and execution-event tail remain one logical history even when physically separate:

- StreamRef kind artifact addresses an immutable, content-addressed ArtifactBundle containing ordered workflow-construction RecordedEvents, codec/schema versions, final construction cursor, and digest;
- publishing a reusable artifact is idempotent by digest and may use a small CAS initialization cell when named creation/ambiguity must be resolved;
- each ExecutionCell pins the exact artifact digest/cursor and verifies its durability receipt during execution creation;
- StreamRef kind execution addresses the mutable ExecutionCell plus its immutable transition-bundle tail;
- Runtime replay loads and verifies the pinned artifact prefix first, then applies the execution tail in order;
- runtime graph additions/removals/rewrites remain ordinary execution events and do not mutate the shared artifact.

Artifact and execution creation do not require a cross-key transaction because the artifact is immutable and durable before the execution cell references it. Journal.load routes each StreamRef kind explicitly, and conformance tests require artifact-prefix plus execution-tail replay to be byte/event equivalent across CASPaxos, SQLite, PostgreSQL, and Ra.

## 7. Journal commit and outcome protocol

### 7.1 Commit transformation

The proposer applies a closed deterministic transition to the value returned by prepare:

~~~text
commit(stream_ref, expected_position, authority_token, transaction)
  -> prepare quorum
  -> recover highest accepted ExecutionCell
  -> validate namespace, generation, expected position, authority,
     command identity/digest, transaction identity, activation/read set,
     artifact revision, limits, and referenced object receipts
  -> return an existing receipt or derive an event-bearing/receipt-only successor
  -> accept the successor on quorum
  -> map its positive/negative receipt to the Journal result
  -> publish commit notification as a best-effort wakeup
~~~

The storage plane does not call Workflow.decide. The candidate transition has already been decided by Runic and encoded by a trusted proposer. The proposer revalidates it against the recovered predecessor; if the predecessor changed, it discards the candidate and redecides from the newly recovered projection.

When prepare returns a predecessor created by another proposer, including a minority-accepted predecessor, the new proposer must fetch and verify its complete newly introduced object closure before accepting a descendant. A receipt embedded in the cell must be independently verifiable against the configured object authority; a proposer-local acknowledgement is not transferable evidence.

### 7.2 Confirmed conflicts

A prepare result alone cannot authoritatively reject stale expected position, stale authority epoch, command-ID/content mismatch, invalid activation, or exceeded limit: the observed value may have been only partially accepted. A confirmed rejection requires a receipt-only successor. It preserves workflow head and event position, but adds a retained negative transaction receipt and ID-reuse guard, then reaches an accept quorum.

That receipt-only transition both linearizes the rejection and resolves earlier partially accepted state. If it may have entered accept but cannot be confirmed, commit returns unknown(transaction_id). If no accept was issued and no authoritative result was chosen, it returns retryable unavailable rather than a fabricated confirmed conflict.

Conflict classes remain those of Runic.Runtime.Journal. CASPaxos ballot conflicts are an internal retry reason, not a new public semantic outcome.

### 7.3 Ambiguous outcomes

Failure boundaries are different before and after accept:

- before any accept request for the candidate is issued, the attempt can safely retry or return retryable unavailable; a public semantic conflict still requires the receipt-only transition above;
- once any acceptor may have durably accepted the candidate, the outcome is potentially ambiguous: a value accepted by only a minority can be discovered by a later prepare and become an ancestor of a later chosen state, so every candidate object reference must already be durable before the first accept message;
- after accept messages may have reached a quorum, the candidate may be chosen even if the caller received no acknowledgement;
- a proposer crash after quorum acceptance cannot undo the chosen state;
- a later prepare must recover the highest accepted state before applying another transformation.

If a later proposer adopts an unacknowledged candidate as its predecessor and chooses a descendant, that candidate becomes part of the authoritative Runic history. The successor must preserve its bundle link and receipts, fetch and verify every referenced object, and expose the earlier transaction as committed when it is resolved.

Every candidate cell therefore records transaction_id and, when present, command_id plus request digest and original receipt. Journal.resolve:

1. runs prepare and recovers the highest accepted cell;
2. returns committed/rejected immediately when the retained transaction receipt already proves that result;
3. when the ID is absent inside the published horizon, proposes a receipt-only successor that preserves the workflow head while recording not_committed and a negative ID guard;
4. returns not_committed only after that successor reaches an accept quorum;
5. returns unknown if the negative-proof accept is itself ambiguous, expired when proof is outside the horizon, or retryable unavailable before accept;
6. never infers not_committed from absence in a current local value or generic EKV VSN comparison.

If the ambiguous candidate was chosen or is adopted into a chosen descendant, recovery exposes its positive receipt. Otherwise, the chosen receipt-only successor both excludes the old ballot and permanently guards that transaction ID for the retained/archived horizon.

### 7.4 Deduplication horizons

Client command and storage transaction identities solve different problems:

- command_id deduplicates one semantic ingress even if a retry uses a new transaction;
- transaction_id identifies one candidate cell mutation and resolves its unknown outcome.

Receipts stay in persistent maps for advertised horizons. Archived indexes must prevent unsafe ID reuse after detailed receipts are compacted. Beyond a resolution horizon, the API returns expired, not absent or rejected.

### 7.5 Mapping to Runic.Runtime.Journal callbacks

| Callback/capability | CASPaxos implementation and constraint |
|---|---|
| init/capabilities | Validate fixed voter manifest, quorum intersection, codec/transform versions, object durability class, limits, and recovery scanner before claiming a clustered profile |
| load | Barrier-read one ExecutionCell, capture position/root/snapshot, then page immutable objects to exactly that captured head |
| commit | Prewrite candidate objects; run prepare; validate expected position, authority, receipts, activation/read set; accept one event-bearing or receipt-only successor |
| resolve | Recover accepted state; return an existing receipt or choose a receipt-only negative proof before returning not_committed |
| acquire/renew/release authority | CAS-transform the same execution cell; takeover increments epoch and release retains generation |
| list_work_scopes | Page stable virtual-storage-shard references and placement generations from the fixed/configured topology |
| scan_active | Union durable acceptor recovery inventories and verify each candidate by barrier read; eventually complete and duplicate tolerant, not a global snapshot |
| claim_dispatches | Discover candidates, then CAS each execution cell independently; a returned list contains successful claims but the batch is not atomic across executions |
| ack/release dispatch | CAS the claim identity in that execution cell; stale claim returns stale_claim |
| claim/release due timers | Discover through conservative due indexes, then independently CAS each execution cell |
| snapshots | Put immutable snapshot, then record SnapshotCommitted and its reference through an ordinary cell transition |

The companion contract exposes distinct typed scopes:

- AuthorityRef identifies the execution cell fenced by acquire/renew/release in this profile;
- WorkScopeRef identifies a virtual storage shard containing many execution keys for scan_active, claim_dispatches, and claim_due_timers;
- Capabilities advertises authority_scope: :execution so Runtime never reuses one token across several cells.

A separate partition-owner key cannot fence all execution-cell writes atomically. A future partition-cell design may advertise partition authority only if it co-locates and validates every protected stream mutation.

The concrete manifest is directionally:

~~~elixir
%Runic.Runtime.Capabilities{
  adapter: RunicCASPaxos.Journal,
  contract_version: 1,
  roles: [:journal],
  authority_scope: :execution,
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
    max_cell_bytes: max_cell_bytes,
    max_bundle_bytes: max_bundle_bytes,
    max_events: max_events,
    object_durability_class: durability_class,
    command_resolution_horizon: command_horizon,
    transaction_resolution_horizon: transaction_horizon
  }
}
~~~

Exact public mapping:

- same command ID/digest -> duplicate_command with original receipt;
- same command ID/different digest -> command_conflict;
- expected-position mismatch -> conflict(actual_position), after a chosen receipt-only rejection;
- stale execution epoch -> stale_authority, after a chosen receipt-only rejection;
- uncertainty after any accept may persist -> unknown(transaction_id);
- chosen positive receipt -> committed;
- chosen negative receipt -> not_committed;
- no quorum before any accept -> retryable unavailable;
- proof outside the published horizon -> expired.

## 8. Linearizable registration and ownership

### 8.1 Registration cell

A bounded process registration record may contain:

~~~elixir
%RunicCASPaxos.Registration{
  name: tenant_qualified_name,
  registration_id: registration_id,
  session_id: session_id,
  owner_incarnation: owner_incarnation,
  generation: generation,
  route: route,
  capabilities: capabilities,
  deadline: deadline,
  operation_receipt_root: operation_receipt_root,
  operation_reuse_guard_root: operation_reuse_guard_root,
  operation_resolution_horizon: operation_resolution_horizon
}
~~~

Competing register or replace operations are ordinary CASPaxos transformations. At most one operation claims a given observed generation; a later valid operation may serialize after it at a higher generation. A consistent lookup is an identity transition. Eventual local lookup and Group/:pg membership may cache the result but cannot grant write authority.

The bounded API is:

- register(name, session, operation_id): claim an absent/released name, increment generation, or return the original receipt for the same operation;
- replace(name, observed_generation, session, operation_id): apply the configured takeover policy and always increment generation;
- renew(name, generation, session, operation_id): update liveness metadata only when generation/session still match;
- release(name, generation, session, operation_id): record a released tombstone without erasing generation history;
- lookup(name, consistent: true): perform a barrier read and return registration plus generation;
- watch/scan: deliver eventually consistent hints that callers verify with lookup.

Autoscaled nodes normally register unique node-incarnation keys, avoiding a hot global node set. A singleton execution/partition name intentionally contends on one key. Capability enumeration remains an eventually repaired projection unless a deliberately bounded whole-group cell is selected.

Operation receipts follow the same positive/negative proof and horizon rules as Journal transactions. A single last_operation_id field is insufficient because a later renewal would erase the proof needed to resolve an earlier ambiguous acquire or release.

### 8.2 Leases and failure detection

CASPaxos orders a lease record; it does not prove that an owner is dead. A partitioned owner may continue running after another node replaces its registration.

Safety therefore comes from fencing:

- a registration generation is included in every protected mutation;
- the protected authority must validate that generation atomically with its own state;
- in the full CASPaxos Journal, the authoritative epoch lives inside the ExecutionCell;
- in a registry-only deployment, the selected Journal must issue and validate its own token or provide an atomic integration.

Fenced execution authority is mandatory for the full clustered Journal profile and advertises authority_scope: :execution. Multi-writer describes who may propose acquisition/takeover and run CASPaxos, not permission for a non-owner to commit. An ownerless optimistic-multiwriter Runtime would be a separate future guarantee profile and does not satisfy the current clustered authority contract.

Deadlines improve availability only under an explicit clock-skew and time-authority policy. An old owner may still execute work, but its stale result cannot be accepted after the cell epoch advances.

### 8.3 Preferred proposer, not permanent leader

Rendezvous hashing or Group may route one execution to a preferred coordinator to reduce ballot contention and preserve an in-memory Workflow projection. This is a performance optimization:

- any healthy proposer may take over after timeout;
- the route does not change quorum membership;
- a wrong route can increase latency but cannot bypass cell validation;
- a preferred proposer can batch local requests and apply fairness without becoming a safety dependency.

### 8.4 Group membership queries

Per-name lookup is linearizable. A query such as “all GPU workers in region A” is not automatically linearizable across independent registration keys.

Choose semantics explicitly:

- Group/:pg or acceptor-local scans for fast eventually consistent capability discovery;
- one bounded CAS cell for a small group requiring a linearizable whole-set update;
- bucketed cells for larger groups, accepting that no read is an atomic snapshot across buckets;
- a separate database/index when rich discovery matters more than consensus ordering.

## 9. Durable discovery without a consensus log

### 9.1 The cold-start problem

Replay can rebuild an execution only after Runtime knows its key. CASPaxos provides no global ordered log from which a new coordinator can discover every active key. A local prefix scan may also miss a value accepted on another quorum member.

The Journal capability scan_active therefore means a durable, eventually complete, duplicate-tolerant recovery enumeration whose candidates are verified by consistent per-key reads. It does not claim a global linearizable snapshot.

### 9.2 Accept-time recovery markers

Each acceptor must atomically persist:

- promised ballot;
- accepted ballot and encoded cell;
- a dirty/recovery marker for that key and accepted version;
- derived conservative hints such as active, has pending dispatch, or next due time.

The acceptor acknowledges only after that local atomic write is durable. If a value is chosen, a quorum contains its marker. A recovery worker queries a responsive quorum, takes the union of markers, and runs consistent identity reads for candidate keys. False positives are safe; omission of a chosen key is not.

Every marker insert/update also advances a local monotonic inventory revision. Pagination scans revisions rather than only key order, then repeats from a captured generation or performs periodic full reconciliation. A marker inserted for a key behind the current lexical cursor must reappear at a later revision; cursor rollover may not permanently omit it.

Markers cannot be cleared merely because one proposer sent a best-effort learned/committed notification. Clearing requires a reconciled chosen version and a policy that cannot hide an older accepted version during quorum changes. The first implementation retains base markers for the execution lifetime; terminal/archive state alone does not permit removal. Marker GC uses the same higher-barrier, proposer/configuration-fencing, and accepted-value accounting proof as hard cell/object deletion.

### 9.3 Accepted but not published

Some practical implementations distinguish accept from a later local promotion or commit broadcast. If the proposer dies after an accept quorum:

- the value is already chosen;
- local eventual readers may not see it;
- no publish event or subscription is guaranteed;
- the next consistent identity transition must recover and expose it.

Accept-time markers plus periodic reconciliation are therefore mandatory Journal semantics, not an optional observability feature.

### 9.4 Dispatch and timer indexes

Pending dispatches and timers remain roots in the ExecutionCell. Acceptor-local discovery indexes are conservative materializations:

- an accepted cell that adds pending work adds/upserts a marker in the same durable accept operation;
- removing an older due item is deferred until the chosen successor is reconciled;
- the scanner treats index rows as candidates and verifies the chosen cell;
- duplicate delivery or timer firing is fenced by claim/attempt identity and accepted-result dedupe.

This allows at-least-once wakeup despite lost commit broadcasts, process crashes, or stale replicas.

## 10. Dispatch, timers, and long-running workflows

### 10.1 Write-ahead dispatch

RunnableDispatchRequested is included in a chosen TransitionBundle before ExecutionBackend.dispatch is called. The same cell transition adds its dispatch entry to pending_dispatch_root.

A delivery loop:

1. discovers a candidate execution;
2. consistently reads the cell;
3. CAS-claims one or more pending dispatches with claimant, claim generation, and deadline;
4. submits the recorded intent to a direct or Broadway backend;
5. records an acknowledgement or releases/expires the claim through another cell transition.

Broker acknowledgement occurs only after Runic reports the attempt result committed or known duplicate. Dispatch may occur more than once. Its terminal graph outcome may be accepted only once.

### 10.2 Timers

Retries, sleeps, deadlines, and scheduled inputs are recorded events plus timer-root entries. An acceptor-local due index is a discovery accelerator. Timer claims use unique claim identity and are checked in the same cell.

Wall clocks decide when to attempt a timer, not whether a stale transition is safe. Early or duplicate firing is rejected or deduplicated by the cell's logical timer state. Time-skew bounds still matter for latency and lease behavior and belong in the certified profile.

### 10.3 In-memory versus durable state

An active coordinator may retain:

- reconstructed Workflow and graph indexes;
- hydrated recent facts;
- prepared Runnable projections;
- proposer ballot/cache hints;
- scheduler queues and batching state.

All are disposable. After failover, snapshot plus event bundles rebuild the Workflow; cell roots reveal pending claims and timers. Passivation is safe only after no uncommitted in-memory semantic transition is treated as accepted.

## 11. Partitioning, scale, and contention

### 11.1 Key and shard layout

Hash tenant-qualified execution identity to a fixed virtual shard. Map virtual shards to stable acceptor sets. Within a set, each execution remains an independent CASPaxos register.

Scale comes from:

- independent keys progressing concurrently;
- several acceptor sets serving disjoint virtual shards;
- elastic proposers and compute workers;
- parallel workflow activities whose results serialize through the cell's chosen descendant chain;
- batched object writes, network requests, and recovery scans;
- moving virtual shards through an explicitly proven reconfiguration process.

### 11.2 Hot-key ceiling

One execution has one noncommutative descendant chain. More proposers increase contention rather than its maximum serial transition rate. Large fan-out should execute activities concurrently and return results through bounded aggregation, but chosen graph mutations still advance one cell at a time.

Mitigations:

- route a key to a preferred proposer while retaining takeover;
- batch compatible ingress into one Runic transition;
- apply admission control and tenant fairness before phase one;
- use randomized exponential backoff after ballot conflicts;
- isolate pathological hot tenants/shards;
- consider a mergeable state-delta path only where Runic semantics prove commutativity.

### 11.3 Backpressure

Limit:

- cell and TransitionBundle bytes;
- events and payload references per transaction;
- outstanding proposals per key and proposer;
- object prewrites, accepted-candidate retention, and proven-orphan budget;
- pending dispatch/timer entries per execution;
- consistent read rate;
- recovery scan concurrency;
- per-tenant bandwidth, storage, and CPU.

Overload returns a typed retryable result before uncontrolled memory or object growth. A confirmed durable input is never dropped as an overload tactic.

## 12. Stable acceptors and dynamic proposers

### 12.1 Acceptors

Start with three stable durable acceptors per shard set, distributed across independent failure domains. Use five only for a measured requirement to tolerate two faults.

Acceptors require:

- stable logical identity independent of Erlang node name, plus a configuration-controlled acceptor incarnation;
- exclusive process/volume fencing so two processes can never diverge while presenting one quorum identity;
- synchronous durable promise/accept writes;
- protocol and storage schema versions;
- checksummed values and ballot metadata;
- bounded RPC and disk queues;
- backup and restore procedures that preserve accepted and promised state;
- quarantine for stale or wiped data;
- no user workflow execution.

Compute nodes, preemptible instances, and frequently autoscaled pods are not voters.

### 12.2 Proposers

Proposers are elastic and mostly stateless. Their ballot is conceptually:

~~~text
{configuration_epoch, counter, unique_proposer_incarnation}
~~~

Uniqueness and ordering do not rely on synchronized wall clocks. A proposer bumps beyond every conflicting promise it observes and never reuses an incarnation. Persisting a local high-water mark improves restart behavior but cannot replace acceptor promises.

Changing proposer count is easy for protocol safety. Operational services that enumerate all proposer caches for deletion or reconfiguration are why the first version has no fast-path cache and no hard deletion.

### 12.3 Acceptor membership is not autoscaling

The paper's membership procedure changes prepare and accept quorums in stages and performs an identity transition for every key, or copies and reconciles a majority's accepted state. Skipping the state-transfer/barrier step can eventually replace every old acceptor and lose chosen or still-relevant accepted state while each local change appeared to have a quorum.

Therefore:

- the first certified topology has a static voter set;
- rolling code/process replacement preserves non-rollbacked disk state and logical identity, advances/synchronizes the acceptor incarnation, and proves the old process cannot overlap;
- a replacement with lost storage does not vote until it is safely bootstrapped and certified caught up;
- online add/remove needs a configuration generation, intersecting joint/flexible quorums, accepted-state transfer, concurrent-write catch-up, and a proof;
- all keys, including dormant registrations and terminal executions, participate in the reconfiguration barrier;
- operator agreement on a cluster_size integer is not a reconfiguration protocol.

Dynamic proposer/compute registration must never be confused with dynamic voter membership.

## 13. Deletion, garbage collection, and cache safety

CASPaxos deletion is more involved than writing a normal tombstone. Delayed prepare/accept messages or proposer caches can otherwise reintroduce a deleted value.

The paper's design:

1. chooses a tombstone with a normal quorum;
2. performs an identity transition using the maximum quorum;
3. invalidates proposer caches;
4. advances/persists proposer ages or minimum accepted ballot ages;
5. removes acceptor state only when obsolete messages can no longer revive it.

Runic's first safe policy is simpler:

- never hard-delete an authoritative ExecutionCell;
- mark it terminal/archived and retain generation, final head, and compact dedupe proof;
- create a new execution with a new immutable execution ID/generation;
- disable one-round proposer caches;
- disable candidate-object collection in v1; a later collector must mark chosen cells, accepted cells/recovery markers, and durable pre-accept proposal pins, then require a higher-barrier and proposer/configuration-fencing exclusion proof before clearing any candidate root; elapsed grace time alone is never proof in the asynchronous model;
- treat legal erasure of payload bytes separately from retaining non-sensitive integrity and dedupe metadata.

Hard cell deletion is a later protocol feature requiring model checking, delayed-message tests, cache invalidation, and documented restore semantics.

## 14. Storage engine choices

CASPaxos is the replication protocol; its acceptor store must still provide local atomic durability.

| Store | Strengths | Risks and required proof | Initial role |
|---|---|---|---|
| SQLite WAL through a maintained NIF | Simple transactional promise/accept/marker update, online-backup primitives, EKV precedent, strong embedded ergonomics | Serialized writer per database, NIF/platform operations, checkpoint/fsync stalls, shard-count tuning; a coherent consensus backup is additional work | Recommended reference implementation |
| RocksDB | High local throughput, atomic WriteBatch, column families, mature LSM compaction and checkpoints | NIF quality, WAL/sync configuration, compaction stalls, backup consistency, restoring ballot state, no distribution by itself | Scale-oriented acceptor candidate after reference model |
| LevelDB | Small embedded surface and ordered KV | Less concurrency/operational depth than RocksDB, binding maturity | Prototype only unless it demonstrates a concrete advantage |
| PostgreSQL | Familiar transactions, observability, managed options | The database already supplies concurrency/HA; layering CASPaxos usually duplicates coordination and adds latency | Prefer a direct runic_postgres Journal instead |
| Khepri | BEAM-native replicated metadata and tree model | Uses Ra underneath; using it for each CASPaxos acceptor nests consensus and defeats the alternative | Bounded external control metadata only |
| DETS/Mnesia | Built into the ecosystem | Durability, repair, replication, and contention semantics do not match the needed acceptor proof without substantial work | Not recommended |

For SQLite or RocksDB, one local atomic operation must update promise/accepted state and the recovery marker before acknowledgement. An in-memory cache may accelerate reads but can never be the only copy of a promise.

TransitionBundles, snapshots, and large payloads belong in an object/segment store such as S3, GCS, Azure Blob, a self-hosted S3-compatible system, or a certified replicated filesystem. The object profile must support idempotent content-addressed puts, integrity verification, bounded reads, lifecycle/versioning, and disaster-recovery evidence.

The immutable tree/bundle provider is an internal correctness component hidden behind runic_caspaxos Journal initialization, health, capabilities, and limits; it is not a fourth stable Runic core behaviour. Runic.Runtime.PayloadStore remains the separate public contract for workflow facts and other user payloads. An implementation may share one object service underneath both roles while preserving their distinct reference, retention, and failure semantics.

## 15. EKV as implementation evidence

The current [chrismccord/ekv](https://github.com/chrismccord/ekv) implementation is valuable prior art. This plan audited version 0.4.3 at commit [b389db8](https://github.com/chrismccord/ekv/tree/b389db8e618a62f05057f6b0a4ad53f99cda80dd).

### 15.1 What EKV already demonstrates

- a zero-runtime-dependency Elixir API backed by vendored SQLite NIF storage;
- member, durable observer, and stateless client modes;
- a per-key CASPaxos register with multiple proposers, linearizability-oriented regression tests, and a local checker harness;
- stable persisted node IDs and durable per-key promise/accepted ballots; proposer counter high-water marks persist on orderly shutdown/handoff and restart also bumps from wall time;
- prepare, durable accepted-but-invisible state, choice at accept quorum, later visibility promotion/commit dissemination, and recovery through a consistent barrier read;
- explicit conflict versus unconfirmed outcomes;
- eventual local reads versus consistent identity reads;
- sharded SQLite WAL stores, oplog repair, anti-entropy, transport callbacks, and :pg-based routing;
- a local :peer history generator checked with Knossos/Jepsen tooling, plus local CAS benchmarks, that are useful starting points but are not a conventional multi-host Jepsen certification.

The API documents that an unconfirmed write may or may not have committed and must be resolved by a consistent read. It also uses bounded retries and randomized backoff, practical evidence that leaderless does not mean contention-free or unconditionally terminating.

EKV's configured shards are local concurrency/storage partitions replicated on every durable member. They do not distribute ownership of the data set among member subsets. A Runic scale-out design therefore needs explicit virtual-shard placement across several stable acceptor sets rather than assuming that increasing EKV's shard or member count horizontally partitions capacity.

### 15.2 Why Runic should not use EKV unmodified as its Journal

The audited implementation has important gaps for Runic's guarantee profile:

- its ordinary data model is eventually consistent LWW with opt-in CAS; the LWW-to-CAS cutover is explicitly not partition-safe, so Runic requires an isolated CAS-only instance/keyspace from creation;
- prefix scans and subscriptions are not a linearizable or proven eventually complete recovery index for accepted-but-unpublished workflow work;
- there is no atomic multi-key transaction, so separate receipt, dispatch, timer, and registration keys would be unsafe;
- ambiguous writes expose version resolution but do not carry Runic's durable command and transaction receipt model;
- node-down and blue/green shutdown paths need a phase-aware audit so an operation that may have reached accept never returns a definitive no-quorum/shutdown rejection;
- TTL and local wall-clock expiry cannot serve as the writer fence;
- voter membership is based on configured logical cluster size and reachable stable IDs, not a consensus-owned configuration generation with joint reconfiguration;
- at the audited revision, fresh/full synchronization excludes tentative CASPaxos acceptor state; a blank replacement can therefore miss an accepted value unless old/new quorum intersection and state transfer are separately enforced;
- hard deletion/GC is not the paper's full delayed-message/cache-age deletion protocol;
- retained promise metadata means a high-churn CAS namespace leaves approximately one kv_paxos row per distinct key until a separately safe forgetting protocol exists;
- one GenServer per shard can serialize otherwise independent local operations;
- transport trust, tenant authorization, protocol upgrades, backup/restore of Paxos metadata, and object-root publication need Runic-specific certification.

These are not criticisms of EKV's stated eventually consistent KV purpose. They define the delta between a useful library and a workflow Journal that promises no stranded confirmed input.

A concrete unsafe reconfiguration to exclude is: old voters A/B/C accept X on A+B, the proposer dies before promotion, A is replaced by blank D, and a new C+D prepare quorum never observes X. A production Runic profile must transfer promise/accepted state or use an intersecting configuration transition that makes this history impossible.

EKV's audited SQLite configuration uses synchronous NORMAL. That is a reasonable embedded-database trade-off, but consensus promises and accepts require a published stable-storage policy for host power loss as well as process crashes. The Runic profile must select and test FULL or an equivalently durable fsync mode before acknowledging production consensus writes, certify that the filesystem/volume honors synchronization, and fail safely on rollback or lying storage.

### 15.3 Reuse paths

Evaluate three paths in order:

1. **Prototype adapter on EKV:** a non-production deployment with a fixed voter set, exclusive intact volumes, a dedicated CAS-only keyspace, one encoded ExecutionCell per key, no TTL deletion, external immutable bundles, and explicit Runic outcome resolution. Fastest way to validate cell size, contention, and event-root design after post-accept node-down/handoff outcome paths are corrected.
2. **Contribute or fork focused hooks:** durable accept-time recovery markers, CAS-only namespaces, operation receipts, explicit membership/configuration state, safe bootstrapping, and scan semantics. Use only if the resulting surface remains aligned with EKV's project.
3. **Extract a generic CASPaxos library:** separate proposer/acceptor protocol from storage, transport, and Runic semantics. Highest control and largest proof/operations burden.

The prototype may graduate only when chosen-but-unpublished recovery, configuration safety, outcome classification, and deletion rules are addressed. Otherwise EKV remains a fixed-membership experimental registry/reference implementation, while the full Journal uses a purpose-built layer.

### 15.4 Other Elixir ecosystem evidence

The Hex package [caspax](https://hex.pm/packages/caspax) is a small historical Elixir CASPaxos implementation last released as 0.1.1 in 2018. Its age and incomplete deletion/garbage-collection work make it useful for code archaeology, not a production dependency.

Riak Ensemble and related projects implement Multi-Paxos-style ensembles rather than this leaderless per-key CASPaxos design. They may inform storage and operational testing, but substituting them would be a different architecture.

The official [TLA+ CASPaxos example](https://github.com/tlaplus/Examples/tree/master/specifications/CASPaxos) is the best available formal starting point. Runic must extend it with transaction receipts, immutable object roots, discovery markers, owner epochs, configuration generations, and deletion rather than treating the unmodified register model as sufficient.

## 16. Proposed library boundaries

### 16.1 In the main Runic package

Keep dependency-light semantics in Runic:

- Runic.Runtime.Journal and capability groups;
- StreamRef, RecordedEvent, Transaction, Commit, receipts, and error classes;
- authority, dispatch, timer, and scan semantics;
- pure transition decision/application;
- CASPaxos-neutral conformance and fault fixtures;
- Runtime coordinator, activation/passivation, and ExecutionBackend integration.

There is no runic_runtime package and no CASPaxos-specific workflow lifecycle.

### 16.2 Heavy adapter

runic_caspaxos may contain:

- Journal implementation and ExecutionCell codec;
- TransitionBundle/history-index implementation;
- proposer client, preferred-route driver, and recovery scanners;
- acceptor application and storage engine integration;
- static topology and later configuration tooling;
- telemetry, repair, backup, and chaos helpers;
- an optional Registry facade implemented over bounded cells.

It is a separate package because storage NIFs, transport, cluster operations, and independent releases are material dependencies, not because it defines parallel Runic behaviours.

### 16.3 Possible generic caspaxos package

If EKV cannot expose the required seams, a reusable Elixir library should hide protocol complexity behind a narrow byte-oriented interface.

Core behaviours:

~~~elixir
defmodule CASPaxos.AcceptorStore do
  @callback prepare(key, ballot, configuration, state) ::
              {:promise, accepted, state} | {:nack, higher_ballot, state}

  @callback accept(key, ballot, encoded_value, configuration, state) ::
              {:accepted, state} | {:nack, higher_ballot, state}

  @callback list_recovery_markers(shard, cursor, limit, state) ::
              {:ok, markers, next_cursor, state}
end

defmodule CASPaxos.Transport do
  @callback prepare_many(acceptors, request, timeout, state) :: replies
  @callback accept_many(acceptors, request, timeout, state) :: replies
end
~~~

The real API also needs:

- encoded-value size/digest/version validation;
- unique ballots and configuration generations;
- phase-specific quorum policies with intersection validation;
- typed pre-accept, unknown, chosen, and unavailable outcomes;
- no-op barrier reads;
- durable accept-time recovery hints;
- backpressure and cancellation;
- storage bootstrap and quarantine;
- protocol metrics and trace correlation;
- model-test adapters with deterministic message scheduling.

It should not accept arbitrary remote Elixir functions or deserialize untrusted ETF into the acceptor. The application supplies a pure local transformation at the trusted proposer boundary; storage sees bytes.

The store creates the unconditional key/version recovery marker itself inside accept; it does not trust a proposer to decide whether a key needs recovery. Optional active/due hints may be derived from a validated cell header, but omission of those hints can never omit the base dirty key.

The configuration argument is a claimed request generation, not trusted membership input. Each acceptor compares it with its own locally durable active/transition configuration. The configuration check, promise/accept mutation, and recovery marker need a formally specified atomic relationship.

## 17. Membership and reconfiguration research track

Online membership is the largest difference between a paper prototype and an operable durable runtime.

### 17.1 Required configuration object

Every request names an immutable configuration generation containing:

- acceptor logical identities, active incarnations, exclusive-volume fences, and failure domains;
- prepare and accept quorum definitions;
- protocol/codec compatibility floor;
- shard ownership;
- predecessor configuration and transition phase;
- state-transfer/barrier watermark.

Acceptors reject unknown or retired configurations according to a formally specified state machine. Proposers cannot redefine membership from local environment variables.

### 17.2 Safe transition requirements

A production reconfiguration protocol must show:

- during transition, each prepare quorum either intersects every still-valid accept quorum or is activated only after a fenced state-transfer/barrier has adopted those quorums' highest accepted state;
- the new acceptor set receives the highest relevant promised/accepted state for every key;
- concurrent writes during bulk copy are captured and replayed or constrained by a barrier;
- dormant and tombstoned keys are included;
- only one configuration transition advances at a time;
- a failed transition can resume or roll forward without inventing state;
- a stale proposer cannot use an obsolete quorum to publish a cell;
- backups and disaster restore retain configuration and ballot metadata.

The paper's full-key identity sweep is a correct conceptual baseline but may be too expensive for millions of executions. Its optimized path changes the accept-side configuration, copies a majority of old acceptors into the new acceptor while resolving every key by highest accepted ballot, and then catches up concurrent deltas before the final barrier/fence. That may be the practical direction, but it needs a TLA+, Quint, or equivalent executable model before implementation.

### 17.3 Initial operational constraint

Until that work passes:

- deploy a fixed three-acceptor set per shard;
- autoscale only proposers and compute;
- replace a process only when it has exclusive ownership of the same logical acceptor identity and non-rollbacked durable promises/accepted values, using synchronized handoff or proof the old process is dead before opening the volume;
- treat permanent disk/member loss as a documented repair/restore event;
- do not market elastic storage membership.

## 18. Failure analysis

| Failure | Required behavior |
|---|---|
| proposer dies before prepare quorum | No cell change; retry elsewhere |
| proposer dies after promises | A higher ballot can make progress; latency only |
| proposer dies after minority accepts | Outcome is unknown; later prepare may adopt or supersede the candidate |
| proposer dies after accept quorum | Candidate is chosen; recovery marker and consistent barrier expose it |
| commit/wakeup broadcast is lost | Scanner rediscovers the key and verifies chosen state |
| one acceptor is down in a three-node set | Quorum operations continue; catch-up/repair remains bounded |
| quorum is unavailable | Consistent reads and writes stop; no consistency downgrade |
| two authorized proposals race on one execution | They serialize through prepare/adoption; either or both semantic operations may enter the descendant chain if their Runic preconditions remain valid, and ambiguous callers resolve by receipt |
| old owner remains alive | Cell epoch rejects its mutation; its external effect may still require idempotency |
| object prewrite succeeds and no accept is issued | Proven never-accepted orphan may be collected |
| candidate may have been accepted but a later call returns first | Retain its complete object closure until higher barrier plus proposer/configuration fencing proves adoption impossible |
| CAS chooses a missing object reference | Profile invariant violation; fail closed, alert, and repair from redundant object copies |
| local eventual scan is stale | It may delay activation, never decide truth; quorum-union recovery must remain eventually complete |
| worker result is duplicated | Same attempt/command receipt returns the original committed outcome |
| acceptor disk returns stale/blank | Quarantine; it cannot vote until safe bootstrap |
| delayed packet from retired config arrives | Configuration generation rejects it |
| process clock jumps | May affect promptness; cannot bypass epoch/position/claim checks |

## 19. Security and tenant isolation

- tenant-qualified keys and object prefixes are mandatory;
- acceptors authorize proposer identities and namespace access;
- use mTLS or an equivalently authenticated private transport outside a fully trusted BEAM cluster;
- never decode untrusted ETF or execute a client-supplied function in storage;
- encode a transform/protocol version in every candidate cell and reject incompatible proposers; unlike a deterministic Ra machine, CASPaxos trusts proposer-computed state, so mixed-version rollout and proposer bugs are part of the safety boundary;
- encrypt acceptor volumes and object payloads according to the deployment profile;
- sign or MAC versioned protocol frames where transport identity is insufficient;
- enforce tenant quotas before object prewrite and consensus;
- keep secrets out of TransitionBundles; dispatch events carry ContextRefs resolved on workers;
- retain audit events for authority changes, configuration changes, unknown outcomes, repair, and restore;
- make object reachability and legal erasure namespace aware.

## 20. Backup, restore, and disaster recovery

Back up two coupled durability planes:

1. acceptor state: promises, accepted values, configuration, recovery markers, and storage schema;
2. immutable history/payload state: bundles, persistent tree nodes, snapshots, and payloads.

A restore is valid only when it can prove that every restored chosen head reaches verified objects. Restoring an older acceptor snapshot beside newer surviving voters or resurrecting a retired configuration is unsafe.

Required procedures:

- online per-acceptor backup with an exact local checkpoint;
- object versioning/replication and inventory manifests;
- configuration-generation and shard-map backup;
- clean-cluster restore that reconstructs quorum without reusing stale identities blindly;
- reconciliation of every recovery marker through a barrier read;
- reachability verification from every terminal/active cell;
- command/transaction horizon preservation;
- delayed-old-proposer and delayed-worker quarantine after restore;
- published RPO/RTO for single member, shard, object region, and full regional loss.

Multi-region active-active updates to one cell are not a first target. A regional quorum plus object replication and a tested standby/restore path is the initial posture.

## 21. Observability and overload signals

Measure by shard, tenant, and operation:

- prepare/accept/barrier latency and quorum member distribution;
- ballot conflicts, retries, starvation age, and preferred-proposer hit rate;
- confirmed, unknown, unavailable, expired, and semantic conflict outcomes;
- chosen-but-unpublished recoveries;
- recovery-marker backlog and oldest age;
- consistent versus eventual reads;
- cell and bundle encoded bytes;
- persistent-tree objects written per transition, accepted-candidate retention, and proven-orphan rate;
- object prewrite latency/failures and missing-reference checks;
- acceptor fsync, WAL, compaction/checkpoint, disk queue, and space;
- pending dispatch/timer count and oldest age;
- active/passivated coordinators and rebuild duration;
- membership/config generation and catch-up progress;
- stale authority, claim, attempt, and delayed-result rejections;
- per-tenant admissions, throttles, and hot-key concentration.

Suggested SLO indicators:

- confirmed command acknowledgement latency;
- time from confirmed input to visible pending work;
- time to recover a chosen-but-unpublished cell;
- completion acceptance latency;
- failover/rebuild time;
- percentage of calls returning unknown;
- proof-resolution latency;
- recovery backlog age;
- restore verification time.

## 22. Model, conformance, Jepsen, and chaos program

### 22.1 Executable models

Before a production acceptor:

- model prepare/accept, identity read, ambiguity, and receipt resolution;
- model the ExecutionCell transform and persistent-root publication;
- model accept-time marker enumeration and clearing;
- model owner replacement and stale epoch rejection;
- model flexible/joint reconfiguration separately;
- model terminal archive and any future deletion protocol.

Safety properties:

- chosen cells and their adopted accepted ancestors form one descendant chain;
- stream position and history predecessor agree;
- at most one terminal semantic outcome per attempt appears in that chain;
- every chosen cell and every accepted value that can still become chosen has a reachable, verified object closure;
- every chosen cell that has durable work remains discoverable;
- stale configurations and epochs cannot mutate current state;
- resolution never reports not_committed for a transaction in the lineage;
- every returned not_committed result has a chosen retained negative receipt/ID guard;
- scanner pagination cannot permanently omit a concurrently inserted recovery marker;
- artifact construction prefix plus execution tail replay equals the canonical event sequence.

### 22.2 Journal conformance

Run the same Runic.Runtime.Journal suite as SQLite, PostgreSQL, and Ra:

- chronological replay and page boundaries;
- expected-position conflict;
- command-ID duplicate and content conflict;
- transaction unknown/resolve/expired;
- authority acquire/replace/fence;
- dispatch and timer claim/release/expiry;
- snapshot plus tail rebuild;
- corrupt codec/payload fail-closed behavior;
- capability and limit enforcement.

### 22.3 Distributed histories

Extend EKV's Jepsen starting point into a Runic-specific black-box harness:

- single execution register under multiple writers/readers;
- many independent executions and hot-key skew;
- network partitions including proposer/acceptor asymmetry;
- acceptor and proposer process crashes/restarts;
- disk loss, stale disk, fsync delay, full disk, and checkpoint stalls;
- ambiguous replies after each protocol boundary;
- arbitrary-time retention and later adoption of a minority-accepted candidate;
- negative transaction resolution followed by delayed old accepts and ID reuse attempts;
- recovery scanner rollover with inserts behind its cursor;
- coordinator death after object put, accept quorum, and wakeup;
- proposer death after the proposal pin but before the first accept, and delayed accept delivery after proposer death;
- duplicate Broadway deliveries and delayed worker results;
- fixed-membership replacement drills;
- later, every reconfiguration phase.

Check linearizability of cells and Runic-level invariants. A repository containing a Jepsen harness is not evidence until repeatable result artifacts, configuration, and failures are published.

### 22.4 Long-running workflow workloads

- millions of mostly idle executions;
- one very hot evolving workflow;
- long event histories with snapshot/archive;
- large fan-out/fan-in and stateful components;
- equal payload values with distinct fact occurrences;
- retry/timer storms;
- high coordinator churn and passivation;
- object-store throttling or regional errors;
- noisy multi-tenant skew;
- rolling codec/artifact/runtime upgrades.

## 23. Implementation phases

### CP0 — semantic and protocol model

Deliver:

- pure ExecutionCell and TransitionBundle models;
- closed commit/receipt/authority/claim transformations;
- CASPaxos prepare/accept simulation with deterministic message scheduler;
- ambiguity, adopted-minority ancestry, receipt-only negative resolution, and ID guards;
- accept-time recovery marker model;
- construction-artifact prefix plus execution-tail replay model;
- explicit liveness language and capability manifest.

Gate: exhaustive/property traces preserve descendant, event-root, receipt, fencing, and discovery invariants.

### CP1 — single-node storage and object roots

Deliver:

- SQLite reference acceptor store with atomic promise/accept/marker transaction;
- versioned byte codec and checksums;
- content-addressed bundle, payload, and persistent-map implementation;
- Journal load/commit/resolve on one acceptor;
- accepted-value-aware reachability inventory and a collector that only removes never-accepted or barrier-and-fencing-excluded candidates.

Gate: every crash point leaves every chosen or still-adoptable accepted cell with a completely reachable object closure.

### CP2 — fixed three-acceptor CASPaxos

Deliver:

- two-round proposer and identity reads;
- stable IDs, ballots, quorum validation, backpressure, and telemetry;
- three local/:peer acceptors with independent directories;
- concurrent multi-writer tests, minority failure, unknown outcomes, and restart recovery;
- dedicated CAS-only keyspace.

Gate: model equivalence and linearizable black-box histories under partitions and process restarts, including arbitrary-time minority adoption with no missing object closure.

### CP3 — Runic Journal execution loop

Deliver:

- runic_caspaxos Journal adapter against the in-package contract;
- portable RunnableDispatchRequested bundles;
- authority embedded in the cell;
- direct backend, AttemptResult validation, and duplicate-safe completion;
- pending dispatch, retry, timer, cancellation, passivation, and resume;
- consistent scan/recovery integration.

Gate: killing components at every input/object/prepare/accept/wakeup/result boundary loses no confirmed input and places at most one terminal semantic outcome per attempt in the chosen lineage.

### CP4 — elastic proposer and Broadway profile

Deliver:

- preferred proposer routing through Group/:pg with safe fallback;
- autoscaling proposer/coordinator clients;
- Broadway broker bridge using the common ExecutionBackend;
- tenant admission, fairness, batching, and hot-key controls;
- eventual capability registry with linearizable per-name lookup where needed.

Gate: arbitrary route divergence and compute churn affect latency, not Journal safety.

### CP5 — operational storage profile

Deliver:

- production SQLite tuning and a measured RocksDB acceptor experiment;
- backup/restore, stale-disk quarantine, repair, and reachability verification;
- rolling protocol/codec/storage upgrades;
- dashboards, alerts, operator runbooks, soak tests, and published limits;
- authenticated transport profile.

Gate: the fixed-membership regional profile meets stated SLO, RPO, RTO, and sustained-chaos criteria.

### CP6 — membership research

Deliver:

- formal configuration-generation and flexible/joint-quorum model;
- bulk majority-state copy plus concurrent delta/barrier design;
- non-voting bootstrap and catch-up;
- add/remove/replace tooling and interruption recovery;
- Jepsen histories across every reconfiguration stage.

Gate: no old/new quorum history can lose or fork a chosen cell or omit a still-adoptable accepted predecessor, including dormant and tombstoned keys.

### CP7 — optimization only after evidence

Candidates:

- one-round preferred-proposer fast path with complete cache invalidation;
- batch/vectorized RPC across independent keys;
- concurrent acceptor storage lanes;
- persistent-tree/segment packing;
- virtual-shard movement;
- safe terminal cell deletion;
- multi-region standby automation.

Gate: each optimization improves a published workload and preserves the reference model.

## 24. Graduation criteria

The full runic_caspaxos Journal remains experimental until all are true:

1. It passes the same Journal conformance suite as SQLite/PostgreSQL/Ra.
2. Three-acceptor linearizability histories pass under partitions, restarts, delayed messages, and ambiguous replies.
3. Every chosen-but-unpublished state is rediscovered after proposer and coordinator loss.
4. Event, receipt, dispatch, and timer roots remain atomically consistent for every tested crash point.
5. Long histories keep the cell bounded and restore through immutable bundles/snapshots.
6. Unknown outcomes resolve without duplicate semantic application.
7. A stale route, owner, worker, clock, or proposer cannot bypass cell fencing.
8. Object loss/corruption fails closed and redundant restore is proven.
9. Fixed-membership backup, full restore, stale-disk quarantine, and rolling upgrade runbooks pass.
10. Capacity, backpressure, tenant isolation, and proof-retention limits are published.
11. Strict wait-free or exactly-once marketing claims are absent.
12. Dynamic voter membership remains disabled until CP6 independently graduates.
13. Every object referenced by a still-adoptable accepted value remains reachable for arbitrary time; collection requires a protocol exclusion proof.
14. Every returned not_committed outcome has a durable negative receipt/ID guard and survives delayed messages and retries.
15. Recovery scan pagination is eventually complete under concurrent marker insertion.
16. Construction-artifact prefix plus execution-tail replay is equivalent to every other certified Journal.

The bounded registry profile can graduate earlier, but must say that it provides per-key linearizable registration and route/placement metadata, not Runic Journal durability.

## 25. CASPaxos versus Ra for Runic

| Concern | CASPaxos profile | Ra profile |
|---|---|---|
| Ordering unit | Descendant chain per ExecutionCell | Total ordered command log per Ra group |
| Writer topology | Any proposer may acquire/take over; only current execution epoch commits; optional preferred route | Current group leader |
| Quorum loss | Unavailable, preserves consistency | Unavailable, preserves consistency |
| Leader failure | No election dependency, but ballots may contend | Election pause then stable leader |
| Same-key concurrency | Serial descendant chain; partial proposals may be adopted and one or both semantic operations may apply | Serialized through leader/log |
| Different-key concurrency | Naturally independent registers and shards | Parallel across groups; commands within one group ordered |
| State replicated | Whole compact cell each update | Commands/log plus deterministic machine state |
| Runic history | Must be external immutable bundles/index roots | Native ordered log initially, then external archival still needed |
| Consistent read | Identity consensus transition | Leader/read-index style query depending on Ra API |
| Multi-key atomicity | None without another protocol | Several keys can be one group command if co-located |
| Unknown client outcome | Positive receipt or chosen receipt-only negative proof | Command ID/query resolution still required |
| Discovery | Must build durable marker/index path | Log/state-machine effects and indexes are more direct |
| Membership | Paper protocol plus full-key state transfer; substantial custom work | Mature library support, still operationally careful |
| Hot-key behavior | Multi-proposer contention can reduce progress | Stable leader usually reduces write contention |
| Storage control | Very high; small state and acceptor design | Very high; WAL/snapshot/state-machine design |
| Ecosystem maturity | EKV is promising current prior art; Runic gaps remain | RabbitMQ Ra is production-used and continuously tested |
| Best initial fit | Fine-grained registry/claims; experimental high-key-count Journal | Primary purpose-built native Journal candidate |

CASPaxos is most compelling when there are many independent, compact execution heads and avoiding a permanent leader or replicated command log materially improves the measured workload. Ra is simpler when Runic wants one ordered partition log, atomic co-sharded indexes, mature membership/snapshot tooling, and predictable hot-key serialization.

Neither protocol changes the fundamental rule that external activity effects need idempotency, reconciliation, or an application-specific transaction.

## 26. Recommended delivery posture

1. Keep the Ra plan as the more mature primary native implementation track.
2. Build CP0 and a narrow EKV-backed or SQLite-backed CASPaxos prototype in parallel after the Runtime Journal contract exists.
3. First prove the bounded linearizable registry and single ExecutionCell under contention.
4. Do not call the prototype a Journal until immutable event roots for chosen and still-adoptable accepted cells, durable discovery, positive/negative outcome receipts, artifact replay, and restart recovery pass.
5. Benchmark high-cardinality independent workflows, hot executions, long histories, timers, and object-store failure against Ra and PostgreSQL.
6. Promote runic_caspaxos only if it demonstrates a meaningful workload advantage and accepts the extra reconfiguration/deletion proof burden.
7. Keep all semantics behind Runic.Runtime.Journal and its optional callbacks so consumers can select CASPaxos, Ra, SQLite, or PostgreSQL without changing workflow construction, replay, or execution events.

## 27. Open decisions

1. Whether the first prototype adapts EKV, forks it, or starts from a generic protocol model.
2. Exact ExecutionCell byte ceiling and maximum events per TransitionBundle.
3. Persistent HAMT versus Merkle B-tree versus packed immutable segment index.
4. Object durability receipt required before phase two.
5. Whether acceptors store bundle bytes temporarily as an additional recovery copy.
6. Recovery-marker clearing and compaction protocol.
7. Static virtual-shard count and acceptor sets per node.
8. Preferred proposer routing and fairness policy.
9. Receipt horizons and permanent compact reuse guards.
10. Clock source/skew budget for registration and claim deadlines.
11. SQLite shard/process layout and when RocksDB is justified.
12. Authenticated transport after the trusted distributed-Erlang prototype.
13. Configuration model/tooling for CP6.
14. Legal erasure behavior for payloads while retaining event integrity.
15. Conditions under which the bounded registry profile becomes a separate runic_caspaxos package or an EKV integration.
16. Accepted-value object accounting and the exact barrier/configuration/proposer-fencing proof that permits collection.
17. Negative transaction/registration receipt retention and permanent ID-reuse guard representation.

## 28. Primary sources and audited evidence

- Denis Rystsov, [CASPaxos: Replicated State Machines without logs](https://arxiv.org/abs/1802.07000), especially protocol Section 2.2, membership Section 2.3, key/value deletion Section 3.1, and the safety proof appendices.
- Howard et al., [Flexible Paxos: Quorum intersection revisited](https://arxiv.org/abs/1608.06696), for phase-one/phase-two quorum intersection.
- Leslie Lamport, [Paxos Made Simple](https://lamport.azurewebsites.net/pubs/paxos-simple.pdf), especially the competing-proposer progress discussion in Section 2.4.
- Fischer, Lynch, and Paterson, [Impossibility of Distributed Consensus with One Faulty Process](https://groups.csail.mit.edu/tds/papers/Lynch/jacm85.pdf), for the boundary between asynchronous safety and unconditional deterministic termination.
- Maurice Herlihy, [Wait-Free Synchronization](https://courses.csail.mit.edu/6.852/05/papers/p124-herlihy.pdf), for the conventional wait-free progress definition.
- Chris McCord, [EKV repository](https://github.com/chrismccord/ekv) and [v0.4.3 audited revision](https://github.com/chrismccord/ekv/tree/b389db8e618a62f05057f6b0a4ad53f99cda80dd).
- EKV [public CAS API at the audited revision](https://github.com/chrismccord/ekv/blob/b389db8e618a62f05057f6b0a4ad53f99cda80dd/lib/ekv.ex#L630-L1036); [current HexDocs](https://hexdocs.pm/ekv/EKV.html) are a convenience link and may move beyond the audit.
- EKV [core proposer/acceptor implementation](https://github.com/chrismccord/ekv/blob/b389db8e618a62f05057f6b0a4ad53f99cda80dd/lib/ekv/replica.ex).
- EKV [operator guidance](https://github.com/chrismccord/ekv/blob/b389db8e618a62f05057f6b0a4ad53f99cda80dd/OPERATORS.md).
- EKV [storage schema and synchronous configuration](https://github.com/chrismccord/ekv/blob/b389db8e618a62f05057f6b0a4ad53f99cda80dd/lib/ekv/store.ex#L112-L149), [retained Paxos metadata](https://github.com/chrismccord/ekv/blob/b389db8e618a62f05057f6b0a4ad53f99cda80dd/lib/ekv/store.ex#L1682-L1690), and [synchronization/accepted-state notes](https://github.com/chrismccord/ekv/blob/b389db8e618a62f05057f6b0a4ad53f99cda80dd/lib/ekv/replica.ex#L711-L736).
- EKV [ordinary phase-aware outcome classification](https://github.com/chrismccord/ekv/blob/b389db8e618a62f05057f6b0a4ad53f99cda80dd/lib/ekv/replica.ex#L6461-L6525), [node-down bypass](https://github.com/chrismccord/ekv/blob/b389db8e618a62f05057f6b0a4ad53f99cda80dd/lib/ekv/replica.ex#L6800-L6817), and [blue/green handoff path](https://github.com/chrismccord/ekv/blob/b389db8e618a62f05057f6b0a4ad53f99cda80dd/lib/ekv/replica.ex#L1893-L1903).
- EKV [local Jepsen/Knossos harness scope](https://github.com/chrismccord/ekv/blob/b389db8e618a62f05057f6b0a4ad53f99cda80dd/jepsen/README.md) and [local CAS benchmark notes](https://github.com/chrismccord/ekv/blob/b389db8e618a62f05057f6b0a4ad53f99cda80dd/bench/CAS_RESULTS.md); these are engineering evidence, not independent proof of Runic's profile.
- Historical Elixir [caspax package](https://hex.pm/packages/caspax), its [incomplete implementation notes](https://github.com/ericentin/caspax/blob/master/README.md), and the [TLA+ CASPaxos model](https://github.com/tlaplus/Examples/tree/master/specifications/CASPaxos).
- RabbitMQ [Khepri](https://github.com/rabbitmq/khepri) and Basho [Riak Ensemble](https://github.com/basho/riak_ensemble), for the ecosystem comparisons in Sections 14 and 15.
- RocksDB [basic operations and atomic WriteBatch](https://github.com/facebook/rocksdb/wiki/Basic-Operations) and [checkpoints](https://github.com/facebook/rocksdb/wiki/Checkpoints).
- SQLite [write-ahead logging](https://sqlite.org/wal.html), [synchronous pragma](https://sqlite.org/pragma.html#pragma_synchronous), and [online backup API](https://sqlite.org/backup.html).
