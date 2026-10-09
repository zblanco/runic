# Runic PR Integration and Durable Runtime Action Plan

**Status:** PR integration completed via #25/#29; historical review retained, broader Runtime work proposed
**Date:** 2026-10-08
**Original reviewed upstream baseline:** `main` at `ddcde3a852727ee0896084bd4da40107b5a52312`, Runic `0.1.0-alpha.11`
**Local planning branch:** `zw/dist-runtime` at `6b2ef1befdcc7eed068a339baaeab934e2b83038` before this documentation change
**Companions:** [Runtime Contract Upgrade](runic-runtime-contract-upgrade-plan.md), [Distributed Durable Runtime Core](distributed-durable-runtime-core-plan.md), [Adapter Portfolio](distributed-adapter-portfolio-plan.md), [PostgreSQL Library](runic-postgres-library-implementation-plan.md)

**Original consumer reference:** `agentjido/jido_action`, branch `release/v3`, at `65330e3dfcaae570bc87f570a9c815f52ec2d872`. This corrected an earlier `jido_runic` review, but has itself been superseded by the newer Action design described below. Historical PR-head findings and their original validation remain recorded separately.

## Post-integration update — 2026-10-08

The recommended repair sequence was implemented in [#25](https://github.com/zblanco/runic/pull/25) and [#29](https://github.com/zblanco/runic/pull/29), with upstream main verified at `c23f28bc0ccd0127b07160e2c089d7e3525f58b4`:

- #25 merged first; #23/#24/#26 landed with their original ancestry and targeted integration tests.
- #28's independent recovery/context and executor-lifecycle changes were extracted and adjusted; its stacked draft is closed as superseded.
- #27's revised retry classification and timed-task containment landed; its draft remains open for scoped failure/uncertain-outcome work. No permanent graph halt or new async chunk barrier landed.
- The integrated Runic tree passed **55 doctests and 1,498 tests, 0 failures, 13 skipped**, independently with seeds `739430` and `905355`; focused acceptance passed **57 tests**. These are prior integration results, not new Jido tests or tests of the proposed Runtime.

See the [landed implementation record](https://github.com/zblanco/runic/blob/c23f28bc0ccd0127b07160e2c089d7e3525f58b4/.docs/runtime-pr-foundation-integration.md) for exact adjustments and limitations. The planning checkout was not advanced to main; do not infer implementation state from its older local code.

[Mike's revised review](https://gist.githubusercontent.com/mikehostetler/e238ac08d8a175fd3145e09ec3a31daf/raw/760d7dae3b3ca4a790da0757a7374b5e4cb599f4/runic-runtime-interface-review.md) uses Action `5e52df8` with Runic fork `6b1c8c8`, not our upstream tree. That Action uses Runner for managed calls and custom Invokable nodes; the earlier Controller/Flow.Engine/Invocation-host inventory is no longer its current design. The cited Jido AgentServer independently pins older Action `8e9b3f7` and Runic alpha.11. Dependency migration and fork/upstream failure-policy compatibility therefore require explicit fixtures.

The revised [consumer-simplification plan](runic-runtime-consumer-simplification-design.md) now governs the next consumer-facing slices: complete task ownership and ordinary-node lifecycle support, then correlated outcomes, followed by composite/batch and local-value capability gates. Jido retains Agent revision commits and post-commit effect semantics. The sections below retain the original PR review and historical consumer observations; their open-PR status, deletion targets and receipt-host recommendations are superseded by this update, not additional unfinished merge work.

## 1. Recommendation

Accept the direction of Mike's contributions, land the localized correctness improvements promptly, and separate the new failure semantics from those repairs. Do not make the whole distributed Runtime project a prerequisite for fixing the current Runner. Equally, do not turn today's Task/Worker implementation details into the permanent durable contract.

The original integration sequence was (steps 1–4 are now resolved as recorded above):

1. **Merge #25's acknowledged-persistence fix first.** Silent loss of pending events is the highest-priority correctness problem. Its limits are documented and do not undermine the planned Journal replacement.
2. **Land #23, #24, and #26 with the narrow acceptance gates below.** Manual admission belongs in the runtime shell; dynamic construction-event retention and FactRef metadata preservation reinforce existing core invariants.
3. **Extract/rebase #28's independent recovery and resource-lifecycle repairs.** They should not wait for a decision about terminal failure semantics. Remove the dependency on #27's new halt field from that independent slice.
4. **Revise/split #27.** Retry classification and task-exit handling are useful. A sticky workflow-wide terminal flag and a new barrier-batched async algorithm need an explicit semantic decision and stronger tests before entering the core.
5. **Deliver one small end-to-end durable Runtime slice inside Runic**, using the existing C0–C5 plan: acknowledged input, chronological events, conditional Journal commit, committed dispatch intent, one-attempt execution, accepted result, and replay. Then grow the adapter portfolio against those contracts.

This changes the proposed numerical PR order (`23 → 24 → 26 → 27 → 28`) deliberately: prioritize #25 and avoid coupling useful #28 fixes to #27's larger design decision. If Mike prefers to retain his stack, complete the #27 semantic review before rebasing #28; do not merge the cumulative branch wholesale merely to obtain its lifecycle fixes. This document proposes coordination with him; it does not represent an agreement already made.

The architectural boundary remains: **a topology-independent functional graph VM, with a dependency-light first-party `Runic.Runtime` imperative shell and replaceable infrastructure adapters.** No parallel `runic_runtime` package, no permanent legacy Store bridge, and no mandatory distributed dependency in core.

The original Jido v3 snapshot supplied evidence for scoped fail-fast admission and a host receipt boundary. The newer Action implementation instead uses Runner and custom nodes. Neither snapshot makes our merged Runic tests proof of downstream compatibility; use the pinned differential fixtures in the revised consumer plan.

**Consumer-leverage follow-up:** [A Deeper Runic Runtime](runic-runtime-consumer-simplification-design.md) owns the updated deletion targets: custom-node event boilerplate, task watchers/tracking, event-scanning result inference, internal composite endpoints and local-value wrappers. Its staged gates retain Jido's language, validation and Agent commit/effect authority. Do not make a Journal prerequisite for local benefits or restore removed receipt-host APIs as part of the migration.

## 2. Review inventory and evidence boundary

The six open PRs were inspected through GitHub metadata, patches, and an isolated checkout of their exact heads. #22's recovery of prepared activations is already in the reviewed `main`; it is not unfinished work in #24. GitHub reported #25 as ready for review, although it was originally opened as a draft. #27 and #28 were drafts. These are observations on the date above, not permanent status claims.

| PR | Exact reviewed head | Incremental purpose | Recommendation |
|---|---|---|---|
| [#23](https://github.com/zblanco/runic/pull/23) | `53297ea7cca99c99e693a27d53840a860d761f03` | Opt-in manual Runner dispatch; `step` and `continue` | Land with explicit scheduler-unit semantics and scheduler/admission tests |
| [#24](https://github.com/zblanco/runic/pull/24) | `3ad453985e9f434aaae09027a6b4bf4601044a6b` | Capture construction events produced by apply hooks | Land as a scoped event-completeness fix; retain its no-hook fast path |
| [#25](https://github.com/zblanco/runic/pull/25) | `52cf508d906a8c4d7e7e1b4e808ac914e018c05e` | Acknowledged persistence; retained retry batches; visible failures | Highest-priority merge; preserve its semantics when integrating Worker changes |
| [#26](https://github.com/zblanco/runic/pull/26) | `8545ecfdd2b9e71edb614a52473b8bfd035c45e0` | Carry `Fact.meta` through FactRef and lean replay | Land with a deliberate old-persisted-shape decision |
| [#27](https://github.com/zblanco/runic/pull/27) | `442da3245e6ff6af8e02c24e72d7ff8b2562c82c` | Retry predicate, external failure handling, persistent halt, changed local execution loops | Split mechanics from lifecycle semantics; revise before merging the latter |
| [#28](https://github.com/zblanco/runic/pull/28) | `3468a4eb14ea3cd92c7f1271c9d59315c6e4cf32` | Resume context/policies, snapshot context clearing, supervisor routing, executor release/cleanup | Extract independent repairs; explicitly keep release separate from durable acknowledgement |

### Actual stack shape matters

#23, #24, #25, and #26 are each directly based on the reviewed main. #27 contains four commits: #23, earlier versions of the dynamic-event and metadata changes, and its failure-policy commit. #28 adds one commit to #27. Its incremental change is four files, not the entire 15-file GitHub diff. Review future rebased heads again.

The earlier dynamic-event commit in the stack, `8039a63`, lacks the no-hook fast path in the independently reviewed #24. It counts/reverses the construction log even when there are no apply hooks. Rebuilding on the merged #24 avoids reintroducing that unnecessary history-sized work on every application. This is relevant to long-running, evolving workflows, not just patch cleanliness.

An isolated `git merge-tree --write-tree review/pr25 review/pr28` reports a real conflict in `lib/runic/runner/worker.ex`: initialization, call handlers, stop, and idle transition. A textual resolution alone is insufficient; Section 6 specifies the combined behavior.

### Validation performed during this review

All execution checks used `/tmp/runic-pr-review.rddevO`, a separate clone with copied dependencies/build artifacts, not the user's working checkout. No GitHub messages, merges, branch pushes, or application changes were made.

| Check | Observed result |
|---|---|
| #28 exact head: affected Runner, policy, hook, three-phase, dynamic-event, and FactResolver tests | **439 tests, 0 failures**; seed `739430` |
| #28 exact head: full committed suite, temporary probes outside `test/` | **55 doctests, 1,453 tests, 0 failures, 13 skipped**; seed `739430` |
| #28 exact head: formatter and strict development compilation | `mix format --check-formatted` and `mix compile --warnings-as-errors` passed |
| #25 exact head: persistence-failure, parallel-Promise, Runner, and Worker tests | **93 tests, 0 failures**; seed `479014` |
| Additional desired-behavior probes on #28 | **3 failures**, detailed below; these are outside the committed suite |
| #25/#28 merge-tree check | Worker content conflict; no integrated tree was resolved or tested |

The passing full suite does not include #25, because #28's stack does not contain it. PR descriptions report their own test counts; the table records fresh results, not a reconciliation of those historical counts. There was no live Jido application, database, broker, multi-node failover, or production validation.

## 3. Reconcile the plans with what is already implemented

The July/August architecture plans target alpha.8. The current baseline is alpha.11. Their architectural direction remains appropriate, but implementation must not restart completed work:

- `Runic.Identity` already provides domain-separated SHA-256 identities; `Fact` carries occurrence/content/payload identities and `Runnable` has activation/attempt fields. See [Fact](../lib/workflow/fact.ex), [Runnable](../lib/workflow/runnable.ex), and [Identity](../lib/identity.ex). The remaining task is to bind those identities to durable execution/command/graph-revision semantics, not to introduce cryptographic identity from scratch. Default local Fact construction is not a substitute for a caller-stable ingress command ID.
- The [issue #19 foundation](issue-19-foundation.md) already includes compact coordination contexts, descriptor selection/bounded preparation options, and graph-index improvements. Preserve those gains. Bounded preparation is an opt-in optimization, not automatically a replacement for full-frontier batching.
- `context/1,2`, runtime context injection, event streaming, FactRef hydration, cursor-aware replay, and snapshot reading exist. #28 fixes an ordering/lifecycle defect around them; it does not introduce these concepts.
- #22 recovers already-prepared work. It does not make an after-the-fact `RunnableDispatched` event a write-ahead dispatch record.
- `Runic.Runtime`, the planned conditional Journal, and the structured ExecutionBackend are still proposals. Neither local registration nor a Store acknowledgement provides their fencing, command deduplication, or unknown-outcome resolution.

Use [Runtime Contract Upgrade](runic-runtime-contract-upgrade-plan.md) as the contract authority. Older [distribution primitives](phase-8-distribution-primitives.md) and [full-breadth scheduling](full-breadth-runner-scheduling-considerations.md) documents are useful background, not permission to revive registry-led ownership or expand the closure-based Executor into a second distributed protocol.

## 4. What Jido Action v3 contributes to the design

**Historical snapshot:** This section analyzes `65330e3`, not the newer `5e52df8` reviewed by Mike. Use [the revised evidence inventory](runic-runtime-consumer-simplification-design.md#2-rebaseline-the-evidence-before-choosing-deletion-targets) for current adapter targets. In particular, the old Invocation-host API below is not a requirement to restore in the new Action implementation.

The relevant consumer is [`agentjido/jido_action` on `release/v3`](https://github.com/agentjido/jido_action/tree/65330e3dfcaae570bc87f570a9c815f52ec2d872). At the reviewed commit, [mix.exs](https://github.com/agentjido/jido_action/blob/65330e3dfcaae570bc87f570a9c815f52ec2d872/mix.exs) declares `3.0.0-beta.12` and exactly `runic == 0.1.0-alpha.11`; [mix.lock](https://github.com/agentjido/jido_action/blob/65330e3dfcaae570bc87f570a9c815f52ec2d872/mix.lock) resolves that Runic version and Multigraph `0.16.1-mg.5`. Looking at `jido_action/main` was not a valid way to assess this branch's use of Runic.

### 4.1 Actual package and execution boundaries

Jido v3 owns validated Actions, executable Instruction call frames, canonical data-first Flow definitions, and an in-memory Exec session. The [compiler](https://github.com/agentjido/jido_action/blob/65330e3dfcaae570bc87f570a9c815f52ec2d872/lib/jido_flow/compiler.ex) lowers Flow into native Runic components, including Step, Map/Reduce, and support work, with source/component indexes and semantic/compilation digests. This is not the earlier custom ActionNode/agent Strategy integration.

The [Flow Engine](https://github.com/agentjido/jido_action/blob/65330e3dfcaae570bc87f570a9c815f52ec2d872/lib/jido_exec/flow/engine.ex) drives Runic prepare/execute/apply directly. It owns finite session status, ready work, canonical result application, and revision advancement outside `%Runic.Workflow{}`. It binds a `:jido` runtime context through `Workflow.put_run_context`; the [RunnableExecutor](https://github.com/agentjido/jido_action/blob/65330e3dfcaae570bc87f570a9c815f52ec2d872/lib/jido_exec/flow/runnable_executor.ex) installs call-local execution functions during invocation and restores the original context in the returned Runnable. The inspected execution path does not call `Runic.Runner`.

Consequently, the open Runner PRs address useful shared runtime requirements, but merging them does not itself replace Jido's execution engine or establish a durable Jido deployment. The current branch already uses the released Runic version without those open PR heads. Their precise historical motivation cannot be inferred solely from today's consumer source.

The [execution contract](https://github.com/agentjido/jido_action/blob/65330e3dfcaae570bc87f570a9c815f52ec2d872/guides/execution.md) explicitly excludes persistence, queues, automatic retries/backoff, compensation, distributed coordination, deployment-safe continuation, and durable cancellation. These belong to an outer host. The earlier recommendation about existing Jido automatic retries multiplying Runic retries is withdrawn for v3. One retry owner remains a useful future composition rule, not a defect established in this branch.

### 4.2 Direct lessons for the PR review

| Jido v3 behavior | Consequence for Runic |
|---|---|
| `step/1,2` synchronously executes one selected native runnable; `wave/1` operates on the initial ready set; `continue/1` runs to a terminal result | #23 is a related admission primitive, not API equivalence: its `:ok` is admission and a scheduler unit may be a Promise. Native support work also means a step is not universally one authored Action. |
| Work tokens are revision-scoped; stale/concurrent use is rejected by an in-memory guard | Carry stable execution/command/attempt identity in durable Runtime. A local revision guard or token is not a distributed fence or replay checkpoint. |
| Failure stops new admission, while admitted siblings may finish; session failure is outside the native Workflow | Strong evidence for #27's fail-fast use case, but not for permanently halting a reusable graph on every future input. |
| Concurrent execution refills available slots and sorts completed results back into ready order | A concrete reference for completion-driven admission without #27's chunk barriers; distinguish scheduling order from state/effect application order. |
| Every Action runs in a fresh supervised Task; one call owns its controller/private supervisor and timeout budget | #28's supervisor routing and handle lifecycle are relevant. Reuse these invariants without imposing Jido's exact process tree on all Runic users. |
| Flow collects deferred effect requests in canonical order; Exec does not deliver them | Durable effect delivery needs host-owned acceptance/outbox/idempotency, not telemetry or an executor release callback. |

The [`Execution`](https://github.com/agentjido/jido_action/blob/65330e3dfcaae570bc87f570a9c815f52ec2d872/lib/jido_exec/execution.ex) and [`ExecutionGuard`](https://github.com/agentjido/jido_action/blob/65330e3dfcaae570bc87f570a9c815f52ec2d872/lib/jido_exec/execution_guard.ex) types explicitly contain local references/atomics and are not storage formats. The guard's handling of interrupted mutations is useful inspiration for explicit unknown outcomes, not an implementation of clustered authority.

### 4.3 The important durable-integration seam: Action invocation receipts

[`Jido.Exec.Invocation`](https://github.com/agentjido/jido_action/blob/65330e3dfcaae570bc87f570a9c815f52ec2d872/lib/jido_exec/invocation.ex) defines a host acceptance boundary, not just observer hooks:

```elixir
before_invoke(invocation, ref)
# => :execute | {:replay, receipt} | {:interrupt, reason} | {:error, reason}

after_invoke(receipt, ref)
# => :ok | {:interrupt, reason} | {:error, reason}
```

The [implementation](https://github.com/agentjido/jido_action/blob/65330e3dfcaae570bc87f570a9c815f52ec2d872/lib/jido_exec/invocation/runtime.ex) calls `before_invoke` before Action validation/work and calls `after_invoke` for a fresh normalized outcome before exposing it to dependent Flow work or the root caller. Replay skips the Action's input validation, callback, output validation, and fresh-receipt callback. Concurrent Actions can call the host concurrently. The option is available to `run/4` and `run_async/4`, not the step-wise `start/4` API.

An occurrence ID includes `run_key`, continuation `chain_index`, full component path, role, and selector such as collection/iteration index or Choice option. It is independent of worker PIDs and completion order. A receipt retains the historical descriptor and normalized success, error, or continuation. This gives a much better consumer fixture for Runtime command/attempt identity than the earlier SignalFact analysis.

The distinction from a Runic Journal is essential:

- Jido replay starts a new Exec call and reruns orchestration, replacing confirmed Action invocations with recorded outcomes. It does **not** fold Runic construction/lifecycle events or restore an Execution snapshot.
- Expressions, validation outside the Action edge, parameter binding, Reduce/Iterate coordination, and materialization may run again. The host must pin or control their inputs and code so replay is deterministic.
- Jido verifies protocol/occurrence/shape validity; the host decides whether Action, params, compatibility token, and evidence permit reuse. Flow digests do not identify all Action/helper code.
- Descriptors omit raw context, but a context value copied into params remains there. Receipt outcomes can contain exceptions, functions, streams, PIDs, opaque values, and effects; a structural identity is not a guarantee that the whole receipt is portable.
- An effect can happen before receipt acceptance, and an acceptance can succeed before its reply reaches the caller. Neither gap permits automatic assumption that the Action did not run.
- Replayed success can return the same deferred effects again. Host delivery must deduplicate and preserve the chosen publication boundary.
- An explicit nested `Jido.Exec.run` inside an Action is opaque to its parent invocation; it has no automatic child durable identity. Do not confuse it with structural Subflow paths or supported continuation-chain identities.

The repository contains a [two-VM receipt replay test](https://github.com/agentjido/jido_action/blob/65330e3dfcaae570bc87f570a9c815f52ec2d872/test/system/invocation_restart_test.exs) that transfers a definition, call data, and selected receipts without a native Workflow, then expects only missing Action work to execute. This test was inspected, not run here. Its deliberately missing receipt also illustrates why receipt replay alone does not prevent repeated effects.

### 4.4 Revised integration recommendation

Keep Runic's canonical event/Journal design. Use Jido's receipt protocol as an application-facing integration seam, not a substitute event authority or a reason to force Jido to become a durable runtime.

There are two distinct profiles worth evaluating:

1. **Runic-managed graph execution with Jido Actions as work.** Runic owns committed graph/attempt transitions. The integration preserves Jido's input/output validation and normalized Action result semantics, while core Runtime owns retry/timer/acceptance. Decide how fine-grained Action occurrences map to activations: Reduce, Iterate, and continuation paths must not be assumed one-to-one with a scheduler unit.
2. **Host-managed replay of a Jido Exec session.** A host implements Invocation receipts and reconstructs the Jido session under an explicit deterministic-orchestration contract. That can use the same storage/identity foundations, but is a separate replay profile, not automatically equivalent to event-fold recovery of arbitrary continuously evolving Runic workflows.

Prototype the receipt host in consumer/integration code against the reference Journal. Before returning `:execute`, the host must have resolved existing accepted/uncertain work and, for a durable profile, committed the intended attempt. Return `:ok` from `after_invoke` only after authoritative receipt acceptance; on an unresolved outcome interrupt the session rather than dispatch dependent work. Define how accepted Action receipts, Runic result events, and deferred-effect eligibility share an atomic decision or a recoverable handoff. Do not introduce two independent execution authorities or put Jido-specific fields into every Runic event.

This is a correctness-critical acceptance protocol when enabled, unlike best-effort lifecycle observation or #28's local `release/2`. It reinforces the planned deep Journal/ExecutionBackend boundary. Keep Jido's Flow DSL, validation, effect collection, and finite-session semantics application-owned; retain Runic's topology-free functional APIs and broader long-running workflow model.

## 5. PR-by-PR decisions

### 5.1 #25 — merge the persistence repair, with honest limits

The [patch](https://github.com/zblanco/runic/pull/25/files) fixes a broken acknowledgement contract at the correct boundary: the Worker. It retains full chronological retry data until fact/payload saves and event append succeed; records the Store-returned cursor; returns errors from explicit checkpoint/stop; keeps the Worker alive after failed persistent stop; and preserves updated state through idle transition.

This is compatible with the future Journal even though today's Worker still applies before committing. A necessary local repair is not an endorsement of the old Store as the clustered contract.

Preserve these guarantees when rebasing:

- failed fact/payload writes prevent compact event append;
- the full batch survives repeated failures while the Worker is alive;
- only acknowledged append advances the event cursor;
- a failed stop does not clean up executors or terminate the Worker;
- startup build persistence fails visibly before dispatch;
- computation completion and acknowledged persistence remain distinguishable;
- individual, sequential-Promise, and parallel-Promise results share persistence staging.

Explicit limits must survive release notes:

- `:saved` describes the acknowledged state so far, not future in-flight results or universal disk durability;
- Store callback errors retain live memory; Worker/VM death can still lose uncommitted work;
- timeout-after-commit cannot be resolved reliably by this callback shape alone;
- re-sending an expanding pending batch is not a stable Journal transaction protocol;
- no automatic bounded outage retry, dispatch suspension, or admission budget is introduced;
- `Runner.run` is still a cast, not durable input acceptance;
- lifecycle logging still occurs after execution; external side effects remain retryable/possibly duplicated.

The cursor reported immediately after resume is zero until this Worker observes an append acknowledgement. Do not feed that value to a new snapshot-writing policy as though it were the restored stream boundary. Thread the actual restored cursor/receipt before labeling snapshots.

The PR documents a separate full Map/Reduce build-log reconstruction failure: successful stop/resume can lose the reconstructed productions, while replay against the authored topology succeeds. That is prior recorded evidence in the [PR's analysis](https://github.com/zblanco/runic/blob/52cf508d906a8c4d7e7e1b4e808ac914e018c05e/.docs/issue-21-checkpoint-persistence.md), not freshly reproduced here. Keep it as a named C1/recovery gate; do not claim #24 or #25 establishes complete Map/Reduce recovery.

Follow-up: add bounded pending-byte/admission health controls to the managed runtime. Do not delay this fix to design a distributed retry system, and do not let an observer hook become the correctness path.

### 5.2 #23 — accept local admission control, not durable pause semantics

The [manual-dispatch patch](https://github.com/zblanco/runic/pull/23/files) stays in Runner and is appropriately scoped. `run` plans without dispatch in manual mode; `step` admits one scheduler unit; `continue` switches the process back to automatic admission. Active tasks make `step` return `:busy`.

For Jido v3 interoperability, distinguish its synchronous one-runnable `step` and initial-ready-set `wave` from this admission API. A Jido revision token is not a Runic durable command ID, and the Invocation receipt option currently does not apply to Jido's step-wise API. Do not imply #23 closes that integration gap by itself.

Before merge, make the following executable/documented:

- `step :ok` acknowledges admission, not completion or persistence; Inline execution may nevertheless complete inside the call;
- Promise execution can include several components; a debugger needing one-node stepping selects an appropriate scheduler;
- manual mode is process-local configuration, not a journaled human-approval checkpoint, rewind, cancellation, or durable pause;
- checkpointing a manually held workflow and resuming manually must not execute held work unexpectedly;
- `continue` with in-flight work must not duplicate dispatch;
- custom stateful schedulers must tolerate partial acceptance of their returned plan.

The last point exposes an existing contract tension: Scheduler documentation describes concurrency-filtered input, while Worker intentionally supplies a full candidate frontier and later caps dispatch. #23 additionally takes one returned unit. Scheduler state must not assume that every proposed unit was dispatched. Clarify proposal-versus-acceptance now; test a scheduler with state and more units than available slots. The long-term Scheduler contract should receive a budget and/or an explicit accepted-plan update, not infer ownership from a planning call. Use the smallest change justified by the fixture.

Do not add a special distributed stepping behaviour. In durable Runtime, a durable control command can authorize a bounded dispatch decision, with the chosen unit semantics recorded. Local inspection mode can remain nonpersistent.

### 5.3 #24 — accept event completeness; do not overclaim chronology

The [dynamic-event patch](https://github.com/zblanco/runic/pull/24/files) measures the construction-log suffix produced by apply hooks and inserts it into the uncommitted event buffer. The included test reconstructs and executes a dynamically added component. This supports the intended event-first reconstruction lifecycle and is worth landing independently.

Retain the standalone PR's guard that skips construction-log scanning when there are no apply hooks. Add/retain coverage for multiple additions, ordering relative to triggering execution and downstream activation, and replay from a nonempty prefix.

Boundaries:

- recording a hook-produced event is different from replaying its arbitrary closure;
- construction-log suffix capture assumes append-only construction recording; graph mutation that bypasses that contract is not suddenly replayable;
- current split reconstruction is not yet a strict chronological fold over construction, mutation, and execution;
- snapshot-plus-structural-tail replay and Promise-local mutation/application require separate tests;
- a test adding a Step does not prove all Map/Reduce/custom-component rebuilds.

For C1, require live projection equals replay at every relevant prefix, including graph revision changes. Keep AST/bindings reconstruction. Do not prohibit anonymous Runic components simply because the live struct also contains a compiled function.

### 5.4 #26 — accept metadata preservation; close persisted-shape handling

The [FactRef patch](https://github.com/zblanco/runic/pull/26/files) fixes a real representation mismatch: moving a Fact to cold storage and hydrating it should not discard its metadata. It intentionally does not change value/content/occurrence identity.

One additional probe failed on the reviewed stack: take a pre-change FactRef term without the `:meta` key, decode it, then hydrate it. `%FactRef{}` matching still accepts that old struct-shaped map, but `FactResolver.resolved_fact/2` accesses `ref.meta` and raises `KeyError`.

Recommended small repair: normalize missing metadata to `%{}` at the supported read boundary (or use the equivalent safe field access), with an ETF round-trip regression. This is not a request for indefinite backwards compatibility. An explicit snapshot/version incompatibility error is also legitimate in alpha, but an accidental `KeyError` is not a useful persisted-data policy. Coordinate with #28's version-one snapshot normalization instead of scattering field defaults throughout execution code.

Keep metadata bounded and separate from credentials/worker resources. Fact metadata that matters to replay must survive the codec and projection pipeline; runtime secrets belong in context resolution. Metadata should not become an ad hoc place for authority epochs, transaction receipts, or opaque executor handles.

### 5.5 #27 — split mechanics from new lifecycle semantics

There are three different changes in the [failure-policy proposal](https://github.com/zblanco/runic/pull/27/files). Review them separately.

#### A. Retry classification: accept the capability

An optional `retry_if` predicate is useful for typed action errors, provider throttling, validation failure, and user cancellation. Preserve a local function form for direct in-memory execution and support an explicit module/function form for portable policy references.

Required decisions/tests:

- define what the predicate receives: the normalized attempt error, with original error available where safe;
- require a boolean result and specify invalid/raising predicate behavior;
- max retries/deadlines still bound execution;
- classify before deciding retry/fallback/skip/halt consistently;
- retain error classification at the application boundary; Runic must not know Jido's exception taxonomy;
- portable policies pin code/config versions; a function in an in-memory policy is not automatically a portable durable record.

Do not extend the `Process.sleep` retry loop into durable operation. The new Runtime executes one attempt, records its accepted result, and records a due-time retry if policy permits. Local convenience evaluation may still have a bounded in-process retry loop.

#### B. Task-exit normalization: useful, but incomplete

The proposal handles `{:exit, reason}` from `Task.yield` and adds `external_failure/3` for executor crashes. Two issues remain:

1. **Linked-task failure is not fully contained.** The timeout path uses `Task.async`. A probe running a timed step that calls `Process.exit(self(), :kill)` in a monitored, non-trapping caller observed `{:DOWN, ..., :killed}` for the caller, not a failed Runnable. The new test covers a normal exit, which does not prove abnormal-exit isolation. This is an existing weakness not fully solved by the new clause, not a claim that #27 introduced all linked-task behavior.
2. **External failure bypasses retry/fallback.** At the reviewed head, `PolicyDriver.external_failure/3` directly applies `on_failure`. It does not run the ordinary retry predicate/max-retry/fallback decision. A normal Runnable error and an executor crash can therefore receive different policies. A remote crash may also leave the effect outcome unknown; it must not be treated as proof that no effect occurred.

Choose a common pure failure decision over typed outcomes; let the local driver or Runtime supply the mechanism. For Task isolation use a monitored/nonlinked execution mechanism appropriate to the host. Do not globally change the caller's trap-exit policy or require a new mandatory process topology for direct Workflow use. Add abnormal exit, timeout, predicate exception, fallback, and external-crash tests; do not convert VM/process death into a false exactly-once promise.

Promise crash accounting needs care too: a crashed task does not prove every promised activation ran and failed. Distinguish accepted completed prefixes, started/uncertain attempts, and undispatched obligations. Serial and parallel batch results must not fabricate execution of later nodes or rerun accepted prefixes.

#### C. Durable workflow-wide halt: do not merge this representation unchanged

The new `%Workflow{halted_by_failure: boolean}` is sticky: any halting failure in `runnable_events` sets it, replay restores it, and there is no explicit clearing/control transition. That changes the meaning of a graph that may accept repeated inputs and evolve indefinitely.

Questions the representation does not answer:

- Does failure stop the current evaluation call, one activation, a causal input branch, or the entire managed execution?
- Can an independent branch or later input proceed?
- Is the state paused/recoverable, or terminal/failed?
- What happens to already-dispatched siblings and their late results?
- Is an operator retry/resume a control event, a new attempt, or a new execution?
- Does an idle callback mean success, failure, waiting for input, or merely no active tasks?

There is also a concrete inconsistency: after appending a halting failure, `react_until_satisfied(halted)` returns unchanged, but `react_until_satisfied(halted, 10)` executes a first reaction before checking the flag. A one-step `input + 1` graph produces `[11]`. The three-probe run reproduced this on #28, which includes #27.

Recommended direction:

- keep an attempt's failure/outcome in typed graph/runtime events;
- make direct evaluation's stop decision explicit and scoped to that evaluation, without silently making all future uses of the graph terminal;
- let managed Runtime own execution-level admission/lifecycle policy and project it from explicit control/terminal events;
- distinguish `paused`, `failed`, `cancelled`, `waiting`, and `quiescent` where the managed API needs them; graph quiescence alone is not terminal success;
- if a terminal execution is restarted, create a new execution identity by default; if a recoverable pause is resumed, record that transition and its scope;
- do not mechanically move the same ambiguous boolean to Worker: semantics must be defined first.

This need not become a large new public outcome hierarchy before any fix lands. A small ADR and pure decision table, exercised by direct/async/Runner fixtures, is sufficient to choose the first supported semantics. If `on_failure: :halt` cannot be changed cleanly in alpha, rename the option to its actual scope. Avoid preserving an ambiguous API at the cost of multiple hidden meanings.

#### D. Preserve work-conserving concurrency

The async implementation changes from one task stream to chunks of `max_concurrency`, waiting for each entire chunk before starting the next. That bounds post-failure admission but creates a barrier: one slow action holds up the next chunk even when other slots are free.

Use an explicit bounded completion-driven admission loop for the controlled runtime, with a stop decision made when failure is observed. Promise/batch schedulers remain available when a batch barrier is intentional. In-flight effects cannot be recalled retroactively. Do not promise that observing one failure means no sibling could have started.

Jido v3's `RunnableExecutor.execute_concurrently` is a concrete reference: it tracks available slots and active Tasks, stops additional admission after failure/interruption, and restores ready-order results before application. Review it for transferable invariants; do not copy its private controller/context machinery into Runic's functional core.

Before adopting an alternative loop, preserve any documented application/reduction ordering. Completion-order task admission does not imply completion-order state application is safe for every Runic node. Test mixed fast/slow tasks, multiple simultaneous failures, `max_concurrency > 1`, noncommutative reducers, and repeated inputs. The issue #19 performance work makes a silent global barrier especially undesirable.

### 5.6 #28 — accept recovery ordering and local resource ownership

The [incremental commit](https://github.com/zblanco/runic/commit/3468a4eb14ea3cd92c7f1271c9d59315c6e4cf32) has several strong, reusable repairs:

- apply resume-time context and policy overrides before recovering pending work;
- choose the configured single or partitioned Task Supervisor;
- make supervisor information available to custom executors;
- associate each active handle with the actual executor instance;
- separate same-module executor instances with distinct configuration;
- release handle resources after result/crash;
- clean up the initialized executor once on ordinary stop instead of twice.

These are Worker/shell responsibilities and good candidates to land ahead of #27's lifecycle redesign. Rebase tests that depend on the new halt field, and leave any halt-field snapshot normalization with the change that finally defines that field/model.

Define `release/2` narrowly: **local executor bookkeeping/resource release after observing a handle's terminal notification**. It is optional because correct basic execution has a fallback without it. It is not durable acceptance, a broker acknowledgement, cancellation confirmation, or a guarantee of cleanup after `:kill`/VM loss.

This distinction is critical: #28 releases before result application/checkpointing. A Broadway/RabbitMQ/PubSub implementation must not interpret that callback as permission to acknowledge work. In the new ExecutionBackend contract, acknowledgement/redelivery obligations follow a committed result receipt (or another explicitly durable result inbox), not arrival at the Worker mailbox.

Additional gates:

- duplicate/late result and `:DOWN` notifications release a tracked handle at most once; independently verify that duplicate results do not reapply side-effectful hooks or persistence batches;
- successful stop cleans up once; failed persistent stop cleans up zero times and retains executor state;
- initialization failure releases initialized resources even though normal `terminate` handling is not available for a failed init;
- cover per-policy override executors, distinct options, Promises, and partitioned supervision;
- specify what happens if release/cleanup raises, so resource bookkeeping cannot silently destroy an uncommitted result;
- do not treat an unbounded `{module, opts}` cache as a permanent pool/resource model if runtime policies continuously introduce new configurations.

Snapshot context clearing is a good security default with a narrow claim: the patch removes the top-level `Workflow.run_context`. A raw Workflow ETF can still contain ordinary captured values, node-specific context, policies, hook functions, or resources embedded elsewhere. It is not the portable/safe snapshot IR in C5. Preserve macro AST and valid captured bindings; validate the declared portable projection and resolve runtime resources separately.

For the current single-process API, applying replacement resume options before prepare is correct. For future overlapping inputs, context must be scoped by input/activation lineage and resolved on the executing worker. Do not let a newly supplied global context silently rebind an already committed attempt. Policy revisions similarly affect new decisions unless an explicit authorized control transition changes pending work.

## 6. Combined Worker integration checklist

The following is the intended resolution contract, not an instruction to take either side of merge conflicts:

| Boundary | Required combined behavior |
|---|---|
| Resume initialization | Restore supported shape; apply context/policies before prepare/recovery; obtain correct executor supervisor; preserve #25's acknowledged build/init error flow |
| Fresh initialization | No dispatch before successful required build persistence; clean initialized executors on failed init |
| Manual calls | Keep `step`/`continue` and `persistence_status`; admission state and persistence health remain distinct |
| Result/crash | Correlate tracked attempt; release local handle once; stage full event/value batch; retain on returned persistence error; apply defined failure/admission policy |
| Stop with persistence | Persist first; on failure return error and retain process/resources; on success normal termination owns cleanup once |
| Stop without persistence | Explicit discard semantics; cleanup once; do not pretend remote side effects were cancelled |
| Idle/quiescence | Preserve the returned post-persistence state; report persistence outcome; do not conflate halt/quiescence with successful durable completion |
| Resume cursor/snapshot | A restored stream boundary is not a freshly started Worker's zero cursor; snapshot state and committed position must match |

Add a combined regression: custom executor completes an action; Store append fails; local handle resources release once; pending values/events remain; persistent stop fails without executor cleanup; checkpoint retry succeeds; stop succeeds and executor cleanup occurs once. For a future broker backend, the corresponding delivery remains unacknowledged until the committed completion outcome is known.

Add a second combined regression: manual execution mutates graph structure, creates metadata-bearing output, checkpoints, stops, and resumes with fresh runtime context; uncommitted graph events, metadata, and subsequent execution all survive. Include a snapshot-tail variant only with an accurately paired acknowledged cursor.

## 7. The next architecture increment: one durable vertical slice

**Post-#29 sequencing:** This is the durable workstream, not a prerequisite for the consumer plan's S1 ownership/node-contract and S2 outcome work. Reuse their shared mechanics in this slice. The concrete Journal gates below remain necessary before new durability claims.

The PR batch should leave the local runtime more reliable, not add a second distributed implementation. The next implementation should demonstrate the complete correctness path on a small graph before broadening callbacks or packages:

```text
input command + stable ID
  → decide ordered transition
  → Journal conditional commit → confirmed receipt
  → apply committed projection
  → committed dispatch request → one-attempt backend
  → result proposal → validate/decide → Journal commit
  → apply accepted events → acknowledge delivery
```

After a commit with unknown outcome, resolve/retry the same transaction identity according to the Journal contract before advancing authority-side state or acknowledging delivery. The diagram shows logical boundaries, not necessarily one process or one database round trip per arrow.

### 7.1 First slice acceptance surface

Use an in-memory reference Journal plus controllable fault injection. An ETS implementation proves protocol behavior and Worker restart within its owner lifetime, not crash-persistent disk durability. Add a persistent SQLite/consumer fixture when proving process/VM recovery.

The first runnable example should demonstrate:

- start an execution from a reconstructable macro-built definition;
- accept two commands with distinct IDs, including equal payload values;
- preserve captured bindings and resolve execution context without journaling secrets;
- commit a dispatch intent before executing one action;
- accept a result at most once into history even if delivery repeats;
- crash/recover the coordinator at each transition boundary;
- resolve a lost append reply without inventing a second transaction;
- stop admission on storage unavailability according to the requested durable profile;
- replay to the same graph/lifecycle projection.

A no-retry initial slice may stop with an explicitly represented failed attempt; it must reject unsupported durable-retry policy rather than silently use an in-process sleep. Add a real timer event/claim path before enabling durable retries or scheduled waits.

### 7.2 Map the contributions into existing phases

| Existing phase | Reuse from PRs/current implementation | Work still required |
|---|---|---|
| C0: semantics/reference model | Typed identity foundation; observed failure and acknowledgement cases | Receipt/unknown/fencing types; failure/control scope ADR; pure transition model |
| C1: chronological events | #24 construction suffix, #26 metadata, current typed graph events | Strict chronological fold, complete skip/failure/control events, custom-node and Map/Reduce round trips, schema/version policy |
| C2: Journal | #25 failure fixtures and payload-before-reference discipline | Conditional atomic transaction, stable transaction identity, command dedupe, outcome resolution, cursor/receipt semantics |
| C3: Runtime coordinator | #23 admission UX; #25 health/error observation; #28 recovery ordering | Acknowledged ingress; decide/commit/apply; durable admission/control; restart from committed truth |
| C4: ExecutionBackend | #28 resource ownership; current Task/GenStage/Promise experience | Structured committed requests/results, duplicate/stale handling, backpressure and delivery acknowledgement |
| C5: context/payload/portability | `context/1,2`, macro AST/bindings, identity verification, #26 | Invocation-scoped context references; portable snapshots/artifacts; custom-component conformance |
| C6/C7: consumers/adapters | Jido Action v3 Flow/Invocation contracts alongside Infinite Isekai, RunicAI, Compendium, Libbit | Migration fixtures, receipt-versus-event replay profiles, bounded durable queues, authority/fencing and multi-node fault tests |

These phases are deliverables, not a waterfall requiring all portability and cloud features before a useful local Runtime. Implement the minimum coherent path through them first; label incomplete capabilities explicitly.

### 7.3 Keep the interface small and the implementation deep

- Keep Journal, ExecutionBackend, and PayloadStore as the initial infrastructure behaviours, with Scheduler/ContextResolver as in-package policies.
- Prefer a common pure failure/transition decision over duplicated loops in Worker, direct serial, direct async, and broker consumers.
- Keep lifecycle/control policy out of graph algorithms unless it expresses a genuine graph semantic. Pure state can carry event-derived projections without importing process ownership or cloud assumptions.
- Treat optional callbacks as optimizations/resource hooks with correct defaults. Fencing, conditional commit, and durable acknowledgement are requested capabilities, not optional best-effort conventions.
- Preserve direct Workflow use and Jido Action v3's native Flow driver. Do not require an Ecto repo, Broadway pipeline, Task Supervisor singleton, registry, or `Runic.Runtime` process to compose/evaluate a graph locally.
- Replace alpha contracts once, migrating reference consumers in the same effort. Current bug fixes do not require maintaining a permanent compatibility runtime.

## 8. Adapter consequences

The portfolio order does not change because of these PRs. Their contribution is better reusable semantics/tests, not a reason to start with native consensus or a distributed registry.

| Adapter/profile | What this review changes | Gate before durability claims |
|---|---|---|
| SQLite / existing consumer stores | Reuse failure, reconstruction, metadata, and context fixtures | Atomic journal protocol and supported replay; explicitly single-writer/host failure assumptions |
| `runic_postgres` | Reuse #25 tests; implement projection/status from committed events rather than callbacks | RP0–RP5 contracts; conditional transaction/dedupe/unknown resolution; paired snapshots and cursors |
| PostgreSQL queue + Broadway | Preserve manual/bounded admission concepts and batch tuning; release is not queue ack | Commit completion before ack; lease/redelivery/claim generation; bounded in-flight work and fair budgets |
| Broadway + external broker | Backend owns transport, not retry truth | Committed request/result correlation; duplicate/late outcome conformance; backpressure independent of Journal choice |
| RocksDB / blob payloads | #26 supports cold/hot metadata consistency; #25 shows failure ordering | Immutable payload integrity and safe reference/GC rules; embedded storage alone is not HA |
| Group / Horde / registry | Helpful routing, membership, placement | Journal-fenced authority still required; registration is not a completion receipt |
| Ra / Khepri-native profile | Reuse deterministic transition and fault suite | Replay/conditional commit first; no arbitrary closures/resources in replicated commands |
| CASPaxos / EKV experiments | Same core protocol and acknowledgement boundaries | Validate the selected protocol's actual safety/liveness assumptions; no blanket wait-free claim under arbitrary contention/partition |

For PostgreSQL, keep the planned separation between immutable payloads, append-oriented canonical events, mutable queue/lease rows, management definitions, and projections. Neither `on_idle` nor `release` should become a trigger that commits domain truth. A projection may lag; a completion receipt may not falsely precede its authoritative transaction. Preserve independent Journal/PayloadStore/backend selection.

Broader expert load controls belong in Runtime/backend policy: pending-byte budget, selected activation count, in-flight attempts, batch size/bytes, checkpoint/commit cadence appropriate to the guarantee, tenant fairness, connection/claim limits, and downstream service limits. One Worker `max_concurrency` value cannot express all of these. Introduce controls with measured workloads and avoid exposing backend-specific implementation knobs through the functional VM.

## 9. Concrete work packages and exit gates

### A. Stabilize the current alpha runtime

**Completed repair integration:** #25/#29 landed the scoped changes; see the post-integration update for the exact split and remaining #27 semantics. The checklist below records the original work package rather than requesting another merge of those PRs.

1. Land #25; release notes distinguish successful computation, acknowledged persistence, and durable effects.
2. Land #23/#24/#26 after the narrow tests/shape handling above.
3. Rebase/extract #28; resolve Worker lifecycle behavior using Section 6, not an ours/theirs merge.
4. Split #27 into retry classification/task supervision and a separately decided failure-scope change.
5. Run the complete integrated suite, focused fault tests, formatter, strict compile, and whitespace checks on the final head. Record pre-existing warnings separately if present; passing tests do not waive a failed compile gate.

Exit: no acknowledged Store failure loses live pending data; metadata and dynamic additions survive supported replay; manual admission and resource cleanup have defined semantics; no new ambiguous terminal flag ships by accident.

### B. Close the semantic decisions with fixtures

Write a small ADR covering:

- direct evaluation stop vs branch failure vs managed execution terminal state;
- new-input behavior after each state;
- late sibling results, cancellation, and uncertain effects;
- one retry owner and retryable error classification;
- scheduler proposal/accepted work distinction;
- definition capture vs invocation context vs portable policy;
- supported old event/snapshot versions and explicit incompatibility errors.

Use the revised Jido Action custom-node and Runner integration as fixtures without adding a Jido dependency to Runic. Include an unrelated callback component and preserve low-level custom-node conformance. The old Invocation-host receipt fixtures remain historical requirements to re-evaluate, not an API to restore. Exercise the selected `jido_action/release/v3` revision against upstream before calling the migration supported. Include a finite fail-fast invocation, repeated inputs and a long-running graph accepting unrelated later inputs.

Exit: the same semantic case has the same observable outcome under direct serial, async, managed Task, and Promise execution, except for documented concurrency/in-flight boundaries.

### C. Repair replay completeness and build the Runtime slice

1. Add live-versus-replay properties for dynamic construction, graph revisions, failures, skips, joins, stateful components, and Map/Reduce.
2. Implement the reference Journal/transition protocol and use #25's failure cases as conformance seeds.
3. Introduce `Runic.Runtime` and replace Runner/Store/Executor internals intentionally; retain no parallel durable event model.
4. Add structured attempt dispatch/results, invocation context, and truthful persistence/acceptance receipts.
5. Add timers/control transitions and bounded recovery/admission incrementally.

Exit: accepted commands and accepted results survive every supported failure boundary; unsupported guarantee profiles fail explicitly.

### D. Prove consumers, then publish infrastructure libraries

1. Migrate one SQLite-backed consumer and the Infinite Isekai PostgreSQL fixture.
2. Add the revised Jido Action ordinary-node, task ownership, correlated-outcome, composite-batch and portability fixtures. Separately migrate Jido AgentServer's older Action API/dependency and prove its Turn commit/post-commit effect boundary. Verify Action-to-activation granularity before promising child-level replay; do not require the removed Invocation-host API.
3. Build `runic_postgres` and the Broadway bridge against actual behaviour contracts; do not publish a new durable queue architecture on the old closure Executor merely because `release/2` now exists.
4. Add native Ra/CASPaxos and route integrations after the shared semantics/fault harness can evaluate them.

Exit: adapters differ in infrastructure, operational tuning, and capability, not in the meaning of input acceptance, dispatch, result acceptance, or replay.

## 10. Regression and performance matrix

| Area | Minimum cases to add/retain | Why |
|---|---|---|
| Persistence | Failure at each value write/append; retry; idle; stop; startup; non-count cursor | #25 must survive every rebase and execution mode |
| Merge interaction | Release then append failure; failed stop; later checkpoint success; one cleanup | #25 and #28 overlap semantically as well as textually |
| Manual control | Single unit, Promise unit, in-flight busy, manual recovery, continue race, stateful scheduler | Prevent debugger UX from silently becoming ownership/durability policy |
| Failure semantics | New input after halt; independent branches; skip/fallback; normal/abnormal exit; timeout; predicate errors | Current tests miss important entry paths and process failure modes |
| Async execution | Fast/slow siblings, multiple failures, work-conserving admission, ordering-sensitive reducers | Avoid a throughput regression disguised as failure consistency |
| Replay | Metadata, dynamic additions/removals/replacement where supported, snapshot structural tail, custom nodes, Map/Reduce | Recorded events must actually reconstruct the same state |
| Persisted evolution | Pre-meta FactRef, pre-field Workflow snapshot, unsupported version, old event envelope | Prefer a supported upcast or explicit rejection over accidental crashes |
| Context | Fresh resume values, no top-level snapshot secret, nested nonportable values, overlapping input lineages | Local context clearing is not a portable context protocol |
| Results | Duplicate/late notifications, stale attempts, retry after lost commit reply | Resource release and authoritative acceptance are different |
| Jido integration | Fork/upstream policy differences, callback-node lifecycle, owner death, repeated invocation/batch identities, nonportable outcomes, stale Turn results and post-commit delivery | Runic completion does not replace Jido's Agent revision commit or effect delivery authority; old host receipt APIs are historical |
| Long-running load | Growing construction history, 10k+ frontier, mixed latency, outage pending bytes, changing executor configurations | Test history-sensitive costs, fairness, and bounded resource ownership |

Reuse the issue #19 harness for directional regressions, adding a no-hook apply path with a large construction log and an async mixed-latency workload. Report build, execution, persistence, and replay costs separately. A test count is not throughput evidence; no new performance benchmark was run in this review.

## 11. Reproducible review notes

The isolated checkout was fetched from the six PR refs and switched to the pinned commits, with dependencies copied from the local checkout. Mix needed permission to open its local PubSub socket; the initial sandbox `:eperm` was an environment failure, not a Runic test failure. Runic has no `mix precommit` task (`mix help precommit` confirms this), so the available test, formatting, and strict compilation commands were used. Local documentation links, fenced blocks, and whitespace were checked separately.

Reproduction commands with the observed test seeds made explicit:

```sh
# On 3468a4eb14ea3cd92c7f1271c9d59315c6e4cf32:
mix test test/runner test/workflow/failure_policy_test.exs test/workflow/fact_resolver_test.exs test/workflow/dynamic_apply_events_test.exs test/policy_driver_test.exs test/hook_runner_test.exs test/three_phase_test.exs test/three_phase_invokable_test.exs --seed 739430
mix test --seed 739430
mix format --check-formatted
mix compile --warnings-as-errors

# On 52cf508d906a8c4d7e7e1b4e808ac914e018c05e:
mix test test/runner/persistence_failure_test.exs test/runner/parallel_promise_test.exs test/runner/runner_test.exs test/runner/worker_test.exs --seed 479014

# Temporary exact-head integration analysis only:
git merge-tree --write-tree review/pr25 review/pr28
```

The extra probes are left outside the suite in the temporary review checkout as `review_pr_probes.exs`; they are not production edits or committed regression tests. Their minimal cases are:

1. Append `RunnableFailed{failure_action: :halt}` to a graph with one `input + 1` Step. Empty-input `react_until_satisfied` returns unchanged; a new input `10` nevertheless produces `[11]`.
2. In a monitored non-trapping caller, execute a Step that `Process.exit(self(), :kill)` through PolicyDriver with a finite timeout. Observe caller exit `:killed`, not a returned failed Runnable.
3. Remove the new `meta` field from a FactRef, round-trip it through ETF, and hydrate from a resolver containing its payload. Observe `KeyError` at `FactResolver.resolved_fact/2`.

The first is a new halt-path inconsistency; the second limits the proposed exit-handling fix; the third requires an explicit persisted-shape policy. These observations support the proposed review gates without implying the entire PRs are unsuitable.

## 12. Sources and design precedence

Primary implementation sources are the linked [PR #23](https://github.com/zblanco/runic/pull/23), [#24](https://github.com/zblanco/runic/pull/24), [#25](https://github.com/zblanco/runic/pull/25), [#26](https://github.com/zblanco/runic/pull/26), [#27](https://github.com/zblanco/runic/pull/27), and [#28](https://github.com/zblanco/runic/pull/28), with exact review heads recorded above. Relevant immutable source views include [#27 PolicyDriver](https://github.com/zblanco/runic/blob/442da3245e6ff6af8e02c24e72d7ff8b2562c82c/lib/workflow/policy_driver.ex), [#27 Workflow](https://github.com/zblanco/runic/blob/442da3245e6ff6af8e02c24e72d7ff8b2562c82c/lib/workflow.ex), and [#28 Worker](https://github.com/zblanco/runic/blob/3468a4eb14ea3cd92c7f1271c9d59315c6e4cf32/lib/runic/runner/worker.ex).

The corrected consumer analysis uses `agentjido/jido_action` branch `release/v3` at `65330e3dfcaae570bc87f570a9c815f52ec2d872`, fetched into `/tmp/jido-action-review.ykERs3`. Primary sources include the linked package declaration/lockfile, Flow compiler/engine, RunnableExecutor, ExecutionGuard, Invocation behaviour/implementation, execution guide, and receipt-replay test in Section 4. They were inspected without changing the Jido repository or installing/running its dependencies. Earlier `jido_runic` Strategy, ActionNode, SignalFact, and `jido_action/main` dependency conclusions are superseded, not current consumer findings. The Runic PR validation table records the prior exact-head checks and was not rerun for this documentation-only correction.

For future contract design, use this document for PR sequencing/current-baseline corrections and the following for the deeper target architecture:

- [Runtime Contract Upgrade](runic-runtime-contract-upgrade-plan.md): one event protocol, Journal, ExecutionBackend, and in-package Runtime;
- [A Deeper Runic Runtime](runic-runtime-consumer-simplification-design.md): Jido source evidence, ephemeral scope/session support, information-hiding boundaries, and measurable consumer simplification;
- [Distributed Durable Runtime Core](distributed-durable-runtime-core-plan.md): authority, attempts, evolving graphs, context, lifecycle, and guarantee vocabulary;
- [Adapter Portfolio](distributed-adapter-portfolio-plan.md): package roles, rankings, and capability gates;
- [PostgreSQL Library](runic-postgres-library-implementation-plan.md): RP0–RP5, queue/Journal separation, projections, managed workflows, and load controls;
- [Ra-native](runic-raft-native-runtime-plan.md) and [CASPaxos-native](runic-caspaxos-native-runtime-plan.md): alternative implementations of the same semantic authority, not alternatives to deciding Runic's execution contract;
- [Snapshot Checkpoint Policy](snapshot-checkpoint-policy-implementation-plan.md): optional replay acceleration, subordinate to acknowledged cursor/state pairing and portable snapshot decisions;
- [Runtime Context Implementation](runtime-context-implementation-plan.md): implemented local context mechanics, refined by invocation-scoped context in the durable contract.

The central decision is to **stabilize current behavior without stabilizing accidental boundaries**. Most of these PRs improve the intended boundaries. The terminal-halt representation, task failure containment, scheduler admission contract, and delivery-acknowledgement distinction are where a small amount of design work now prevents a much more expensive correction later.
