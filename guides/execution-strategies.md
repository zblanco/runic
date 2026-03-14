# Execution Strategies

This guide covers Runic's pluggable execution and scheduling system — how to control **where** runnables execute (Executors) and **how** they're grouped for dispatch (Schedulers). These features are opt-in performance tools built on top of the Runner infrastructure described in the [Scheduling](scheduling.html) and [Durable Execution](durable-execution.html) guides.

> **Prerequisites**: Familiarity with the three-phase execution model (prepare → execute → apply), the `Runic.Runner` API, and `Runic.Workflow.SchedulerPolicy`. See the [Scheduling](scheduling.html) guide for background.

## When You Need This

The default Runner configuration — `Executor.Task` + `Scheduler.Default` — is correct and efficient for most workflows. You should reach for these tools when:

- **Long linear chains** (a → b → c → d → ...) are spending more time spawning tasks than doing work → use `ChainBatching` scheduler
- **Large fan-outs** (Map over 10,000 items) are bottlenecked by per-item dispatch overhead → use `FlowBatch` scheduler
- **Sub-millisecond steps** have task spawn overhead that dominates actual computation → use `:inline` executor
- **Sustained high-throughput** workloads need back-pressure to avoid overwhelming the system → use `GenStage` executor
- **Mixed workloads** where some steps are fast and some are slow, or some need isolation and others don't → use per-component executor overrides

If your workflows complete quickly and you're not hitting performance bottlenecks, the defaults are the right choice.

## Architecture Overview

The Worker's dispatch loop has two pluggable extension points:

```
         ┌─────────────────────────────────────────┐
         │              Worker                      │
         │                                          │
         │  prepare_for_dispatch(workflow)           │
         │          │                               │
         │          ▼                               │
         │  ┌───────────────┐                       │
         │  │  Scheduler    │ ← what to dispatch    │
         │  │  plan_dispatch│   together and when    │
         │  └───────┬───────┘                       │
         │          │                               │
         │          ▼                               │
         │  ┌───────────────┐                       │
         │  │  Executor     │ ← how to dispatch     │
         │  │  dispatch     │   (task, inline, etc.) │
         │  └───────────────┘                       │
         └─────────────────────────────────────────┘
```

- **Schedulers** decide _what_ gets dispatched together. They receive prepared runnables and return dispatch units — either individual runnables or batched Promises.
- **Executors** decide _how_ each dispatch unit runs. They control the process/task mechanism.

These are orthogonal. You can combine any scheduler with any executor.

## Executors

An executor controls the compute mechanism for dispatching work. All executors implement the `Runic.Runner.Executor` behaviour and must preserve the message contract: send `{handle, result}` on success and `{:DOWN, handle, :process, pid, reason}` on crash.

### Task Executor (Default)

Wraps `Task.Supervisor.async_nolink/2`. Each runnable runs in its own monitored Task process — if it crashes, only that task dies.

```elixir
# This is the default — no configuration needed
Runic.Runner.start_workflow(runner, :my_workflow, workflow)

# Explicitly:
Runic.Runner.start_workflow(runner, :my_workflow, workflow,
  executor: Runic.Runner.Executor.Task
)
```

**Use when:** Most workflows. Good crash isolation, reasonable overhead for steps that take more than ~1ms.

**Trade-off:** Each dispatch spawns a new process. For sub-millisecond computations, spawn overhead can dominate.

### Inline Executor

Executes runnables synchronously in the Worker process. No task spawned, no process overhead.

```elixir
Runic.Runner.start_workflow(runner, :my_workflow, workflow,
  executor: :inline
)
```

**Use when:** All steps are fast (sub-millisecond), deterministic, and you want to minimize latency. Also useful for testing — synchronous execution makes assertions simpler.

**Trade-off:** Blocks the Worker GenServer. A slow or crashing step blocks all other dispatches and can bring down the Worker. No crash isolation. Timeout enforcement is skipped (set to `:infinity`).

