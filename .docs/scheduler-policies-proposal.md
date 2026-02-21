# Scheduler Policies — Architecture & API Proposal

**Status:** Draft  
**Scope:** `Runic.Workflow` runtime, `Invokable` protocol execution, `Runnable` lifecycle  

---

## Table of Contents

- [Motivation](#motivation)
- [Design Principles](#design-principles)
- [API Surface](#api-surface)
  - [Policy Definition](#policy-definition)
  - [Runtime Integration Points](#runtime-integration-points)
  - [Fallback & Recovery](#fallback--recovery)
- [Architecture](#architecture)
  - [Where Policies Apply in the Three-Phase Model](#where-policies-apply-in-the-three-phase-model)
  - [Policy Resolution](#policy-resolution)
  - [The SchedulerPolicy Struct](#the-schedulerpolicy-struct)
  - [Execution Driver](#execution-driver)
- [Runnable Serializability](#runnable-serializability)
  - [The Case for Serializable Runnables](#the-case-for-serializable-runnables)
  - [Hybrid Approach: Event-Sourced Runnables](#hybrid-approach-event-sourced-runnables)
  - [RunnableEvent Struct](#runnableevent-struct)
- [Durable Execution Primitives](#durable-execution-primitives)
  - [Timeouts](#timeouts)
  - [Retries with Backoff](#retries-with-backoff)
  - [Fallbacks](#fallbacks)
  - [Circuit Breakers](#circuit-breakers)
  - [Deadlines & Budgets](#deadlines--budgets)
  - [Checkpointing](#checkpointing)
- [Interaction with Existing Systems](#interaction-with-existing-systems)
  - [Hooks](#hooks)
  - [Async Execution](#async-execution)
  - [External Schedulers](#external-schedulers)
  - [Event Log / from_log](#event-log--from_log)
- [API Alternatives Considered](#api-alternatives-considered)
- [Implementation Phases](#implementation-phases)
- [Full API Examples](#full-api-examples)

---

## Motivation

Runic's three-phase execution model (Prepare → Execute → Apply) already decouples _what_ runs from _how_ it runs. Today, the execute phase is fire-and-forget: the work function runs, and if it raises, the runnable is marked `:failed` and a warning is logged. There is no built-in retry, timeout, backoff, fallback, or durability mechanism.

Real-world workflows — especially those involving LLM calls, external APIs, database operations, or distributed services — need configurable execution strategies per component. A `classify_actions` step calling a fast model has different failure characteristics than a `generate_narrative` step calling a slow one. Hardcoding retry logic into work functions or hooks pollutes the workflow definition with infrastructure concerns.

**Scheduler policies** solve this by allowing execution strategies to be declaratively attached to workflow components by name, resolved at dispatch time, and enforced by the execution driver — without changing the workflow graph, the Invokable protocol, or the component definitions themselves.

---

## Design Principles

1. **Policies live on the workflow as base configuration, overrideable at runtime.** The `%Workflow{}` struct stores a base `scheduler_policies` map. Runtime calls (`react/3`, `react_until_satisfied/3`) can pass `:scheduler_policies` as an option to override or extend the base. This gives workflows a portable default execution strategy while allowing environments to tune at call-time.

2. **Policies are resolved by pattern matching, not just name lookup.** A minimal rule-based resolution system matches policies to components by name, component type, name pattern, or catch-all default. This enables broad policies like "all Conditions run eagerly in-memory" alongside specific overrides like "`:generate_narrative` gets 30s timeout with exponential backoff."

3. **Policies compose with, not replace, existing mechanisms.** Hooks, async execution, and external scheduler integration all continue to work. Policies add a layer between `prepare_for_dispatch` and `Invokable.execute` — they wrap the execute phase.

4. **The Invokable protocol is not modified.** Policies operate outside the protocol boundary. `Invokable.execute/2` remains a pure, single-invocation function. The policy driver calls it, potentially multiple times with backoff, but the protocol itself is unaware of retries.

5. **Policies are optional.** All existing APIs continue to work without policies. `react_until_satisfied/3` with no `:scheduler_policies` option and no workflow-level policies behaves exactly as it does today.

6. **A Step's identity is its work function and hash.** Retry counts, timeouts, and fallbacks are properties of the execution environment, not the step. The same workflow graph can run with different policies in different environments.

---

## API Surface

### Policy Definition

A single policy is a map of execution options. Policies are organized into a `scheduler_policies` list of `{matcher, policy}` tuples, evaluated in order. The first matching rule wins, with later entries acting as fallbacks.

```elixir
@type backoff_strategy :: :none | :linear | :exponential | :jitter
@type failure_action :: :skip | :halt | :fallback

@type scheduler_policy :: %{
  optional(:max_retries) => non_neg_integer(),       # default: 0
  optional(:backoff) => backoff_strategy(),           # default: :none
  optional(:base_delay_ms) => pos_integer(),          # default: 500
  optional(:max_delay_ms) => pos_integer(),           # default: 30_000
  optional(:timeout_ms) => pos_integer() | :infinity, # default: :infinity
  optional(:on_failure) => failure_action(),           # default: :halt
  optional(:fallback) => fallback_fn(),                # default: nil
  optional(:deadline_ms) => pos_integer() | nil,       # default: nil (workflow-level deadline)
  optional(:circuit_breaker) => circuit_breaker_opts() | nil,
  optional(:execution_mode) => :sync | :async | :durable, # default: :sync
  optional(:priority) => :high | :normal | :low,           # default: :normal
  optional(:idempotency_key) => (Runnable.t() -> term()) | nil
}

@type fallback_fn ::
  (Runnable.t(), term() -> Runnable.t())          # return modified runnable for retry
  | (Runnable.t(), term() -> {:retry_with, map()})  # return context overrides
  | (Runnable.t(), term() -> {:value, term()})       # return a synthetic result
```

### Policy Matchers — Rule-Based Resolution

Rather than a flat `%{component_name => policy}` map, policies use a list of `{matcher, policy}` tuples. Matchers are evaluated in order against each runnable's node; the first match wins.

```elixir
@type policy_matcher ::
  :default                                  # catch-all, always matches
  | atom()                                  # exact component name match
  | {:name, Regex.t()}                      # component name pattern
  | {:type, module()}                       # component struct type (Step, Condition, etc.)
  | {:type, [module()]}                     # any of these types
  | (struct() -> boolean())                 # arbitrary predicate on the node struct

@type scheduler_policies :: [{policy_matcher(), scheduler_policy()}]
```

**Matcher types:**

| Matcher | Matches | Example |
|---------|---------|---------|
| `:my_step` | Exact component name | `:generate_narrative` |
| `{:name, ~r/llm_/}` | Names matching regex | `{:name, ~r/^llm_/}` |
| `{:type, Step}` | All Steps | `{:type, Runic.Workflow.Step}` |
| `{:type, Condition}` | All Conditions | `{:type, Runic.Workflow.Condition}` |
| `{:type, [Step, Accumulator]}` | Steps or Accumulators | `{:type, [Step, Accumulator]}` |
| `fn node -> ... end` | Custom predicate | `fn node -> node.name in @external_apis end` |
| `:default` | Everything (catch-all) | `:default` |

**Example:**

```elixir
policies = [
  # Specific step override — highest priority (first in list)
  {:generate_narrative, %{
    max_retries: 3,
    backoff: :exponential,
    base_delay_ms: 1_000,
    timeout_ms: 30_000,
    fallback: fn _r, _e -> {:retry_with, %{model: "gpt-4o-mini"}} end
  }},

  # All steps whose names match "llm_*" — LLM call defaults
  {{:name, ~r/^llm_/}, %{
    max_retries: 2,
    backoff: :exponential,
    base_delay_ms: 500,
    timeout_ms: 15_000
  }},

  # All Conditions — fast in-memory, no retries, no timeout
  {{:type, Runic.Workflow.Condition}, %{
    max_retries: 0,
    timeout_ms: :infinity,
    execution_mode: :sync
  }},

  # All Steps — general durable execution defaults
  {{:type, Runic.Workflow.Step}, %{
    max_retries: 1,
    backoff: :linear,
    base_delay_ms: 500,
    timeout_ms: 10_000,
    execution_mode: :async
  }},

  # Catch-all default
  {:default, %{
    max_retries: 0,
    timeout_ms: :infinity
  }}
]
```

### Storing Policies on the Workflow

The `%Workflow{}` struct gains a `scheduler_policies` field for base configuration:

```elixir
# Set base policies during construction
workflow = Workflow.new(name: :my_workflow, scheduler_policies: policies)

# Or set/replace after construction
workflow = Workflow.set_scheduler_policies(workflow, policies)

# Add a single policy rule (prepends — higher priority than existing)
workflow = Workflow.add_scheduler_policy(workflow, :my_step, %{max_retries: 3})
workflow = Workflow.add_scheduler_policy(workflow, {:type, Step}, %{timeout_ms: 5_000})

# Add to the end (lower priority than existing)
workflow = Workflow.append_scheduler_policy(workflow, :default, %{max_retries: 1})
```

### Runtime Override

Runtime options deep-merge over the workflow's base policies. This allows per-invocation tuning:

```elixir
# Base policies live on the workflow
workflow = Workflow.set_scheduler_policies(workflow, base_policies)

# Runtime override — these rules are prepended (higher priority)
Workflow.react_until_satisfied(workflow, input,
  scheduler_policies: [
    {:generate_narrative, %{timeout_ms: 60_000}}  # override just this step's timeout
  ]
)

# Or replace entirely for this invocation
Workflow.react_until_satisfied(workflow, input,
  scheduler_policies: completely_different_policies,
  scheduler_policies_mode: :replace  # default is :merge (prepend)
)
```

### Low-Level Integration

For external schedulers using `prepare_for_dispatch/1` directly:

```elixir
{workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

# Resolve and execute with policies
executed = Workflow.execute_with_policies(runnables, workflow.scheduler_policies)
# or individually:
executed = Workflow.execute_runnable(runnable, workflow.scheduler_policies)

workflow = Enum.reduce(executed, workflow, &Workflow.apply_runnable(&2, &1))
```

### Fallback & Recovery

Fallbacks receive the runnable and the error, and can return one of three shapes:

```elixir
# 1. Modify the runnable and retry (e.g., swap model, change params)
fallback: fn runnable, _error ->
  updated_node = %{runnable.node | work: &alternative_model/1}
  %{runnable | node: updated_node}
end

# 2. Return context overrides for retry
fallback: fn _runnable, _error ->
  {:retry_with, %{model_override: "grok-4.1-fast"}}
end

# 3. Return a synthetic value (skip execution entirely)
fallback: fn _runnable, error ->
  {:value, %{error: inspect(error), fallback: true}}
end
```

---

## Architecture

### Where Policies Apply in the Three-Phase Model

```
┌─────────────┐      ┌──────────────────────────────┐      ┌─────────────┐
│   PREPARE   │ ───► │     POLICY-DRIVEN EXECUTE     │ ───► │    APPLY    │
│  (Phase 1)  │      │         (Phase 2)              │      │  (Phase 3)  │
└─────────────┘      └──────────────────────────────┘      └─────────────┘
      │                          │                                │
      ▼                          ▼                                ▼
 Extract context         ┌──────────────┐                  Reduce results
 from workflow           │ Resolve policy│                  into workflow
 → %Runnable{}           │ for component │
                         └──────┬───────┘
                                │
                         ┌──────▼───────┐
                         │ Start timer  │
                         │ (timeout_ms) │
                         └──────┬───────┘
                                │
                         ┌──────▼───────┐  success
                         │   Execute    │────────────► Runnable.complete()
                         │   (invoke)   │
                         └──────┬───────┘
                                │ failure
                         ┌──────▼───────┐
                         │ Retry logic  │──► backoff delay
                         │ attempts < N │──► re-execute
                         └──────┬───────┘
                                │ exhausted
                         ┌──────▼───────┐
                         │  Fallback?   │──► call fallback_fn
                         └──────┬───────┘    └──► retry with modified runnable
                                │                  or return synthetic value
                         ┌──────▼───────┐
                         │ on_failure   │
                         │ :halt/:skip  │
                         └──────────────┘
```

Critically, the policy driver wraps Phase 2 **without modifying Phase 1 or Phase 3**. The `Runnable` struct enters the policy driver in `:pending` state and exits in `:completed`, `:failed`, or `:skipped` state — the same contract `apply_runnable/2` already expects.

### Policy Resolution

Resolution evaluates the merged policy list (runtime overrides prepended to workflow base) top-to-bottom. The first matching rule's policy is merged over built-in defaults:

1. Build the effective rule list: `runtime_overrides ++ workflow.scheduler_policies`
2. Walk the list; for each `{matcher, policy}`, test the matcher against the runnable's node
3. First match wins — its policy is merged over `@default_policy`
4. If no rule matches, use `@default_policy` (zero retries, no timeout, halt on failure)

```elixir
defmodule Runic.Workflow.SchedulerPolicy do
  @default_policy %{
    max_retries: 0,
    backoff: :none,
    base_delay_ms: 500,
    max_delay_ms: 30_000,
    timeout_ms: :infinity,
    on_failure: :halt,
    fallback: nil,
    deadline_ms: nil,
    circuit_breaker: nil,
    execution_mode: :sync,
    priority: :normal,
    idempotency_key: nil
  }

  @doc """
  Resolves the effective policy for a runnable given a list of {matcher, policy} rules.
  """
  @spec resolve(Runnable.t(), scheduler_policies()) :: scheduler_policy()
  def resolve(%Runnable{node: node}, policies) when is_list(policies) do
    case find_matching_policy(node, policies) do
      nil -> @default_policy
      policy -> Map.merge(@default_policy, policy)
    end
  end

  def resolve(_runnable, _policies), do: @default_policy

  @doc """
  Builds the effective policy list by merging runtime overrides with workflow base.
  """
  def merge_policies(runtime_overrides, workflow_base) when is_list(runtime_overrides) do
    runtime_overrides ++ workflow_base
  end

  def merge_policies(nil, workflow_base), do: workflow_base

  defp find_matching_policy(_node, []), do: nil

  defp find_matching_policy(node, [{matcher, policy} | rest]) do
    if matches?(node, matcher) do
      policy
    else
      find_matching_policy(node, rest)
    end
  end

  # Exact name match
  defp matches?(%{name: name}, matcher) when is_atom(matcher) and matcher != :default do
    normalize_name(name) == matcher
  end

  # Catch-all
  defp matches?(_node, :default), do: true

  # Regex on name
  defp matches?(%{name: name}, {:name, %Regex{} = regex}) do
    name_str = if is_atom(name), do: Atom.to_string(name), else: to_string(name)
    Regex.match?(regex, name_str)
  end

  # Type match — single module
  defp matches?(node, {:type, module}) when is_atom(module) do
    node.__struct__ == module
  end

  # Type match — list of modules
  defp matches?(node, {:type, modules}) when is_list(modules) do
    node.__struct__ in modules
  end

  # Custom predicate function
  defp matches?(node, matcher) when is_function(matcher, 1) do
    matcher.(node)
  end

  defp matches?(_node, _matcher), do: false

  defp normalize_name(name) when is_atom(name), do: name
  defp normalize_name(name) when is_binary(name), do: String.to_existing_atom(name)
  defp normalize_name(_), do: nil
end
```

### The SchedulerPolicy Struct

While policies can be plain maps at the API boundary, internally they are normalized into a struct for validation and pattern matching:

```elixir
defmodule Runic.Workflow.SchedulerPolicy do
  @moduledoc """
  Configures execution strategy for a workflow component.

  Policies are resolved by pattern matching at dispatch time and govern
  timeout, retry, backoff, fallback, and failure behavior.
  """

  @type t :: %__MODULE__{
    max_retries: non_neg_integer(),
    backoff: :none | :linear | :exponential | :jitter,
    base_delay_ms: pos_integer(),
    max_delay_ms: pos_integer(),
    timeout_ms: pos_integer() | :infinity,
    on_failure: :skip | :halt | :fallback,
    fallback: (Runnable.t(), term() -> term()) | nil,
    deadline_ms: pos_integer() | nil,
    circuit_breaker: map() | nil,
    execution_mode: :sync | :async | :durable,
    priority: :high | :normal | :low,
    idempotency_key: (Runnable.t() -> term()) | nil
  }

  defstruct [
    max_retries: 0,
    backoff: :none,
    base_delay_ms: 500,
    max_delay_ms: 30_000,
    timeout_ms: :infinity,
    on_failure: :halt,
    fallback: nil,
    deadline_ms: nil,
    circuit_breaker: nil,
    execution_mode: :sync,
    priority: :normal,
    idempotency_key: nil
  ]

  @doc "Creates a policy from a keyword list or map, validating options."
  def new(opts) when is_map(opts), do: struct!(__MODULE__, opts)
  def new(opts) when is_list(opts), do: struct!(__MODULE__, Map.new(opts))
end
```

### Execution Driver

The execution driver is the core runtime addition. It wraps `Invokable.execute/2` with policy enforcement:

```elixir
defmodule Runic.Workflow.PolicyDriver do
  @moduledoc """
  Executes a runnable according to its resolved scheduler policy.

  Handles timeout, retry with backoff, fallback, and failure actions.
  This module is stateless — all state is carried in the runnable and policy.
  """

  alias Runic.Workflow.{Invokable, Runnable, SchedulerPolicy}

  @doc """
  Executes a single runnable with the given policy.

  Returns a runnable in :completed, :failed, or :skipped state.
  """
  @spec execute(Runnable.t(), SchedulerPolicy.t()) :: Runnable.t()
  def execute(%Runnable{} = runnable, %SchedulerPolicy{} = policy) do
    do_execute(runnable, policy, _attempt = 0)
  end

  defp do_execute(runnable, policy, attempt) do
    result = execute_with_timeout(runnable, policy.timeout_ms)

    case result do
      %Runnable{status: :completed} = completed ->
        completed

      %Runnable{status: :skipped} = skipped ->
        skipped

      %Runnable{status: :failed, error: error} = failed ->
        cond do
          attempt < policy.max_retries ->
            delay = compute_delay(policy, attempt)
            Process.sleep(delay)
            do_execute(reset_for_retry(runnable), policy, attempt + 1)

          not is_nil(policy.fallback) ->
            handle_fallback(runnable, policy, error)

          policy.on_failure == :skip ->
            skip_runnable(runnable)

          true ->
            # :halt — return the failed runnable as-is
            failed
        end
    end
  end

  defp execute_with_timeout(runnable, :infinity) do
    Invokable.execute(runnable.node, runnable)
  end

  defp execute_with_timeout(runnable, timeout_ms) do
    task = Task.async(fn -> Invokable.execute(runnable.node, runnable) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> Runnable.fail(runnable, {:timeout, timeout_ms})
    end
  end

  defp compute_delay(%{backoff: :none}, _attempt), do: 0
  defp compute_delay(%{backoff: :linear, base_delay_ms: base, max_delay_ms: max}, attempt) do
    min(base * (attempt + 1), max)
  end
  defp compute_delay(%{backoff: :exponential, base_delay_ms: base, max_delay_ms: max}, attempt) do
    min(base * :math.pow(2, attempt) |> trunc(), max)
  end
  defp compute_delay(%{backoff: :jitter, base_delay_ms: base, max_delay_ms: max}, attempt) do
    exponential = base * :math.pow(2, attempt) |> trunc()
    jittered = :rand.uniform(max(exponential, 1))
    min(jittered, max)
  end

  defp reset_for_retry(runnable) do
    %{runnable | status: :pending, result: nil, error: nil, apply_fn: nil}
  end

  defp handle_fallback(runnable, policy, error) do
    case policy.fallback.(runnable, error) do
      # Modified runnable — retry with it
      %Runnable{} = modified ->
        do_execute(modified, %{policy | max_retries: 0, fallback: nil}, 0)

      # Context overrides for the work function
      {:retry_with, overrides} when is_map(overrides) ->
        modified = apply_overrides(runnable, overrides)
        do_execute(modified, %{policy | max_retries: 0, fallback: nil}, 0)

      # Synthetic result — produce a completed runnable with this value
      {:value, value} ->
        fact = Runic.Workflow.Fact.new(value: value,
          ancestry: {runnable.node.hash, runnable.input_fact.hash})

        apply_fn = fn workflow ->
          workflow
          |> Runic.Workflow.log_fact(fact)
          |> Runic.Workflow.draw_connection(runnable.node, fact, :produced,
               weight: runnable.context.ancestry_depth + 1)
          |> Runic.Workflow.mark_runnable_as_ran(runnable.node, runnable.input_fact)
          |> Runic.Workflow.prepare_next_runnables(runnable.node, fact)
        end

        Runnable.complete(runnable, fact, apply_fn)

      other ->
        Runnable.fail(runnable, {:invalid_fallback_return, other})
    end
  end

  defp apply_overrides(runnable, overrides) do
    # Overrides are placed on the CausalContext's meta_context so the work
    # function can access them via meta expressions or a 2-arity work fn.
    updated_meta = Map.merge(runnable.context.meta_context, overrides)
    updated_ctx = %{runnable.context | meta_context: updated_meta}
    reset_for_retry(%{runnable | context: updated_ctx})
  end

  defp skip_runnable(runnable) do
    apply_fn = fn workflow ->
      Runic.Workflow.mark_runnable_as_ran(workflow, runnable.node, runnable.input_fact)
    end

    Runnable.skip(runnable, apply_fn)
  end
end
```

---

## Runnable Serializability

### The Case for Serializable Runnables

Today, `%Runnable{}` structs contain:
- `node` — the component struct (Step, Condition, etc.) which includes a `work` function (not serializable)
- `apply_fn` — a closure over workflow operations (not serializable, only present post-execute)
- `input_fact` — a `%Fact{}` struct (serializable)
- `context` — a `%CausalContext{}` struct (serializable, except `hooks` which are functions)

For durable execution, we need runnables that can be persisted to a database, picked up by a different node, and completed. This requires **splitting the serializable dispatch intent from the non-serializable execution machinery**.

### Hybrid Approach: Event-Sourced Runnables

Rather than making the full `%Runnable{}` serializable (which would require removing all closures), we use the existing event log model. A `%RunnableDispatched{}` event captures the intent, and `%RunnableCompleted{}` / `%RunnableFailed{}` events capture the outcome:

```elixir
defmodule Runic.Workflow.RunnableDispatched do
  @moduledoc """
  Event recording that a runnable was prepared for dispatch.

  Contains enough information to re-prepare and re-execute the runnable
  from a restored workflow if needed.
  """
  defstruct [
    :runnable_id,
    :node_name,
    :node_hash,
    :input_fact,        # %Fact{} — serializable
    :dispatched_at,     # DateTime
    :policy,            # %SchedulerPolicy{} sans fallback fn
    :attempt            # which retry attempt this represents
  ]
end

defmodule Runic.Workflow.RunnableCompleted do
  @moduledoc """
  Event recording that a runnable completed execution.
  """
  defstruct [
    :runnable_id,
    :node_hash,
    :result_fact,       # %Fact{} — serializable
    :completed_at,
    :attempt,
    :duration_ms
  ]
end

defmodule Runic.Workflow.RunnableFailed do
  @moduledoc """
  Event recording that a runnable failed permanently (retries exhausted).
  """
  defstruct [
    :runnable_id,
    :node_hash,
    :error,             # serializable error term
    :failed_at,
    :attempts,
    :failure_action     # :halt | :skip
  ]
end
```

This approach:
- Keeps the existing `%Runnable{}` struct unchanged (no protocol or API breakage)
- Allows durable workflows to persist dispatch/completion events alongside the existing `%ReactionOccurred{}` events
- Enables reconstruction: `from_log/1` can replay `RunnableDispatched` events to identify in-flight work after a crash
- Works with the existing `Closure`-based workflow serialization

### When Full Runnable Serialization Makes Sense

For simpler durable execution (e.g., a job queue), the runnable can be made "reference-serializable" — storing enough to re-prepare:

```elixir
defmodule Runic.Workflow.RunnableRef do
  @moduledoc """
  A serializable reference to a runnable that can be used to re-prepare
  it from a restored workflow.
  """
  defstruct [
    :runnable_id,
    :node_hash,
    :node_name,
    :input_fact_hash,
    :input_fact_value,
    :policy
  ]

  @doc "Creates a ref from a live runnable."
  def from_runnable(%Runnable{} = r) do
    %__MODULE__{
      runnable_id: r.id,
      node_hash: r.node.hash,
      node_name: r.node.name,
      input_fact_hash: r.input_fact.hash,
      input_fact_value: r.input_fact.value,
      policy: strip_fns(r)  # remove non-serializable fallback fns
    }
  end

  @doc "Re-prepares a runnable from a ref and a workflow."
  def to_runnable(%__MODULE__{} = ref, %Workflow{} = workflow) do
    node = Workflow.get_component(workflow, ref.node_name)
    fact = Fact.new(value: ref.input_fact_value)
    {:ok, runnable} = Invokable.prepare(node, workflow, fact)
    runnable
  end
end
```

---

## Durable Execution Primitives

### Timeouts

Per-runnable execution timeout enforced by `Task.yield/2` + `Task.shutdown/2`:

```elixir
classify_actions: %{timeout_ms: 10_000}
```

- Timeout produces a `{:timeout, timeout_ms}` error, eligible for retry
- `:infinity` (the default) disables timeout

### Retries with Backoff

```elixir
generate_narrative: %{
  max_retries: 3,
  backoff: :exponential,
  base_delay_ms: 1_000,
  max_delay_ms: 30_000
}
```

Backoff strategies:
- `:none` — no delay between retries (immediate)
- `:linear` — `base_delay_ms * (attempt + 1)`, capped at `max_delay_ms`
- `:exponential` — `base_delay_ms * 2^attempt`, capped at `max_delay_ms`
- `:jitter` — randomized exponential, capped at `max_delay_ms`

Each retry calls `Invokable.execute/2` on a fresh (reset) runnable. The `apply_fn` from failed attempts is discarded.

### Fallbacks

Fallback functions are invoked after all retries are exhausted. They receive the runnable and the last error:

```elixir
generate_narrative: %{
  max_retries: 2,
  fallback: fn runnable, _error ->
    # Switch to a cheaper/faster model
    {:retry_with, %{model_override: "gpt-4o-mini"}}
  end,
  on_failure: :halt
}
```

Three return shapes:
1. `%Runnable{}` — modified runnable, executed once more (no further retries)
2. `{:retry_with, %{overrides}}` — overrides merged into `meta_context`, re-executed once
3. `{:value, term}` — synthetic result, no execution, immediately completes

### Circuit Breakers

For workflows with many instances hitting the same external service, a shared circuit breaker prevents cascade failures:

```elixir
llm_call: %{
  circuit_breaker: %{
    name: :openai_breaker,        # registered circuit breaker name
    failure_threshold: 5,          # failures before opening
    reset_timeout_ms: 60_000,      # time before half-open
    on_open: :skip                 # what to do when circuit is open
  }
}
```

Circuit breaker state is **external to the workflow** — it lives in a named `Agent` or `:ets` table, shared across workflow instances. This keeps the workflow pure and the circuit breaker global.

> **Note:** Circuit breakers are a Phase 2 feature. The initial implementation can defer this to a hook or external library integration point.

### Deadlines & Budgets

A deadline is a wall-clock cutoff for the entire workflow execution, distinct from per-step timeouts:

```elixir
Workflow.react_until_satisfied(workflow, input,
  scheduler_policies: policies,
  deadline_ms: 120_000  # entire workflow must finish in 2 minutes
)
```

The policy driver checks the remaining budget before each retry attempt. If the remaining time is less than the step's `timeout_ms`, the step is skipped or failed immediately.

### Checkpointing

For long-running durable workflows, checkpointing persists the workflow state at defined intervals so that a crash doesn't lose all progress:

```elixir
Workflow.react_until_satisfied(workflow, input,
  scheduler_policies: policies,
  checkpoint: fn workflow ->
    # Called after each react cycle with applied results
    MyApp.Repo.save_workflow_state(workflow.name, Workflow.log(workflow))
  end
)
```

The checkpoint callback is invoked after each `apply_runnable/2` cycle, not after every individual runnable. This keeps the checkpoint granularity at the "generation" level — each cycle produces a consistent workflow state.

---

## Interaction with Existing Systems

### Hooks

Hooks and policies are complementary:
- **Hooks** observe and optionally modify the workflow (logging, metrics, dynamic composition)
- **Policies** govern execution strategy (retry, timeout, fallback)

Hooks execute _inside_ each `Invokable.execute/2` call. If a step is retried 3 times, hooks fire 3 times. This is correct — hooks see the real execution lifecycle.

If a hook returns `{:error, reason}`, the runnable fails, and that failure is subject to the policy's retry logic.

### Async Execution

The existing `async: true` option parallelizes across runnables within a single react cycle. Policies add per-runnable retry/timeout _within_ that parallelization:

```elixir
Workflow.react_until_satisfied(workflow, input,
  async: true,
  max_concurrency: 8,
  scheduler_policies: policies
)
```

Each concurrent task runs the full policy driver for its runnable. A slow step retrying with backoff does not block other parallel runnables.

### External Schedulers

For users who call `prepare_for_dispatch/1` directly, the policy driver is available as a standalone module. Policies are read from the workflow or passed explicitly:

```elixir
{workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

# Use the policy driver with workflow-stored policies
executed = Task.async_stream(runnables, fn runnable ->
  policy = SchedulerPolicy.resolve(runnable, workflow.scheduler_policies)
  PolicyDriver.execute(runnable, policy)
end, timeout: :infinity)

workflow = Enum.reduce(executed, workflow, fn {:ok, r}, w ->
  Workflow.apply_runnable(w, r)
end)
```

This keeps the three-phase model's flexibility fully intact. External schedulers can use the policy driver, ignore it, or implement their own. The built-in `Runic.Runner` modules (see [Runner Proposal](runner-proposal.md)) use this pattern internally.

### Event Log / from_log

Policy-related events (`RunnableDispatched`, `RunnableCompleted`, `RunnableFailed`) are appended to the workflow's event log alongside `ComponentAdded` and `ReactionOccurred` events. `from_log/1` can reconstruct in-flight state:

```elixir
log = Workflow.log(workflow)
# log now includes:
# [%ComponentAdded{}, ..., %ReactionOccurred{}, ...,
#  %RunnableDispatched{}, %RunnableCompleted{}, ...]

# On restore, identify runnables that were dispatched but never completed
restored = Workflow.from_log(log)
in_flight = Workflow.pending_runnables(restored)
```

---

## API Alternatives Considered

### Alternative 1: Policies as Component Metadata

```elixir
# Rejected: couples execution strategy to component identity
step = Runic.step(fn x -> x + 1 end,
  name: :add,
  max_retries: 3,
  timeout_ms: 10_000
)
```

**Why rejected:** This changes the Step struct and its hash. The same step would have different identities when run with different policies. It also means policies can't be changed without rebuilding the workflow graph.

### Alternative 2: Flat Map Keyed by Name Only

```elixir
# Considered: simple %{component_name => policy} map
policies = %{classify: %{max_retries: 3}, :default => %{max_retries: 1}}
```

**Why evolved:** Too coarse. Can't express "all Conditions should be eager" or "all steps matching `llm_*` get retries" without enumerating every component name. The rule-based matcher list subsumes this — an atom key is just the simplest matcher form.

### Alternative 3: Policy Protocol on Components

```elixir
# Rejected: over-engineered for the use case
defprotocol Runic.ExecutionPolicy do
  def policy_for(component, context)
end
```

**Why rejected:** Policies are simple key-value configuration, not polymorphic behavior. A protocol adds indirection without benefit — there's no case where different Step structs need different policy _resolution_ logic.

### Alternative 4: Wrapping Steps in Policy Decorators

```elixir
# Rejected: changes the graph topology
policy_step = Runic.with_policy(my_step, max_retries: 3)
```

**Why rejected:** This would create a wrapper node in the graph, changing the topology. It complicates graph traversal, edge resolution, and breaks the content-addressability guarantee.

### Chosen Approach: Workflow Base + Runtime Override + Rule-Based Matchers

Policies are stored on the `%Workflow{}` struct as a base configuration and can be overridden at runtime via options. They are resolved by a rule-based matcher list evaluated top-to-bottom, kept external to the graph, and applied by the execution driver. This is the simplest approach that maintains all of Runic's existing invariants. Serialization warnings for anonymous function callbacks (fallbacks, predicates) are provided during serialization; documentation recommends using MFA tuples or reconstruction functions for durable policies.

---

## Extended State Space — Comparison with Other Systems

This section surveys execution primitives from the broader serverless, durable execution, and workflow DAG ecosystem. Each primitive is assessed for Runic applicability.

### From Temporal / Durable Execution Engines

| Primitive | Temporal Concept | Runic Mapping | Status |
|-----------|-----------------|---------------|--------|
| **Activity retry** | Activity options `RetryPolicy` | `max_retries` + `backoff` | ✅ Core proposal |
| **Activity timeout** | `ScheduleToCloseTimeout` | `timeout_ms` | ✅ Core proposal |
| **Start-to-close timeout** | Time from dispatch to completion | `timeout_ms` (covers this) | ✅ Core proposal |
| **Schedule-to-start timeout** | Time in queue before picked up | `queue_timeout_ms` | 🔮 Future: relevant for Runner queue |
| **Heartbeat timeout** | Long-running activities must heartbeat | `heartbeat_interval_ms` | 🔮 Future: relevant for durable runners |
| **Workflow run timeout** | Entire workflow deadline | `deadline_ms` (workflow-level) | ✅ Core proposal |
| **Continue-as-new** | Reset workflow state, carry forward | `Workflow.purge_memory/1` + re-plan | Exists in Runic |
| **Signals** | External events injected into running workflow | `Workflow.plan(workflow, signal_fact)` | Exists in Runic |
| **Queries** | Read workflow state without mutation | `Workflow.raw_productions/1`, introspection APIs | Exists in Runic |
| **Child workflows** | Spawn sub-workflows from activities | Nested `Workflow` in a Step's work fn | Exists in Runic |
| **Saga / compensation** | Undo chain on failure | `on_failure: :compensate` + compensation_fn | 🔮 Future |
| **Versioning** | Run old workflow definitions for in-flight work | `from_log/1` rebuilds from events | Partially exists |

### From Serverless / FaaS Platforms (AWS Step Functions, Azure Durable Functions)

| Primitive | Platform Concept | Runic Mapping | Status |
|-----------|-----------------|---------------|--------|
| **Wait state** | Pause execution for duration or until timestamp | `delay_ms` policy option or `:wait` execution_mode | 🔮 Future |
| **Choice state** | Branch on conditions | `Condition` + `Rule` nodes | Exists in Runic |
| **Parallel state** | Fan-out/fan-in | `Map`/`Reduce` components | Exists in Runic |
| **Map state** | Dynamic parallelism over collection | `Map` component | Exists in Runic |
| **Error catch** | Catch specific error types, route to handler | `on_failure: {:catch, error_pattern, handler}` | 🔮 Future |
| **Result selector** | Transform output before passing downstream | Steps naturally do this | Exists in Runic |
| **Input/output path** | JSONPath filtering | Facts carry full values; steps select what they need | Exists in Runic |
| **Task token** | External system completes the step | `execution_mode: :external` + token-based completion | 🔮 Future |
| **Execution event history** | Full event log of execution | `Workflow.log/1` | Exists in Runic |
| **Express vs Standard** | Fast ephemeral vs durable execution | `execution_mode: :sync` vs `:durable` | ✅ Core proposal |

### From Job Queue Systems (Oban, Faktory, Sidekiq)

| Primitive | Queue Concept | Runic Mapping | Status |
|-----------|--------------|---------------|--------|
| **Priority queues** | Process high-priority jobs first | `priority: :high \| :normal \| :low` | ✅ Core proposal |
| **Rate limiting** | Max N jobs per time window | `rate_limit` policy option | 🔮 Future |
| **Unique jobs** | Deduplicate by key | `idempotency_key` fn | ✅ Core proposal |
| **Scheduled jobs** | Execute at future time | `scheduled_at` / `delay_ms` | 🔮 Future |
| **Job cancellation** | Cancel in-flight work | Runner API: `Runner.cancel_runnable/2` | 🔮 Future: Runner doc |
| **Dead letter queue** | Failed jobs after max retries | `on_failure: :dead_letter` | 🔮 Future |
| **Batch callbacks** | Notify when batch of jobs completes | Workflow naturally handles this via Joins | Exists in Runic |
| **Cron/periodic** | Recurring execution | Outside Runic scope (use Oban/Quantum) | N/A |

### From DAG Orchestrators (Airflow, Prefect, Dagster)

| Primitive | Orchestrator Concept | Runic Mapping | Status |
|-----------|---------------------|---------------|--------|
| **Task retries** | Per-task retry config | `max_retries` + `backoff` | ✅ Core proposal |
| **Trigger rules** | all_success, one_success, all_failed, etc. | Join wait-mode + Condition logic | Partially exists |
| **Pools / slots** | Limit concurrent tasks of a type | `concurrency_limit` per policy matcher | 🔮 Future |
| **SLA / deadline** | Alert or fail if task exceeds deadline | `deadline_ms` | ✅ Core proposal |
| **Sensor / trigger** | Wait for external condition | `execution_mode: :external` | 🔮 Future |
| **Task group** | Apply config to group of tasks | `{:type, Step}` or `{:name, ~r/group_/}` matcher | ✅ Core proposal |
| **Dynamic task mapping** | Generate tasks from runtime data | `Map` component | Exists in Runic |
| **Lineage / provenance** | Track data lineage through DAG | Fact ancestry + causal edges | Exists in Runic |
| **Materialization** | Persist intermediate results | Checkpointing + persistence adapter | 🔮 Future: Runner doc |

### Additional Policy Options to Consider

Beyond the core proposal, these options extend the policy surface for future phases:

```elixir
@type extended_policy :: %{
  # --- Queue & Scheduling ---
  optional(:queue_timeout_ms) => pos_integer(),          # max time waiting in dispatch queue
  optional(:concurrency_limit) => pos_integer(),          # max concurrent instances of this step
  optional(:rate_limit) => {pos_integer(), pos_integer()}, # {max_count, window_ms}
  optional(:delay_ms) => pos_integer(),                   # delay before first execution
  optional(:scheduled_at) => DateTime.t(),                # absolute scheduled time

  # --- Durability ---
  optional(:heartbeat_interval_ms) => pos_integer(),     # for long-running steps
  optional(:checkpoint_after) => boolean(),               # persist workflow state after this step
  optional(:execution_mode) => :sync | :async | :durable | :external,

  # --- Error Handling ---
  optional(:retryable_errors) => [module() | atom()],    # only retry these error types
  optional(:non_retryable_errors) => [module() | atom()], # never retry these
  optional(:on_failure) => :halt | :skip | :fallback | :compensate | :dead_letter,
  optional(:compensation_fn) => (Runnable.t(), term() -> term()),

  # --- Observability ---
  optional(:telemetry_prefix) => atom(),                  # custom telemetry event prefix
  optional(:log_level) => Logger.level(),                 # per-step log level for policy events
  optional(:metadata) => map()                            # arbitrary metadata for telemetry/logging
}
```

---

## Implementation Phases

### Phase 1: Core Policy Driver

**Modules:**
- `Runic.Workflow.SchedulerPolicy` — struct, validation, rule-based resolution, matcher evaluation
- `Runic.Workflow.PolicyDriver` — execute with retry, timeout, backoff

**Integration:**
- `%Workflow{}` struct gains `scheduler_policies` field (list of `{matcher, policy}` tuples, default `[]`)
- `Workflow.set_scheduler_policies/2` — replace the entire policy list
- `Workflow.add_scheduler_policy/3` — prepend a `{matcher, policy}` rule (higher priority)
- `Workflow.append_scheduler_policy/3` — append a `{matcher, policy}` rule (lower priority)
- `Workflow.react/2` and `react_until_satisfied/3` accept `:scheduler_policies` option for runtime override
- `execute_runnables_serial/2` and `execute_runnables_async/3` route through `PolicyDriver` when policies are present
- No changes to `Invokable` protocol or `Runnable` struct

**Tests:**
- Matcher evaluation (exact name, regex, type, type list, predicate, default)
- Policy resolution order (first match wins, runtime prepended over base)
- Retry with each backoff strategy
- Timeout enforcement
- Fallback return shapes (modified runnable, `{:retry_with, ...}`, `{:value, ...}`)
- `:skip` vs `:halt` on failure
- Workflow-stored policies + runtime override merge
- Integration with `react_until_satisfied`

### Phase 2: Durable Execution Events

**Modules:**
- `Runic.Workflow.RunnableDispatched` — dispatch event struct
- `Runic.Workflow.RunnableCompleted` — completion event struct
- `Runic.Workflow.RunnableFailed` — failure event struct

**Integration:**
- `PolicyDriver` emits events (returned alongside the runnable, or via a callback)
- `Workflow.log/1` includes runnable lifecycle events
- `Workflow.from_log/1` handles new event types
- `RunnableRef` for serializable dispatch references

### Phase 3: Advanced Primitives

- Circuit breaker integration (external state, `Agent`-based)
- Workflow-level deadline enforcement
- Checkpoint callbacks
- Observability integration (telemetry events for retry, timeout, fallback)

### Phase 4: Convenience APIs

- `SchedulerPolicy.llm_policy/1` — preset for LLM call patterns
- `SchedulerPolicy.io_policy/1` — preset for I/O-bound operations
- `SchedulerPolicy.fast_fail/0` — zero retries, short timeout
- Policy composition: `SchedulerPolicy.merge(base, overrides)`

---

## Full API Examples

### Basic: LLM Workflow with Policies on Workflow

```elixir
require Runic
alias Runic.Workflow

classify = Runic.step(&MyApp.LLM.classify/1, name: :classify)
narrate = Runic.step(&MyApp.LLM.narrate/1, name: :narrate)

workflow =
  Runic.workflow(steps: [{classify, [narrate]}])
  |> Workflow.set_scheduler_policies([
    # Specific overrides first
    {:classify, %{
      max_retries: 3,
      backoff: :exponential,
      base_delay_ms: 500,
      timeout_ms: 10_000,
      on_failure: :skip
    }},
    {:narrate, %{
      max_retries: 2,
      backoff: :exponential,
      base_delay_ms: 1_000,
      timeout_ms: 30_000,
      fallback: fn _runnable, _error ->
        {:retry_with, %{model: "gpt-4o-mini"}}
      end,
      on_failure: :halt
    }},
    # Catch-all
    {:default, %{max_retries: 1, timeout_ms: 15_000}}
  ])

# Runs with workflow-stored policies
workflow
|> Workflow.react_until_satisfied(input)
|> Workflow.raw_productions()

# Or override at runtime — e.g. tighter timeout in a test env
workflow
|> Workflow.react_until_satisfied(input,
  scheduler_policies: [{:default, %{timeout_ms: 2_000}}]
)
|> Workflow.raw_productions()
```

### Pattern-Based Policies

```elixir
workflow =
  build_complex_workflow()
  |> Workflow.set_scheduler_policies([
    # All LLM steps by naming convention
    {{:name, ~r/^llm_/}, %{
      max_retries: 3,
      backoff: :exponential,
      base_delay_ms: 1_000,
      timeout_ms: 30_000,
      execution_mode: :async
    }},

    # All Conditions — eager, no retries
    {{:type, Runic.Workflow.Condition}, %{
      max_retries: 0,
      timeout_ms: :infinity,
      execution_mode: :sync
    }},

    # All Steps that hit external APIs (custom predicate)
    {fn node -> Map.get(node, :name) in [:fetch_weather, :call_stripe, :query_db] end, %{
      max_retries: 2,
      backoff: :linear,
      timeout_ms: 10_000,
      on_failure: :skip
    }},

    # Everything else
    {:default, %{max_retries: 0, timeout_ms: :infinity}}
  ])
```

### Advanced: External Scheduler with Durability

```elixir
alias Runic.Workflow
alias Runic.Workflow.{PolicyDriver, SchedulerPolicy, RunnableRef}

# Phase 1: Prepare
{workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

# Persist dispatch intent for durability
refs = Enum.map(runnables, &RunnableRef.from_runnable/1)
MyApp.Repo.save_dispatched(workflow.name, refs)

# Phase 2: Execute with workflow policies
policies = workflow.scheduler_policies
executed = Task.async_stream(runnables, fn runnable ->
  policy = SchedulerPolicy.resolve(runnable, policies)
  PolicyDriver.execute(runnable, policy)
end, timeout: :infinity)

# Phase 3: Apply and persist
workflow = Enum.reduce(executed, workflow, fn {:ok, runnable}, wrk ->
  wrk = Workflow.apply_runnable(wrk, runnable)
  MyApp.Repo.save_checkpoint(wrk.name, Workflow.log(wrk))
  wrk
end)
```

### GenServer Integration (Agent Pattern)

```elixir
defmodule MyApp.Agent do
  use GenServer

  alias Runic.Workflow
  alias Runic.Workflow.{PolicyDriver, SchedulerPolicy, Runnable}

  def handle_cast({:process, input}, %{workflow: wf} = state) do
    wf = Workflow.plan(wf, input)
    {wf, runnables} = Workflow.prepare_for_dispatch(wf)

    # Dispatch each runnable as a supervised task with its resolved policy
    for runnable <- runnables do
      policy = SchedulerPolicy.resolve(runnable, wf.scheduler_policies)
      Task.Supervisor.async_nolink(MyApp.TaskSup, fn ->
        PolicyDriver.execute(runnable, policy)
      end)
    end

    {:noreply, %{state | workflow: wf}}
  end

  def handle_info({ref, %Runnable{} = executed}, state) do
    Process.demonitor(ref, [:flush])
    wf = Workflow.apply_runnable(state.workflow, executed)

    if Workflow.is_runnable?(wf) do
      # Continue — prepare and dispatch next generation
      handle_cast({:continue}, %{state | workflow: wf})
    else
      {:noreply, %{state | workflow: wf}}
    end
  end
end
```
