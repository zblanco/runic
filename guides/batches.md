# Batches and accepted Promise progress

Use `Runic.batch/2` to run a Step, a custom `SingleOutput` component, or a nested
batch for each item. Runic connects FanOut and FanIn, identifies each invocation
and item, completes empty input, and returns outcomes in input order.

```elixir
batch = Runic.batch(MyApp.Price.new(:price), name: :prices)
workflow = Runic.Workflow.new()
  |> Runic.Workflow.add(batch)
  |> Runic.Workflow.add(result_step, to: :prices)
input = Runic.Workflow.Batch.input([10, 20], %{adjustment: 3})
{completed, execution} = Runic.Workflow.execute(workflow, input)
```

The result step receives `%Runic.Workflow.Batch.Result{id, parent, outcomes}`.
Each outcome has `id`, `batch_id`, `index`, `status`, `value`, and `error`.
The batch ID uses the FanOut activation and source Fact occurrence. The item ID
uses that occurrence and its output index. Index alone is not an identity.
Use `Workflow.execute/3` or `Runner.start_execution/4` for repeated invocations
with equal input. Raw Fact planning keeps the existing deduplication behavior.
Nested batches have their own source occurrence and activation.

Items must be a proper list. Supply a list directly when no parent data is
needed. Supply `Batch.input(items, parent)` to keep parent data separate from
items. Empty input returns an empty outcome list and its parent data. It does
not execute the member callback and does not use a synthetic item.

A custom callback reads `SingleOutput.Context.batch`. This view has `id`,
`item_id`, `index`, `source_fact_id`, and `parent`. Steps can read
`context(:batch)`. The parent belongs to the source Fact. Stored item Facts have
coordinates, without a parent copy. Prepared callback contexts do contain the
parent once in `CausalContext.batch`. Runic does not add another view to runtime
or meta context. Steps resolve `context(:batch)` during execution. User runtime
keys, including `:batch`, remain unchanged in the public runtime view. Large
parent maps can still increase worker copying. The completed Result also contains
the parent. This is not a zero-copy execution contract.

The [price example](../examples/batch/demo.exs) uses a custom component without
Fact ancestry, custom events, or collection bookkeeping. Run it with:

```sh
MIX_ENV=test mix run examples/batch/demo.exs
MIX_ENV=test mix run examples/batch/measure.exs
```

Nested members use the parent from their own input. An outer parent is not
inherited. Put `Batch.input(inner_items, inner_parent)` in an outer item to supply
an inner parent; a plain list gives inner members `parent: nil`.

The measurement script reports stored item Fact ETF bytes separately from
context flat words and memory in receiving processes. Process heap allocation
and binary sharing affect those numbers. Stored bytes do not prove worker
copy cost.

Batch members must have separate component definitions within one workflow.
Runic checks ownership on addition and workflow merge, and before dispatch.
A member cannot acquire additional incoming or outgoing structural links outside
its Batch. Low-level graph edits are rejected at dispatch if they violate this
rule. Removing an outer Batch removes all its owned nodes and nested definitions,
then reconnects its external parents and consumers. An owned member or nested
Batch cannot be removed alone; remove the named outer owner. A workflow with
no remaining Batch definitions also has no Batch context index or flag.
Skipped work suppresses only activations in the failed item occurrence;
sibling collections remain available. A terminal inner Batch input error also
becomes a terminal outcome for its owning outer item.
Stateful nodes, conditional readiness, arbitrary multi-output components, and
Map/Reduce members are rejected. This first contract supports ordinary
SingleOutput members and nested batches. It does not add a scheduler.

## Failure, cancellation, and partial observation

Existing scheduler policies apply to the member. Retries keep the same item
identity. Only its terminal outcome enters the completed collection. Fallback
values are completed values. Error-shaped values remain data unless the custom
callback converts them with `SingleOutput.Result.failure/1`.

With `on_failure: :skip`, the item has a skipped outcome with its error. Other
items can complete. With `on_failure: :halt`, the execution scope stops new
admission. Already admitted units can finish. There is no rollback of accepted
items or external effects.

Raw terminal errors remain in `Outcome.error` and the terminal event. Their
identity uses activation, attempt, status, and explicit error kind. It does not
encode arbitrary error fields. This lets PID exits, functions inside exceptions,
and opaque errors remain observable without crashing Result application. Raw
fields do not become portable through this identity projection. Store and
transport adapters must still validate the raw payload for their profile.
Completed data keeps its current canonical encoding rules. Batch does not add
a general local-value mode.

