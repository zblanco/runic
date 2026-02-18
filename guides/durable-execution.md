# Durable Execution and Persistence

This guide covers persisting workflow state, recovering from crashes, capturing runnable lifecycle events, and checkpointing long-running workflows. It builds directly on the concepts from the [Building a Workflow Scheduler](scheduling.html) guide.

> **Prerequisites**: Familiarity with the three-phase execution model (prepare → execute → apply) and building schedulers covered in the [scheduling guide](scheduling.html). Basic knowledge of `Runic.Workflow.SchedulerPolicy` and `Runic.Workflow.PolicyDriver`.

## Why Durable Execution?

Runic workflows are in-memory data structures. When the process running a workflow crashes — or the VM restarts — all progress is lost. For short-lived computations this is fine. But many real workflows are long-running, involve unreliable external services, or must survive infrastructure failures:

- **LLM pipelines** where each API call takes seconds and costs money
- **Order fulfillment** workflows spanning minutes of I/O across multiple services
- **ETL pipelines** processing millions of records over hours
- **Approval workflows** that pause for days waiting on human input

Durable execution means: _the workflow can be stopped, crashed, or restarted and resume exactly where it left off_.

Runic achieves this through three mechanisms:

1. **Event sourcing** — `Workflow.log/1` captures the full history of a workflow as a list of events that can rebuild it
2. **Scheduler policies** — per-node retry, timeout, and failure handling declarative configuration
3. **The Runner** — supervised infrastructure that combines dispatch, persistence, and crash recovery

## Event Sourcing: `log/1` and `from_log/1`

Every Runic workflow maintains a build log — a list of events that describe how the workflow was constructed and what it has produced. This log is a complete record, and you can reconstruct a workflow from it:

```elixir
require Runic
alias Runic.Workflow

# Build and run a workflow
workflow =
  Runic.workflow(name: :example, steps: [
    Runic.step(fn x -> x * 2 end, name: :double),
    Runic.step(fn x -> x + 1 end, name: :increment)
  ])
  |> Workflow.react_until_satisfied(5)

# Capture the full event log
log = Workflow.log(workflow)

# Rebuild the workflow from the log — same graph, same produced facts
restored = Workflow.from_log(log)

# Productions are preserved
Workflow.raw_productions(restored) == Workflow.raw_productions(workflow)
# => true
```

The log contains two kinds of events:

1. **Build events** — `%ComponentAdded{}`, edges, and structural changes that define the workflow graph
2. **Reaction events** — `%ReactionOccurred{}` recording which nodes produced which facts

Together these are sufficient to reconstruct both the workflow's structure and its execution state.

### Runnable Lifecycle Events

When scheduler policies are used with `execution_mode: :durable`, three additional event types are captured:

- `%RunnableDispatched{}` — records that a runnable was sent for execution, including the resolved policy and attempt number
- `%RunnableCompleted{}` — records successful completion with duration and the produced fact
- `%RunnableFailed{}` — records permanent failure (retries exhausted) with the error and failure action

These events enable crash recovery: by comparing dispatched events against completed/failed events, you can identify _in-flight_ work that was interrupted.

```elixir
alias Runic.Workflow.SchedulerPolicy
alias Runic.Workflow.PolicyDriver

# Build a policy that emits lifecycle events
policy = SchedulerPolicy.new(%{
  max_retries: 2,
  backoff: :exponential,
  timeout_ms: 5_000,
  execution_mode: :durable
})

# Execute with event emission
{executed_runnable, events} = PolicyDriver.execute(runnable, policy, emit_events: true)

# events is a list of %RunnableDispatched{} and %RunnableCompleted{} or %RunnableFailed{}
```

Append these events to the workflow for persistence:

```elixir
workflow = Workflow.append_runnable_events(workflow, events)

# They're included in the log
log = Workflow.log(workflow)

# And survive round-trip reconstruction
restored = Workflow.from_log(log)
```

### Identifying In-Flight Work

After a crash, use `Workflow.pending_runnables/1` to find dispatched-but-not-completed work:

```elixir
# After restoring from a log
restored = Workflow.from_log(log)

pending = Workflow.pending_runnables(restored)
# => [%RunnableDispatched{node_name: :call_external_api, attempt: 1, ...}]
```

This returns `%RunnableDispatched{}` events that have no corresponding `%RunnableCompleted{}` or `%RunnableFailed{}` event — work that was in progress when the process died.

## Scheduler Policies for Resilient Execution

