# Changelog

Notable user-facing changes are recorded here, newest first. Entries follow
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Runic is currently an
alpha release; breaking changes and required upgrade steps are called out
explicitly. A merge to `main` is not a published Hex release.

## [Unreleased]

### Changed

- **Breaking:** generated workflow identities now use versioned,
  domain-separated SHA-256 `%Runic.Identity{}` values instead of integer
  `phash2` hashes. This affects component, connection, workflow artifact, Fact,
  activation, and attempt identifiers. See [#18](https://github.com/zblanco/runic/pull/18).
- Facts distinguish payload digests, causal content digests, and occurrence
  IDs. Equal payloads at different fan-out indexes remain separate occurrences.
  `Fact.hash` mirrors the typed occurrence ID; explicit legacy integer and
  binary hashes remain a compatibility input, not an automatic history migration.
- Identity documents use Runic's canonical encoding. Unsupported structs and
  process-local values raise `Runic.Identity.CanonicalError`; applications must
  supply portable data or an explicit `Runic.Identity.Projectable` implementation.
- Workflow artifact hashes incorporate registered semantic component
  projections, including Step/Condition contracts. Rebuild preserves recorded
  authored closures. Runtime context is excluded from artifact identity.
- Cytoscape exports full tagged identity strings in its JSON `hash` fields.

### Added

- `Runic.Identity` digest, derivation, verification, and textual representation
  APIs, plus the `Runic.Identity.Projectable` protocol for explicit projections.
- Explicit Fact occurrence IDs through `Fact.new(id: identity, value: value)`;
  conflicting `id`/`hash` inputs and invalid typed occurrence IDs are rejected.
- Separate Runnable activation and attempt identities, carried through lifecycle events.
- Payload digest verification during FactRef hydration and optional
  `save_payload/3` / `load_payload/2` Store callbacks implemented by ETS and Mnesia.
- Canonical byte vectors and a reproducible identity benchmark in `.docs`.

### Fixed

- Distinct Facts no longer silently alias due to the reported 32-bit hash
  collision, through either `Step.new` or `Runic.step` construction.
  Conflicting identity evidence raises `Runic.Workflow.IdentityConflictError`
  before Fact insertion. See [#16](https://github.com/zblanco/runic/issues/16).
- Projected structs cannot encode as ordinary tuples; external function
  bindings cannot alias literal MFA tuple data.
- Binding-dependent Step, Condition, Reduce, and Accumulator macros use the
  same portable binding projection, including pinned external function captures.

### Upgrading from `0.1.0-alpha.8` or `0.1.0-alpha.9`

The identity change is currently on GitHub `main`. The application version
still reports `0.1.0-alpha.9`, so version strings alone cannot distinguish the
published Hex release from this code. Record the Git revision and identity
scheme in deployment and compiled-artifact provenance until a new release is
published.

1. Update the dependency in the application that declares Runic. If another
   dependency also brings in Runic, retain an explicit override:

   ```elixir
   {:runic, github: "zblanco/runic", branch: "main", override: true}
   ```

   Run `mix deps.update runic` and commit `mix.lock` to pin the resolved Git
   revision. Review the lockfile for incidental transitive updates. To preserve
   all other locked versions, use `mix deps.unlock runic` followed by
   `mix deps.get` instead. For local testing,
   `{:runic, path: "../runic", override: true}` is
   also supported; resolve the path relative to the declaring Mix project.

2. Audit integer-only hash guards, parsing, database columns, and UI identifiers.
   Use typed identities for internal maps and graph lookup. At JSON or other
   text boundaries, use `Runic.Identity.to_string/1`; do not use shortened
   display strings, truncate digests, or rehash them through `phash2` for lookup.
   Keep application-authored node names and business IDs separate from these keys.
   Integer database columns need an explicit migration: a full tagged identity
   fits a text column, not a SQL integer. Update both write and lookup paths.
   Preserve legacy keys separately or tag them with their original scheme;
   converting an old integer to text does not turn it into a SHA-256 identity.

3. Audit values passed into Facts and captured bindings. Plain maps, lists,
   tuples, binaries, atoms, integers, and finite floats are supported. Registered
   struct projections are explicit; arbitrary structs, PIDs, ports, references,
   and live functions are not portable payloads. External function captures in
   closure bindings are projected by MFA. Keep process handles and executable
   callbacks in runtime context instead of content-addressed data.
   This restriction also applies to familiar structs such as `DateTime` and
   `MapSet`, and to nested `%Runic.Workflow{}` values. A map containing an
   unsupported struct is still unsupported. For timestamp-only interchange,
   explicitly convert to ISO 8601 at the application boundary; otherwise define
   a projection that preserves the timestamp semantics your application needs.
   Canonical version 1 also defaults to limits of 64 nesting levels, 100,000
   items, and 16 MiB of encoded bytes.

4. Rebuild compiled workflow caches from authored definitions under the new
   code. There is no general old-hash-to-new-hash upcaster. Preserve old logs and
   snapshots with their original runtime; do not mix old and new graph identities
   in one continuing execution. For disposable development runs, start fresh
   executions after rebuilding definitions. For retained executions, finish or
   isolate them on the old runtime, or implement and validate an application-specific
   migration of every node, Fact, edge, event, and store reference. Do not delete
   durable history merely to get tests passing.

5. Exercise construction, execution, serialization, replay, and storage in the
   consuming application. New Store payload callbacks are optional; a custom
   store must still accept typed keys wherever it stores generated Fact IDs.
   Register custom projections in application source before protocol consolidation,
   and include every field that changes the value's meaning.

   For example, a value object can define its complete versioned document in a
   separate implementation file:

   ```elixir
   defimpl Runic.Identity.Projectable, for: MyApp.Money do
     def identity_document(%MyApp.Money{currency: currency, minor_units: amount}) do
       %{version: 1, currency: currency, minor_units: amount}
     end
   end
   ```

   This defines identity, not serialization or reconstruction. Nested structs
   need their own projections. Do not add an unrestricted `Any` fallback or
   drop meaningful fields merely to make hashing succeed.

[Unreleased]: https://github.com/zblanco/runic/compare/f230c955e241f0e68627efcc7cd2ebbf78a7e4e1...main