### GenStage Executor

Demand-driven dispatch using a GenStage Producer + Consumer pool. Consumers pull work items on demand, providing natural back-pressure.

```elixir
# Requires {:gen_stage, "~> 1.2"} in your deps
Runic.Runner.start_workflow(runner, :my_workflow, workflow,
  executor: Runic.Runner.Executor.GenStage,
  executor_opts: [
    max_demand: 8,     # concurrent consumers (default: System.schedulers_online())
    buffer_size: 1000  # producer buffer size (default: :infinity)
  ]
)
```

**Use when:** Sustained high-throughput workloads where you need to prevent the system from being overwhelmed. The Producer buffers work when all consumers are busy — dispatches don't pile up unbounded.

**Trade-off:** More infrastructure than Task executor. Work items execute inside long-lived consumer processes rather than ephemeral tasks. Individual work item failures are caught via `try/catch` inside the consumer (the consumer doesn't crash), so failure behavior is slightly different from Task's crash-based isolation.

**Requires:** `{:gen_stage, "~> 1.2"}` as a dependency.

### Per-Component Executor Overrides

Different steps in the same workflow can use different executors via `SchedulerPolicy`:

```elixir
alias Runic.Workflow.SchedulerPolicy

workflow =
  Runic.workflow(name: :mixed, steps: [fast_step, slow_step, critical_step])
  |> Workflow.set_scheduler_policies([
    # Fast lookups run inline — no process spawn overhead
    SchedulerPolicy.new(:fast_lookup, executor: :inline),

    # Critical external calls get their own isolated executor
    SchedulerPolicy.new(:external_api, executor: Runic.Runner.Executor.Task)
  ])
```

Override executors are lazily initialized on first use and maintained in the Worker state. The default executor handles any runnables without a policy override.

## Schedulers

A scheduler controls how prepared runnables are grouped and ordered for dispatch. All schedulers implement the `Runic.Runner.Scheduler` behaviour.

### Default Scheduler

Wraps each runnable as an individual `{:runnable, r}` dispatch unit. Zero overhead — identical to pre-scheduler Worker behavior.

```elixir
# This is the default — no configuration needed
Runic.Runner.start_workflow(runner, :my_workflow, workflow)
```

**Use when:** Workflows are simple, don't have long chains, and don't have high fan-out. Most workflows.

### ChainBatching Scheduler

Detects linear chains in the workflow graph and batches them into sequential Promises. A chain like `a → b → c` becomes a single dispatch that executes all three steps sequentially within one task.

```elixir
Runic.Runner.start_workflow(runner, :my_workflow, workflow,
  scheduler: Runic.Runner.Scheduler.ChainBatching,
  scheduler_opts: [min_chain_length: 2]  # default: 2
)

# Shorthand via promise_opts (equivalent to above):
Runic.Runner.start_workflow(runner, :my_workflow, workflow,
  promise_opts: [min_chain_length: 2]
)
```

**How it works:** The `PromiseBuilder` walks `:flow` edges forward from each runnable. A chain continues as long as each node has exactly one successor and that successor has exactly one predecessor. The chain is dispatched as a single task that executes steps sequentially, applying each result to a local workflow copy before running the next.

**Chain exclusions:** Join/FanIn nodes (they synchronize external inputs) and nodes with `:meta_ref` edges (they read mutable workflow state) are never included in chains.

**Use when:** Workflows have long linear pipelines (ETL transforms, LLM chains, data processing). Reduces N task spawns to 1 for an N-step chain.

**Trade-off:** Chain steps lose individual crash isolation — if step 3 of a 5-step chain fails, step 1 and 2 results are committed (partial commit), but step 4 and 5 never run. The workflow resumes from the failed step on the next dispatch cycle, which matches individual dispatch semantics.

### FlowBatch Scheduler

Extends `ChainBatching` to also detect **parallel batch** opportunities. After extracting sequential chains, groups independent runnables into a single `:parallel` Promise executed concurrently via `Flow` (or `Task.async_stream` as fallback).

```elixir
# Requires {:flow, "~> 1.2"} in your deps for Flow execution
# Falls back to Task.async_stream if Flow is not available
Runic.Runner.start_workflow(runner, :my_workflow, workflow,
  scheduler: Runic.Runner.Scheduler.FlowBatch,
  scheduler_opts: [
    min_chain_length: 2,                    # sequential chain threshold (default: 2)
    min_batch_size: 4,                      # parallel batch threshold (default: 4)
    flow_stages: System.schedulers_online(), # max Flow stages (default: schedulers_online)
    flow_max_demand: 1                       # Flow max_demand per stage (default: 1)
  ]
)
```

**How it works:**

1. Extract sequential chains via `PromiseBuilder` (same as `ChainBatching`)
2. From remaining standalone runnables, identify eligible candidates (exclude Join/FanIn, `:meta_ref`)
3. Build a dependency graph of eligible runnables using `:flow` edges
4. Group into connected components via union-find
5. Singleton components (runnables with no `:flow` edges to other eligibles) are independent
6. If the independent count ≥ `min_batch_size`, merge them into one `:parallel` Promise

**Killer use case: large fan-outs.** When a Map component fans out over 10,000 items, all 10,000 child runnables are independent (same parent, no edges between siblings). FlowBatch detects this and creates a single parallel Promise. Instead of 10,000 individual task dispatches bounded by `max_concurrency`, one task runs Flow internally with optimal concurrent execution.

```elixir
# A Map component that processes items in parallel
mapper = Runic.map(fn item -> expensive_transform(item) end, name: :process_items)

workflow =
  Runic.workflow(name: :batch_pipeline, steps: [
    {validate_step, [mapper]}
  ])

# FlowBatch automatically groups the fan-out into a parallel Promise
Runic.Runner.start_workflow(runner, :batch, workflow,
  scheduler: Runic.Runner.Scheduler.FlowBatch,
  scheduler_opts: [min_batch_size: 4]
)
```

**Use when:** Workflows produce large numbers of independent runnables — Map/FanOut patterns, broad fan-outs after a rule, or any topology where many steps become runnable simultaneously with no dependencies between them.

**Trade-off:** The `min_batch_size` threshold (default: 4) prevents Flow overhead from hurting small batches. Below the threshold, runnables dispatch individually. Parallel promises have no intermediate state sharing — all runnables must be truly independent, which FlowBatch verifies structurally.

## How Promises Work

Promises are the internal mechanism that makes `ChainBatching` and `FlowBatch` possible. Users don't create Promises directly — they're constructed by schedulers and managed by the Worker.

A `Promise` groups runnables into a single dispatch unit:

- **Sequential promises** (`:sequential` strategy): Execute runnables one after another within a single task. Each step sees the updated workflow state from the previous step. Created by `ChainBatching` for linear chains.

- **Parallel promises** (`:parallel` strategy): Execute all runnables concurrently via `Flow.from_enumerable |> Flow.map` (or `Task.async_stream` if Flow is unavailable). Runnables are independent by construction — no intermediate state sharing. Created by `FlowBatch` for independent batches.

Both types count as **1 dispatch slot** in the Worker's concurrency tracking, regardless of how many runnables they contain internally. A parallel Promise with 10,000 runnables occupies 1 slot. This is intentional — it replaces what would have been many individual dispatches.

### Failure Semantics

- **Sequential:** Partial commit. If runnable N fails, runnables 1..N-1 are committed, the failed runnable is returned for error handling, and runnables N+1..end are skipped. The workflow resumes from the failed step on the next dispatch cycle.

- **Parallel:** All runnables execute independently. Individual failures are caught via `try/rescue/catch` inside the Flow stage (or async stream). The result list contains a mix of completed and failed runnables. All succeeded runnables are committed; failed ones go through the normal error path.

### Telemetry

Promise lifecycle events are emitted in addition to per-runnable events:

- `[:runic, :runner, :promise, :start]` — promise dispatched, metadata includes `promise_id`, `runnable_count`, `node_hashes`
- `[:runic, :runner, :promise, :stop]` — promise completed, includes `duration` measurement

## Worker Hooks

Hooks provide observability and light customization without replacing the Worker:

```elixir
Runic.Runner.start_workflow(runner, :my_workflow, workflow,
  hooks: [
    on_dispatch: fn runnable, _worker_state ->
      Logger.info("Dispatching: #{runnable.node.name}")
    end,

    on_complete: fn runnable, duration_ms, _worker_state ->
      Logger.info("Completed: #{runnable.node.name} in #{duration_ms}ms")
    end,

    on_failed: fn runnable, reason, _worker_state ->
      Logger.error("Failed: #{runnable.node.name}: #{inspect(reason)}")
    end,

    on_idle: fn _worker_state ->
      Logger.info("Workflow idle — no more runnables")
    end,

    transform_runnables: fn runnables, _workflow ->
      # Reorder, filter, or annotate runnables before dispatch
      Enum.sort_by(runnables, & &1.node.name)
    end
  ]
)
```

Hook exceptions are logged but never crash the Worker. `transform_runnables` receives the full runnable list before the scheduler sees it.

## Execution Dependencies

Runic depends on both `gen_stage` and `flow` for its execution strategies:

```elixir
# mix.exs
defp deps do
  [
    {:runic, "~> 0.1"},
    {:flow, "~> 1.2"},
    {:gen_stage, "~> 1.2"}
  ]
end
```

## Choosing the Right Configuration

### Decision Flow

1. **Are your workflows simple with no performance concerns?**
   → Use defaults. Stop here.

2. **Do you have long linear chains (5+ steps) with fast individual steps?**
   → Use `ChainBatching` scheduler to reduce dispatch overhead.

3. **Do you have large fan-outs (Map over 100+ items)?**
   → Use `FlowBatch` scheduler. Add `{:flow, "~> 1.2"}` for best performance.

4. **Do you have sub-millisecond steps where task overhead dominates?**
   → Use `:inline` executor (globally or per-component via policy).

5. **Do you need back-pressure under sustained load?**
   → Use `GenStage` executor. Add `{:gen_stage, "~> 1.2"}`.

6. **Do you have a mixed workload (some fast, some slow, some risky)?**
   → Use per-component executor overrides via `SchedulerPolicy`.

### Common Configurations

```elixir
# Default — works for most workflows
Runic.Runner.start_workflow(runner, :id, workflow)

# Pipeline optimization — batch linear chains
Runic.Runner.start_workflow(runner, :id, workflow,
  promise_opts: [min_chain_length: 3]
)

# High fan-out optimization — parallel batch + Flow
Runic.Runner.start_workflow(runner, :id, workflow,
  scheduler: Runic.Runner.Scheduler.FlowBatch,
  scheduler_opts: [min_batch_size: 8, flow_stages: 16]
)

# Maximum throughput with back-pressure
Runic.Runner.start_workflow(runner, :id, workflow,
  executor: Runic.Runner.Executor.GenStage,
  executor_opts: [max_demand: 16],
  scheduler: Runic.Runner.Scheduler.FlowBatch
)

# Testing — synchronous, deterministic execution
Runic.Runner.start_workflow(runner, :id, workflow,
  executor: :inline
)
```

## Building Custom Schedulers

Implement the `Runic.Runner.Scheduler` behaviour:

```elixir
defmodule MyApp.PriorityScheduler do
  @behaviour Runic.Runner.Scheduler

  @impl true
  def init(opts) do
    {:ok, %{priority_fn: Keyword.get(opts, :priority_fn, fn _ -> 0 end)}}
  end

  @impl true
  def plan_dispatch(_workflow, runnables, state) do
    units =
      runnables
      |> Enum.sort_by(state.priority_fn)
      |> Enum.map(&{:runnable, &1})

    {units, state}
  end
end
```

Use the conformance test suite to verify your implementation:

```elixir
defmodule MyApp.PrioritySchedulerTest do
  use Runic.Runner.Scheduler.ContractTest,
    scheduler: MyApp.PriorityScheduler,
    opts: []
end
```

The contract test verifies: all input runnables are accounted for, no duplicates, no overlapping `node_hashes`, valid dispatch unit types, proper state threading, and correct handling of empty input.

## Building Custom Executors

Implement the `Runic.Runner.Executor` behaviour:

```elixir
defmodule MyApp.PoolExecutor do
  @behaviour Runic.Runner.Executor

  @impl true
  def init(opts) do
    pool = Keyword.fetch!(opts, :pool)
    {:ok, %{pool: pool}}
  end

  @impl true
  def dispatch(work_fn, _opts, %{pool: pool} = state) do
    caller = self()
    handle = make_ref()

    # Your dispatch mechanism must send these messages to the caller:
    #   {handle, result}                           — on success
    #   {:DOWN, handle, :process, pid, reason}     — on crash
    spawn(fn ->
      try do
        result = work_fn.()
        send(caller, {handle, result})
      catch
        kind, reason ->
          send(caller, {:DOWN, handle, :process, self(), {kind, reason}})
      end
    end)

    {handle, state}
  end

  @impl true  # optional callback
  def cleanup(state) do
    # Clean up resources when Worker stops
    :ok
  end
end
```

The critical contract: the executor must arrange for the calling process to receive `{handle, result}` on success and `{:DOWN, handle, :process, pid, reason}` on failure. This matches `Task.Supervisor.async_nolink` semantics.

## Runtime Context in Runners

When using the `Runic.Runner`, you can provide runtime context values via the `:run_context` option in `Runner.run/4`:

```elixir
Runic.Runner.run(runner, :my_workflow, input,
  run_context: %{
    call_llm: %{api_key: "sk-..."},
    _global: %{workspace_id: "ws1"}
  }
)
```

The Worker applies `run_context` before `plan_eagerly`, making context values available to all components during the prepare → execute cycle.

For workflows using `react_until_satisfied/3` directly (without Runner), pass `:run_context` in the options:

```elixir
Workflow.react_until_satisfied(workflow, input,
  run_context: %{call_llm: %{api_key: "sk-..."}}
)
```

Context values are resolved during the prepare phase and merged into the `CausalContext`, so they are available in both serial and parallel execution modes, including when using custom schedulers and executors.

### Supported Component Types

`context/1` is supported in all workflow component types:

- **Steps** — `Runic.step(fn x -> x + context(:offset) end)`
- **Conditions** — `Runic.condition(fn x -> x > context(:threshold) end)`
- **Rules** — `context/1` in `where` and `then` clauses
- **Accumulators** — `Runic.accumulator(0, fn x, s -> s + x * context(:factor) end)`
- **Map pipelines** — `Runic.map(fn x -> x * context(:multiplier) end)`
- **Reduce** — `Runic.reduce(0, fn x, acc -> acc + x * context(:weight) end)`
- **State Machines** — internal state conditions and reactions support `context/1`

### Default Values

Use `context/2` to provide defaults when `run_context` doesn't supply a key:

```elixir
# Literal default
step = Runic.step(fn _x -> context(:model, default: "gpt-4") end, name: :call_llm)

# Function default — called lazily when key is missing
step = Runic.step(fn _x -> context(:api_key, default: fn -> System.get_env("KEY") end) end, name: :call_llm)
```

Keys with defaults are not reported as missing by `Workflow.validate_run_context/2`. Use `Workflow.required_context_keys/1` to see which keys are `:required` vs `{:optional, default}`.