Before diving into the Runner, let's see how scheduler policies make individual steps resilient. Policies wrap the execute phase with retries, timeouts, and fallbacks — all without changing the workflow graph or the `Invokable` protocol.

### Attaching Policies to a Workflow

Policies are a list of `{matcher, policy_map}` rules stored on the workflow. During execution, each runnable is matched top-to-bottom; the first match wins and its policy map is merged over the defaults:

```elixir
require Runic
alias Runic.Workflow

workflow =
  Runic.workflow(name: :resilient_pipeline, steps: [
    Runic.step(fn order -> call_inventory_api(order) end, name: :check_inventory),
    Runic.step(fn order -> call_fraud_api(order) end, name: :screen_fraud),
    Runic.step(fn order -> compute_shipping(order) end, name: :estimate_shipping)
  ])

# Add policies — higher priority rules first
workflow =
  workflow
  # External API calls get retries with exponential backoff
  |> Workflow.add_scheduler_policy(:check_inventory, %{
    max_retries: 3,
    backoff: :exponential,
    base_delay_ms: 1_000,
    timeout_ms: 10_000
  })
  |> Workflow.add_scheduler_policy(:screen_fraud, %{
    max_retries: 2,
    backoff: :linear,
    timeout_ms: 15_000,
    on_failure: :skip  # fraud check failure shouldn't block the order
  })
  # Local computation — fast fail, no retries
  |> Workflow.append_scheduler_policy(:estimate_shipping, %{
    max_retries: 0,
    timeout_ms: 1_000
  })
```

### Using Policy Presets

`SchedulerPolicy` includes presets for common patterns:

```elixir
alias Runic.Workflow.SchedulerPolicy

# For LLM / external AI calls: 3 retries, exponential backoff, 30s timeout
llm = SchedulerPolicy.llm_policy()

# For I/O operations: 2 retries, linear backoff, 10s timeout, skip on failure
io = SchedulerPolicy.io_policy()

# No retries, 5s timeout, halt on failure
fast = SchedulerPolicy.fast_fail()

# Use preset values as policy maps in workflow rules
workflow =
  workflow
  |> Workflow.add_scheduler_policy(:call_llm, Map.from_struct(llm))
  |> Workflow.add_scheduler_policy({:type, Runic.Workflow.Step}, Map.from_struct(io))
```

### Matchers

Matchers determine which policy applies to which node:

```elixir
# Exact name match
{:check_inventory, %{max_retries: 3}}

# Regex on node name — matches :llm_classify, :llm_summarize, etc.
{{:name, ~r/^llm_/}, %{max_retries: 3, backoff: :exponential}}

# Type match — all Steps get this policy
{{:type, Runic.Workflow.Step}, %{timeout_ms: 10_000}}

# Type match — Steps and Rules
{{:type, [Runic.Workflow.Step, Runic.Workflow.Rule]}, %{timeout_ms: 5_000}}

# Custom predicate
{fn node -> Map.get(node, :name) in [:api_a, :api_b] end, %{max_retries: 2}}

# Catch-all default (should be last)
{:default, %{timeout_ms: 30_000}}
```

### Runtime Policy Overrides

Policies can be overridden at execution time without modifying the workflow:

```elixir
# Prepend runtime overrides (higher priority than workflow policies)
Workflow.react_until_satisfied(workflow, input,
  scheduler_policies: [
    {:check_inventory, %{max_retries: 5, timeout_ms: 30_000}}
  ]
)

# Replace workflow policies entirely
Workflow.react_until_satisfied(workflow, input,
  scheduler_policies: [{:default, %{max_retries: 0}}],
  scheduler_policies_mode: :replace
)
```

### Fallbacks

When all retries are exhausted, a fallback function provides a last-resort recovery:

```elixir
workflow =
  workflow
  |> Workflow.add_scheduler_policy(:call_llm, %{
    max_retries: 3,
    backoff: :exponential,
    timeout_ms: 30_000,
    fallback: fn _runnable, _error ->
      # Return a synthetic value — the workflow continues with this output
      {:value, %{response: "Service unavailable", fallback: true}}
    end
  })
```

Fallbacks receive `(runnable, error)` and can return:

- `{:value, term}` — synthetic output, workflow continues as if the step succeeded
- `{:retry_with, %{key: val}}` — merge overrides into `meta_context` and try once more
- `%Runnable{}` — a modified runnable to execute once (e.g., with different input)

### Deadlines

For time-bounded workflow execution, use `:deadline_ms`:

```elixir
# Entire workflow must complete within 60 seconds
Workflow.react_until_satisfied(workflow, input,
  deadline_ms: 60_000,
  scheduler_policies: [
    {:default, %{max_retries: 2, backoff: :exponential}}
  ]
)
```

The deadline is converted to an absolute monotonic timestamp and checked before each retry attempt and used to cap per-step timeouts. Steps fail with `{:deadline_exceeded, remaining_ms}` when the deadline is reached.

### Checkpointing During Execution

For long-running workflows, persist intermediate state with the `:checkpoint` callback:

```elixir
Workflow.react_until_satisfied(workflow, input,
  checkpoint: fn workflow ->
    log = Workflow.log(workflow)
    MyApp.Repo.save_workflow_log(:my_workflow, log)
  end
)
```

The checkpoint fires after each `react` cycle — after all runnables in a generation execute and their results are applied. If the process crashes mid-execution, load the last checkpoint and resume:

```elixir
{:ok, log} = MyApp.Repo.load_workflow_log(:my_workflow)
workflow = Workflow.from_log(log)

# Continue from where we left off
workflow |> Workflow.react_until_satisfied()
```

## The Runner: Managed Durable Execution

While scheduler policies and manual checkpointing work for programmatic use, the `Runic.Runner` provides a complete managed execution environment:

- **Supervision** — each workflow runs in its own `GenServer` under a `DynamicSupervisor`
- **Task isolation** — runnables dispatch to `Task.Supervisor.async_nolink` for fault isolation
- **Registry** — workflows are addressable by ID via Elixir's `Registry`
- **Persistence** — pluggable `Store` behaviour with built-in ETS and Mnesia adapters
- **Policy integration** — automatic resolution and execution through `PolicyDriver`
- **Crash recovery** — `resume/3` rebuilds from persisted logs and re-dispatches in-flight work
- **Telemetry** — lifecycle events under `[:runic, :runner, ...]` for observability

### Starting a Runner

Add the Runner to your application's supervision tree:

```elixir
defmodule MyApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Runic.Runner, name: MyApp.Runner}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

The Runner starts a supervision tree internally:

```
MyApp.Runner (Supervisor, :rest_for_one)
├── MyApp.Runner.Store (ETS table owner GenServer)
├── MyApp.Runner.Registry (Elixir Registry, :unique)
├── MyApp.Runner.TaskSupervisor (Task.Supervisor)
└── MyApp.Runner.WorkerSupervisor (DynamicSupervisor)
    ├── Worker<order-123>
    ├── Worker<order-456>
    └── ...
```

### Running Workflows

```elixir
require Runic
alias Runic.Workflow

# Build the workflow with policies
workflow =
  Runic.workflow(name: :order_fulfillment, steps: [
    Runic.step(&MyApp.Orders.validate/1, name: :validate),
    {Runic.step(&MyApp.Inventory.check/1, name: :check_inventory), [
      Runic.step(&MyApp.Fraud.screen/1, name: :screen_fraud),
      Runic.step(&MyApp.Shipping.estimate/1, name: :estimate_shipping)
    ]}
  ])
  |> Workflow.add_scheduler_policy(:check_inventory, %{
    max_retries: 3,
    backoff: :exponential,
    timeout_ms: 10_000,
    execution_mode: :durable
  })
  |> Workflow.add_scheduler_policy(:screen_fraud, %{
    max_retries: 2,
    timeout_ms: 15_000,
    on_failure: :skip,
    execution_mode: :durable
  })
  |> Workflow.append_scheduler_policy(:default, %{timeout_ms: 5_000})

# Start a managed workflow
{:ok, _pid} = Runic.Runner.start_workflow(
  MyApp.Runner,
  "order-#{order.id}",
  workflow,
  max_concurrency: 4,
  checkpoint_strategy: :every_cycle,
  on_complete: fn id, workflow ->
    results = Workflow.raw_productions(workflow)
    MyApp.Orders.finalize(id, results)
  end
)

# Feed input — the Worker handles the full dispatch loop
:ok = Runic.Runner.run(MyApp.Runner, "order-#{order.id}", order)

