# Composite `phash2` Identity Stopgap Implementation Plan

- **Status:** Implemented on `zw/issue-16-phash2-composite` for draft review
- **Date:** 2026-08-29
- **Target baseline:** Runic `0.1.0-alpha.9`
- **Trigger:** [GitHub issue #16](https://github.com/zblanco/runic/issues/16), "Workflow graph silently aliases distinct facts on 32-bit phash2 collisions"
- **Reproduction:** [Issue 16 collision script](issue-16-phash2-collision-reproduction.exs)
- **Long-term successor:** [SHA-256 Content and Occurrence Identity Implementation Plan](sha256-content-identity-implementation-plan.md)
- **Related distributed-runtime planning:** `zw/dist-runtime:.docs/distributed-durable-runtime-core-plan.md`, section 6

## Executive decision

Ship a deliberately temporary `phash2_64_v1` identity scheme that combines two domain-separated 32-bit `:erlang.phash2/2` results into one non-negative integer. Apply it through the existing `Runic.Workflow.Components.fact_hash/1` funnel, use it for Runnable IDs, and add a fail-fast fact identity conflict check before Multigraph insertion.

This plan reduces the probability of an accidental collision by many orders of magnitude without first introducing canonical encoding, cryptographic digests, new graph identity structs, or distributed occurrence semantics. It does not claim cryptographic collision resistance and must not become the durable identity contract for `Runic.Runtime`.

The rollout is an alpha hard cut:

- generated hashes change for components, closures, facts, joins, connections, and compiler-generated nodes;
- active persisted workflows, snapshots, fact-store keys, and event histories must not silently mix the old 32-bit and new composite schemes;
- applications either rebuild/reset alpha-era persisted state or run an explicit application-owned migration;
- the core library does not retain permanent dual-hash behavior.

## 1. Goals and non-goals

### 1.1 Goals

1. Prevent the known issue #16 values from sharing the same generated Fact identity.
2. Reduce accidental hash collision probability from a 32-bit to an approximately 64-bit space.
3. Preserve the current public shape of generated hashes as non-negative Elixir integers.
4. Change the shared hash implementation rather than editing every macro and component constructor individually.
5. Replace silent fact aliasing with an explicit `Runic.Workflow.IdentityConflictError` if a collision still reaches graph insertion.
6. Upgrade the separate 27-bit default Runnable ID calculation to the same composite scheme.
7. Preserve deterministic hashing across supported machine architectures and ERTS versions, subject to `phash2`'s existing guarantees.
8. Add regression, replay, rehydration, and store tests that prove the new behavior.

### 1.2 Non-goals

- Cryptographic or adversarial collision resistance.
- Canonical cross-language or cross-OTP-major content encoding.
- Stable public identities for a distributed Journal protocol.
- Separating component definition, graph node occurrence, fact occurrence, payload, activation, attempt, command, transaction, and event identities.
- Resolving whether repeated equal root input is memoized or represents a new occurrence.
- Repairing already-corrupted snapshots or event histories.
- Making a consistent-hash placement ring authoritative for workflow ownership.
- Retaining `phash2_64_v1` as a permanent compatibility layer after SHA-256 migration.

## 2. Current baseline and measured blast radius

### 2.1 Hash production

`Runic.Workflow.Components.fact_hash/1` currently returns one 32-bit value:

```elixir
@max_phash 4_294_967_296

def fact_hash(value), do: :erlang.phash2(value, @max_phash)
```

The current checkout contains 136 `fact_hash` call sites across 11 files, but they funnel through this one function. They cover:

- `Runic.step`, rule, condition, map, reduce, accumulator, FSM, aggregate, saga, and process-manager macros;
- `Runic.Closure` source and captured-binding identity;
- `Fact.new/1` over `{value, ancestry}`;
- joins, conjunctions, connections, named-port `InputBinding`s, and compilation utilities;
- workflow and pipeline component hashes;
- some state initialization and invocation paths.

The stopgap therefore changes generated identities broadly while requiring few production edits.

### 2.2 Hash consumers

Generated hashes are used as:

- Multigraph vertex IDs through `Components.vertex_id_of/1`;
- entries in `Workflow.components`, hook maps, `inputs`, and `mapped` indexes;
- ancestry references `{producer_hash, parent_fact_hash}`;
- fields in construction, runtime, lifecycle, map/reduce, join, and state events;
- ETS and Mnesia fact-store keys;
- `FactRef` hydration keys;
- Runnable idempotency keys;
- serializer and graph visualization identifiers.

Most event fields and Store callbacks already use `term()`. Several component and lifecycle type specifications still say `integer()` or `non_neg_integer()`. A composite integer remains compatible with those shapes, although inconsistent specifications should be corrected while touching the relevant modules.

### 2.3 Separate direct `phash2` sites

There are nine direct `:erlang.phash2` uses across six source/test files. The correctness-relevant production uses are:

- `Runic.Workflow.Runnable.new/3`;
- `Runic.Workflow.Runnable.runnable_id/2`.

Serializer and edgelist uses are display adapters. They are not workflow authority, but their collision behavior should be covered by the long-term plan.

### 2.4 Silent insertion behavior

`Workflow.apply_event/2` constructs the Fact recorded in `FactProduced` and calls `Workflow.log_fact/2`. `Private.log_fact/2` delegates directly to `Multigraph.add_vertex/2`. Multigraph checks only the configured vertex ID and returns the graph unchanged when that ID exists. It does not compare the existing and incoming vertices.

The result is a successful event application that connects a new producer to an older, unrelated Fact.

### 2.5 Reproduction evidence

The Tidewave reproduction establishes both forms:

| Construction | Isolated values | Shared 32-bit hash | Applied values |
|---|---:|---:|---:|
| Explicit `Step.new` issue pair | `11_396`, `19_508` | `2_532_671_132` | `11_396`, `11_396` |
| Macro-built `Runic.step` searched pair | `135_162`, `17_404` | `2_237_561_755` | `135_162`, `135_162` |

For the issue pair, the proposed secondary hash produces `1_691_296_184` and `2_524_127_245`, so the composite identities differ.

## 3. Proposed `phash2_64_v1` scheme

### 3.1 Calculation

Add an explicit scheme name and combine the existing primary value with a domain-separated secondary pass:

```elixir
defmodule Runic.Workflow.Components do
  @max_phash 4_294_967_296
  @hash_scheme :phash2_64_v1

  @spec hash_scheme() :: :phash2_64_v1
  def hash_scheme, do: @hash_scheme

  @spec fact_hash(term()) :: non_neg_integer()
  def fact_hash(term) do
    high = :erlang.phash2(term, @max_phash)
    low = :erlang.phash2({@hash_scheme, :secondary, term}, @max_phash)

    high * @max_phash + low
  end
end
```

Properties:

- the return range is `0..2^64-1`;
- the return value remains an Elixir integer;
- the high 32 bits preserve the previous primary `phash2` output for diagnostics;
- the scheme/version atom domain-separates the second pass and provides an obvious replacement point;
- the calculation is deterministic wherever `phash2` is deterministic;
- Elixir transparently represents values above the BEAM small-integer range as boxed integers.

Do not call this `hash64/1` without the scheme name. The algorithm is specifically a composite of two non-cryptographic 32-bit hashes, not a general 64-bit content digest.

### 3.2 Collision probability

If the two domain-separated outputs behave independently for non-adversarial inputs, the birthday approximation is:

```text
p(collision) ≈ n(n - 1) / (2 × 2^64)
```

Examples:

| Generated identities | Approximate accidental-collision probability |
|---:|---:|
| 1,001 | 1 in 36.8 trillion |
| 100,000 | 1 in 3.69 billion |
| 1,000,000 | 1 in 36.9 million |

These numbers are engineering estimates, not a security claim. An attacker can deliberately search `phash2` outputs, and the two passes have no cryptographic independence proof.

### 3.3 Performance evidence

Tidewave/Benchee on Elixir 1.19.5, OTP 28.5, and an AMD Ryzen 7 5800X measured compiled functions:

| Method | Small Fact-shaped term | 64 KiB Fact-shaped term |
|---|---:|---:|
| One 32-bit `phash2` | 88.6 ns | 23.2 µs |
| Composite two-pass `phash2` | 197 ns | 50.7 µs |
| Deterministic ETF plus SHA-256 | 576 ns | 36.0 µs |

The stopgap adds about 108 ns for the small identity terms most common in graph construction. It is not always faster for large values because it traverses the term twice. This is another reason not to treat the composite as the long-term payload digest.

## 4. Fail-fast Fact conflict detection

### 4.1 Required failure mode

The composite reduces probability; it does not make collision impossible. A conflicting Fact at an existing identity must fail the apply operation rather than silently return the older vertex.

Add a dedicated exception:

```elixir
defmodule Runic.Workflow.IdentityConflictError do
  defexception [:identity, :existing, :incoming, :context]

  @impl Exception
  def message(error) do
    "workflow identity conflict at #{inspect(error.identity)} " <>
      "while #{error.context || "inserting a vertex"}"
  end
end
```

The exception should retain bounded diagnostic evidence. Avoid unconditionally rendering arbitrary Fact values into the message because they may be large or sensitive.

### 4.2 Fact equivalence rules

The current Fact hash basis is `{value, ancestry}`. `meta` is excluded. Conflict checking must use the same basis:

```elixir
defp equivalent_identity?(
       %Fact{value: left, ancestry: ancestry},
       %Fact{value: right, ancestry: ancestry}
     ),
     do: left === right

defp equivalent_identity?(
       %FactRef{ancestry: ancestry},
       %FactRef{ancestry: ancestry}
     ),
     do: true

defp equivalent_identity?(_existing, _incoming), do: false
```

`Fact`/`FactRef` equality is necessarily partial because a reference has no value. Mixed full/reference insertion therefore fails closed: matching ancestry alone is not identity proof. Lean replay inserts only references, while the existing rehydration implementation deliberately replaces graph vertices without calling `log_fact/2`.

### 4.3 Guarded insertion

Centralize Fact insertion in `Private.log_fact/2`:

```elixir
def log_fact(%Workflow{graph: graph} = workflow, fact)
    when is_struct(fact, Fact) or is_struct(fact, FactRef) do
  identity = Components.vertex_id_of(fact)

  case Map.fetch(graph.vertices, identity) do
    :error ->
      %{workflow | graph: Multigraph.add_vertex(graph, fact)}

    {:ok, existing} ->
      if equivalent_identity?(existing, fact) do
        workflow
      else
        raise IdentityConflictError,
          identity: identity,
          existing: identity_summary(existing),
          incoming: identity_summary(fact),
          context: "applying a produced fact"
      end
  end
end
```

This directly protects the issue #16 path, lean replay, state/join/fan-in results that call `log_fact/2`, and any caller using `Workflow.log_fact/2`.

### 4.4 Component collision boundary

The stopgap does not attempt to define a canonical semantic comparison for every component struct. Macro-built components contain both reconstructable Closure data and compiled function values; raw `Step.new` components may contain only a function and explicit hash. A generic struct comparison would either reject legitimate idempotent additions or accept a second collision-prone hash as proof.

Required limited controls are:

- a Fact colliding with any non-Fact vertex raises when the Fact is logged;
- composite hashes reduce same-type component collision probability;
- the SHA-256 plan introduces domain-tagged component identities and canonical identity documents;
- a later Multigraph adapter/wrapper may generalize conflict checking once each vertex family exposes reliable identity evidence.

This limitation must be called out in release notes. The stopgap closes the demonstrated runtime corruption path but is not the complete identity architecture.

## 5. Runnable identity

`Runnable.new/3` currently calls one-argument `phash2`, whose default range is only `0..2^27-1`. Replace both constructors/helpers with the shared scheme and a Runnable domain tag:

```elixir
def new(node, fact, context) do
  %__MODULE__{
    id: runnable_id(node, fact),
    node: node,
    input_fact: fact,
    context: context,
    status: :pending
  }
end

def runnable_id(node, fact) do
  Components.fact_hash({:runnable, node.hash, fact.hash})
end
```

This remains a content-derived local Runnable key. It is not the distributed activation or attempt ID described in the SHA-256 plan.

## 6. Compatibility and persistence policy

### 6.1 Why this is a format break

Changing the central function changes all newly generated identities, including:

- Closure, component, work, condition, and reaction hashes;
- connection and `InputBinding` IDs;
- root, produced, state, reduced, joined, and fan-out Fact hashes;
- ancestry references and graph indexes;
- Runnable IDs;
- fact-store keys and persisted event fields.

Construction replay usually restores the recorded `ComponentAdded.hash`, which can make old histories appear to work. That is not sufficient proof of compatibility: old events without explicit hashes, new work appended to an old stream, rebuilt compiler artifacts, and fact-store references can create a mixed identity graph.

### 6.2 Chosen alpha policy

For the core library:

1. Document `phash2_32_v0` histories as incompatible with `phash2_64_v1` continuation.
2. Bump the next alpha release and note that persisted workflows/snapshots must be rebuilt.
3. Do not auto-detect a scheme from integer width; small composite outputs can still fit in 32 bits.
4. Do not silently recompute hashes during replay when an event contains an explicit historical hash.
5. Do not add a permanent `{old_hash, new_hash}` index.
6. Allow consuming applications to write one-off migrations if their retained source events and Fact values are sufficient.

If a consumer cannot reset alpha data, it should stay on the old Runic version until the SHA-256 migration/upcaster is available rather than create a mixed stream.

## 7. Implementation phases

### Phase P0 — Freeze evidence and baseline

Deliver:

- move the issue reproduction into an ExUnit regression fixture while retaining the Tidewave script;
- capture the current benchmark as a reproducible Benchee script or test-support module;
- assert the current issue pair collides under the primary 32-bit pass;
- enumerate persisted consumers that require reset or migration instructions.

Gate: the regression fails for the current silent-alias behavior and records isolated versus applied results.

### Phase P1 — Composite hash helper

Deliver:

- add `Components.hash_scheme/0`;
- replace `Components.fact_hash/1` with `phash2_64_v1`;
- document range and non-cryptographic status;
- update narrow types/docs that incorrectly claim string-only or 32-bit identities;
- add deterministic test vectors for atoms, AST, maps, binary payloads, closures, and Fact bases.

Gate: every content-addressability test preserves equality/inequality semantics without relying on old numeric values.

### Phase P2 — Fact identity conflict guard

Deliver:

- add `Runic.Workflow.IdentityConflictError`;
- guard `Fact` and `FactRef` insertion in `Private.log_fact/2`;
- keep exact duplicate Facts and FactRefs idempotent;
- reject mixed Fact/FactRef insertion because a reference cannot prove value equality;
- reject Fact-versus-Fact value/ancestry conflict and Fact-versus-component conflict;
- bound error diagnostics and telemetry metadata.

Gate: forcing two distinct Facts to the same explicit hash fails loudly and cannot produce a successful wrong result.

### Phase P3 — Runnable and direct-call audit

Deliver:

- route `Runnable.new/3` and `Runnable.runnable_id/2` through the composite helper;
- classify remaining direct `phash2` uses as correctness or display-only;
- ensure visualization adapters never influence graph lookup or replay;
- update doctests and type specifications.

Gate: no correctness or idempotency identity in `lib/` uses default-range `phash2` directly.

### Phase P4 — Persistence and release gate

Deliver:

- ETS and Mnesia fact save/load tests with composite keys;
- full, lean, hybrid, and snapshot-tail replay coverage;
- release notes declaring the alpha identity-format break;
- consumer reset/migration checklist;
- benchmark comparison in CI or a documented manual performance gate.

Gate: no test mixes old/new schemes accidentally, and each supported Store round-trips composite keys.

## 8. Expected file-level change surface

### 8.1 Required production edits

| File | Expected change |
|---|---|
| `lib/workflow/components.ex` | Composite implementation, scheme identifier, specifications, documentation |
| `lib/workflow/runnable.ex` | Replace two direct default-range `phash2` uses |
| `lib/workflow/private.ex` | Guard Fact/FactRef insertion |
| `lib/workflow/identity_conflict_error.ex` | New explicit exception |
| Selected component/event modules | Correct inconsistent hash type documentation/specifications |

The 136 central-helper call sites should not require mechanical edits in this plan.

### 8.2 Required tests

| Test area | Coverage |
|---|---|
| New issue #16 regression | Explicit `Step.new` and macro-built `Runic.step` variants |
| `test/content_addressability_test.exs` | Same basis remains equal; different basis remains different |
| Fact/FactRef tests | Exact duplicate, placeholder equivalence, forced conflict |
| Event-sourced tests | Live projection and replay equivalence with composite IDs |
| Runner Store tests | ETS/Mnesia fact keys and stripped-value hydration |
| Runnable tests | Stable 64-bit composite local ID |
| Serializer tests | Composite integer rendering remains valid |

### 8.3 Estimated review size

- Approximately 4-8 production files with substantive edits.
- Approximately 5-8 test files, depending on whether store/replay cases are consolidated.
- No new runtime dependency.
- No mass rewrite of `Runic.step` macro call sites.
- One intentional persisted-format break.

## 9. Test matrix

### 9.1 Determinism

- same term hashes identically across processes;
- same macro source and captured bindings hash identically;
- map insertion/enumeration differences produce the same `phash2` result for equal terms;
- test vector values are stable on the supported OTP matrix.

### 9.2 Collision regression

- issue `Step.new` pair has different composite Fact hashes;
- searched macro-built pair has different composite Fact hashes;
- both applied workflow results remain correct;
- applying two explicitly forced conflicting Facts raises `IdentityConflictError`;
- error happens before drawing the second producer edge.

### 9.3 Replay and storage

- `FactProduced` event round-trip preserves the composite integer exactly;
- `Workflow.from_events/1,2` reconstructs the same graph;
- lean replay produces a `FactRef` with the same identity and ancestry;
- ETS/Mnesia save and load use the composite key unchanged;
- snapshot plus tail replay preserves mapped/join/fan-in indexes.

### 9.4 Performance

- benchmark small and 64 KiB Fact bases;
- record allocations and boxed-integer impact;
- investigate if small-term composite hashing exceeds 3× the current `phash2` time;
- do not block on large-payload performance that the SHA/payload split intentionally replaces unless a current workload regresses materially.

## 10. Acceptance criteria

1. The issue #16 `Step.new` reproduction returns distinct correct results after application.
2. A macro-built `Runic.step` collision probe returns distinct correct results after application.
3. A deliberately forced identity conflict raises a typed error instead of aliasing.
4. Exact duplicate Fact insertion remains idempotent.
5. FactRef-based lean replay continues to resolve values from Store.
6. Runnable IDs no longer use default-range 27-bit `phash2`.
7. All content-addressability, event replay, checkpointing, Runner, and Store tests pass.
8. `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`, and `git diff --check` pass.
9. Release notes explicitly describe the persisted identity-format break.
10. Documentation labels this scheme temporary and links to the SHA-256 successor plan.

## 11. Risks and mitigations

| Risk | Mitigation |
|---|---|
| False sense of cryptographic safety | Name the scheme `phash2_64_v1`; document non-adversarial scope |
| Two passes double traversal cost | Measured small-term overhead is about 108 ns; retain benchmark |
| Large-term hashing is slower than SHA-256 | Do not position composite as payload digest; execute SHA plan |
| Boxed 64-bit integers allocate | Benchmark allocations; accept as temporary or use a later identity struct |
| Old/new histories mix | Alpha hard cut and explicit consumer reset/migration policy |
| Collision still happens | Fail-fast Fact conflict guard |
| Component same-type collision remains hard to compare | 64-bit reduction now; canonical component identity document in SHA plan |
| Stopgap becomes permanent | Track removal as an explicit SHA migration gate |

## 12. Removal condition

`phash2_64_v1` can be removed when all of the following are true:

- `Runic.Identity` and canonical SHA-256 encoding are implemented;
- component definitions and graph node occurrences have distinct identities;
- Fact occurrence and payload/content digests are separate;
- graph insertion validates domain and identity evidence;
- persisted events and snapshots declare/upcast their identity scheme;
- Runner/Runtime idempotency uses activation, attempt, command, transaction, and event IDs rather than graph-local hashes;
- known consumers have migrated or intentionally reset alpha-era data.

At that point `phash2` may remain only inside BEAM Maps/ETS or explicitly private display/cache accelerators where exact-key comparison protects correctness.