A partial batch has no completed Result. If all
items were already admitted, their terminal outcomes can complete the boundary,
but stopped admission does not dispatch its consumer. A parallel Promise is
one admitted unit and retains its existing all-member policy.

`Batch.invocations(workflow, batch)` lists accepted FanOut invocation IDs.
`Batch.outcomes(workflow, batch, id)` returns ordered observations even for a
partial batch. Accepted outcomes have completed, skipped, or failed status.
A pending item has no accepted terminal result. An uncertain item has an
observed executor loss. Pending and uncertain work can repeat on explicit
recovery. A lost executor within a nested Batch marks the owning outer item
uncertain until it has an accepted terminal boundary result. This observes
unresolved nested work; it does not invent an outer callback failure. Use the execution observation API and persistence status for admission
and Store state; item observations do not acknowledge persistence.

`Runner.cancel/2` uses the existing native task ownership scope. It waits for
owned native work to stop and removes the Worker. It does not invent terminal
item outcomes for lost computations. Accepted progress is retained only to the
extent allowed by the existing persistence contract. Keep Jido parameter
expressions, result conversion, fail-fast choice, and effect order in Jido.

## Recovery scope

Batch definitions retain the member construction event, including its source,
closure, and original hash. This keeps internal identities stable during replay.
The member must have reconstructable construction data for build-log recovery. Full-value event
replay and native workflow snapshots preserve accepted collection tracking,
item metadata, parent data, failure observations, and downstream activations.
After the Store acknowledges that progress, explicit resume does not execute
those accepted items again. Supply fresh runtime context and runtime scheduler
policies on resume. Unresolved work can run again.

This support does not repair the separate pre-existing native Map/Reduce full
build-log reconstruction limit recorded in PR #29 and
`.docs/issue-21-checkpoint-persistence.md`. The recorded probe produced
`[2, 4, 6, 12]` before stop and `[]` after full `Runner.resume/3`, with successful
ETS writes. Runtime events replayed against the original authored topology;
full build-log reconstruction did not restore the same result. Do not apply a general
Map/Reduce resume claim to this Batch contract. Lazy/hybrid replay is outside
this first contract because parent data and collected values must be present.
Runner.resume returns `{:error, {:unsupported_batch_rehydration, mode}}` before
creating a Worker for these unsupported Batch modes.
Partial collection recovery through a legacy save/load graph log is not
claimed. Use the supported streaming event Store path or a native snapshot.
Native snapshots are trusted, version-coupled data. Captured component bindings
keep their existing storage limits. Batch values follow the existing canonical
Fact payload rules; this work does not define a new local-value mode.

## Sequential Promise progress

The built-in Task executor sends each completed sequential Promise member and
the next prepared frontier to its live Worker before it starts that frontier.
The existing Promise reference correlates the message. The current frontier
authorizes acceptance. Activation identities deduplicate accepted results.
Later full, partial, duplicate, and stale replies do not apply the accepted
member, its deferred hooks, or its events again. Deferred graph hooks run in the
Worker at acceptance. A member with deferred graph hooks ends the Promise.
The Worker applies the hooks once and prepares the remaining work from the
changed context and topology. Inline and custom executors use the same hook
boundary. The Task's private copy does not continue past omitted hook changes.
Members without deferred hooks use live sequential Task progress as described
above. Original scheduler dispatch data and telemetry counts stay separate from
the mutable unresolved frontier.

If A is accepted and the Task dies while B runs, A remains accepted. New Worker
admission stops. B is uncertain; C has not been accepted or newly admitted.
No node-failure event is created for executor loss. A final control reply can
also be lost after all members are accepted. In that case admission stops,
but no unresolved member outcome is invented. Until that control reply or loss
arrives, execution observation remains active with `control_pending?: true` and
an empty list of unresolved member IDs. An invalid or stale member/frontier
report cannot change the accepted prefix.

Each member report copies its result and next frontier. It can trigger the
configured checkpoint strategy. This adds member messages and checkpoint
operations to chain batching, while it still avoids a Task spawn for every
member. Computation, Worker acceptance, and Store acknowledgement remain
separate boundaries. Effects without an accepted result can repeat. Reporting
does not make an effect atomic with persistence.

Parallel Promises, custom/remote executors, Worker or VM loss, portable journals,
and per-input failure isolation are outside this narrow progress phase. The
batch contract above has its own explicit execution and replay scope.