# Query results (non-blocking — returns current state)
{:ok, results} = Runic.Runner.get_results(MyApp.Runner, "order-#{order.id}")
```

### Checkpoint Strategies

The Worker supports multiple checkpointing strategies to balance durability against performance:

| Strategy | Behavior | Use Case |
|----------|----------|----------|
| `:every_cycle` | Persist after each react cycle (default) | Maximum durability, moderate overhead |
| `:on_complete` | Persist only when workflow satisfies | Fast execution, risk of losing in-progress work |
| `{:every_n, n}` | Persist every Nth completed runnable | Tunable balance between durability and throughput |
| `:manual` | Only persist on explicit `checkpoint/2` call | Full user control |

```elixir
# Checkpoint every 5th completed runnable
Runic.Runner.start_workflow(MyApp.Runner, :etl_pipeline, workflow,
  checkpoint_strategy: {:every_n, 5}
)

# Manual checkpointing
Runic.Runner.start_workflow(MyApp.Runner, :approval_flow, workflow,
  checkpoint_strategy: :manual
)

# Later, explicitly checkpoint
Runic.Runner.checkpoint(MyApp.Runner, :approval_flow)
```

### Crash Recovery with `resume/3`

When a Worker crashes (or the VM restarts), the Runner can resume from persisted state:

```elixir
# The original Worker crashed or the VM restarted...

# Resume loads the log from the store, rebuilds the workflow, and starts a new Worker
{:ok, _pid} = Runic.Runner.resume(MyApp.Runner, "order-123")

# If the workflow had durable-mode policies, pending_runnables are re-dispatched automatically
```

Under the hood, `resume/3`:

1. Calls `Store.load/2` to retrieve the persisted event log
2. Calls `Workflow.from_log/1` to rebuild the workflow graph and state
3. Starts a new Worker with the restored workflow
4. The Worker calls `Workflow.pending_runnables/1` to find in-flight work
5. Re-plans and re-dispatches any pending runnables

This is why `execution_mode: :durable` matters: without it, the lifecycle events that track dispatched-vs-completed work aren't captured, and in-flight recovery isn't possible.

### Store Adapters

The Runner's persistence is abstracted behind the `Runic.Runner.Store` behaviour:

```elixir
defmodule Runic.Runner.Store do
  @callback init_store(opts :: keyword()) :: {:ok, state()} | {:error, term()}
  @callback save(workflow_id(), log(), state()) :: :ok | {:error, term()}
  @callback load(workflow_id(), state()) :: {:ok, log()} | {:error, :not_found | term()}
  @callback checkpoint(workflow_id(), log(), state()) :: :ok | {:error, term()}
  @callback delete(workflow_id(), state()) :: :ok | {:error, term()}
  @callback list(state()) :: {:ok, [workflow_id()]} | {:error, term()}
  @callback exists?(workflow_id(), state()) :: boolean()
