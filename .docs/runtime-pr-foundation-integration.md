# Runtime PR Foundation Integration

**Date:** 2026-10-08
**Scope:** Integrate the reviewed PR repairs before the larger consumer-simplification/`Runic.Runtime` work. No new durable runtime, distributed guarantee, or package release is introduced.

## Source and landing decisions

| PR | Reviewed head | Disposition |
|---|---|---|
| [#25](https://github.com/zblanco/runic/pull/25) | `52cf508d906a8c4d7e7e1b4e808ac914e018c05e` | Merged first as `f2411c3df3f9c281e26fac1b7acccab687f4ef68` after fresh full-suite, format, and strict compile checks |
| [#23](https://github.com/zblanco/runic/pull/23) | `53297ea7cca99c99e693a27d53840a860d761f03` | Original commit retained in integration ancestry; preserve both manual calls and #25 persistence status when resolving Worker conflict |
| [#24](https://github.com/zblanco/runic/pull/24) | `3ad453985e9f434aaae09027a6b4bf4601044a6b` | Original commit retained, including the no-hook fast path; add multi-addition/prefix/order regression |
| [#26](https://github.com/zblanco/runic/pull/26) | `8545ecfdd2b9e71edb614a52473b8bfd035c45e0` | Original commit retained; normalize missing legacy FactRef metadata at hydration and test ETF/cache/store paths |
| [#28](https://github.com/zblanco/runic/pull/28) | `3468a4eb14ea3cd92c7f1271c9d59315c6e4cf32` | Extract its individual recovery/lifecycle commit with original authorship and cherry-pick provenance; omit the dependency on #27's unadopted halt field/external-failure protocol |
| [#27](https://github.com/zblanco/runic/pull/27) | `442da3245e6ff6af8e02c24e72d7ff8b2562c82c` | Adapt retry classification and timed-task exit containment, crediting Mike; leave the draft open for the explicitly deferred semantics below |

The working implementation was built in `/tmp/runic-pr-integration.IoewMA` on `integrate/runtime-pr-foundation`. The primary `zw/dist-runtime` checkout and its in-progress architecture documents were not staged into this integration. The planning references are `runic-pr-integration-and-durable-runtime-action-plan.md` and `runic-runtime-consumer-simplification-design.md` in that planning checkout; this document is the standalone implementation record for main.

## Integrated contracts

### Persistence and local executor resources

Keep #25's acknowledgement boundary: failed append/value writes retain pending results, failed persistent stop keeps the Worker alive, and successful retry advances the acknowledged cursor. `release/2` is strictly local executor resource bookkeeping, never broker acknowledgement or durable result acceptance.

Correlate result messages with a live handle and expected runnable/Promise identity before applying or releasing them. Duplicate, late, and mismatched notifications cannot reapply hooks, repeat Promise prefixes, append results again, or release an already consumed handle.

Release callback exceptions, throws, and catchable exits are logged without discarding the result. The prior executor state remains available to cleanup. Normal termination cleans each initialized executor once; failed persistent stop does not clean it. One failing cleanup callback does not prevent cleanup of other executor instances. Hard process/VM loss and uncatchable kills still cannot guarantee resource cleanup.

Validate/init the scheduler before allocating executor resources. Required build-persistence failure explicitly cleans the initialized executor, because a failed GenServer init cannot rely on normal termination handling. This is not a general transactional resource-allocation protocol for arbitrary callbacks.

### Admission is not proposal, completion, or durability

Manual `step/2` admits one scheduler unit; a Promise may contain multiple nodes. `:ok` is admission, not successful completion or storage acknowledgement. Manual mode remains Worker-local configuration and must be supplied again on resume.

The Scheduler sees the whole eligible frontier so batching remains useful. Its proposed list may be truncated by concurrency/manual limits. The optional `on_dispatch/2` callback updates bookkeeping only for selected units, immediately before submission and before inline completion. It is a local notification, not a durable authority. Existing stateless schedulers need no change; the future Runtime can replace this alpha contract with a structured plan/admission boundary.

### Recovery and persisted shape

Resume applies replacement runtime context and policy options before recovering prepared work. Custom executors receive the configured single or partitioned Task Supervisor, and override state is separated by module plus options, not just module.

Snapshots omit/clear top-level `run_context`, including older version-one values lacking that field. This is not deep secret sanitization or portable snapshot IR: other graph fields can contain bindings, policies, functions, and local resources. There is no `halted_by_failure` field to synthesize. Older FactRef values missing `meta` hydrate with `%{}` rather than raising an accidental `KeyError`.

### Local failure classification and containment

`retry_if` accepts a local one-argument function or `{module, function, extra_args}`, receiving the attempt error first. Both event-emitting and ordinary execution share classification. `false` proceeds to the existing fallback/skip/failure path. Invalid returns or raised/thrown/catchable-exit predicates fail closed, retain the original error, and do not invoke fallback. Retry count and inherited deadlines remain bounded; zero timeout starts no work.

Timed execution uses a temporary Task Supervisor plus `async_nolink` rather than linking the user Task to the caller. Normal, shutdown, and uncatchable Task-kill exits become failed Runnables without changing caller trap-exit flags. The temporary supervisor is stopped when execution returns. Fallback reexecution retains the timeout/deadline budget instead of silently reverting to an unlimited default.

This adds local process cost to timed attempts; no performance improvement is claimed. Keep this mechanism private so the next Runtime scope can amortize it without changing public contracts. Unlimited direct functional evaluation keeps its existing process model. Neither task-exit containment nor retry classification proves that external effects did not occur or are exactly once.

## Intentionally deferred from #27

- No sticky workflow-wide halt field, replay-derived permanent halt, or equivalent ambiguous Worker boolean.
- No new chunk barrier in direct async evaluation. This integration does not claim a new uniform fail-fast scheduler.
- No adoption of `external_failure/3` that bypasses ordinary retry/fallback decisions.
- No new claim that a crashed Promise's entire batch ran and failed. Existing outer-executor/batch crash accounting remains a known limitation requiring attempt/progress/unknown-outcome design.

The next consumer-simplification pass should establish evaluation/session versus managed-execution failure scope, shared completion-driven admission, explicit uncertain outcomes, and recoverable accepted prefixes. Those requirements belong in the dependency-light Runtime and its deep Journal/ExecutionBackend contracts, not in application-specific failure types or a terminal bit on the reusable graph VM.

The independent #28 tests now assert resource release and native quiescence after an outer executor crash, not #27's unadopted durable external-failure event semantics. This narrower acceptance claim is deliberate.

## Validation

- Exact #25 head before merge: **55 doctests, 1,449 tests, 0 failures, 13 skipped**, seed `905355`; formatting and strict development compilation passed.
- Integrated focused acceptance: **57 tests, 0 failures**, seed `905355`.
- Integrated full suite: **55 doctests, 1,498 tests, 0 failures, 13 skipped**, independently passed with seeds `739430` and `905355`.
- `mix format --check-formatted`, `mix compile --warnings-as-errors`, and `git diff --check` passed.

Regression coverage is in [PR integration tests](../test/runner/pr_integration_test.exs), [runtime recovery](../test/runner/runtime_recovery_test.exs), [policy safety](../test/policy_driver_safety_test.exs), [dynamic apply events](../test/workflow/dynamic_apply_events_test.exs), and [FactRef hydration](../test/workflow/fact_resolver_test.exs), alongside the existing persistence failure suite.

Initial full-suite runs exposed tight test timing assumptions: an existing successful-timeout test used a 5 ms sleep against a 100 ms budget, and the new Flow fixture initially allowed only 100/1,000 ms to initialize during concurrent suite load. The success test now uses immediate work with a generous budget; the Flow notification uses a 5 s acceptance window. These are correctness fixtures, not throughput benchmarks. Passing reruns do not constitute performance measurements.

Runic has no `mix precommit` alias; its test/format/compile gates were run directly. No Jido test execution, live database/broker validation, deployment-safe replay, multi-node failover, or production validation is claimed. The separate known Map/Reduce full build-log recovery limitation from #25 remains open.
