# PR #27: eager match admission and consumed activation labels

Review base: `c0b7349f83c6cd355cdf0f340f6575b96496f269`.
Review threads: [eager admission](https://github.com/zblanco/runic/pull/27#discussion_r4233148596)
and [consumed labels](https://github.com/zblanco/runic/pull/27#discussion_r4233148602).

## Planning outcomes belong to the execution scope

The Worker previously called `Workflow.plan_eagerly/2`, which ran Conditions
internally and returned only a workflow. A failed Condition was applied and
discarded before the Worker could call `record_failure/2`. Independent RHS work
could consequently run while `admission_status/2` still reported open admission.

The internal `Workflow.plan_eagerly_with_result/1,2` returns
`{workflow, failed_runnable_or_nil}`. Matching stops on its first failed Runnable,
consumes that activation through the native application path, and leaves other
activations pending. The Worker records this outcome before dispatch, invokes
its existing `on_failed` hook and failure telemetry, and drains already admitted
work through its normal completion handling. Startup recovery that eagerly
evaluates recorded pending work observes the same outcome.

The public `plan_eagerly/1,2` still returns a workflow. The new result is internal
execution information, not a graph field, persisted halt state, new behaviour,
or a new event schema. Eager matching retains its existing synchronous
`Invokable` execution semantics; this change does not add scheduler-policy
execution to that path.

The planner reads the current match frontier after each application. Previously
it recursed inside a reducer over an older frontier, allowing outer iterations
to execute matches that a recursive iteration had already consumed. Reading the
current frontier prevents those duplicate visits and stops immediately after a
known failure.

Adding input while admission is stopped uses `plan/2` only. This records input
and activations without executing its predicates or their hooks. Explicit
continuation or recovery admits retained work under the existing scope rules.

## Failure history identifies the actual activation

Failure application now obtains `ActivationConsumed.from_label` from
`Private.connection_for_activatable/1`. Steps consume `:runnable`; Conditions and
Conjunctions consume `:matchable`. Hard-coding `:runnable` produced incorrect
history even though the current replay implementation infers consumption from
the node and masks the error.

No event shape changes, storage migration, new broker acknowledgement, or
distributed guarantee is introduced. The suppression and Promise progress
limitations in #39 and #40 remain separate.

## Acceptance evidence

The two original review probes both failed at the unchanged review base. The
initial regression surface reproduced 12 failures across 13 tests
before the implementation. The final new surface contains 16 tests covering:

- Before/after predicate failures with automatic/manual dispatch and inline/Task
  executors; no independent RHS executes before explicit continuation.
- Failure cause identity, reason, notification, and retention of unstarted work.
- Input added while stopped, followed by explicit continuation without repeating
  the consumed failed activation.
- Active work draining, with continuation rejected while those units remain.
- Planning failure during recovery of a recorded pending match.
- Store acknowledgement followed by compact-payload hydration and core event
  replay against the authored topology.
- Exact consumed labels and replay for Step, Condition, and Conjunction failures.
- Successful match visits without stale-frontier duplication.

The final full suite passed **55 doctests and 1,624 tests**, with zero failures
and 13 existing skips, seed `130650`, `--max-cases 4`. The combined
failure/race/policy/persistence surface passed **99 tests** under one BEAM
scheduler, seed `130650`. Formatting, strict development/test compilation, and
whitespace checks pass.

## Separate construction-replay limitation

An additional full Rule reconstruction probe found that its rebuilt Condition
identity differs from the authored identity. This also reproduces on unchanged
`c0b7349` in an isolated baseline worktree. Runtime activation events referencing
the old subcomponent identity then cannot find that node in the rebuilt graph.
This is outside the two review fixes and must not be confused with the corrected
consumption label or authored-topology replay proof.

The isolated probe constructs:

```elixir
rule = Runic.rule(fn value when value < 10 ->
  send(context(:observer), {:rhs, value})
  value
end, name: :guarded)

authored = Runic.workflow(rules: [rule])
rebuilt = Workflow.from_log(Workflow.build_log(authored))
[original] = Workflow.get_component(authored, {:guarded, :condition})
[restored] = Workflow.get_component(rebuilt, {:guarded, :condition})
assert restored.hash == original.hash
# Fails on the unchanged review base.
```

Accordingly, this pass claims acknowledged event replay against an authored
topology and recovery admission handling, not complete Rule reconstruction or
general stop/resume correctness. Fixing stable composite subcomponent identities
requires a separate construction/replay change and persisted-history analysis.
