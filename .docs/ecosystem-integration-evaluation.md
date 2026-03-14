# Runic Ecosystem Integration Evaluation

**Status:** Reference  
**Scope:** Evaluate external libraries for integration with Runic at various layers — Store adapters, distributed registration, process supervision, and workflow coordination.  
**Companion to:** [phase-8-distribution-primitives.md](phase-8-distribution-primitives.md)

---

## Table of Contents

1. [Runic Integration Surface](#1-runic-integration-surface)
2. [Distributed Registration](#2-distributed-registration)
3. [Persistence / Store Adapters](#3-persistence--store-adapters)
4. [Distributed Actor Frameworks](#4-distributed-actor-frameworks)
5. [Integration Matrix](#5-integration-matrix)
6. [Recommended Packages](#6-recommended-packages)
7. [Raft-Based Coordination (Ra / Khepri)](#7-raft-based-coordination-ra--khepri)
8. [Combining Options: Deployment Topology Guide](#8-combining-options-deployment-topology-guide)
9. [Case Study: Libbit](#9-case-study-libbit)
10. [Recommended Adapter Combinations for Libbit](#10-recommended-adapter-combinations-for-libbit)

---

## 1. Runic Integration Surface

Libraries can integrate with Runic at several well-defined boundaries:

```
┌─────────────────────────────────────────────────────────┐
│                     User Application                     │
│   (Phoenix, CLI, standalone)                             │
├──────────────┬──────────────────────────────┬────────────┤
│  Runner API  │  Workflow Construction API   │  Protocols │
├──────────────┴──────────────────────────────┴────────────┤
│                                                          │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐ │
│  │ Registry │  │ Store    │  │ Executor │  │ Scheduler│ │
│  │(lookup)  │  │(persist) │  │(dispatch)│  │(plan)    │ │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘ │
│       ▲              ▲             ▲             ▲       │
│       │              │             │             │       │
│   Libraries plug in here                                │
└─────────────────────────────────────────────────────────┘
```

| Integration Point | Contract | What It Controls |
|---|---|---|
| **Store** | `Runic.Runner.Store` behaviour | Workflow event persistence, snapshots, fact storage |
| **Executor** | `Runic.Runner.Executor` behaviour | How/where runnables execute (local, remote, pooled) |
| **Scheduler** | `Runic.Runner.Scheduler` behaviour | What gets dispatched together and when |
| **Registry** | `Runner.via/2` tuple, `Runner.lookup/2` | Worker process discovery and addressing |
| **Supervision** | `Runner.init/1` children list | Worker lifecycle management |
| **Hooks** | Worker `:hooks` option | Observability and light customization |

---

## 2. Distributed Registration

### 2.1 Horde

**Library:** [elixir-horde/horde](https://github.com/elixir-horde/horde)  
**Deps:** `delta_crdt`, `libring`  
**What it is:** CRDT-based distributed Registry + DynamicSupervisor with API compatibility to OTP equivalents.

#### Architecture

Horde runs a δ-CRDT (Add-Wins Last-Write-Wins Map) on each node, gossipping deltas every 300ms (configurable). Both `Horde.Registry` and `Horde.DynamicSupervisor` use this CRDT as their source of truth. Lookups are O(1) local ETS reads — no GenServer roundtrip, no network hop.

`Horde.DynamicSupervisor` uses pluggable distribution strategies (`UniformDistribution`, `UniformQuorumDistribution`, `UniformRandomDistribution`) to determine which node owns a given child spec. When a node dies, other nodes detect the dead member via CRDT diffs and restart orphaned processes on themselves.

#### Consistency Model

**Eventually consistent (AP).** A `register/3` call always succeeds locally. If two nodes concurrently register the same key, the CRDT merges them and the losing process receives `Process.exit(pid, {:name_conflict, ...})`. This means **transient duplicates are possible** for up to one sync interval (~300ms). `UniformQuorumDistribution` prevents split-brain duplicates by shutting down all processes when quorum is lost.

#### Runic Integration: RunicHorde Package

**What it provides:**
- **Distributed Worker registration** — Replace `Elixir.Registry` with `Horde.Registry` in `Runner.via/2`. Workers become addressable cluster-wide.
- **Distributed Worker supervision** — Replace `DynamicSupervisor` with `Horde.DynamicSupervisor`. Workers automatically restart on surviving nodes when a node dies.
- **State handoff** — On Worker `terminate/2`, checkpoint to Store. On `init/1` of the replacement Worker, resume from Store. Horde provides the lifecycle; Runic's Store provides the state.

**How it plugs in:**

```elixir
# In a RunicHorde.Runner supervisor:
children = [
  {Horde.Registry, name: Module.concat(name, Registry), keys: :unique,
   members: :auto},
  {Horde.DynamicSupervisor, name: Module.concat(name, WorkerSupervisor),
   strategy: :one_for_one, members: :auto,
   distribution_strategy: Horde.UniformQuorumDistribution},
  # Store, TaskSupervisor remain local
]

# Runner.via/2 becomes:
def via(runner, workflow_id) do
  {:via, Horde.Registry, {Module.concat(runner, Registry), {Worker, workflow_id}}}
end
```

**Trade-offs:**
- ✅ Drop-in replacement for Registry/DynamicSupervisor API
- ✅ Automatic process redistribution on node failure
- ✅ Quorum mode prevents split-brain
- ⚠️ Transient duplicates during netsplit (without quorum mode)
- ⚠️ No state transfer — Worker state must survive via Store checkpoint/resume
- ⚠️ Adds `delta_crdt` + `libring` as transitive dependencies
- ⚠️ 300ms convergence window — not suitable if you need immediate consistency

**Verdict:** Good fit for a `runic_horde` package. Provides distributed supervision + registry with minimal code. Appropriate when workflows can tolerate brief duplicate execution during netsplits (most data pipelines) or when quorum mode is acceptable.

---

### 2.2 Syn

**Library:** [ostinelli/syn](https://github.com/ostinelli/syn)  
**Deps:** None (pure Erlang)  
**What it is:** Distributed process registry + process groups with metadata, scopes, event callbacks, and pub/sub.

#### Architecture

Syn uses an authority-node model: all mutations for a PID are routed to that PID's node via `gen_server:call`. The authority node writes to local ETS and broadcasts the change asynchronously to all peers in the scope. Reads are always local ETS lookups — O(1), no network.

The key differentiators from `:pg` and Horde:

1. **Scopes** — Independent subclusters. A node can join only the scopes it cares about. Data is replicated only within a scope, not globally. Perfect for isolating workflow registration from other concerns.

2. **Metadata** — Every registry entry and group membership carries arbitrary metadata (any Erlang term), replicated to all nodes. Runic can store Worker state summaries (status, step count, priority) directly in the registration.

3. **Event callbacks** — `on_process_registered`, `on_process_unregistered`, `on_process_joined`, `on_process_left` fire on every node in the scope. Enables cluster-wide observability without polling.

4. **Conflict resolution** — Custom `resolve_registry_conflict/4` callback for netsplit recovery. You choose the winner based on metadata, timestamps, or domain logic.

5. **Pub/Sub + multi_call** — `syn:publish/3` fans out to all group members. `syn:multi_call/4` is a synchronous fan-out with timeout — useful for coordinated operations.

#### Runic Integration

**What it provides:**
- **Worker registration with metadata** — Register Workers with status, priority, and node capability info. Lookup includes metadata — callers can make routing decisions without a GenServer call.
- **Compute node grouping** — Process groups with metadata replace `:pg` for capability advertisement. Metadata carries load info, hardware capabilities, etc.
- **Lifecycle callbacks** — `on_process_unregistered` triggers cluster-wide notification when a Worker crashes. Can drive automatic resume-from-Store without relying on supervision.
- **Scoped isolation** — `:runic_workers` scope for Worker registration, `:runic_compute` scope for compute node groups. Nodes that only run compute don't need to participate in Worker registration.

**How it plugs in:**

```elixir
# Worker registration with metadata
:syn.register(:runic_workers, {:workflow, workflow_id}, self(), %{
  status: :running,
  node: node(),
  started_at: System.monotonic_time(:millisecond)
})

# Lookup returns pid + metadata
case :syn.lookup(:runic_workers, {:workflow, workflow_id}) do
  {pid, meta} -> {:ok, pid, meta}
  :undefined -> {:error, :not_found}
end

# via-tuple support
GenServer.start_link(Worker, opts,
  name: {:via, :syn, {:runic_workers, {:workflow, workflow_id}}})

# Compute node capability groups with metadata
:syn.join(:runic_compute, :gpu, self(), %{
  vram_gb: 24,
  load: 0.3,
  model: "A100"
})

# Query GPU nodes with their metadata
gpu_nodes = :syn.members(:runic_compute, :gpu)
# [{pid1, %{vram_gb: 24, load: 0.3, ...}}, ...]
```

**Trade-offs:**
- ✅ Zero dependencies (pure Erlang)
- ✅ Metadata on every entry — richer than `:pg` or Horde
- ✅ Scopes for workload isolation
- ✅ Event callbacks for cluster-wide observability
- ✅ Built-in pub/sub and multi_call
- ✅ Custom conflict resolution
- ⚠️ No distributed supervision — doesn't restart crashed Workers on other nodes (pair with Horde or manual resume-from-Store)
- ⚠️ Eventually consistent (same as Horde and `:pg`)
- ⚠️ External dependency (though minimal — single Erlang module)

**Verdict:** Excellent fit for distributed registration and group management in Runic core (or a `runic_syn` package). Syn's metadata + scopes + callbacks provide significantly more than `:pg` with zero transitive deps. The lack of distributed supervision is fine — Runic's Store + resume mechanism handles Worker recovery.

---

### 2.3 Horde vs Syn vs `:pg` Summary

| Capability | `:pg` | Syn | Horde |
|---|---|---|---|
| Unique registry (name → pid) | ❌ | ✅ + metadata | ✅ |
| Process groups | ✅ | ✅ + metadata | Via Registry |
| Distributed supervision | ❌ | ❌ | ✅ |
| Metadata on entries | ❌ | ✅ any term | ❌ |
| Scopes / subclusters | ✅ | ✅ (first-class) | ❌ |
| Event callbacks | monitor/2 | ✅ full lifecycle | ❌ |
| Pub/Sub | ❌ | ✅ built-in | ❌ |
| Conflict resolution | N/A | ✅ custom callback | CRDT merge |
| Dependencies | Zero (OTP) | Zero (Erlang) | `delta_crdt`, `libring` |
| API compatibility | OTP `:pg` | `:via` tuple | OTP Registry/DynSup |

**Recommendation:**
- **Core Runic (no deps):** Use `:pg` for discovery as planned in Phase 8.
- **`runic_syn` package:** Syn for rich distributed registration with metadata and callbacks. Best balance of features and simplicity.
- **`runic_horde` package:** Horde for distributed supervision (automatic Worker restart on node failure). Can be combined with Syn for registration.

---

## 3. Persistence / Store Adapters

### 3.1 RocksDB Journal (from libbit)

**Source:** `~/wrk/libbit/apps/core/lib/core/workflow_management/journal.ex`  
**Deps:** `rocksdb` (Erlang NIF binding)  
**What it is:** A RocksDB-backed append-only journal with partitioned column families, materialized state, sequence tracking, and snapshot/checkpoint support. Inspired by [Restate](https://restate.dev/).

#### Architecture

The Journal provides two modes:

**Partitioned mode** — Designed for high-throughput multi-workflow systems. Each partition (default: 24) has its own column family triplet: `p{N}_journals`, `p{N}_state`, `p{N}_metadata`. Workflows are assigned to partitions via `phash2(workflow_id) % num_partitions`. This distributes write load across RocksDB's write buffers and reduces lock contention.

**Non-partitioned mode** — Simple single-CF mode for backward compatibility or simple use cases.

Key operations:
- `append_to_partition/5` — Atomic append with auto-incrementing sequence via `write_batch`. Supports optimistic concurrency via `expected_sequence`.
- `read_stream_from_partition/3` — Prefix-scan iterator over `workflow_id:padded_seq` keys.
- `put_state_in_partition/5` / `get_state_from_partition/4` — Key-value materialized state per workflow.
- `create_checkpoint/2` — RocksDB hardlink-based checkpoint (near-instant, disk-efficient).
- `create_snapshot/1` — Point-in-time consistent read snapshot.

#### Runic Store Adapter Mapping

```elixir
defmodule Runic.Runner.Store.RocksDB do
  @behaviour Runic.Runner.Store

  # Core
  def init_store(opts) do
    path = Keyword.fetch!(opts, :path)
    partitions = Keyword.get(opts, :partitions, 24)
    {:ok, db_ref} = Journal.open_partitioned(path, partitions)
    {:ok, %{db: db_ref, partitions: partitions}}
  end

  # Event-sourced (stream semantics)
  def append(workflow_id, events, state) do
    config = Journal.partition_config_for(workflow_id, state.partitions)
    encoded = Enum.map(events, &%{type: event_type(&1), payload: &1})
    # Append each event individually (or batch via write_batch)
    Enum.reduce_while(encoded, {:ok, 0}, fn entry, {:ok, _seq} ->
      case Journal.append_to_partition(state.db, to_string(workflow_id), entry, config) do
        {:ok, seq} -> {:cont, {:ok, seq}}
        error -> {:halt, error}
      end
    end)
  end

  def stream(workflow_id, state) do
    config = Journal.partition_config_for(workflow_id, state.partitions)
    case Journal.read_stream_from_partition(state.db, to_string(workflow_id), config) do
      {:ok, entries} -> {:ok, Enum.map(entries, &decode_event/1)}
      error -> error
    end
  end

  # Fact storage via materialized state
  def save_fact(fact_hash, value, state) do
    wf_id = "facts"  # or use a dedicated partition
    config = Journal.partition_config_for(wf_id, state.partitions)
    Journal.put_state_in_partition(state.db, wf_id, to_string(fact_hash), value, config)
  end

  def load_fact(fact_hash, state) do
    wf_id = "facts"
    config = Journal.partition_config_for(wf_id, state.partitions)
    Journal.get_state_from_partition(state.db, wf_id, to_string(fact_hash), config)
  end

  # Snapshot via RocksDB checkpoint
  def save_snapshot(workflow_id, cursor, snapshot_binary, state) do
    config = Journal.partition_config_for(workflow_id, state.partitions)
    Journal.put_state_in_partition(
      state.db, to_string(workflow_id), "snapshot",
      %{cursor: cursor, data: snapshot_binary}, config)
  end
end
```

**Trade-offs:**
- ✅ Extremely fast — RocksDB is orders of magnitude faster than Postgres for append-only workloads
- ✅ Embedded — no external database process, no network I/O
- ✅ Partitioned column families distribute write contention
- ✅ Hardlink-based checkpoints are near-instant and disk-efficient
- ✅ Point-in-time snapshots for consistent reads
- ✅ Optimistic concurrency via `expected_sequence`
- ⚠️ Single-node only — RocksDB doesn't replicate. Not suitable for distributed Store without an additional replication layer.
- ⚠️ NIF dependency — `rocksdb` is a C++ NIF. Compile complexity, potential for scheduler blocking on long operations.
- ⚠️ No query language — prefix-scan only. Can't do "find all workflows with status X".

**Verdict:** Ideal for single-node, high-throughput Runic deployments. A `runic_rocksdb` package is high-value — it would be the fastest Store adapter by a large margin. The partitioned architecture from libbit maps cleanly to Runic's multi-workflow-per-Runner model.

---

### 3.2 SQLite (via exqlite / ecto_sqlite3)

**Deps:** `exqlite` (C NIF), optionally `ecto_sqlite3` for Ecto integration  
**What it is:** Embedded SQL database. Single file, zero-config, ACID transactions.

#### Why SQLite for Runic?

SQLite occupies a unique niche: it's a **real SQL database** that's **embedded** (no external process). With WAL mode (default in ecto_sqlite3), it supports concurrent reads with a single writer — sufficient for a single Runner's workflow persistence.

Key properties:
- WAL journal mode enables concurrent reads while writing
- ACID transactions with configurable sync modes
- Full SQL query capability — can query across workflows
- Single file — trivially portable, backupable
- `IMMEDIATE` transaction mode prevents write starvation under concurrent load

#### Runic Store Adapter

```elixir
defmodule Runic.Runner.Store.SQLite do
  @behaviour Runic.Runner.Store

  def init_store(opts) do
    db_path = Keyword.fetch!(opts, :database)
    {:ok, conn} = Exqlite.Sqlite3.open(db_path)
    create_tables(conn)
    {:ok, %{conn: conn}}
  end

  def append(workflow_id, events, state) do
    Exqlite.Sqlite3.execute(state.conn, "BEGIN IMMEDIATE")
    for {event, idx} <- Enum.with_index(events) do
      Exqlite.Sqlite3.execute(state.conn,
        "INSERT INTO events (workflow_id, seq, type, data) VALUES (?, ?, ?, ?)",
        [workflow_id, idx, event_type(event), :erlang.term_to_binary(event)])
    end
    Exqlite.Sqlite3.execute(state.conn, "COMMIT")
    {:ok, length(events)}
  end

  def stream(workflow_id, state) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(state.conn,
      "SELECT data FROM events WHERE workflow_id = ? ORDER BY seq")
    events = collect_rows(stmt, [workflow_id])
    {:ok, Enum.map(events, &:erlang.binary_to_term/1)}
  end

  # save_fact / load_fact map to a simple KV table
  def save_fact(hash, value, state) do
    Exqlite.Sqlite3.execute(state.conn,
      "INSERT OR REPLACE INTO facts (hash, value) VALUES (?, ?)",
      [hash, :erlang.term_to_binary(value)])
  end
end
```

Or with Ecto for a richer experience:

```elixir
defmodule Runic.Runner.Store.Ecto.SQLite do
  # Uses ecto_sqlite3 adapter
  # Schema: events table, facts table, snapshots table
  # Ecto migrations for schema management
  # Repo pattern for connection pooling
end
```

**Trade-offs:**
- ✅ Zero infrastructure — single file, no external database
- ✅ ACID transactions
- ✅ Full SQL — queryable event history, analytics on workflow data
- ✅ Portable — copy the file to move the entire store
- ✅ Ecto integration available via `ecto_sqlite3`
- ⚠️ Single-writer — only one process can write at a time (WAL helps with concurrent reads)
- ⚠️ Not suitable for distributed Store (single file, no replication)
- ⚠️ Slower than RocksDB for pure append workloads
- ⚠️ NIF dependency (exqlite compiles C code)

**Verdict:** Excellent for single-node Runic deployments where queryability matters more than raw throughput. A `runic_sqlite` or generic `runic_ecto` Store adapter is high-value. The Ecto path is especially attractive because it works with both SQLite and Postgres via adapter swap.

---

### 3.3 Commanded EventStore (Postgres)

**Library:** [commanded/eventstore](https://github.com/commanded/eventstore)  
**Deps:** `postgrex`, `jason`, `gen_stage`  
**What it is:** Production-grade, Postgres-backed, append-only event store with subscriptions, snapshots, and optimistic concurrency.

#### Architecture

EventStore uses five Postgres tables (`streams`, `events`, `stream_events`, `subscriptions`, `snapshots`) with a sophisticated notification pipeline:

1. Appending events triggers a Postgres `NOTIFY` on a channel.
2. A `GenStage` pipeline (`Listener` → `Publisher`) consumes notifications, re-reads the events from the database, and broadcasts to in-process subscribers.
3. Persistent subscriptions use `pg_advisory_lock` for exclusive ownership — only one node processes a given subscription at a time. This gives exactly-once delivery semantics across a cluster without distributed Erlang.
4. Optimistic concurrency via `UNIQUE (stream_id, stream_version)` constraint — concurrent writers to the same stream get `{:error, :wrong_expected_version}`.

#### Runic Store Adapter Mapping

| `Runic.Runner.Store` | EventStore API | Notes |
|---|---|---|
| `append/3` | `append_to_stream/4` | Wrap Runic events in `%EventData{}`. Use workflow_id as stream_uuid. |
| `stream/2` | `stream_forward/3` | Returns lazy `Elixir.Stream`. Map `%RecordedEvent{}` back to Runic events. |
| `save_snapshot/4` | `record_snapshot/2` | Maps to `%SnapshotData{}`. Upsert by source_uuid. |
| `load_snapshot/2` | `read_snapshot/2` | Direct mapping. |
| `save_fact/3` | `record_snapshot/2` (reuse) | Store facts as "snapshots" with `source_type: "runic_fact"`. |
| `load_fact/2` | `read_snapshot/2` | Lookup by fact hash as source_uuid. |
| `save/3` (legacy) | `append_to_stream/4` | Append full log as events. |
| `load/2` (legacy) | `read_stream_forward/4` | Read all events, reconstruct log. |

```elixir
defmodule Runic.Runner.Store.EventStore do
  @behaviour Runic.Runner.Store

  def init_store(opts) do
    event_store = Keyword.fetch!(opts, :event_store)
    {:ok, %{event_store: event_store}}
  end

  def append(workflow_id, events, state) do
    event_data = Enum.map(events, fn event ->
      %EventStore.EventData{
        event_type: to_string(event.__struct__),
        data: event
      }
    end)
    case state.event_store.append_to_stream(
      to_string(workflow_id), :any_version, event_data) do
      :ok -> {:ok, length(events)}
      error -> error
    end
  end

  def stream(workflow_id, state) do
    stream = state.event_store.stream_forward(to_string(workflow_id))
    {:ok, Stream.map(stream, & &1.data)}
  end
end
```

**Additional capability — Persistent Subscriptions:**

EventStore's persistent subscriptions could power a **reactive workflow coordinator** — subscribe to workflow event streams and trigger actions (resume stalled workflows, send notifications, update read models) cluster-wide:

```elixir
# Subscribe to all workflow events across the cluster
{:ok, sub} = MyEventStore.subscribe_to_all_streams(
  "runic_coordinator",
  self(),
  start_from: :current,
  concurrency_limit: 3,
  partition_by: fn event -> event.stream_uuid end
)
```

**Trade-offs:**
- ✅ Production-proven (used by Commanded in many production systems)
- ✅ Postgres is well-understood infrastructure
- ✅ Optimistic concurrency built-in
- ✅ Persistent subscriptions with at-least-once delivery
- ✅ Cluster-wide subscription exclusivity via advisory locks
- ✅ Lazy streaming (doesn't load all events into memory)
- ✅ External transaction support — can atomically write events + projections
- ⚠️ Requires Postgres
- ⚠️ Heavyweight dependency tree (`postgrex`, `gen_stage`, etc.)
- ⚠️ `save_fact`/`load_fact` requires repurposing the snapshots table
- ⚠️ Performance bounded by Postgres — slower than embedded stores for pure append

**Verdict:** The strongest option for production Runic deployments with existing Postgres infrastructure. The subscription system is uniquely valuable — it enables reactive patterns that no other Store adapter provides. A `runic_eventstore` package is high-value.

---

### 3.4 Postgres (via Postgrex / Ecto directly)

**Deps:** `postgrex` (raw) or `ecto` + `ecto_sql` + `postgrex` (Ecto)  
**What it is:** Direct Postgres integration without the EventStore abstraction.

#### Why Go Direct?

Commanded EventStore brings a lot of opinions (event sourcing patterns, subscription management, schema design). If Runic only needs append + stream + snapshot, a direct Postgrex/Ecto adapter is simpler and gives full control over the schema.

#### Schema Design

```sql
-- Minimal schema for Runic Store
CREATE TABLE runic_events (
  id BIGSERIAL PRIMARY KEY,
  workflow_id TEXT NOT NULL,
  seq INTEGER NOT NULL,
  event_type TEXT NOT NULL,
  data BYTEA NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (workflow_id, seq)
);

CREATE TABLE runic_snapshots (
  workflow_id TEXT PRIMARY KEY,
  cursor BIGINT NOT NULL,
  data BYTEA NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE runic_facts (
  hash TEXT PRIMARY KEY,
  value BYTEA NOT NULL
);

CREATE INDEX idx_events_workflow ON runic_events (workflow_id, seq);
```

#### Ecto-Based Store Adapter

```elixir
defmodule Runic.Runner.Store.Ecto do
  @behaviour Runic.Runner.Store

  def init_store(opts) do
    repo = Keyword.fetch!(opts, :repo)
    {:ok, %{repo: repo}}
  end

  def append(workflow_id, events, %{repo: repo}) do
    entries = Enum.with_index(events, fn event, idx ->
      %{workflow_id: workflow_id, seq: idx, event_type: event_type(event),
        data: :erlang.term_to_binary(event), created_at: DateTime.utc_now()}
    end)
    {count, _} = repo.insert_all("runic_events", entries)
    {:ok, count}
  end

  def stream(workflow_id, %{repo: repo}) do
    query = from e in "runic_events",
      where: e.workflow_id == ^workflow_id,
      order_by: e.seq,
      select: e.data
    {:ok, repo.all(query) |> Enum.map(&:erlang.binary_to_term/1)}
  end
end
```

**The Ecto adapter is notable because it's database-agnostic.** The same `Runic.Runner.Store.Ecto` module works with:
- Postgres (via `postgrex`)
- SQLite (via `ecto_sqlite3`)
- MySQL (via `myxql`)
- Any future Ecto adapter

This makes a single `runic_ecto` package that covers multiple databases.

**Trade-offs:**
- ✅ Full control over schema and queries
- ✅ Database-agnostic via Ecto adapters
- ✅ No extra dependencies beyond what most Phoenix apps already have
- ✅ Can co-locate in the same database as the application
- ✅ Ecto migrations for schema management
- ⚠️ No subscriptions (unlike EventStore) — poll-based or external pub/sub needed
- ⚠️ Must implement optimistic concurrency manually (UNIQUE constraint + rescue)
- ⚠️ No built-in serialization — must handle event encoding/decoding

**Verdict:** The most pragmatic option. A `runic_ecto` package providing a generic Ecto-based Store adapter is probably the single highest-value integration package for adoption, since most Elixir apps already have Ecto + a database.

---

### 3.5 Persistence Comparison

| Property | ETS (built-in) | RocksDB | SQLite | Postgres (Ecto) | EventStore |
|---|---|---|---|---|---|
| **Durability** | ❌ in-memory | ✅ WAL + fsync | ✅ WAL + fsync | ✅ WAL + fsync | ✅ Postgres |
| **Performance** | Very fast | Very fast | Fast | Moderate | Moderate |
| **Infrastructure** | None | None (embedded NIF) | None (embedded NIF) | Postgres server | Postgres server |
| **Queryability** | Limited | Prefix-scan only | Full SQL | Full SQL | Stream-oriented |
| **Distribution** | ❌ | ❌ | ❌ | ✅ (Postgres replication) | ✅ (Postgres + advisory locks) |
| **Subscriptions** | ❌ | ❌ | ❌ | ❌ (DIY) | ✅ built-in |
| **Ecto compat** | ❌ | ❌ | ✅ (ecto_sqlite3) | ✅ | ❌ (own schema) |
| **Fact storage** | ✅ (ETS) | ✅ (KV) | ✅ (table) | ✅ (table) | ⚠️ (via snapshots) |
| **Best for** | Dev/test | High-throughput single-node | Simple single-node | Production multi-node | Event-sourced production |

---

## 4. Distributed Actor Frameworks

### 4.1 Mesh

**Library:** [eigr/mesh](https://github.com/eigr/mesh)  
**Deps:** `libcluster`  
**What it is:** Capability-based distributed actor system with automatic sharding, clustering, and lazy activation.

#### Architecture

Mesh hashes actor IDs into 4096 shards, maps shards to nodes via capability groups, and lazily activates GenServer actors on first invocation. Actors are supervised with `restart: :temporary` — they don't auto-restart on crash but are recreated on next call.

Key design:
- `Mesh.call(%Request{module: MyActor, id: "abc", capability: :gpu, payload: msg})` — routes to the correct node, finds or creates the actor, forwards the message.
- Capabilities isolate workload types — `:gpu` nodes only handle `:gpu` actors.
- Coordinated rebalancing with circuit breaker when nodes join/leave.

#### Runic Integration

Mesh occupies a different layer than Runic's existing abstractions. Rather than plugging into a Store or Executor, Mesh could **wrap Runic Workers as distributed actors**:

```elixir
defmodule Runic.MeshWorker do
  use GenServer

  def start_link(id, init_arg) do
    GenServer.start_link(__MODULE__, Map.put(init_arg, :workflow_id, id))
  end

  def init(args) do
    # Resume workflow from Store or create new
    workflow = load_or_create(args.workflow_id, args)
    {:ok, %{workflow: workflow, ...}}
  end

  def handle_call({:run, input}, _from, state) do
    # Execute workflow step
    {:reply, result, new_state}
  end
end

# Client usage:
Mesh.call(%Mesh.Request{
  module: Runic.MeshWorker,
  id: "workflow-123",
  capability: :workflow,
  payload: {:run, input}
})
```

**Trade-offs:**
- ✅ Automatic sharding — workflows distribute across nodes by ID
- ✅ Capability routing — route ML workflows to GPU nodes, etc.
- ✅ Lazy activation — Workers start on first invocation, no pre-registration
- ✅ Simple API — 4 functions total
- ⚠️ Very new library (v0.1.4, 147 total downloads as of writing)
- ⚠️ No state persistence — must pair with Runic Store
- ⚠️ Eventual consistency during rebalancing — calls may fail briefly
- ⚠️ `restart: :temporary` — no auto-restart on crash
- ⚠️ Overlaps with Runic's Runner/Worker model — unclear where Runic ends and Mesh begins

**Verdict:** Interesting but premature. The capability-based routing concept is compelling for heterogeneous clusters, but Mesh is too young and overlaps significantly with what Phase 8's `Executor.Distributed` + `:pg` capability groups already provide. Worth watching. A future `runic_mesh` package could wrap Workers as Mesh actors, but it's not a priority.

---

## 5. Integration Matrix

### By Runic Layer

```
                          ┌──────────────────────────────────────────┐
                          │         Integration Layer                │
  Library                 │ Store │ Registry │ Executor │ Supervisor │
  ────────────────────────┼───────┼──────────┼──────────┼────────────┤
  Horde                   │       │    ✅    │          │     ✅     │
  Syn                     │       │    ✅    │          │            │
  :pg (OTP)               │       │    ✅    │          │            │
  RocksDB Journal         │  ✅   │          │          │            │
  SQLite (exqlite/ecto)   │  ✅   │          │          │            │
  Commanded EventStore    │  ✅   │          │          │            │
  Postgres (Ecto)         │  ✅   │          │          │            │
  Mesh                    │       │          │    ✅    │     ✅     │
  Ra / Khepri             │  ✅   │    ✅    │          │            │
```

### By Deployment Scenario

| Scenario | Store | Registry | Supervision | Package |
|---|---|---|---|---|
| **Dev / Testing** | ETS (built-in) | Elixir Registry | DynamicSupervisor | Core Runic |
| **Single-node production** | SQLite or RocksDB | Elixir Registry | DynamicSupervisor | `runic_ecto` or `runic_rocksdb` |
| **Multi-node, Postgres** | EventStore or Ecto/Postgres | Syn or `:pg` | DynamicSupervisor + Store resume | `runic_eventstore` or `runic_ecto` + `runic_syn` |
| **Multi-node, auto-failover** | Ecto/Postgres | Horde.Registry | Horde.DynamicSupervisor | `runic_horde` + `runic_ecto` |
| **Multi-node, strong consistency** | Khepri | Ra-Registry | DynamicSupervisor + Ra coordination | `runic_raft` |
| **Heterogeneous cluster (GPU/CPU)** | Any | `:pg` or Syn | Core + Executor.Distributed | Core Phase 8 |

---

## 6. Recommended Packages

### Tier 1: High Value, Broad Adoption

1. **`runic_ecto`** — Generic Ecto-based Store adapter. Works with Postgres, SQLite, MySQL. Includes Ecto migrations for schema setup. This is the single highest-impact integration package because most Elixir apps already use Ecto.

2. **`runic_eventstore`** — Commanded EventStore-based Store adapter. For teams already using event sourcing. Adds subscription-based reactive patterns.

### Tier 2: Specialized

3. **`runic_horde`** — Horde-based distributed Runner with automatic Worker failover. Replaces Registry + DynamicSupervisor with Horde equivalents. Adds process redistribution on node failure.

4. **`runic_rocksdb`** — RocksDB-based Store adapter using the partitioned Journal pattern from libbit. For high-throughput single-node deployments. Highest performance Store option.

5. **`runic_syn`** — Syn-based distributed registration with metadata-rich Worker discovery, scoped subclusters, and lifecycle callbacks. Can be combined with any Store adapter.

### Tier 3: Future / Research

6. **`runic_raft`** — Ra/Khepri-based distributed coordination and Store. For mission-critical workflows requiring strong consistency.

7. **`runic_mesh`** — Mesh-based distributed Worker activation. Interesting but premature — monitor Mesh maturity.

### Package Dependency Graph

```
runic (core)
├── runic_ecto           (ecto, ecto_sql)
│   ├── + postgrex       → Postgres
│   └── + ecto_sqlite3   → SQLite
├── runic_eventstore     (commanded/eventstore, postgrex)
├── runic_rocksdb        (rocksdb NIF)
├── runic_horde          (horde → delta_crdt, libring)
├── runic_syn            (syn)
└── runic_raft           (ra, optionally khepri)
```

Each package depends only on `runic` core + its specific library. No cross-dependencies between integration packages.

---

## 7. Raft-Based Coordination (Ra / Khepri)

This section expands the Ra/Khepri analysis from [phase-8-distribution-primitives.md](phase-8-distribution-primitives.md) into concrete integration designs for a `runic_raft` package.

### 7.1 Ra Overview

**Library:** [rabbitmq/ra](https://github.com/rabbitmq/ra)
**Deps:** None (OTP only — Ra is part of the RabbitMQ/OTP ecosystem)
**What it is:** Raft consensus library for Erlang/Elixir. Provides replicated state machines with strong consistency guarantees.

#### Architecture

Ra implements the Raft consensus protocol with several production-hardened features:

- **Replicated state machine**: All state changes go through the Raft log. Every member applies the same sequence of commands deterministically. The state machine's `apply/3` callback returns `{new_state, reply, effects}` — effects are side effects executed only on the leader.
- **Server IDs**: `{name :: atom(), node :: node()}` — stable registered names, not PIDs. Survive process restarts.
- **Effect system**: Clean separation of deterministic state from side effects. Key effects: `{:send_msg, to, msg}`, `{:monitor, :process, pid}`, `{:timer, name, ms}`, `{:release_cursor, idx, state}` (trigger snapshot).
- **Shared WAL**: All Ra clusters on a node share one write-ahead log — enables thousands of Ra clusters per node with minimal overhead.
- **State enter**: `state_enter/2` callback fires on role change (follower → leader, etc.) — re-issue monitors here to handle leader failover correctly.
- **Versioning**: `version/0` + `which_module/1` for safe rolling upgrades of the state machine without cluster downtime.
- **Queries**: `local_query/2` (stale OK), `leader_query/2`, `consistent_query/2` (linearizable).

#### Runic Integration: Raft Registry State Machine

A Ra state machine tracking `{workflow_id => {node, pid, status}}` with linearizable reads and writes:

```elixir
defmodule RunicRaft.Registry.StateMachine do
  @behaviour :ra_machine

  def init(_config), do: %{workflows: %{}, claims: %{}}

  def apply(_meta, {:register, workflow_id, node, pid}, state) do
    case state.workflows do
      %{^workflow_id => _existing} ->
        {state, {:error, :already_registered}}
      _ ->
        state = put_in(state, [:workflows, workflow_id], %{node: node, pid: pid})
        effects = [{:monitor, :process, pid}]
        {state, :ok, effects}
    end
  end

  def apply(_meta, {:down, pid, _reason}, state) do
    workflows = for {id, %{pid: ^pid}} <- state.workflows, into: %{}, do: {id, nil}
    state = %{state | workflows: Map.drop(state.workflows, Map.keys(workflows))}
    {state, :ok}
  end

  def state_enter(:leader, state) do
    # Re-issue monitors for all registered pids on leader change
    for {_id, %{pid: pid}} <- state.workflows, do: {:monitor, :process, pid}
  end
  def state_enter(_, _), do: []
end
```

**Key design notes:**
- `state_enter/2` re-issues monitors on leader change — critical for correctness. Without this, process crashes during a leader election are silently lost.
- `apply/3` is pure — no `distributed_alive?` or other side effects inside the state machine. All side effects expressed via the effects list.
- Workflow-specific commands beyond registration: `{:claim_runnable, runnable_id, worker_pid}` and `{:complete_runnable, runnable_id, result}` enable distributed work claiming with exactly-once semantics.

---

### 7.2 Khepri Overview

**Library:** [rabbitmq/khepri](https://github.com/rabbitmq/khepri)
**Deps:** `ra`
**What it is:** Tree-structured distributed database built on Ra. Provides a hierarchical namespace with CRUD operations, transactions, projections, and ephemeral nodes.

#### Architecture

- **Hierarchical namespace**: Paths like `[:runic, :workers, workflow_id]` — natural fit for workflow/runnable state organization.
- **CRUD + transactions**: `put`, `get`, `delete`, `compare_and_swap`. Read-write transactions are extracted via Horus (bytecode extraction) and executed deterministically inside the Ra state machine.
- **Projections**: ETS-backed materialized views of tree subsets — ultra-low-latency local reads, eventually consistent with writes. Perfect for hot-path lookups that don't need strict consistency.
- **Keep-while conditions**: Ephemeral nodes that auto-delete when a condition becomes false — like ZooKeeper ephemeral znodes. Useful for Worker liveness: a Worker's registration node can be conditioned on the Worker process being alive.
- **Consistency modes**: `favor: :low_latency` (local read from projection/cache) or `favor: :consistency` (fenced read via leader heartbeat).

#### Runic Integration: Khepri Store Adapter

```elixir
defmodule RunicRaft.Store.Khepri do
  @behaviour Runic.Runner.Store

  def init_store(opts) do
    store_id = Keyword.get(opts, :store_id, :runic_store)
    {:ok, %{store_id: store_id}}
  end

  def append(workflow_id, events, state) do
    :khepri.transaction(state.store_id, fn ->
      path = [:runic, :workflows, workflow_id, :events]
      existing = case khepri_tx:get(path) do
        {:ok, events} -> events
        _ -> []
      end
      :ok = khepri_tx:put(path, existing ++ events)
    end)
  end

  def stream(workflow_id, state) do
    case :khepri.get(state.store_id, [:runic, :workflows, workflow_id, :events]) do
      {:ok, events} -> {:ok, events}
      _ -> {:error, :not_found}
    end
  end

  # Fact storage maps naturally to Khepri's tree
  def save_fact(fact_hash, value, state) do
    :khepri.put(state.store_id, [:runic, :facts, fact_hash], value)
  end

  def load_fact(fact_hash, state) do
    case :khepri.get(state.store_id, [:runic, :facts, fact_hash]) do
      {:ok, value} -> {:ok, value}
      _ -> {:error, :not_found}
    end
  end
end
```

**Value proposition:** Khepri gives you a distributed, durable, consistent Store with no external infrastructure — no Postgres, no Redis. The entire cluster state lives in the Ra WAL. Recovery is automatic — restart any node and it replays from its log or receives a snapshot from the leader.

---

### 7.3 Distributed Work Claiming (Exactly-Once Execution)

For workflows where exactly-once execution across a cluster is critical (e.g., saga orchestration, distributed transactions), a Ra state machine provides atomic claim semantics:

```
Worker A: "I want to execute runnable X"  ──▶ Ra leader
Worker B: "I want to execute runnable X"  ──▶ Ra leader
Ra: commits {claim, X, A} first → A wins, B gets {:error, :already_claimed}
```

This is not needed for Scenario A (one Worker owns the workflow) but becomes relevant when multiple Workers coordinate on a shared workflow — for example, a distributed saga where different nodes own different steps.

---

### 7.4 What Raft Gives That OTP Primitives Don't

| Property | `:pg` / `:global` | Ra / Khepri |
|---|---|---|
| **Consistency** | Eventually consistent (pg) / lock-based (global) | Linearizable (Raft quorum) |
| **State machine** | None (just membership) | Custom replicated state with deterministic transitions |
| **Durable coordination** | No (in-memory only) | Yes (WAL + snapshots on disk) |
| **Workflow state as coordination data** | Must store externally | Can embed workflow metadata in the replicated state |
| **Split-brain safety** | pg diverges; global picks a winner | Minority partition is read-only, majority continues |
| **Transaction support** | None | Read-write transactions with atomicity |
| **Process lifecycle** | pg auto-removes on exit; global deregisters | Ra monitors + committed cleanup commands |
| **Leader election** | Manual via :global or custom | Built-in (Raft) |
| **Dependencies** | Zero (OTP stdlib) | `ra` (and `khepri` for the tree store) |

### 7.5 When Each Makes Sense

**Use OTP primitives when:**
- Workflows are not mission-critical coordination (e.g., data pipelines where retry-from-Store is acceptable)
- The cluster is stable (low churn, trusted network)
- Eventual consistency for Worker discovery is fine (the Worker exists or doesn't — stale reads just cause a retry)
- You want zero external dependencies

**Use Ra/Khepri when:**
- Workflow execution is a coordination primitive itself (e.g., saga orchestration, distributed transactions)
- Exactly-once execution semantics are required across nodes
- Split-brain scenarios must be handled correctly (financial, compliance)
- You need durable coordination state that survives full cluster restarts
- You want atomic claim-and-execute semantics (only one node runs a runnable)

### 7.6 Trade-offs

- ✅ Linearizable consistency — strongest guarantee available
- ✅ Durable coordination state — survives full cluster restarts
- ✅ Split-brain safe — minority partition is read-only, no divergent state
- ✅ Transaction support — atomic read-write operations inside the state machine
- ✅ Shared WAL — thousands of Ra clusters per node
- ✅ Process monitoring via committed commands — crash handling is consistent across replicas
- ⚠️ All replicated state is in-memory on every node — not suitable for workflows with very large fact values (use fact hashes in the event stream, store blobs externally)
- ⚠️ Write throughput bounded by Raft consensus (majority quorum per write) — fine for coordination, not for high-frequency fact storage
- ⚠️ Requires `ra` and optionally `khepri` as dependencies
- ⚠️ Operational complexity — Ra clusters need monitoring, capacity planning for WAL/snapshot disk usage

**Verdict:** The right choice for mission-critical distributed workflow coordination. Separate `runic_raft` package with sub-phases: 8R-A (Raft registry state machine), 8R-B (Khepri Store adapter), 8R-C (Distributed work claiming). Not a replacement for `:pg`/OTP primitives in core — a complement for teams that need stronger guarantees.

---

## 8. Combining Options: Deployment Topology Guide

Different deployment scenarios call for different combinations of Store, Registry, Supervision, and Executor. This section provides concrete recipes.

### 8.1 Single-Node: Embedded Everything

**Use case:** CLI tools, single-server apps, development, edge computing.

```
┌─────────────────────────────────────────────┐
│  Runic Runner (single node)                 │
│  ┌──────────────┐  ┌────────────────────┐   │
│  │ Elixir       │  │ Store: RocksDB     │   │
│  │ Registry     │  │ or SQLite/Ecto     │   │
│  └──────────────┘  └────────────────────┘   │
│  ┌──────────────┐  ┌────────────────────┐   │
│  │ Dynamic      │  │ Executor: Task     │   │
│  │ Supervisor   │  │ (local)            │   │
│  └──────────────┘  └────────────────────┘   │
└─────────────────────────────────────────────┘
```

| Layer | Choice | Package |
|---|---|---|
| Store | RocksDB (throughput) or SQLite/Ecto (queryability) | `runic_rocksdb` or `runic_ecto` |
| Registry | Elixir Registry | Core |
| Supervision | DynamicSupervisor | Core |
| Executor | Executor.Task | Core |
| Scheduler | Default, ChainBatching, or Adaptive | Core |

**Why this works:** Zero external infrastructure. RocksDB gives the fastest append-only performance. SQLite gives SQL queryability with Ecto compatibility. Both are embedded NIFs — no external process to manage.

**When to choose RocksDB vs SQLite:**
- RocksDB: High write throughput (>10K events/sec), partitioned column families distribute contention, no query requirements beyond prefix-scan
- SQLite: Need SQL queries across workflows, want Ecto integration, portability (single file backup), lower write volume

---

### 8.2 Multi-Node: Postgres + Eventually Consistent Discovery

**Use case:** Typical SaaS deployment — Postgres already in the stack, multiple app nodes, tolerance for brief inconsistency during deploys/failures.

```
  Node A                     Node B                     Postgres
  ┌──────────────────┐      ┌──────────────────┐      ┌──────────┐
  │ Runner            │      │ Runner            │      │          │
  │  ├─ :pg registry  │◀────▶│  ├─ :pg registry  │      │  Events  │
  │  ├─ Ecto Store ───┼──────┼──┼─ Ecto Store ───┼─────▶│  Facts   │
  │  ├─ Workers       │      │  ├─ Workers       │      │  Snaps   │
  │  └─ Executor.Task │      │  └─ Executor.Dist │      │          │
  └──────────────────┘      └──────────────────┘      └──────────┘
```

| Layer | Choice | Package |
|---|---|---|
| Store | Ecto/Postgres (or EventStore for subscriptions) | `runic_ecto` or `runic_eventstore` |
| Registry | `:pg` (core Phase 8) + optionally Syn for metadata | Core + optionally `runic_syn` |
| Supervision | DynamicSupervisor + Store-based resume | Core |
| Executor | Task (local) + Distributed (remote compute) | Core Phase 8 |

**Why `:pg` + Ecto is the sweet spot:**
- `:pg` gives zero-dep cluster-wide Worker discovery with sub-millisecond local reads
- Postgres/Ecto Store makes workflow state accessible from any node — enables resume-on-different-node after crashes
- No extra dependencies beyond what most Phoenix apps already have
- EventStore adds persistent subscriptions for reactive coordination (e.g., subscribe to all workflow completions)

**Adding Syn for richer discovery:**
- Syn's metadata allows Workers to advertise status, step count, priority directly in the registration — callers can make routing decisions without a GenServer call
- Syn's scoped subclusters isolate workflow registration from compute node discovery
- Syn's event callbacks enable cluster-wide observability without polling

---

### 8.3 Multi-Node: Auto-Failover with Horde

**Use case:** High-availability requirements — Workers must automatically restart on surviving nodes when a node dies. Acceptable trade-off: brief duplicate execution during netsplit.

```
  Node A                     Node B                     Node C
  ┌──────────────────┐      ┌──────────────────┐      ┌──────────────┐
  │ Horde.Registry    │◀───▶│ Horde.Registry    │◀───▶│ Horde.Registry│
  │ Horde.DynSup     │◀───▶│ Horde.DynSup     │◀───▶│ Horde.DynSup │
  │  ├─ Worker W1     │      │  ├─ Worker W3     │      │              │
  │  ├─ Worker W2     │      │                   │      │              │
  │  └─ Ecto Store ──┼─────▶│  Postgres         │◀────┤  Ecto Store  │
  └──────────────────┘      └──────────────────┘      └──────────────┘
                                    ▲
                              Node A dies → W1, W2 restart on B or C
```

| Layer | Choice | Package |
|---|---|---|
| Store | Ecto/Postgres (must be shared for state handoff) | `runic_ecto` |
| Registry | Horde.Registry (CRDT-based, cluster-wide) | `runic_horde` |
| Supervision | Horde.DynamicSupervisor (auto-redistribution) | `runic_horde` |
| Executor | Task (local) + Distributed | Core Phase 8 |

**State handoff pattern:** On Worker `terminate/2`, checkpoint to Ecto Store. On replacement Worker `init/1` (started by Horde on a surviving node), resume from Store. Horde provides the lifecycle; Runic's Store provides the state.

**Quorum mode:** `Horde.UniformQuorumDistribution` prevents split-brain duplicates by shutting down all processes when quorum is lost. Use this when duplicate execution is worse than brief unavailability.

---

### 8.4 Multi-Node: Strong Consistency with Raft

**Use case:** Mission-critical workflows — saga orchestration, financial transactions, compliance-sensitive pipelines where exactly-once execution and split-brain safety are required.

```
  Node A (Ra member)         Node B (Ra member)         Node C (Ra member)
  ┌──────────────────┐      ┌──────────────────┐      ┌──────────────────┐
  │ Ra Registry SM    │◀───▶│ Ra Registry SM    │◀───▶│ Ra Registry SM    │
  │ Khepri Store     │◀───▶│ Khepri Store     │◀───▶│ Khepri Store     │
  │  ├─ Worker W1     │      │  ├─ Worker W2     │      │  ├─ Worker W3     │
  │  └─ Claim SM      │      │  └─ Claim SM      │      │  └─ Claim SM      │
  └──────────────────┘      └──────────────────┘      └──────────────────┘
        │                          │ (leader)                │
        │    All writes through Ra leader (quorum)           │
```

| Layer | Choice | Package |
|---|---|---|
| Store | Khepri (tree-structured, on Ra) | `runic_raft` |
| Registry | Ra state machine (linearizable lookup) | `runic_raft` |
| Coordination | Ra claim state machine (exactly-once execution) | `runic_raft` |
| Supervision | DynamicSupervisor + Ra-coordinated resume | Core + `runic_raft` |
| Executor | Task + Distributed | Core Phase 8 |

**When this is worth the complexity:**
- Multiple Workers can coordinate on a shared workflow (work claiming prevents double execution)
- Split-brain: minority partition becomes read-only, majority continues — no divergent state
- Durable coordination survives full cluster restarts — no "who was doing what?" after power failure
- All coordination state (registry, claims, workflow metadata) is consistent and queryable

**Limitation:** Khepri stores all replicated state in-memory on every node. Large fact values should be stored externally (Postgres, S3) with only hashes in the Khepri tree.

---

### 8.5 Heterogeneous Cluster: GPU/CPU Split

**Use case:** ML inference pipelines, mixed-hardware clusters where runnables need to be routed to specific node types.

```
  Coordinator Node              CPU Pool                    GPU Pool
  ┌──────────────────┐      ┌──────────────┐           ┌──────────────┐
  │ Runner            │      │ ComputeNode   │           │ ComputeNode   │
  │  ├─ Worker         │      │  ├─ TaskSup   │           │  ├─ TaskSup   │
  │  │  ├─ Scheduler   │      │  └─ :pg caps  │           │  └─ :pg caps  │
  │  │  │  (Distrib.)  │      │    [:cpu]     │           │    [:gpu]     │
  │  │  └─ Executor    │──────▶              │           │              │
  │  │     (Distrib.)  │──────────────────────────────▶│              │
  │  └─ Ecto Store    │      └──────────────┘           └──────────────┘
  └──────────────────┘
```

| Layer | Choice | Package |
|---|---|---|
| Store | Ecto/Postgres (coordinator has DB access) | `runic_ecto` |
| Registry | `:pg` with capability groups | Core Phase 8 |
| Executor | Executor.Distributed with capability-based node_selector | Core Phase 8 |
| Scheduler | Scheduler.Distributed (annotates runnables with node hints) | Core Phase 8 |

**Compute nodes are minimal:** Just a `Task.Supervisor` and a `:pg` capability advertiser. The `work_fn` closure carries all dependencies — no Runic.Runner or Workflow needed on compute nodes.

**Node selector strategies:**
- `random(pg_scope, group)` — random member from a capability group
- `round_robin(pg_scope, group)` — round-robin across group members
- `local_first(pg_scope, group)` — prefer local execution, fall back to remote
- Custom: query compute node load via `:erpc.call(node, :erlang, :statistics, [:run_queue])` and route to least-loaded

---

### 8.6 Combination Compatibility Matrix

Not all combinations are sensible. This matrix shows which combinations are tested/recommended:

| Store ↓ / Registry → | Elixir Registry | `:pg` | Syn | Horde | Ra |
|---|---|---|---|---|---|
| **ETS (built-in)** | ✅ Default | ✅ | ✅ | ✅ | ✅ |
| **RocksDB** | ✅ | ✅ | ✅ | ⚠️ (single-node store with multi-node registry) | ❌ |
| **SQLite/Ecto** | ✅ | ✅ | ✅ | ⚠️ (same caveat) | ❌ |
| **Postgres/Ecto** | ✅ | ✅ | ✅ | ✅ Recommended | ✅ |
| **EventStore** | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Khepri** | ❌ (use Ra registry) | ⚠️ | ⚠️ | ❌ | ✅ Natural pair |

⚠️ = Works but unusual — typically the Registry and Store should have matching distribution properties (both local or both distributed).

---

## 9. Case Study: Libbit

[Libbit](https://github.com/zblanco/libbit) is a platform product built on Runic that provides a no-code workflow builder, sandboxed polyglot execution, and isolated workspaces. It predates Runic's Runner/Worker/Store/Executor layers but demonstrates the architectural patterns that motivated them. Analyzing Libbit reveals how a real platform extends Runic and what adapter combinations serve different deployment modes.

### 9.1 Workspace Supervision Architecture

Libbit's core abstraction is the **Workspace** — an isolated environment containing workflows, databases, storage, and compute resources. Each workspace gets its own supervision tree:

```
Core.Application
├── Registry (Core.WorkspaceRegistry)
├── PartitionSupervisor (Core.WorkspaceSupervisors → DynamicSupervisor)
├── Core.Runtime.WorkspaceManager (loads active workspaces from Postgres on boot)
│
└── per-workspace (started by WorkspaceManager → WorkspaceSupervisor):
    WorkspaceSupervisor (workspace_id)
    ├── Registry (workflow registry — per-workspace, :unique)
    ├── Registry (durable runner registry — per-workspace, :unique)
    ├── Registry (subscription registry — per-workspace, :duplicate)
    ├── WorkflowSupervisor (DynamicSupervisor for WorkflowRunners)
    ├── PartitionSupervisor (Task.Supervisor pool for runnable execution)
    ├── Task.Supervisor (durable runner tasks)
    ├── WorkflowManager (spawns WorkflowRunners based on config)
    │
    ├── [optional] JournalManager (single-writer RocksDB per workspace)
    ├── [optional] EventStoreManager (Commanded EventStore per workspace)
    ├── [optional] SqliteManager (embedded SQLite + dynamic Ecto repo)
    ├── [optional] LitestreamManager (S3 replication of SQLite)
    ├── [optional] SubscriptionSupervisor (EventStore → SQLite projections)
    └── [optional] ScheduleManager (cron-based workflow triggers)
```

**Key design patterns:**

1. **Workspace-scoped isolation**: Each workspace has its own Registry, TaskSupervisor, and storage processes. Workflows in different workspaces are completely isolated — they share nothing. This maps directly to Runic's Runner model where each Runner owns its own Registry, TaskSupervisor, and Store.

2. **Pluggable persistence per workspace**: Workspaces can use `:memory` or `:rocksdb` persistence, configured at the Workspace schema level. The `DurableRunner` accepts a `:persistence` option choosing between `JournalPersistence` (RocksDB) and `EventStorePersistence` (Postgres). This mirrors Runic's Store behaviour — different workspaces can use different Store backends.

3. **PartitionSupervisor for concurrency**: Libbit wraps both `DynamicSupervisor` (for WorkspaceSupervisors) and `Task.Supervisor` (for runnable execution) in `PartitionSupervisor`. This distributes supervision across BEAM schedulers — identical to how Runic's Runner could benefit from partitioned task dispatch.

4. **Manager-as-bootstrap pattern**: `WorkspaceManager` streams active workspaces from Postgres on boot and starts their supervision trees. This is the same pattern as a hypothetical `Runner.Manager` that resumes all persisted workflows from Store on startup.

### 9.2 DurableRunner: Libbit's Pre-Runner Worker

`Core.Runtime.DurableRunner` is Libbit's equivalent of Runic's Worker — a GenServer that durably executes a Runic Workflow with pluggable persistence:

```elixir
# DurableRunner parallels Runic's Worker:
DurableRunner         →  Runic.Runner.Worker
  persistence_module  →  Store behaviour
  pending_tasks       →  active_tasks
  completed_steps     →  applied runnables (via Workflow.apply_runnable)
  persist_event()     →  Store.append()
  replay_entries()    →  Store.stream() + event replay
  enqueue_step()      →  dispatch_runnables()
```

**Architectural lessons:**
- DurableRunner uses `Task.Supervisor.async_nolink` for step execution — exactly the pattern Runic's Executor.Task codifies
- Replay on init (read journal, rebuild state from events) — this is what Runic's `Runner.resume/3` does via `Store.stream` + event application
- DurableRunner tracks `pending_tasks` as `%{ref => {step_hash, input}}` — identical to Worker's `active_tasks` tracking

The main difference: DurableRunner predates Runic's Worker and lacks the Executor/Scheduler/Hook abstractions. Migrating to Runic's Worker with a RocksDB Store adapter would give Libbit all of DurableRunner's functionality plus pluggable scheduling, per-component executors, Promises, and the hook system.

### 9.3 Storage Layer: Disaggregated Architecture

Libbit uses a **disaggregated storage model** within each workspace:

| Storage Layer | Technology | Purpose |
|---|---|---|
| **Event journal** | RocksDB (partitioned) | Workflow execution events, step state, sequence tracking |
| **Read models** | SQLite (per-workspace) | Queryable projections of workflow state, user data |
| **Object storage** | S3/Tigris (via Litestream) | SQLite backup/replication, large file storage |
| **Global state** | Postgres (shared) | Workspace metadata, user accounts, team management |
| **Event bus** | Commanded EventStore (Postgres) | Cross-workspace events, CQRS command routing |

This separation is intentional:
- RocksDB handles the hot path (workflow execution) with minimal latency
- SQLite provides per-workspace queryability without shared-database contention
- S3 provides durability and cross-region replication for SQLite
- Postgres handles the control plane (workspace CRUD, team management)

### 9.4 Infrastructure Provider Abstraction

Libbit defines a `Core.Infrastructure.Provider` behaviour for provisioning compute and storage resources:

```elixir
@callback provision_workspace(workspace_id, opts) :: {:ok, workspace_info} | {:error, term}
@callback provision_runtime(workspace_id, runtime_config, opts) :: {:ok, runtime_info} | {:error, term}
@callback exec_runtime(workspace_id, runtime_id, command, opts) :: {:ok, exec_result} | {:error, term}
@callback provision_storage(workspace_id, bucket_name, opts) :: {:ok, storage_info} | {:error, term}
```

The Fly.io implementation maps each workspace to:
- One Fly App (named `libbit-ws-{workspace_id_prefix}-{suffix}`)
- One or more Fly Machines (runtime environments with configurable CPU/GPU/memory)
- Optional Fly Volumes (persistent storage)
- A Tigris S3 bucket (object storage)

**This is the layer where Runic's Executor.Distributed and ComputeNode would integrate.** Rather than running runnables on generic Fly Machines via `exec_runtime`, Libbit could run ComputeNode supervisors on provisioned Machines and dispatch runnables via `Task.Supervisor.async_nolink({:runic_compute_task_sup, machine_node}, work_fn)`.

### 9.5 Mapping Libbit to Runic's Current Architecture

| Libbit Component | Runic Equivalent | Migration Path |
|---|---|---|
| `WorkspaceSupervisor` | `Runic.Runner` (Supervisor) | Runner per workspace, with distributed option |
| `DurableRunner` | `Runic.Runner.Worker` | Replace with Worker + Store adapter |
| `JournalPersistence` | `Runic.Runner.Store` (RocksDB impl) | Implement `runic_rocksdb` Store adapter |
| `EventStorePersistence` | `Runic.Runner.Store` (EventStore impl) | Implement `runic_eventstore` Store adapter |
| `WorkflowRunner` | `Runic.Runner.Worker` (in-memory mode) | Replace with Worker + ETS Store |
| `WorkflowManager` | `Runner.resume/3` on boot | Manager starts Runners, each Runner resumes Workers from Store |
| `SqliteManager` | `runic_ecto` Store (SQLite adapter) | Use `ecto_sqlite3` as Ecto adapter |
| `LitestreamManager` | External concern (backup) | Unchanged — Litestream replicates the SQLite file regardless |
| `Infrastructure.Provider` | `Executor.Distributed` + `ComputeNode` | Providers provision ComputeNodes; Executor dispatches to them |

---

## 10. Recommended Adapter Combinations for Libbit

### 10.1 Isolated Workspace Mode (Embedded, Single-Node)

**Use case:** Each workspace is an isolated environment with its own embedded storage. Workspaces may run on different machines (Fly Machines, K8S pods, or local dev). No shared database for workflow state.

```
Per-Workspace Machine / Container
┌─────────────────────────────────────────────────────────┐
│  Runic Runner (1 per workspace)                         │
│  ┌──────────────┐  ┌─────────────────────────────────┐  │
│  │ Elixir       │  │ Store: RocksDB (hot path)       │  │
│  │ Registry     │  │   + SQLite/Ecto (read models)   │  │
│  └──────────────┘  └─────────────────────────────────┘  │
│  ┌──────────────┐  ┌─────────────────────────────────┐  │
│  │ Dynamic      │  │ Litestream → S3 (durability)    │  │
│  │ Supervisor   │  │ RocksDB checkpoints → S3        │  │
│  └──────────────┘  └─────────────────────────────────┘  │
│  ┌──────────────┐                                       │
│  │ Executor:    │                                       │
│  │ Task (local) │                                       │
│  │ + sandboxed  │  (polyglot via Fly Machine exec)      │
│  └──────────────┘                                       │
└─────────────────────────────────────────────────────────┘
```

| Layer | Choice | Rationale |
|---|---|---|
| **Store** | `runic_rocksdb` | Fastest append path, partitioned CFs match existing Journal architecture |
| **Read models** | `runic_ecto` + `ecto_sqlite3` | Per-workspace SQLite for queryable projections, already exists in Libbit |
| **Backup** | Litestream (SQLite → S3) + RocksDB checkpoint → S3 | Existing Libbit pattern, near-zero latency impact |
| **Registry** | Elixir Registry | Single-node, no distribution needed |
| **Executor** | Executor.Task | Local execution, sandboxed runtimes via Infrastructure.Provider |

**This is Libbit's current architecture, formalized.** The key insight is that each workspace is self-contained — its entire state lives in local RocksDB + SQLite, replicated to S3 for durability. Workspace migration = restore from S3 on a new machine.

**Packages needed:** `runic_rocksdb`, `runic_ecto` (with `ecto_sqlite3`)

---

### 10.2 Distributed Control Plane Mode (SaaS)

**Use case:** Centralized multi-tenant SaaS — Postgres cluster, multiple app nodes behind a load balancer, workspaces distributed across nodes, need for cross-node workflow coordination.

```
  App Node A                  App Node B                  Infrastructure
  ┌──────────────────┐       ┌──────────────────┐       ┌──────────────────┐
  │ WorkspaceManager  │       │ WorkspaceManager  │       │ Postgres         │
  │ ├─ Runner (ws_1)  │       │ ├─ Runner (ws_3)  │       │  ├─ runic_events │
  │ │  └─ Workers     │       │ │  └─ Workers     │       │  ├─ runic_snaps  │
  │ ├─ Runner (ws_2)  │       │ ├─ Runner (ws_4)  │       │  └─ runic_facts  │
  │ │  └─ Workers     │       │ │  └─ Workers     │       ├──────────────────┤
  │ └─ :pg / Syn      │◀────▶│ └─ :pg / Syn      │       │ EventStore       │
  │    (cluster-wide)  │       │    (cluster-wide)  │       │  (subscriptions) │
  └──────────────────┘       └──────────────────┘       ├──────────────────┤
         │                          │                    │ S3 / Tigris      │
         │                          │                    │  (large objects) │
         └──────────Fly / K8S / ECS─┘                    └──────────────────┘
```

| Layer | Choice | Rationale |
|---|---|---|
| **Store** | `runic_ecto` (Postgres) or `runic_eventstore` | Shared Postgres gives cross-node state access; EventStore adds subscriptions |
| **Registry** | Syn (`runic_syn`) or `:pg` (core) | Syn gives metadata-rich discovery + scoped subclusters; `:pg` is zero-dep |
| **Supervision** | Horde (`runic_horde`) or DynamicSupervisor + Store resume | Horde for auto-failover; DynamicSupervisor + manual resume for simplicity |
| **Executor** | Task (local) + Distributed (for GPU/heavy compute) | Most steps run locally; heavy steps dispatch to compute nodes |
| **Coordination** | Phoenix.PubSub (cluster events) + optionally EventStore subscriptions | PubSub for real-time UI updates; EventStore for durable reactive pipelines |

**Progressive adoption path for Libbit:**

1. **Start:** Replace `DurableRunner` + `JournalPersistence` with `Runic.Runner.Worker` + `runic_ecto` (Postgres). All workflow state in Postgres, accessible from any node.
2. **Add:** Syn registration for cluster-wide workspace/workflow discovery with metadata.
3. **Optionally:** Horde for automatic Worker failover on node death. Workers checkpoint to Ecto Store on terminate, resume on the Horde-selected replacement node.
4. **Stretch:** `runic_eventstore` for persistent subscriptions — subscribe to all workflow completions to drive billing, notifications, audit logs.

**Packages needed:** `runic_ecto`, `runic_syn` or core `:pg`, optionally `runic_horde` and `runic_eventstore`

---

### 10.3 Hybrid Mode: Embedded Execution + Distributed Control Plane

**Use case:** Libbit's most natural architecture — workspaces execute locally with embedded storage for low latency, but a centralized control plane manages workspace lifecycle, scheduling, and cross-workspace coordination.

```
  Control Plane (App Nodes)                        Workspace Machines
  ┌──────────────────────────┐                    ┌─────────────────────┐
  │ Postgres (workspace CRUD) │                    │ Workspace ws_1       │
  │ EventStore (coordination) │◀──subscriptions───│  ├─ RocksDB Store   │
  │ Syn registry (discovery)  │◀──:pg advertise───│  ├─ SQLite models   │
  │ WorkspaceScheduler        │──provision────────▶│  ├─ Runner + Workers│
  │ BillingCoordinator        │                    │  └─ Executor.Task  │
  └──────────────────────────┘                    └─────────────────────┘
         │                                         ┌─────────────────────┐
         │                                         │ Workspace ws_2       │
         └────────provision──────────────────────▶│  ├─ RocksDB Store   │
                                                   │  ├─ SQLite models   │
                                                   │  ├─ Runner + Workers│
                                                   │  └─ Executor.Dist  │
                                                   │       └──▶ GPU node │
                                                   └─────────────────────┘
                                                         │
                                                    S3 (backup/replicate)
```

| Layer | Control Plane | Workspace Machine |
|---|---|---|
| **Store** | `runic_eventstore` (subscriptions for coordination) | `runic_rocksdb` (local hot path) |
| **Read models** | Postgres (global views) | SQLite/Ecto (workspace-scoped) |
| **Registry** | Syn or `:pg` (workspace discovery) | Elixir Registry (local only) |
| **Executor** | N/A (control plane doesn't execute) | Task (local) + Distributed (GPU dispatch) |
| **Backup** | EventStore subscriptions consume workspace events | Litestream + RocksDB checkpoints → S3 |

**How events flow:**
1. Workspace executes workflow steps locally via RocksDB Store (fast path)
2. Workspace periodically publishes summary events to EventStore (via `on_complete` hook or async batch)
3. Control plane subscribes to EventStore for cross-workspace coordination: billing, SLA monitoring, resource scheduling
4. Control plane uses Syn/`:pg` to discover which workspaces are running and where

This is the **best of both worlds** — each workspace gets embedded storage performance while the control plane maintains a global view via event subscriptions.

**Packages needed:** `runic_rocksdb` (workspace), `runic_ecto` (workspace read models), `runic_eventstore` (control plane), `runic_syn` or core `:pg` (discovery)

---

### 10.4 Deployment Decision Tree

```
Is your workflow state mission-critical?
├── Yes, exactly-once matters → runic_raft (Ra/Khepri)
│   └── Pair with: Postgres for large fact storage
└── No, retry-from-Store is acceptable
    │
    ├── Single node?
    │   ├── High throughput? → runic_rocksdb
    │   ├── Need SQL queries? → runic_ecto (SQLite)
    │   └── Dev/test only? → ETS (built-in)
    │
    └── Multi-node?
        ├── Have Postgres? → runic_ecto + :pg (core) or runic_syn
        │   ├── Need auto-failover? → + runic_horde
        │   └── Need reactive subscriptions? → runic_eventstore
        ├── No external DB?
        │   ├── Embedded per-node → runic_rocksdb + S3 backup
        │   └── Shared cluster state → runic_raft (Khepri)
        └── Heterogeneous hardware? → Core Phase 8 (Executor.Distributed + :pg caps)
```
