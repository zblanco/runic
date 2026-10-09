# A Deeper Runic Runtime: Simplifying Consumers Without Absorbing Their Domain

**Status:** Revised design recommendation after PR #29; proposed interfaces below are not implemented
**Updated:** 2026-10-08
**Upstream implementation baseline:** Runic `main` at `c23f28bc0ccd0127b07160e2c089d7e3525f58b4`
**Planning checkout:** `zw/dist-runtime` at `6b2ef1befdcc7eed068a339baaeab934e2b83038`; its code has not been advanced to that baseline
**Companions:** [PR Integration](runic-pr-integration-and-durable-runtime-action-plan.md), [Runtime Contracts](runic-runtime-contract-upgrade-plan.md), [Distributed Core](distributed-durable-runtime-core-plan.md), [Adapter Portfolio](distributed-adapter-portfolio-plan.md)
**New consumer input:** [Mike's versioned runtime interface review](https://gist.githubusercontent.com/mikehostetler/e238ac08d8a175fd3145e09ec3a31daf/raw/760d7dae3b3ca4a790da0757a7374b5e4cb599f4/runic-runtime-interface-review.md)

## 1. Answer and architectural decision

Yes: Runic should own more execution mechanics so Jido can describe Actions and Agent Turns without also knowing how Runic constructs activation events, supervises work, or wires composite endpoints. The goal is fewer concepts required of a consumer, not merely fewer lines behind forwarding functions.

Keep **one dependency-light, first-party `Runic.Runtime` inside Runic**, with ephemeral and optional durable profiles sharing admission, worker lifetime, and result machinery. Keep the functional graph VM independently usable. Do not require a Journal for an in-memory call, introduce a second distributed executor behaviour, or put Jido's Agent state machine in Runic.

The revised priority is **task ownership and ordinary custom-node execution first, correlated observation/outcomes next, composite/batch and local-value capabilities after explicit design gates**. These are consumer-facing slices through the existing contracts, not another scheduler project. The durable Journal work can proceed alongside them; local simplification must not wait for PostgreSQL, Ra, or CASPaxos.

Use Ousterhout's information-hiding test: a module's interface includes the ordering rules and implementation details a caller must know. A useful abstraction hides those facts, not just their spelling. [Modular Design lecture](https://web.stanford.edu/~ouster/cgi-bin/cs190-winter18/lecture.php?topic=modularDesign).

## 2. Rebaseline the evidence before choosing deletion targets

### 2.1 These are different integration generations

| Source | Exact revision | What this plan can infer |
|---|---|---|
| Earlier Jido Action review | `65330e3dfcaae570bc87f570a9c815f52ec2d872` | Historical Controller/ExecutionGuard/Flow.Engine/Invocation-host design; useful requirements, not today's deletion inventory |
| Mike's revised Jido Action reference | [`5e52df87d8114a1c8f805ead3c278c47f9f869a4`](https://github.com/agentjido/jido_action/tree/5e52df87d8114a1c8f805ead3c278c47f9f869a4) | Custom Runic components; direct evaluation for immediate calls, Runner for managed calls; concrete adapter mechanics below |
| That Action revision's Runic dependency | [`6b1c8c85d2d560a7ff5da6c3a417254c5d2b85b6`](https://github.com/mikehostetler/runic/tree/6b1c8c85d2d560a7ff5da6c3a417254c5d2b85b6), `integration/jido-v3` | Mike's stacked integration fork, including the #27 halt semantics; not merged upstream |
| Runic after our integration | [`c23f28b`](https://github.com/zblanco/runic/commit/c23f28bc0ccd0127b07160e2c089d7e3525f58b4) | #25, #23/#24/#26, adjusted #28 extraction, and revised independent #27 mechanics; no sticky graph halt |
| Jido AgentServer reference | [`8322de574c53d5c2096243d230c9de4f14803bda`](https://github.com/agentjido/jido/tree/8322de574c53d5c2096243d230c9de4f14803bda) | Pins Action `8e9b3f7b268e175091b0eb3720bab3b8633d3c24` and Runic alpha.11; uses the older async Exec handle API |

The newer Action source no longer has the earlier Controller/ExecutionGuard/Flow.Engine/Invocation modules. Retire the previous seven-file line count and proposed deletions as historical evidence. Do not rebuild those abstractions just to delete them, require preservation of a removed receipt-host API, or describe Jido as avoiding Runner. The useful requirements survive; the adapter implementation has changed.

The live Action `release/v3` head was `22f7c2a38fc9c07e3b117c5e4a53e1a0bdde32aa` when checked for this revision. This plan intentionally analyzes Mike's pinned `5e52df8`, not that later unreviewed head. Before implementation, select a fresh pair of consumer/upstream revisions and record their dependency lockfiles.

### 2.2 Concrete remaining knowledge leaks

| Pinned Jido Action source | Runic-owned mechanism that can disappear from the adapter | Jido-owned meaning that remains |
|---|---|---|
| [Action Invokable](https://github.com/agentjido/jido_action/blob/5e52df87d8114a1c8f805ead3c278c47f9f869a4/lib/jido_exec/node/action.ex#L483-L566) | Context preparation, hook order, child Fact ancestry, activation consumption, lifecycle events, collection tracking | Action schemas, validation, result/error conversion, telemetry, effects and retry classification |
| [TaskExecutor](https://github.com/agentjido/jido_action/blob/5e52df87d8114a1c8f805ead3c278c47f9f869a4/lib/jido_exec/runner/task_executor.ex) and [immediate wrapper](https://github.com/agentjido/jido_action/blob/5e52df87d8114a1c8f805ead3c278c47f9f869a4/lib/jido_exec.ex#L345-L377) | Task reference/PID tracking, owner watchers, cleanup and completion races | Whether a Turn is cancellable and how cancellation affects the public Action/Agent outcome |
| [Exec result/step](https://github.com/agentjido/jido_action/blob/5e52df87d8114a1c8f805ead3c278c47f9f869a4/lib/jido_exec.ex#L156-L237) | Mapping lack of runnable work to completion and scanning private lifecycle-event storage | Output validation and `{:ok, value, effects}` projection |
| [Compiler connections](https://github.com/agentjido/jido_action/blob/5e52df87d8114a1c8f805ead3c278c47f9f869a4/lib/jido_exec/compiler.ex#L607-L651) | Resolving nested endpoints, inserting native joins, Dispatch-specific finish endpoint branching | Dependency derivation, parameter expressions and authored source paths |
| [Map](https://github.com/agentjido/jido_action/blob/5e52df87d8114a1c8f805ead3c278c47f9f869a4/lib/jido_exec/node/map.ex#L73-L164) and [Collection](https://github.com/agentjido/jido_action/blob/5e52df87d8114a1c8f805ead3c278c47f9f869a4/lib/jido_exec/node/map/collection.ex#L36-L66) | Manual FanOut/FanIn wiring, empty sentinel, carrying the parent frame on only the first item | Collection error policy, final result shape and effect order |
| [Fact adapter](https://github.com/agentjido/jido_action/blob/5e52df87d8114a1c8f805ead3c278c47f9f869a4/lib/jido_exec/fact.ex) | Recursive local-value wrapping, unwrapping and inherited identity mode | Domain schema validation and whether a product permits local-only execution |
| [Dynamic Dispatch](https://github.com/agentjido/jido_action/blob/5e52df87d8114a1c8f805ead3c278c47f9f869a4/lib/jido_exec/node/dispatch.ex#L190-L241) | Potential future child occurrence/attachment/completion protocol | Target selection, authorization, registry resolution and target validation |

Runic's [native Step implementation](https://github.com/zblanco/runic/blob/c23f28bc0ccd0127b07160e2c089d7e3525f58b4/lib/workflow/invokable.ex#L399-L499) already owns much of the ordinary node lifecycle, but through Step-private helpers. Share that implementation rather than ask consumers to learn the same events. Treat older FanIn, context-retention and failed-apply workarounds as regression candidates to recheck, not proven current defects.

### 2.3 What #29 fixes, and what it does not

The [landed implementation record](https://github.com/zblanco/runic/blob/c23f28bc0ccd0127b07160e2c089d7e3525f58b4/.docs/runtime-pr-foundation-integration.md) is the authoritative account of the prior integration:

- Persistence buffers clear only after Store acknowledgement; failed persistent stop keeps the Worker alive.
- Manual step acknowledges one admitted scheduler unit, which can be a Promise. The scheduler's optional admission notification is not durable acceptance.
- Dynamic construction events and FactRef metadata survive the tested paths; older FactRefs normalize missing metadata.
- Resume installs fresh context/policies before recovery; executor instances receive supervisor configuration, release and cleanup hooks.
- Live-handle/result-identity correlation rejects duplicate or mismatched replies. Timed-task exits and retry predicates have explicit local failure handling.

Those are foundations, not complete ownership or outcomes. The [default Task executor](https://github.com/zblanco/runic/blob/c23f28bc0ccd0127b07160e2c089d7e3525f58b4/lib/runic/runner/executor/task.ex) still keeps no task registry and has no-op cleanup. Catching a timed task's exit does not implement cancellation of every Runtime-owned descendant on abrupt owner death. Handle correlation is not durable attempt fencing. Snapshot top-level context clearing is not deep portability validation.

The fork's Worker checks `halted_by_failure`, unlike upstream. Its fail-fast/event behavior and older persistence path must not be treated as equivalent to #29. A Jido dependency update therefore needs differential tests, not just a new Git SHA. No package release or downstream migration has been established by our merges.

## 3. What a deep Runtime and VM extension surface should own

### 3.1 Scoped execution, not a public collection of Task utilities

An execution may outlive a request, process or input episode. An operation scope owns work associated with one invocation/advance operation. Select that lifetime explicitly:

- **Caller-attached:** owner death stops further admission and shuts down owned work; appropriate for an immediate finite call when the consumer chooses it.
- **Managed:** client disconnection does not cancel background execution. A failed coordinator loses authority; recovery and attempt policy determine what happens to its work.

Use one internal scope facility for the default executor and immediate execution: establish ownership before starting work; track nested owned tasks; contain work exits; consume only owned result/monitor messages; release capacity; suppress obsolete results. Respect injected supervisors and group leaders. Tests must include work trapping exits, owner death during startup, normal exits and untrappable task kills. A normal `terminate/2` callback alone cannot satisfy owner-death cleanup.

Define the public distinctions before choosing function names:

| Operation | Required meaning |
|---|---|
| Observe/await | Wait for the specified execution/invocation; an observation timeout does not implicitly cancel unless the selected consumer contract requests it |
| Cancel | Stop new admission and request shutdown of owned work; distinguish request acceptance from cancellation settlement |
| Suspend | Preserve resumable execution intent and pause admission; define drain versus interruption and record unresolved work where applicable |
| Stop coordinator | Process/service lifecycle; not an alias for successful completion, cancellation or durable suspension |

After cancellation settlement, local owned processes must be retired and their later results cannot become newly accepted work. Remote backends may only support cancellation request plus uncertain execution outcome; expose that capability honestly. This does not stop arbitrary detached processes, undo completed I/O or prove an external effect never happened. Cancellation racing with accepted completion needs one ordered decision; durable profiles make that decision under Journal authority.

Keep lifecycle work inside the chosen scope where needed: validation, input materialization, output normalization and continuations may execute user code too. Jido decides what those operations mean. The earlier Jido generation's per-Action fresh-task guarantee is not assumed for the revised source; preserve the selected consumer contract, not historical process counts. Prototype a standalone Action and a compound Flow before claiming all execution wrappers can disappear.

A local monotonic deadline cannot be sent as a meaningful timestamp to another VM. Propagate explicit remaining-budget/remote-deadline semantics, account for queue delay, and distinguish execution budgets from observer timeouts. Bound admission and cleanup where enforceable; do not promise a hard response deadline around arbitrary blocking callbacks.

### 3.2 A managed session that hides the graph-driving loop

Keep direct prepare/execute/apply available, but ordinary callers should inspect or advance an execution through a small facade. The following are vocabulary sketches, not released API signatures:

| Operation | Required meaning |
|---|---|
| `run` | One-call ephemeral execution over the shared kernel, with a declared finite completion condition |
| `start_session` / `advance` | Pauseable local progress; selected unit, initial wave or until blocked, without a mandatory Journal |
| managed start/open/submit | Long-lived execution with explicitly selected persistence guarantees |
| observe / await / subscribe | Correlated progress and outcomes, not access to Worker state or Task mailbox internals |

A selected unit is not necessarily one authored Action. A local session revision is an effectful capability: stale advancement cannot silently repeat work; interrupted operations may be indeterminate. This does not restrict ordinary functional copies of `%Workflow{}` and is not a distributed fence. Do not require a permanently parked coordinator merely to hold a paused local session.

An observation should separate:

- identity and observation position: execution, invocation/input occurrence, session/graph revision and, where applicable, accepted event cursor;
- progress: active, eligible, held/manual, delayed or externally waiting work;
- outcome: pending, successful under the selected completion condition, failed, cancelled, or indeterminate;
- output references and ordered failure records, separate from payload loading;
- persistence health/accepted cursor, so computed output is not presented as durably accepted output.

These are conceptual fields, not a new public struct for every row. Offer a cheap summary and bounded inspection of large frontiers/results. Build it from the same transition projection used to coordinate work, not a second status authority or repeated full-history scans. Notifications are hints unless replayable observation is an advertised capability; callers can query by invocation/cursor after a lost notification.

**Quiescence is not universal success.** An open rules workflow may await a new input or graph extension. A finite invocation needs a declared boundary, such as satisfied output ports and settled relevant work. Missing required output is different from waiting on an external signal. Jido interprets the resulting outputs and validates its own finite Flow result.

Allocate invocation identity at ingress, distinct from equal input content, and carry causal lineage into activations, outputs, batches and child invocations. Repeated equal inputs must not share an outcome accidentally. For shared stateful graphs and joins that combine several inputs, do not pretend every output belongs to exactly one call: expose contributing lineage, and either support a declared invocation completion boundary or reject invocation-level waiting for that profile. Execution-level observation remains valid.

Preserve the actual accepted event order for audit/replay. Do not sort stored history to make error presentation deterministic. Recommend a failure summary ordered by a stable admission/source key plus activation/attempt identity, with the admission-stopping cause identified separately. A summary can be provisional until earlier in-flight work settles; bounded buffering/backpressure is part of that cost. Test reverse completion and multiple failures across immediate and managed profiles. Jido owns authored ordering and error presentation; neither profile should infer a primary error from the physical order of `runnable_events`.

### 3.3 Admission and completion as one coherent mechanism

Extend the existing scheduling mechanisms with a shared completion-driven pump, not a second scheduler: refill capacity, stop further admission when policy requires, and account for every candidate and attempt. Keep admission order, failure response, result application order, and isolation/resource limits distinct. Their defaults should be useful; advanced consumers should not need a behaviour for each decision.

Canonical application/output ordering can cause head-of-line buffering. Bound both active work and completed-but-unapplied results; stop admission when those bounds are reached. A selected wave has an initial frontier, whereas ordinary continuous advancement need not impose chunk barriers. Nesting must not let waiting parent orchestration consume every slot required by its children. Do not claim to account for user-created detached tasks.

Failure scope is invocation/session or explicitly managed execution policy, not an irreversible bit on the reusable graph. Independent later inputs can remain useful after one failed invocation. `:collect_errors` is an adapter interpretation of an error as output data, not Runtime silently erasing a failure. Preserve #29's distinction between scheduler proposal, selected admission, completion and persistence; its `on_dispatch/2` is transitional local bookkeeping, not a new authority contract.

### 3.4 Native correctness and compact completion belong below Runtime policy

Native apply owns duplicate/stale coordination validity, graph transitions and event construction. Consumers should not inspect private `mapped` keys, reconstruct failed apply just to suppress logging, or copy sibling coordination payloads into every task. Recheck those historical cases against #29 and issue #19's compact-context/bounded-preparation work before adding fixes.

Failure should produce an inspectable outcome without requiring consumers to reproduce graph mutations to control logging. Observers handle logging policy. Apply the same native execution-result builders in direct and managed paths, retaining pure functional usage. Existing `Runnable.complete/3` still asks callers to provide events; it is not the high-level ordinary-node contract proposed below.

### 3.5 Runtime context should not contaminate reconstruction data

Reuse Runic's context system. Persist requirements and explicitly portable invocation values; resolve repositories, pools, clients, secrets and local invocation functions into an attempt-scoped execution view. Do not retain resolved resources in returned portable results, dispatch events or artifacts. Resume supplies fresh resources without rebuilding definitions around live handles.

Anonymous functions and Runnables are not intrinsically unserializable: macro-built components can reconstruct work from AST and captured bindings with compatible code. Validate the actual representation and bindings. Construction/lifecycle events remain the durable reconstruction protocol; a live projection is not automatically a safe interchange format. #29's snapshot context clearing is useful but narrower than this contract.

### 3.6 A standard ordinary-node contract above Invokable

Provide one opt-in, Step-like execution contract for a node that consumes input and produces one value or an explicit failure. The consumer supplies a work callback and result interpretation, potentially combined into one callback. Runic prepares causal/context/hook state, invokes it, builds child Fact ancestry and collection tracking, and completes or fails the Runnable through the native path. Jido's adapter performs its own schema validation, Action telemetry, effects accumulation and conversion.

The result representation must distinguish **successful data** from **execution failure** without pattern-matching every user tuple globally. An illustrative adapter result is `value({:error, business_reason}, metadata)` versus `failure(execution_reason)`; these are design notation, not API names. A plain Step can continue returning any term, including `{:error, reason}`. Jido deliberately interprets its Action return contract and constructs the appropriate outcome.

Metadata composition remains explicit. Runic propagates its own identity/lineage requirements; Jido determines which effect/source metadata to inherit or append. Do not clone arbitrary transient context into Fact metadata. Ordinary callbacks need no `FactProduced`, `ActivationConsumed` or `MapReduceTracked` construction and no fan-out ancestry matching.

Before adding a public module, compare extending Step's call/result contract with a callback-component builder that generates the existing `Component`/`Invokable` implementations. Prefer the smallest option that preserves domain component identity, ports and reconstructable source without exposing private causal structs. Share Step's underlying implementation; do not maintain two ordinary-node engines. Keep low-level `Invokable` for gates, stateful coordination, multiple outputs and unusual nodes, and preserve their protocol-specific validation.

Construction must record the executable/result-adapter reference and captured inputs. Prove event reconstruction and clean-node portability for supported custom components; local callbacks may honestly remain local-only. Merely serializing an anonymous function or retaining an ETF blob does not establish deployment compatibility. This native helper must work without starting Runtime; the managed shell adds ownership, attempt policy and durable acceptance.

### 3.7 Composite connections, component batches and dynamic children

Complete the public port contract so consumers name declared component ports and Runic resolves endpoints, including nested workflows and terminal Dispatch ports. Connections must declare all-parent versus any-parent readiness, binding names/order, multiplicity and missing/ambiguous ports. Do not silently choose the first port or silently insert an all-parent Join where any-parent delivery was intended. Preserve these connections in construction events so replay rebuilds the same topology.

Generalize native Map/FanOut/FanIn around an arbitrary supported component or nested workflow, not just a plain work function. Runic should own:

- a batch occurrence scoped by execution/invocation and component occurrence; item occurrence includes batch identity and item index, not just index or content;
- zero-item completion without invoking a synthetic user item;
- bounded preparation/admission and ordered item outcomes despite out-of-order execution;
- a shared parent-data reference with lifetime through batch settlement, including zero items and failure of item zero;
- recovery of accepted item outcomes, retry/duplicate distinction and final completion exactly once in the accepted projection.

Jido retains value expressions, `fail_fast` versus `collect_errors`, output formatting and effect order. A batch that stops early must expose failed, cancelled, unstarted and unknown work honestly; it cannot synthesize success or failure for items that never ran. Stateful/multi-output components require declared per-item completion semantics; reject unsupported combinations rather than pretend they are ordinary Steps.

Keeping the parent once in graph/storage does not mean it is copied only once across BEAM workers or remote transports. Benchmark stored bytes, copied bytes, hydration and retained references separately. Reuse payload/context facilities, and bound retention; do not replace the first-item convention with an unbounded shared cache. Retain existing Map/Reduce APIs where sound rather than introduce an unrelated collection language.

Dynamic child invocation is a later extension of this boundary. Runic can own occurrence identity, attachment, context lineage, accepted child completion and recovery; Jido selects and authorizes the target. A definition/target digest is not a child occurrence ID. Test the same target invoked twice, graph additions before/after a crash, and restart between child completion and parent continuation. #24/#29's dynamic-event retention is necessary but does not prove all those cases or fix full Map/Reduce build-log recovery.

### 3.8 Explicit local values without weakening canonical identity

Immediate execution may legitimately use PIDs, references or other nonportable values as data. Do not force every such value into context or ask Jido to disguise it as portable canonical data. Add an explicitly selected local-value capability with scope-qualified occurrence identity and inherited mode for child facts. Keep default canonical payload identity strict and unchanged.

A local digest is not a content address valid across restarts/nodes. Separate local identity from canonical payload/content digests and caches. Avoid a `Projectable` wrapper that only hashes a local term while leaving a durable encoder free to persist the raw value. Do not infer portability merely from a protocol implementation or successful `term_to_binary`.

Check the entire requested boundary: inputs, outputs, captured bindings, metadata and snapshot/event payloads, not just root Fact values. A durable or portable backend rejects unsupported values with a structured path/type/reason error before accepting ingress/dispatch. Nonportable results discovered after user work need a recorded/observable rejection or uncertain outcome according to the profile; they cannot safely trigger blind rerun of a possible effect. Errors identify a field without logging secret contents.

No automatic downgrade to local execution after failed persistence or serialization. No silent promotion of local sessions into durable/remote ones. A future explicit materialization/conversion operation must produce a newly validated portable artifact/value and define new identity mappings. Runtime context capabilities remain a separate concept: a worker-local client can be resolved for an otherwise portable execution without becoming saved data.

## 4. Refinement to the proposed backend contract

Keep one ExecutionBackend, receiving a typed **DispatchRequest** with work/attempt identity and explicit admission provenance: either a local ephemeral admission or the actual committed `RunnableDispatchRequested` record. Ordinary callers never construct it. A prepared Runnable may be retained locally; portable dispatch reconstructs the component/context through declared capabilities.

Requiring an ETS Journal for every local call would impose unnecessary storage concepts; introducing independent LocalExecutor and DurableExecutor behaviours would duplicate lifecycle contracts. The structured request permits the honest local path without weakening the durable path.

For durable requests, commit the dispatch record before delivery. The wrapper is neither an authorization credential nor a replacement for that record. Durable-only adapters may reject ephemeral requests. Unknown/failed commit never falls through to local dispatch. Durable results become accepted through conditional Journal commit; ephemeral results are accepted against the current scope/session revision. Release of local executor resources is neither semantic acceptance nor broker acknowledgement. Broker acknowledgement follows committed or known-duplicate durable acceptance.

Ownership, cancellation and value portability are capabilities of a selected execution profile, not guarantees implied by having this request struct. Reuse one worker execution/result path and the C0–C5 Journal/codec work. Keep Ecto, Broadway, broker SDKs and consensus dependencies in adapters; do not expose Task monitor tuples as the permanent Runtime interface.

## 5. Jido's Agent commit boundary is not a Runic checkpoint

The inspected [Jido Turn implementation](https://github.com/agentjido/jido/blob/8322de574c53d5c2096243d230c9de4f14803bda/lib/jido/agent_server/turn.ex#L243-L319) validates/prepares directives, persists the new Agent revision, exposes committed Agent state, then schedules post-commit work. That sequence stays in Jido. Runic completion supplies a candidate result; it is not permission to commit an Agent or deliver its effects.

| Authority | Owns | Does not replace |
|---|---|---|
| Runic execution | Readiness, attempts, progress, native outcomes, supported recovery; Journal acceptance in durable profiles | Agent/Plugin state validation, signal admission or serial Turn policy |
| Jido Turn | Admission of domain signals, state/Plugin validation, Agent revision commit and cancellation decision | Runic activation/attempt coordination |
| Effect delivery host | Post-commit directive delivery and its dedupe/idempotency/reconciliation | Either workflow completion or Agent state commit |

Carry execution/invocation identity alongside Jido's turn ID, expected Agent revision and effect occurrence IDs. A late result from a cancelled or replaced Turn must not commit a newer Agent revision. Runic filters obsolete work in its own scope; Jido still checks its current Turn/revision at the domain boundary. These checks guard different authorities and are not needless duplication.

For a durable integration, decide the coupling explicitly:

1. With one transactional database and a supported adapter transaction facility, the application can atomically commit its Agent revision and its post-commit delivery intents. Runic must not hard-code Agent schemas or promise a cross-store transaction.
2. With separate stores, keep each authority explicit and use stable receipts, outbox/inbox delivery and reconciliation. Specify crash windows after workflow result acceptance, before/after Agent commit and before/after effect delivery. Do not name an independent checkpoint a Turn commit.

The older Action Invocation-host replay scheme is historical, not a required extra layer in the revised adapter. If fine-grained Action/child recovery is needed, verify the actual new compiler's occurrence-to-activation mapping, especially loops, reductions and Dispatch. One callback may still perform several effects. Reuse one Runic acceptance authority for execution progress rather than adding a second Action receipt log that can disagree; Agent state remains its separate domain authority.

Accepted workflow history cannot prove that a missing external receipt means an effect did not happen. Cancellation is not compensation; retry is not exactly-once I/O. Jido/host chooses provider idempotency, effect delivery and reconciliation policy. Neither new convenience callbacks nor Agent subscriptions should become a second hidden commit protocol.

Jido's older `run_async`/handle-message integration and the revised Action API also need explicit migration. Do not declare Runic/Action coexistence proven by Action-only tests, or restore an old Exec handle abstraction in Runic solely to conceal this dependency mismatch.

## 6. What stays outside Runic

Keep Action schemas and errors, Flow DSL/JSON and parameter expressions, authored provenance, target selection/authorization, collection error/result semantics, effect vocabulary and ordering, Agent/Plugin state, serial Turns and domain commit in Jido. Runic's generic retry mechanism consumes Jido's error classification; there should be one attempt policy owner, not stacked retries multiplied accidentally.

Runic must not recognize `Jido.Flow.Map`, infer purity from generated code, or turn effect metadata into automatically delivered directives. Native coordination can use facts Runic owns; arbitrary callbacks, reducers and hooks are not automatically safe inline work. An ordinary consumer should not implement Journal, Scheduler or Executor just to execute a graph.

Additional internal modules are acceptable if they hide complexity behind a small public contract. Avoid a universal lifecycle-hook behaviour, an options map exposing graph internals, or a collection of aliases that simply relocates the same consumer obligations. Alpha APIs may break deliberately; do not preserve a permanent Store bridge or indefinitely maintain two drivers to avoid a justified migration.

## 7. Implementation sequence and proof of simplification

This revises the earlier S0–S4 scope and supplements C0–C7; it does not renumber the durable contract phases. All interfaces remain proposals until their gates pass.

| Slice | Implementation boundary and acceptance gate |
|---|---|
| **S0 — rebaseline and differential fixtures** | Pin current Action, Jido and upstream Runic separately. Run the selected existing Action tests against its fork, then upstream #29 in isolated environments. Classify deliberate halt-policy differences, missing APIs and actual defects; do not change dependencies in a user's app silently. Preserve #25/#29 acknowledgement and duplicate-result tests. |
| **S1a — complete local ownership** | Built-in Task executor and immediate Runtime scope share owner/startup/cleanup/cancellation machinery. Demonstrate caller-attached and managed lifetimes, owner/worker death, trapped exits, late replies and capacity release. Delete TaskExecutor and immediate watcher mechanics only for proven migrated paths. No Journal prerequisite. |
| **S1b — ordinary custom-node lifecycle** | One shared native implementation underneath Step and an opt-in callback component. Migrate one Jido Action and one unrelated callback node; verify hooks, errors-as-data, metadata, Map participation and event reconstruction without handwritten Runic coordination events. Can proceed independently of S1a after S0. |
| **S2 — observation and one coherent driver** | Shared completion-driven admission and correlated outcomes for immediate/manual/managed use. Replace event-scanning result inference and no-ready-work completion guesses. Include repeated inputs, finite versus open-ended workflows and deterministic failure summaries. Migrate a real Jido vertical slice without indefinite dual drivers. |
| **S3 — composite/value capability gates** | Public composite-port connections and component batches; separately prototype local identity. Prove empty/repeated batches, item-zero failure, bounded parent-data retention and local-value rejection at every persistence/remote boundary. No local identity change without explicit persisted-data compatibility decisions. |
| **S4 — durable and Agent integration** | Reuse the C1–C5 conditional Journal/request/result kernel; prove child occurrence replay, ambiguous completion and the separate Agent commit/effect boundary. Migrate the AgentServer's actual Action dependency/API as a separate consumer change. Optional fine-grained child durability waits for reconstruction tests. |

The first implementation PR should focus on S1a after S0, keeping the ownership mechanism private enough to share with Runtime; S1b is the other immediate, high-leverage slice. S2 makes their progress/results usable through a small facade. S3 does not block local ownership improvements, and S4 does not make a database prerequisite for Action execution. A design spike should reject an interface that cannot simplify both Jido and a plain Runic consumer.

### Current consumer acceptance fixtures

Use the [pinned Action test tree](https://github.com/agentjido/jido_action/tree/5e52df87d8114a1c8f805ead3c278c47f9f869a4/test/jido_exec). These are current source targets, not tests executed in this documentation pass:

- `runner/task_executor_test.exs` and `runner/immediate_task_test.exs`: release, stop, owner/worker death, group leader, injected supervisor, normal and killed tasks, helper cleanup.
- `runner/stepwise_test.exs`, `runner/managed_test.exs`, `runner/policy_test.exs`, `runner/durability_test.exs`: admission, failure, policy, context and resume behavior against the selected fork/upstream pair.
- `node/action_test.exs`, `node/map_test.exs`, `node/dispatch_test.exs`, `node/loop_test.exs`, `compiler_test.exs`, `rebuild_test.exs`: native adapter, composite and reconstruction cases. Their existence is not proof every new gate is covered.
- `fact_test.exs` and `portable_test.exs`: existing local-value and portability expectations; add boundary-wide rejection tests rather than only wrapper unit tests.

Add cross-layer tests, not just copied helpers: cancellation concurrent with result/commit; owner death before dispatch and during a trapping child; capacity one with nested work; duplicate/late replies; await timeout without cancellation; same payload in overlapping invocations; shared-state output lineage; reverse failure completion; empty batches; equal-item/repeated batches; loss of the first item; unknown Promise prefixes; and fresh context after replay.

For the ordinary-node contract, compare direct and managed execution, hook failure order, an `{:error, reason}` value deliberately returned as data, adapter-declared failure, metadata inheritance and clean-node reconstruction. For local values, test nested containers/metadata/captured bindings, a local result produced by effectful work, and scope-crossing rejection without automatic retry or canonical cache reuse.

For durable profiles, no dispatch follows an unknown commit, no durable completion is reported before Journal acceptance, stale ownership cannot accept a result, and ephemeral requests cannot enter durable-only backends. Preserve actual event chronology under every presentation-order policy. Agent integration adds stale-Turn result, cancellation before/after Agent commit and restart at each post-commit delivery boundary.

### The deletion and information-hiding gate

Record a before/after inventory for the exact migrated revisions:

1. Jido's ordinary node no longer constructs activation/collection events or knows fan-out ancestry.
2. No migrated path maintains a second task registry/watcher or generic admission/result loop.
3. Result projection consumes a public correlated outcome, not `runnable_events` or absence of ready work.
4. Composite adapters use declared ports/batches rather than internal endpoints, empty sentinels or first-item parent frames, once S3 lands.
5. Local values need no Jido-specific Runic identity wrapper once that capability is accepted; canonical guarantees are not weakened to achieve the deletion.
6. Remaining code expresses Jido schema, Flow, Turn and effect semantics. Unrelated workflows can use the same interfaces without adopting those semantics or new mandatory infrastructure.

Measure code/knowledge removed only after migration, not by counting the old modules. Benchmark work cost, process creation, descriptor allocation, bytes copied, completion buffering and retained session/batch memory separately. No performance gain or deletion percentage is promised from source review.

## 8. Evidence and validation boundary

This revision read Mike's complete pinned review, inspected the cited Action source and selected test files at `5e52df8`, verified its fork lockfile, compared that fork's history/source with upstream #29, and inspected the pinned Agent Turn and dependency lockfile. It also reread the companion plans and Ousterhout's primary notes. Branch heads may advance; the evidence table deliberately records immutable revisions.

Mike reports 11 focused tests on his reviewed dependency pair; that is his evidence, not a fresh result from this pass. Our prior #29 integration passed 55 doctests and 1,498 tests, 13 skipped, on two seeds; those results concern Runic's integrated tree, not Jido compatibility. Neither set establishes a migrated Jido AgentServer or the proposed interfaces.

This pass changes documentation only. No Runic/Jido implementation, dependency, branch or PR is changed. Markdown links/anchors, fences and whitespace are checked separately; no new runtime, consumer, database, broker, multi-node or performance test result is claimed. The known full Map/Reduce build-log recovery limitation remains a gate, not a solved prerequisite.
