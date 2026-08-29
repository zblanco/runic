# SHA-256 Content and Occurrence Identity Implementation Plan

- **Status:** Core identity foundation implemented on `zw/issue-16-sha256-identities`; distributed-runtime phases remain planned
- **Date:** 2026-08-29
- **Target baseline:** Runic `0.1.0-alpha.9`, after the [composite phash2 stopgap](phash2-composite-identity-implementation-plan.md)
- **Trigger:** [GitHub issue #16](https://github.com/zblanco/runic/issues/16) and distributed durable-runtime identity requirements
- **Reproduction:** [Issue 16 collision script](issue-16-phash2-collision-reproduction.exs)
- **Related distributed-runtime planning:** `zw/dist-runtime:.docs/distributed-durable-runtime-core-plan.md`, section 6; `zw/dist-runtime:.docs/runic-runtime-contract-upgrade-plan.md`, sections 4, 6, and 9

## Executive decision

Replace overloaded integer graph hashes with versioned, domain-separated SHA-256 identities derived from a Runic-owned canonical encoding. At the same time, separate immutable content digests from causal occurrence, execution, activation, attempt, command, transaction, and event identities.

The graph must no longer infer semantic multiplicity from content hashing:

- component definitions have content digests;
- authored graph nodes have node occurrence IDs that reference component definitions;
- payload values have payload digests;
- Facts have causal occurrence IDs and may additionally expose content/provenance digests;
- workflow artifacts are Merkle-style digests over canonical construction records;
- durable execution IDs are recorded explicitly and do not reuse graph hashes;
- every graph key is domain-tagged;
- duplicate insertion verifies identity evidence and fails closed on conflict.

SHA-256 is the default because it is available through OTP `:crypto`, has broad operational/FIPS compatibility, and avoids adding a hashing dependency. The scheme is versioned so a later algorithm or canonical encoding can coexist through an explicit migration rather than an implicit behavior change.

This is an alpha contract replacement, not a permanent dual-ID compatibility layer. Existing persisted fixtures receive a bounded one-time upcast/rebuild path or are intentionally reset.

### Implementation boundary in this stacked PR

Implemented and executable in this branch:

- typed, versioned, domain-separated `%Runic.Identity{}` values;
- `runic_canonical_v1`, bounded errors, preimage framing, integrity verification, and frozen vectors;
- SHA-256 component-definition, connection-definition, workflow-artifact, payload, Fact-content, Fact-occurrence, activation, and attempt identities;
- separate Fact payload/content/occurrence fields and explicit causal output coordinates;
- distinct fan-out Fact occurrences for equal payloads at different output indexes;
- identity-bearing `FactProduced` and `FanOutFactEmitted` events with full/lean replay fields;
- transitionary payload Store callbacks for ETS and Mnesia;
- serializers that retain full identities and never collapse binary identities through `phash2`;
- macro escaping and type/guard migration needed for typed identities across the current Runic constructors.

Still proposal, intentionally outside this core stack layer:

- changing every graph component vertex from definition identity to an authored node-occurrence wrapper;
- the distributed `ExecutionId`, command, transaction, event-position, authority-epoch, Journal, and ExecutionBackend contracts owned by the `zw/dist-runtime` effort;
- a retained-history upcaster for external consumers and the final removal of temporary alpha compatibility fields;
- cross-language conformance runners beyond the frozen byte-level vectors in [Runic Identity Scheme Version 1 Test Vectors](runic-identity-v1-test-vectors.md).

The distinction is deliberate: this PR supplies the core identity vocabulary and causal Fact behavior that `main` can validate now without claiming that unmerged Journal or clustered-runtime authority exists.

## 1. Why a hash-algorithm swap is insufficient

Replacing this:

```elixir
:erlang.phash2({value, ancestry}, 4_294_967_296)
```

with this:

```elixir
:crypto.hash(:sha256, :erlang.term_to_binary({value, ancestry}))
```

would reduce collision probability, but it would not complete the required design:

1. `term_to_binary/2` with `:deterministic` guarantees identical bytes only within one OTP major release.
2. Runtime function terms, PIDs, ports, references, and release-local metadata are not portable content definitions.
3. Components, Facts, and compiler nodes currently share one untagged vertex ID space.
4. Equal values at two fan-out indexes are distinct causal occurrences even if payload bytes are identical.
5. Repeated equal root inputs may be either memoized content or separate ingress occurrences; the policy must be explicit.
6. Runnable hashes currently conflate a logical activation with local idempotency.
7. Distributed commands, Journal transactions, attempts, and events require different deduplication and recovery semantics.
8. Content-addressed payload storage must not become the graph occurrence model.

The implementation therefore introduces an identity system, not merely a stronger helper function.

## 2. Goals and non-goals

### 2.1 Goals

1. Make accidental or adversarial content-digest collision infeasible for practical Runic workloads.
2. Define stable bytes independently of map iteration order, source line metadata, and OTP-major ETF encoding changes.
3. Domain-separate every public identity family.
4. Preserve causal multiplicity independently of payload deduplication.
5. Produce portable component, workflow artifact, payload, Fact content, and event digests.
6. Give local Workflow and future `Runic.Runtime` one identity vocabulary.
7. Support deterministic replay, remote execution validation, immutable artifact caching, and content-addressed payload storage.
8. Detect conflicting identity evidence instead of relying on hash strength alone.
9. Provide explicit test vectors and codec versions for adapters and other languages.
10. Remove `phash2` from correctness, integrity, idempotency, and public durable identity roles.

### 2.2 Non-goals

- Claiming exactly-once execution of arbitrary external effects.
- Using a process registry, placement ring, or broker as workflow authority.
- Persisting raw live `%Runnable{}` structs as a portable protocol.
- Canonicalizing arbitrary BEAM terms without an allowlist and domain schema.
- Hiding incompatible identity changes behind permanent dual reads/writes.
- Requiring every local, ephemeral workflow to start a distributed Runtime.
- Making SHA-256 output itself an occurrence ID when the semantic occurrence must remain distinct.
- Signing/authenticating content. Integrity digest and authenticity are separate capabilities.

## 3. Current code and change inventory

### 3.1 Central hash sites

The current checkout has:

- 136 `fact_hash` call sites across 11 files;
- nine direct `:erlang.phash2` sites across six files;
- 29 integer-only guards/specifications across 15 files;
- active `Multigraph.add_vertex` calls in `Runic`, `Workflow`, and `Workflow.Private`;
- hash-bearing fields across construction, lifecycle, Fact, activation, state, join, fan-out/fan-in, and map/reduce event modules.

The central helper makes an initial shadow implementation possible, but domain separation requires classifying most call sites rather than replacing the helper body once.

### 3.2 Current overloaded meanings

The word `hash` currently means several different things:

| Current use | Actual semantic need |
|---|---|
| Closure hash | Component/executable definition digest |
| Step/Condition/Rule hash | Definition digest, authored node identity, or both |
| Workflow hash | Artifact/revision content digest |
| Fact hash | Payload + provenance content and graph occurrence |
| FactRef hash | Reference to one Fact occurrence |
| Connection/InputBinding hash | Authored connection or compiler-node identity |
| Runnable ID | Local activation/idempotency occurrence |
| Fact-store key | Payload lookup, currently coupled to Fact causal identity |
| Event hash fields | References to nodes/Facts in one graph projection |
| Serializer `phash2` | Display-safe DOM/graph identifier |

The new model gives each meaning its own type/domain.

### 3.3 Existing useful seams

The migration should reuse:

- normalized macro AST and captured bindings in `Runic.Closure`;
- `Runic.Component.source/1` and built-in component protocols;
- chronological construction/runtime events;
- `FactRef` and separate Store value hydration;
- prepare → execute → apply and typed events;
- existing Workflow component registry and Multigraph vertex identifier callback;
- Store/Executor/Scheduler seams during transition;
- planned Journal/ExecutionBackend/PayloadStore/Runtime contracts for the distributed profile.

## 4. Identity taxonomy

### 4.1 Content identities

| Identity | Domain | Basis | Property |
|---|---|---|---|
| Component definition digest | `:component_definition` | Canonical executable definition, bindings, ports, semantic options | Equal executable definitions compare equal |
| Connection definition digest | `:connection_definition` | Canonical source/target node keys, ports, selectors, paths | Equal authored connection intent compares equal |
| Workflow artifact digest | `:workflow_artifact` | Canonical nodes, connections, boundary ports, schema/version | Immutable reusable program identity |
| Payload digest | `:payload` | Canonical logical value bytes | Equal values can deduplicate storage |
| Fact content digest | `:fact_content` | Producer definition, parent content, output coordinate, payload digest | Causal content/memoization key |
| Event data digest | `:event_data` | Canonical versioned event data | Integrity and deterministic event ID derivation input |
| Snapshot/segment digest | `:snapshot` / `:segment` | Canonical encoded bytes and manifest | Restore integrity |

### 4.2 Occurrence and protocol identities

| Identity | Meaning | Generation |
|---|---|---|
| Namespace | Tenant/application isolation | Supplied and validated |
| Node occurrence ID | One authored node position in an artifact/revision | Derived from artifact-local stable node key and component digest |
| Execution ID | One evolving workflow instance | Preallocated globally unique opaque ID |
| Input command ID | Semantic ingress idempotency | Caller-supplied/preallocated; stored with request digest |
| Activation ID | One causal scheduling occurrence | Derived or allocated once, then recorded |
| Attempt ID | One delivery/execution attempt | Derived from activation ID and attempt number |
| Fact occurrence ID | One output coordinate of one activation | Derived from activation ID, output port, and output index |
| Transaction ID | One conditional Journal mutation | Globally unique and queryable after ambiguity |
| Event ID | One committed event occurrence | Derived from stream/transaction/position/batch offset or assigned by Journal |
| Authority epoch | Fenced owner generation | Issued/enforced by authoritative Journal |
| Journal position | Ordered stream/partition revision | Assigned atomically by Journal |

Content digests may be equal across executions. Occurrence IDs must remain distinct where the model requires multiplicity.

## 5. Core identity representation

### 5.1 `Runic.Identity`

Use an explicit struct in core code and events:

```elixir
defmodule Runic.Identity do
  @enforce_keys [:scheme, :version, :domain, :digest]
  defstruct scheme: :sha256, version: 1, domain: nil, digest: nil

  @type domain ::
          :component_definition
          | :node_occurrence
          | :connection_definition
          | :workflow_artifact
          | :payload
          | :fact_content
          | :fact_occurrence
          | :activation
          | :attempt
          | :event_data
          | :snapshot
          | :segment

  @type t :: %__MODULE__{
          scheme: :sha256,
          version: pos_integer(),
          domain: domain(),
          digest: <<_::256>>
        }
end
```

An identity is equal only when scheme, version, domain, and digest are equal. This prevents a payload digest from aliasing a component or Fact vertex even if the raw 32 bytes match.

The struct is the Elixir API representation. A compact wire/storage encoding is:

```text
runic:<scheme>:v<version>:<domain>:<base32-or-hex-digest>
```

Human strings are for logs, URLs, SQL text columns, and graph serializers. Binary/event codecs should encode numeric scheme/version/domain tags plus the raw 32-byte digest.

### 5.2 Public constructors

```elixir
defmodule Runic.Identity do
  alias Runic.Identity.Canonical

  def digest(domain, identity_document) do
    canonical = Canonical.encode!(identity_document)
    digest_bytes(domain, canonical)
  end

  def derive(domain, ordered_identities_and_scalars) do
    digest(domain, {:derive, ordered_identities_and_scalars})
  end

  def digest_bytes(domain, canonical_bytes) when is_binary(canonical_bytes) do
    preimage = Preimage.frame_v1(domain, canonical_bytes)

    %__MODULE__{
      scheme: :sha256,
      version: 1,
      domain: domain,
      digest: :crypto.hash(:sha256, preimage)
    }
  end
end
```

Do not expose an untagged `sha256(term)` helper. Every call must select a registered domain and pass a domain-specific identity document.

### 5.3 Domain-separated preimage

Use unambiguous length framing:

```elixir
defmodule Runic.Identity.Preimage do
  @magic "runic-id"
  @version 1

  def frame_v1(domain, canonical_bytes) do
    domain_bytes = Atom.to_string(domain)

    <<
      @magic::binary,
      0,
      @version::unsigned-16,
      byte_size(domain_bytes)::unsigned-16,
      domain_bytes::binary,
      byte_size(canonical_bytes)::unsigned-64,
      canonical_bytes::binary
    >>
  end
end
```

Test vectors must freeze the exact byte layout. Never build a digest preimage by ambiguous string concatenation or inspect output.

## 6. Canonical encoding v1

### 6.1 Decision

Implement a restricted Runic canonical term codec rather than treating ETF as the durable digest encoding. `term_to_binary(term, [:deterministic])` may remain a same-OTP-major event/snapshot optimization, but it is not `runic_canonical_v1`.

Canonical v1 supports only identity-safe logical values:

- `nil`, booleans, atoms, integers, finite IEEE-754 floats;
- binaries and UTF-8 strings as binaries with no implicit normalization;
- lists and tuples with explicit distinct tags;
- maps sorted by canonical encoded key bytes;
- registered struct/projector documents represented as tagged maps;
- `%Runic.Identity{}` using its compact binary identity encoding.

It rejects:

- functions and anonymous compiled closures;
- PIDs, ports, references, and process-local resources;
- arbitrary structs without a registered projector;
- cyclic/improper structures outside the declared domain schema;
- values exceeding configured depth, item, or byte limits.

### 6.2 Encoder shape

```elixir
defmodule Runic.Identity.Canonical do
  @spec encode!(term()) :: binary()

  def encode!(nil), do: <<0x00>>
  def encode!(false), do: <<0x01>>
  def encode!(true), do: <<0x02>>

  def encode!(integer) when is_integer(integer) do
    bytes = Integer.to_string(integer)
    frame(0x10, bytes)
  end

  def encode!(binary) when is_binary(binary), do: frame(0x20, binary)

  def encode!(atom) when is_atom(atom) do
    frame(0x21, Atom.to_string(atom))
  end

  def encode!(list) when is_list(list) do
    encoded = Enum.map(list, &encode!/1)
    sequence(0x30, encoded)
  end

  def encode!(tuple) when is_tuple(tuple) do
    encoded = tuple |> Tuple.to_list() |> Enum.map(&encode!/1)
    sequence(0x31, encoded)
  end

  def encode!(map) when is_map(map) and not is_struct(map) do
    entries =
      map
      |> Enum.map(fn {key, value} -> {encode!(key), encode!(value)} end)
      |> Enum.sort_by(&elem(&1, 0))

    encoded_entries = Enum.map(entries, fn {key, value} -> frame(0x32, key <> value) end)
    sequence(0x33, encoded_entries)
  end
end
```

The production encoder needs exact signed integer, float, length, overflow, recursion, and error rules; the example communicates the required explicit tagging and ordering, not the final byte constants.

### 6.3 Identity projectors

Hash identity documents, not entire live structs. Add a protocol:

```elixir
defprotocol Runic.Identity.Projectable do
  @spec identity_document(t()) :: term()
  def identity_document(value)
end
```

Built-in components implement it. Custom components must opt in for portable content identity. A local-only component may continue to run in a local Workflow, but cannot be exported as a portable artifact or submitted to a durable distributed profile.

## 7. Component and node identities

### 7.1 Component definition digest

For a Step, include executable semantics and exclude occurrence/presentation/runtime data:

```elixir
defimpl Runic.Identity.Projectable, for: Runic.Workflow.Step do
  def identity_document(step) do
    %{
      kind: :step,
      version: 1,
      executable: closure_document(step.closure),
      call_contract: canonical_call_contract(step.call_contract),
      inputs: canonical_ports(step.inputs),
      outputs: canonical_ports(step.outputs),
      meta_requirements: canonical_meta_refs(step.meta_refs)
    }
  end
end
```

Exclude:

- `name`, which belongs to the authored node occurrence;
- the compiled `work` function;
- source line/file metadata that does not change semantics;
- mutable `run_context` values;
- local hooks and scheduler policy functions;
- diagnostics and Inspect representations.

Closure identity includes normalized AST, explicit captured bindings, required module/function references, and a declared code/schema version. Closure metadata needed only to re-evaluate code must be split into semantic and diagnostic subsets.

### 7.2 Authored node occurrence

Two graph nodes may reference the same component definition and still be distinct positions:

```elixir
node_id =
  Identity.derive(:node_occurrence, [
    artifact_local_parent_key,
    authored_name_or_stable_key,
    sibling_ordinal,
    component_definition_digest
  ])
```

Do not derive node occurrence from component content alone. Explicit authored node keys are preferable to sibling ordinals because they survive unrelated graph edits.

Proposed node wrapper:

```elixir
%Runic.Workflow.Node{
  id: node_occurrence_id,
  definition_digest: component_definition_digest,
  name: :charge_card,
  component: step
}
```

The pure Workflow may introduce this wrapper internally before exposing it publicly. Multigraph keys use `node.id`, while `Runic.Component` continues to execute `node.component`.

### 7.3 Workflow artifact digest

Build a Merkle-style canonical artifact document:

```elixir
artifact_document = %{
  kind: :workflow_artifact,
  version: 1,
  boundary: %{inputs: input_ports, outputs: output_ports},
  nodes:
    nodes
    |> Enum.map(&node_record/1)
    |> Enum.sort_by(&Identity.to_binary(&1.id)),
  connections:
    connections
    |> Enum.map(&connection_record/1)
    |> Enum.sort_by(&Identity.to_binary(&1.id))
}

artifact_digest = Identity.digest(:workflow_artifact, artifact_document)
```

Runtime context, active Facts, hooks that are not portable, scheduler state, process IDs, and execution history are excluded.

## 8. Fact, payload, and causal occurrence identities

### 8.1 Proposed Fact representation

```elixir
defmodule Runic.Workflow.Fact do
  defstruct [
    :id,
    :content_digest,
    :payload_digest,
    :value,
    :ancestry,
    meta: %{}
  ]
end

defmodule Runic.Workflow.FactAncestry do
  @enforce_keys [:producer_node_id, :parent_fact_id]
  defstruct [:producer_node_id, :parent_fact_id, :activation_id, :output_port, :output_index]
end
```

`FactRef` retains `id`, `content_digest`, `payload_digest`, and ancestry but omits `value`.

### 8.2 Payload digest

```elixir
payload_document = %{
  codec: :runic_canonical,
  schema_version: 1,
  value: value
}

payload_digest = Identity.digest(:payload, payload_document)
```

Equal payloads may share immutable storage. The payload digest is never the graph vertex ID.

### 8.3 Fact content digest

```elixir
content_digest =
  Identity.derive(:fact_content, [
    producer_component_definition_digest,
    parent_fact_content_digest,
    output_port,
    output_index,
    payload_digest
  ])
```

This supports memoization and causal-content comparison. Whether `output_index` belongs in content depends on the operation semantics; the default includes it because collection position is semantically observable.

### 8.4 Fact occurrence ID

```elixir
fact_id =
  Identity.derive(:fact_occurrence, [
    execution_id,
    activation_id,
    output_port,
    output_index
  ])
```

Retries of the same activation/output coordinate reproduce the same Fact occurrence ID. A separately scheduled activation produces a different ID even when content is identical.

### 8.5 Root ingress policy

Root Facts require an explicit mode:

- `:distinct` — derive occurrence from the accepted input command ID; repeated equal values are distinct inputs;
- `:memoized` — derive an application-declared semantic input key and reject conflicting payload content;
- `:best_effort_local` — allocate a local occurrence ID without a durable command receipt.

The distributed default is `:distinct`. Content digest remains available for deduplication in every mode.

## 9. Graph identity and collision checks

### 9.1 Type-tagged vertex keys

Multigraph should receive explicit occurrence IDs:

```elixir
def vertex_id_of(%Runic.Workflow.Node{id: id}), do: id
def vertex_id_of(%Runic.Workflow.Fact{id: id}), do: id
def vertex_id_of(%Runic.Workflow.FactRef{id: id}), do: id
def vertex_id_of(%Runic.Workflow.Root{id: id}), do: id
```

Because `Runic.Identity` includes `domain`, a Fact cannot alias a node or payload by raw digest equality.

Bare integer/hash fallbacks should be removed from portable/durable construction. A compatibility decoder may translate old events during the bounded migration phase.

### 9.2 Verified insertion

Wrap every active `Multigraph.add_vertex` call in one core helper:

```elixir
def put_vertex(%Multigraph{} = graph, vertex) do
  id = Components.vertex_id_of(vertex)

  case Map.fetch(graph.vertices, id) do
    :error ->
      {:ok, Multigraph.add_vertex(graph, vertex)}

    {:ok, existing} ->
      if identity_evidence(existing) == identity_evidence(vertex) do
        {:ok, graph}
      else
        {:error,
         %IdentityConflict{
           id: id,
           existing: identity_summary(existing),
           incoming: identity_summary(vertex)
         }}
      end
  end
end
```

Comparison uses domain-specific canonical identity evidence, not full live struct equality. Store the canonical document digest or enough immutable fields to reproduce it. Never treat a matching digest as the only proof when canonical bytes/documents are already available at an integrity boundary.

## 10. Activation, attempt, Runnable, and event identities

### 10.1 Runnable becomes an execution projection

Replace content-hash `Runnable.id` with explicit occurrence references:

```elixir
%Runic.Workflow.Runnable{
  activation_id: activation_id,
  attempt_id: attempt_id,
  attempt_number: 0,
  node: node,
  input_fact: fact,
  context: context,
  status: :pending
}
```

The local pure API may allocate an ephemeral execution/activation namespace. Durable Runtime allocates and records identities before dispatch.

### 10.2 Deterministic child identities

```elixir
activation_id =
  Identity.derive(:activation, [
    execution_id,
    input_fact.id,
    node.id,
    activation_ordinal
  ])

attempt_id = Identity.derive(:attempt, [activation_id, attempt_number])
```

If an activation cannot be deterministically addressed from existing causal coordinates, allocate it once and persist it in the deciding event. Replay consumes the recorded ID; it never regenerates a different one.

### 10.3 Durable events

Version identity-bearing events rather than overloading legacy fields indefinitely:

```elixir
%Runic.Workflow.Events.FactProduced{
  version: 2,
  fact_id: fact.id,
  content_digest: fact.content_digest,
  payload: %Runic.Runtime.PayloadRef{digest: fact.payload_digest, ...},
  ancestry: fact.ancestry,
  producer_label: :produced,
  weight: 1,
  meta: %{}
}
```

Future Runtime persistence wraps it:

```elixir
%Runic.Runtime.RecordedEvent{
  schema_version: 1,
  event_id: event_id,
  stream_id: execution_id,
  position: position,
  transaction_id: transaction_id,
  authority_epoch: epoch,
  causation_id: activation_id,
  correlation_id: input_command_id,
  data_digest: Identity.digest(:event_data, canonical_event_data),
  data: fact_produced
}
```

Journal ordering and occurrence IDs remain authoritative. `committed_at` is diagnostic and excluded from deterministic identity.

## 11. Store, Journal, and PayloadStore changes

### 11.1 Transitional Runner Store

Current Store callbacks use `save_fact(fact_hash, value, state)`. During transition:

```elixir
@callback save_payload(
            payload_digest :: Runic.Identity.t(),
            encoded_payload :: binary(),
            state()
          ) :: :ok | {:error, term()}

@callback load_payload(Runic.Identity.t(), state()) ::
            {:ok, binary()} | {:error, term()}
```

Fact occurrence and ancestry remain in events/graph projection. Payload storage is keyed only by payload digest.

Do not permanently expand the legacy Store into the clustered correctness contract. This is a migration bridge to the planned `Runic.Runtime.PayloadStore` and `Runic.Runtime.Journal` behaviors.

### 11.2 Runtime contract alignment

- Journal owns ordered recorded events, expected position, command/transaction dedupe, authority epoch, and pending durable work.
- PayloadStore owns immutable encoded payload bytes, digest verification, and durability receipts.
- ExecutionBackend consumes committed dispatch requests identified by activation/attempt IDs.
- Scheduler plans from occurrence-aware state; it does not invent durable identities after dispatch.
- Runner remains a local implementation during migration, then moves behind Runtime as described by the dist-runtime plans.

Content digest does not fence authority, order events, or prove exactly-once effects.

## 12. Serializer and external representation changes

Graph serializers must stop collapsing binary identities through `phash2`:

```elixir
def node_id(%{id: %Runic.Identity{} = id}) do
  "n_" <> Runic.Identity.short_string(id, 20)
end
```

The shortened string is display-only. Serializers should retain the full identity in element metadata so consumers can distinguish a theoretical prefix collision.

Update:

- Mermaid, DOT, Cytoscape, and edgelist IDs;
- inspect output and error messages;
- public results/query references;
- JSON adapters and SQL column recommendations;
- telemetry metadata with bounded string forms.

Never feed a shortened/display identity back into Workflow lookup.

## 13. Migration strategy

### 13.1 Scheme identification

Legacy values are explicitly `:phash2_32_v0` or `:phash2_64_v1`. New values are `%Runic.Identity{scheme: :sha256, version: 1, ...}`. Do not infer a scheme from integer size or binary length.

### 13.2 One-time migration, not permanent dual identity

For retained fixtures/consumers:

1. Decode the old construction stream with its historical Runic version or a bounded upcaster.
2. Reconstruct canonical component identity documents.
3. Allocate stable node occurrence keys from names/connection positions and record any ambiguity.
4. Recompute new construction events and workflow artifact digest.
5. Replay runtime events in order, resolving old Fact values from inline events or the old fact store.
6. Generate Fact content and occurrence identities using recorded causal coordinates and deterministic migration ordinals.
7. Write a new stream/snapshot under a new execution/artifact revision.
8. Verify result/state projections before switching readers.
9. Retain the old stream read-only for audit/rollback until the migration horizon closes.

Do not rewrite a stream in place.

### 13.3 Irrecoverable ambiguity

An old history may be impossible to migrate automatically when:

- a silent collision already replaced one vertex and the second value was not retained in events/store;
- an old component event has no reconstructable source/Closure and only a 32-bit hash;
- two unnamed identical nodes cannot be assigned stable distinct occurrence positions;
- required payload bytes are missing;
- a local function/hook cannot be projected into a portable definition.

Return an explicit migration diagnostic. Never guess and label the result verified.

### 13.4 Consumer boundary

Known consumers should migrate through fixtures on the contract branch. Local workspace/BYOC installations can use a coordinated stop/rebuild window. A clustered multi-tenant Runtime requires online version/capability checks, immutable artifact revisions, and fenced stream migration; those guarantees must not be inferred from a successful local reset.

## 14. Implementation phases

### Phase S0 — Identity ADR and executable test vectors

Deliver:

- final identity taxonomy and naming;
- canonical encoding v1 specification;
- domain registry and preimage frame specification;
- fixed SHA-256 vectors for primitive terms, maps, AST, Closure, component, payload, Fact content, and derived occurrence IDs;
- cross-OTP-major and cross-language vector harness;
- benchmark baseline for encoding, digesting, equality, Map keys, ETS keys, and artifact construction.

Gate: another implementation can reproduce every vector without running Runic code.

### Phase S1 — Core `Runic.Identity` and canonical codec

Deliver:

- `Runic.Identity`, `Preimage`, `Canonical`, domain registry, encoding/string APIs;
- structured codec errors and limits;
- `Runic.Identity.Projectable` protocol;
- collision/integrity error types;
- property tests for map order, round trips where applicable, and domain separation;
- optional streaming hash API for large payload encoders.

Gate: identity bytes are stable across supported OTP majors and reject unsupported local terms.

### Phase S2 — Component definitions and workflow artifacts

Deliver:

- identity projectors for every built-in component family;
- Closure semantic identity document;
- canonical ports, call contracts, connections, `InputBinding`, joins, conjunctions, and nested workflow definitions;
- authored node occurrence model;
- workflow artifact canonical document and Merkle digest;
- custom-component portability diagnostics.

Gate: equivalent graphs built in different processes produce the same artifact digest, while repeated identical components at distinct authored positions retain distinct node IDs.

### Phase S3 — Fact occurrence and payload split

Deliver:

- new Fact/FactRef fields and ancestry struct;
- payload digest and encoding;
- Fact content digest and occurrence ID derivation;
- explicit root ingress occurrence policy;
- occurrence-aware map/reduce, join, accumulator, state, and repeated-equal-value behavior;
- verified graph insertion wrapper for all vertex call sites.

Gate: equal payloads at different fan-out indexes remain distinct graph occurrences while sharing one payload digest.

### Phase S4 — Event, replay, Store, and serializer migration

Deliver:

- versioned identity-bearing event schemas and upcasters;
- strict chronological projector support;
- payload-oriented Store bridge and FactRef hydration;
- snapshot manifest/version changes;
- full identity graph serializers;
- old fixture migration tool and diagnostics.

Gate: live projection equals replay for every event prefix and snapshot tail under the new identity scheme.

### Phase S5 — Activation and durable Runtime identities

Deliver:

- explicit execution, command, activation, attempt, transaction, event, epoch, and position types;
- portable `RunnableDispatchRequested` and result commands;
- Journal transaction/reference model integration;
- ExecutionBackend and Scheduler use of recorded identities;
- duplicate/stale/conflict tests;
- invocation-scoped context and graph-revision binding.

Gate: retries preserve Fact occurrence coordinates, duplicate results cannot apply twice, and stale authority cannot commit.

### Phase S6 — Consumer migration and removal

Deliver:

- known SQLite/PostgreSQL consumer fixtures;
- alpha history migration/reset runbooks;
- removal of composite `fact_hash` correctness use;
- removal of integer-only hash guards/specs;
- removal of permanent legacy read/write paths after the bounded horizon;
- updated public guides and telemetry.

Gate: no correctness, integrity, idempotency, or durable public identity relies on `phash2`.

## 15. Expected file-level change surface

### 15.1 New core modules

| Module | Responsibility |
|---|---|
| `Runic.Identity` | Typed scheme/domain/digest and public APIs |
| `Runic.Identity.Preimage` | Versioned domain framing |
| `Runic.Identity.Canonical` | Restricted deterministic encoder |
| `Runic.Identity.Projectable` | Domain identity documents |
| `Runic.Workflow.Node` | Authored node occurrence and component definition reference |
| `Runic.Workflow.FactAncestry` | Explicit causal occurrence coordinates |
| Identity/integrity conflict errors | Fail-closed diagnostics |

Runtime phases additionally add the identity-bearing types already proposed by the distributed-runtime plans.

### 15.2 Existing high-impact modules

| Area | Expected edits |
|---|---|
| `lib/runic.ex` | Classify macro hash bases by component definition, node occurrence, connection, and compiler domains |
| `lib/closure.ex` | Semantic projector and new digest type |
| `lib/workflow/components.ex` | Replace generic fallback with typed identity lookup/projectors |
| `lib/workflow/component.ex` | Component identity contract and built-in implementations |
| `lib/workflow.ex` / `private.ex` | Node/Fact occurrence lookup, verified insertion, event application, replay, results |
| `fact.ex`, `fact_ref.ex`, `facts.ex` | Occurrence/content/payload split |
| `runnable.ex` | Activation/attempt identity fields |
| Connection/compiler nodes | Domain-specific definition and occurrence identities |
| Event modules | Versioned ID/digest fields |
| Runner Store/Worker | Payload digest persistence and replay bridge |
| Serializers | Full stable display mapping without `phash2` collapse |

### 15.3 Quantitative estimate

- 136 current shared-helper call sites require classification, though many macro patterns can be migrated through shared builders.
- 29 integer-only assumptions across 15 files require type/guard changes.
- nine direct `phash2` sites require removal or explicit display/cache classification.
- all active vertex insertion sites move behind one verified helper.
- approximately 13 runtime event modules plus construction/lifecycle event structs carry identity references.
- Expect multiple reviewable PRs, not one mechanical patch: roughly 20-35 production files and 15-30 test files across S1-S4 before Runtime consumer work.
- No new hashing dependency; a custom canonical codec is new core code.

## 16. Test and conformance plan

### 16.1 Canonical encoding

- fixed vectors for every supported type/tag;
- maps with different construction/insertion orders encode identically;
- list, tuple, atom, and binary domains remain distinct;
- integer boundaries and floats have exact vectors;
- unsupported function/PID/port/reference values fail with paths;
- depth, item, and byte limits fail before unbounded allocation;
- supported OTP majors produce identical bytes.

### 16.2 Component/artifact identity

- line/file metadata changes do not change component definition digest;
- semantic AST/binding/port changes do change it;
- runtime context does not affect it;
- two names can reference one definition but get different node occurrence IDs;
- connection selector/path/order semantics are represented exactly;
- nested workflow artifact digest is stable;
- custom local-only components receive actionable diagnostics.

### 16.3 Fact and graph semantics

- issue #16 values cannot alias;
- forced digest conflict returns a typed error;
- equal payload at two fan-out indexes yields one payload digest and two Fact IDs;
- retry of one activation reproduces the same Fact ID;
- a new activation with equal content produces a distinct Fact ID;
- memoized versus distinct ingress policies are explicit;
- FactRef hydration preserves IDs and verifies payload digest;
- component/Fact domain mismatch cannot resolve through Multigraph.

### 16.4 Events, storage, and replay

- event codec/upcaster vectors;
- full, lean, hybrid, stream, and snapshot-tail replay equivalence;
- corrupt payload bytes fail digest verification;
- missing payload is `not_found`/deferred, never decoded as `nil`;
- migration preserves projections or emits explicit ambiguity;
- duplicate transaction/command/event/attempt cases use their own IDs;
- old composite IDs do not enter new streams without an upcast boundary.

### 16.5 Performance

Benchmark separately:

- canonical encoding;
- SHA-256 over pre-encoded bytes;
- combined encode+digest;
- component/artifact construction;
- small and large payloads;
- graph insertion/lookup with `%Identity{}` keys;
- ETS/Mnesia/PostgreSQL key representation;
- FactRef hydration and digest verification;
- streaming versus one-shot payload hashing.

Do not evaluate only the multiplier over `phash2`. Record absolute cost in graph construction, per-Fact execution, replay, and payload I/O. The earlier local benchmark measured about 576 ns for a small deterministic ETF+SHA-256 operation and 36 µs for a 64 KiB value; the custom codec requires its own measurements.

The executable [identity benchmark](identity-benchmark.exs) now compares the
implemented canonical codec plus SHA-256 against `phash2_64_v1`. One local run
on Elixir 1.19.5 / OTP 28.5 and an AMD Ryzen 7 5800X measured:

| Method | Small Fact basis | 64 KiB Fact basis |
|---|---:|---:|
| `phash2_64_v1` | 0.20 µs | 47.89 µs |
| `runic_canonical_v1` + SHA-256 | 1.97 µs | 44.98 µs |

For small terms the stronger identity path was about 9.7 times slower but still
under 2 µs in absolute time. For the 64 KiB term it was slightly faster because
the composite stopgap traverses the input twice. The canonical path allocated
more memory and consumed more reductions, so these figures are a development
baseline rather than a substitute for workflow-level benchmarks.

## 17. Acceptance criteria

1. Every public identity declares scheme, version, and domain.
2. Canonical encoding is stable across the supported OTP-major matrix.
3. No correctness/public durable identity uses raw `phash2`.
4. Component definitions and authored node occurrences are distinct concepts and fields.
5. Fact occurrence, Fact content, and payload digest are distinct concepts and fields.
6. Equal fan-out payloads preserve causal multiplicity.
7. Graph insertion compares identity evidence and fails closed on conflict.
8. Workflow artifacts have reproducible SHA-256 digests.
9. Runtime activation/attempt/command/transaction/event identities do not reuse graph hashes.
10. Full and lean replay are equivalent to live projection.
11. Payload read verifies digest before decode/use.
12. Serializers never shorten an identity for authoritative lookup.
13. Old alpha data is explicitly migrated, reset, or rejected; it is never silently mixed.
14. Custom components declare portable identity documents or are rejected from portable profiles.
15. Core, property, replay, Store, Runtime reference-model, and consumer fixture tests pass.
16. `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`, and `git diff --check` pass.

## 18. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Canonical codec becomes an underspecified serialization format | Freeze byte-level vectors and version every domain/schema |
| Full structs accidentally include local/runtime data | Hash registered identity documents only |
| SHA-256 cost appears on every graph operation | Compute once at construction/production, cache immutable IDs, stream large payloads |
| `%Identity{}` Map keys use more memory than integers | Benchmark; allow private indexed projections that verify full identity |
| Equal content is incorrectly collapsed | Use node/Fact occurrence IDs as graph keys |
| Occurrence IDs lose determinism on retry | Derive from recorded activation/output coordinates |
| Names/ordinals make artifact IDs fragile | Prefer explicit stable authored node keys; canonical sort records |
| Migration invents missing history | Fail with ambiguity diagnostics and preserve old stream read-only |
| Custom components cannot be canonicalized | Explicit local-only portability profile and projector protocol |
| Integrity is mistaken for authenticity | Add signatures/MACs separately where trust boundaries require them |
| Placement hashing is mistaken for authority | Route by execution/work-scope key, but fence mutations in Journal |
| Stopgap dual semantics persist forever | Time-box upcasters and make composite removal an S6 gate |

## 19. Decisions closed by this plan

1. **Digest algorithm:** SHA-256 for identity scheme version 1.
2. **Canonical encoding:** Runic-owned restricted deterministic codec, not raw ETF.
3. **Representation:** typed `%Runic.Identity{}` in Elixir; compact tagged binary on wire/storage.
4. **Domain separation:** scheme/version/domain included before canonical bytes.
5. **Graph key:** occurrence identity, not payload digest.
6. **Multiplicity:** equal content may have distinct occurrences.
7. **Collision handling:** verified insertion fails closed.
8. **Custom components:** explicit canonical projector required for portable profiles.
9. **Migration:** bounded one-time upcast/rebuild or reset; no permanent dual public IDs.
10. **Placement:** execution/work-scope routing is separate from content identity and Journal fencing.

## 20. Remaining implementation-time details

These details must be frozen in S0 test vectors before code lands:

- exact canonical byte tags and signed integer/float encoding;
- supported value limits and error-path format;
- stable authored node-key API and unnamed-node fallback;
- whether `output_index` is always part of Fact content or only occurrence identity for selected operators;
- compact SQL column form (`bytea` components versus one encoded binary);
- event ID derivation inputs after Journal assigns positions;
- exact migration ordinals for old unnamed repeated nodes/Facts;
- whether a local pure Workflow allocates an implicit execution namespace at construction or first input.

None of these reopen the identity taxonomy or permit raw `phash2` as a durable fallback.

## 21. Relationship to existing plans

- [Causal Runtime Architecture](causal-runtime-architecture.md) remains the basis for value + ancestry semantics, but content hash is no longer the sole graph occurrence identity.
- [Checkpointing Implementation Plan](checkpointing-implementation-plan.md) retains FactRef and separate value-storage goals; payload digest replaces causal Fact hash as the immutable value-store key.
- [Event-sourced Implementation Plan](eventsourced-implementation-plan.md) retains typed events and replay; identity-bearing events become versioned and chronological.
- [Port Contracts Implementation Plan](port-contracts-implementation-plan.md) remains relevant to adapter seams; future Journal/PayloadStore contracts own distributed correctness.
- The `zw/dist-runtime` plans already require cryptographic content digests, distinct occurrence IDs, canonical events, Journal fencing, and one-time alpha migration. This document supplies the concrete core identity and canonicalization work needed to satisfy those requirements.
