# Execution observation

Runic workflows are reusable graphs. An idle graph is not a completed
execution. An execution scope gives a caller a bounded view of one input and
the work that it causes.

## Immediate execution

Use `Runic.Workflow.execute/3` when the caller owns the workflow value:

```elixir
{workflow, execution} = Runic.Workflow.execute(workflow, order)

if execution.quiescent? and execution.admission == :open and execution.failures == [] do
  values = Runic.Workflow.Execution.outputs(execution, order: :stable)
end
```

The function returns the updated workflow and an execution observation. It
does not add a halt field to the workflow. A later call can use the workflow
again.

Immediate execution has no Runner Store. Its persistence status is
`:not_managed`.

## Managed execution

Use the Runner API when a Worker owns the workflow:

```elixir
{:ok, execution_id} =
  Runic.Runner.start_execution(MyRunner, :pricing, order)

{:ok, execution} =
  Runic.Runner.await_execution(MyRunner, :pricing, execution_id, 5_000)
```

`start_execution/4` confirms input admission. It does not confirm computation
or persistence. `await_execution/4` waits for execution quiescence.

Use `Runic.Runner.execution/3` for a current snapshot. Do not call it from a
Worker callback or hook.

Only one observed execution can make progress in one Worker at a time. This
keeps the input ancestry and execution boundary clear. The older
`Runic.Runner.run/4` API keeps its existing behavior, but it does not return an
execution ID. Do not add legacy `run/4` input while an observed execution is in
progress. Mixed input admission remains outside this initial contract.

## State meanings

An execution reports separate fields for separate concerns:

| Field | Meaning |
| --- | --- |
| `active` | Scheduler units that the Worker admitted and has not accepted yet. |
| `ready` | Activations for this input that remain in the graph. |
| `admission` | `:open` or `:stopped` for the current scope. |
| `quiescent?` | No active unit remains, and the scope cannot make more progress by itself. |
| `outcomes` | Accepted results and uncertain outer-executor observations. |
| `persistence` | The Runner Store acknowledgement state at observation time. |

A stopped scope can be quiescent and still have ready work. This means that
the scope ended, but an explicit recovery decision can run the retained work.
It does not mean that the reusable graph has a permanent halt.

Immediate execution can also run work retained from an earlier input. If that
work stops admission, the new scope reports `admission: :stopped`. Its outcomes
still contain only results for the new input. Thus an empty failure list alone
does not mean that admission stayed open.

Manual `Runic.Runner.step/2` still confirms the admission of one scheduler
unit. It does not confirm completion, quiescence, or persistence.

## Identity and repeated inputs

Each execution has an `:execution` identity. Each admitted input has an
`:input_command` identity and a distinct `:fact_occurrence` identity. Equal
input values in repeated calls do not share these occurrence identities.

A caller can supply a unique `:execution_id` to immediate or managed
execution. Do not reuse one execution ID for a different occurrence. Managed
execution rejects an ID that the Worker already knows.

Outcome IDs use the execution, activation, attempt, and outcome kind. Retry
attempts have different attempt IDs.

## Outcome order and selection

`execution.outcomes` keeps the order in which the caller or Worker accepted or
observed outcomes. Concurrent completion can change this order. This order is
the audit order for the scope.

Use stable order when a consumer must select the same logical activation:

```elixir
stable =
  Runic.Workflow.Execution.ordered_outcomes(execution, order: :stable)

failures =
  Runic.Workflow.Execution.failures(execution, order: :stable)
```

Stable order uses causal depth and activation identity. It does not rewrite
the observed order.

Outcome kinds are:

  * `:completed` - Runic accepted a computed result.
  * `:failed` - A node returned a final failure and stopped admission.
  * `:skipped` - A policy or custom node consumed an activation without a result.
    A custom skip can have no error.
  * `:uncertain` - The outer executor ended without an accepted result.

An uncertain outcome does not prove whether the work ran or whether it caused
an external effect. Its activation stays ready. A later recovery can repeat
the work.

## Persistence boundary

The current managed observation includes the same status as
`Runic.Runner.persistence_status/2`: `:saved`, `:pending`, or a persistence
error. Computation can be quiescent while persistence is pending or failed.

When another execution or legacy input starts, or stopped admission resumes,
the Worker retains the previous observation as a fixed snapshot. Its
persistence field does not change after later writes or retries. Use
`Runic.Runner.persistence_status/2` to check the current Store acknowledgement
after this point.

The status is the Worker Store boundary. It does not acknowledge an external
broker, undo an effect, or provide exactly-once execution.

Execution observations are process-local. Stop, cancellation, and resume do
not rebuild them from the workflow event stream in this initial contract.
Durable runnable and uncertainty events remain available through the existing
event mechanisms when event emission is enabled.

The Worker retains observations until it stops or the caller uses
`Runic.Runner.forget_execution/3`. Long-running consumers must remove final
observations after they store or process them.

## Current limits

This contract does not define full batch ownership, local-value facts, child
invocation, or application-specific result conversion. A Promise reports the
completed prefix that the Worker accepted in a reply. It cannot report hidden
sequential progress that was lost before the reply.