end
```

`checkpoint/3`, `delete/2`, `list/1`, and `exists?/2` are optional callbacks.

#### ETS Adapter (Default)

`Runic.Runner.Store.ETS` stores workflow logs in a public ETS table owned by a GenServer. Logs survive Worker restarts within the same VM but are lost on VM restart. Zero configuration needed:

```elixir
# ETS is the default — just start the Runner
{:ok, _} = Runic.Runner.start_link(name: MyApp.Runner)
```

#### Mnesia Adapter

`Runic.Runner.Store.Mnesia` uses OTP's built-in Mnesia database for disk persistence and optional distributed storage:

```elixir
{:ok, _} = Runic.Runner.start_link(
  name: MyApp.Runner,
  store: Runic.Runner.Store.Mnesia,
  store_opts: [disc_copies: true]
)
```

Mnesia tables persist across VM restarts. For distributed clusters, pass `:nodes`:

```elixir
store_opts: [disc_copies: true, nodes: [:"app@node1", :"app@node2"]]
```

#### Writing a Custom Adapter

Implement the `Runic.Runner.Store` behaviour and provide `start_link/1` + `child_spec/1` for supervision:

```elixir
defmodule MyApp.PostgresStore do
  @behaviour Runic.Runner.Store

  @impl true
  def init_store(opts) do
    repo = Keyword.fetch!(opts, :repo)
    {:ok, %{repo: repo}}
  end

  @impl true
  def save(workflow_id, log, %{repo: repo}) do
    serialized = :erlang.term_to_binary(log)
    repo.insert_or_update!(
      %MyApp.WorkflowLog{id: workflow_id, data: serialized}
    )
    :ok
  end

  @impl true
  def load(workflow_id, %{repo: repo}) do
    case repo.get(MyApp.WorkflowLog, workflow_id) do
      nil -> {:error, :not_found}
      record -> {:ok, :erlang.binary_to_term(record.data)}
    end
  end

  # start_link/1 and child_spec/1 for the Runner's supervision tree
  def start_link(opts), do: Agent.start_link(fn -> opts end, name: __MODULE__)
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
end
```

### Telemetry

The Runner emits telemetry events at key lifecycle points:

| Event | When |
|-------|------|
| `[:runic, :runner, :workflow, :start]` | Workflow Worker initialized |
| `[:runic, :runner, :workflow, :stop]` | Workflow satisfied (all runnables exhausted) |
| `[:runic, :runner, :runnable, :start]` | Runnable dispatched to a task |
| `[:runic, :runner, :runnable, :stop]` | Runnable completed (includes `duration` measurement) |
| `[:runic, :runner, :runnable, :exception]` | Runnable failed permanently |
| `[:runic, :runner, :store, :start]` | Store operation started |
| `[:runic, :runner, :store, :stop]` | Store operation completed |

```elixir
# Attach a handler for monitoring
:telemetry.attach_many(
  "workflow-logger",
  Runic.Runner.Telemetry.event_names(),
  fn event, measurements, metadata, _config ->
    IO.inspect({event, measurements, metadata}, label: "telemetry")
  end,
  nil
)
```

## Putting It All Together: A Durable LLM Pipeline

Here's a complete example combining policies, durable execution, the Runner, and crash recovery for an LLM-powered document processing pipeline:

```elixir
defmodule MyApp.DocumentPipeline do
  require Runic
  alias Runic.Workflow

  def build_workflow do
    extract = Runic.step(
      fn doc -> MyApp.LLM.extract_entities(doc) end,
      name: :extract_entities
    )

    classify = Runic.step(
      fn doc -> MyApp.LLM.classify(doc) end,
      name: :classify_document
    )

    summarize = Runic.step(
      fn doc -> MyApp.LLM.summarize(doc) end,
      name: :summarize
    )

    store_results = Runic.step(
      fn entities, classification, summary ->
        MyApp.Documents.store(%{
          entities: entities,
          classification: classification,
          summary: summary
        })
      end,
      name: :store_results
    )

    Runic.workflow(name: :doc_pipeline)
    |> Workflow.add(extract)
    |> Workflow.add(classify)
    |> Workflow.add(summarize)
    |> Workflow.add(store_results, to: [:extract_entities, :classify_document, :summarize])
    # LLM calls: retry with exponential backoff, durable for crash recovery
    |> Workflow.add_scheduler_policy({:name, ~r/^(extract|classify|summarize)/}, %{
      max_retries: 3,
      backoff: :exponential,
      base_delay_ms: 2_000,
      max_delay_ms: 30_000,
      timeout_ms: 60_000,
      execution_mode: :durable,
      fallback: fn _runnable, error ->
        {:value, %{error: inspect(error), fallback: true}}
      end
    })
    # Database write: fast fail
    |> Workflow.append_scheduler_policy(:store_results, %{
      max_retries: 1,
      timeout_ms: 5_000
    })
  end

  def process_document(runner, doc_id, document) do
    workflow = build_workflow()

    {:ok, _pid} = Runic.Runner.start_workflow(
      runner,
      "doc-#{doc_id}",
      workflow,
      max_concurrency: 3,
      checkpoint_strategy: :every_cycle,
      on_complete: {MyApp.Notifications, :document_processed, []}
    )

    Runic.Runner.run(runner, "doc-#{doc_id}", document)
  end

  def retry_failed(runner, doc_id) do
    # Resume from the last checkpoint — in-flight LLM calls are re-dispatched
    Runic.Runner.resume(runner, "doc-#{doc_id}")
  end
end
```

The three LLM steps (`extract_entities`, `classify_document`, `summarize`) run concurrently with fault isolation. If the process crashes mid-execution:

1. The ETS store (or Mnesia) has the last checkpointed log
2. `resume/3` rebuilds the workflow from the log
3. `pending_runnables/1` identifies any LLM calls that were dispatched but never completed
4. The Worker re-dispatches them with the same policies

The `fallback` ensures that even if an LLM call permanently fails after all retries, the pipeline continues with a fallback value rather than blocking the entire workflow.

## What's Next

This guide covered the full spectrum of durable execution in Runic. For reference:

- `Runic.Workflow.SchedulerPolicy` — policy struct, matchers, presets, and resolution
- `Runic.Workflow.PolicyDriver` — the execution driver handling retries, timeouts, and fallbacks
- `Runic.Runner` — the supervised execution infrastructure
- `Runic.Runner.Store` — the persistence behaviour and built-in adapters
- `Runic.Runner.Telemetry` — telemetry event catalog
