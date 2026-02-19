defmodule Runic.Workflow.SchedulerPolicy do
  @moduledoc """
  Defines per-node scheduling policies for workflow execution.

  A `SchedulerPolicy` controls retry behavior, timeouts, failure handling,
  execution mode, and other scheduling concerns for individual workflow nodes.

  Policies are resolved at runtime by matching against runnable nodes using
  a list of `{matcher, policy_map}` tuples. The first matching rule wins,
  and its policy map is merged over the default policy.

  ## Matcher Types

  - `atom()` — exact match on the node's name
  - `:default` — catch-all, always matches
  - `{:name, %Regex{}}` — regex match on the node's name
  - `{:type, module}` — match on the node's struct module
  - `{:type, [modules]}` — match on any of the listed struct modules
  - `fn/1` — custom predicate function receiving the node

  ## Backoff Strategies

  - `:none` — no delay between retries
  - `:linear` — `min(base_delay_ms * (attempt + 1), max_delay_ms)`
  - `:exponential` — `min(base_delay_ms * 2^attempt, max_delay_ms)`
  - `:jitter` — randomized exponential: `min(rand(base_delay_ms * 2^attempt), max_delay_ms)`

  ## Execution Modes

  - `:sync` — standard synchronous execution (default)
  - `:async` — asynchronous execution within the workflow's react cycle
  - `:durable` — enables event emission (`%RunnableDispatched{}`, `%RunnableCompleted{}`,
    `%RunnableFailed{}`) for crash recovery and audit trails. Used by `Runic.Runner.Worker`
    to persist runnable lifecycle events in the workflow log.

  ## Fallback Functions

  When all retries are exhausted and a `fallback` function is set, it receives
  `(runnable, error)` and must return one of:

  - `%Runnable{}` — a modified runnable to execute once (no further retries)
  - `{:retry_with, %{key: value}}` — overrides merged into `meta_context`, then executed once
  - `{:value, term}` — a synthetic value used as the step's output

  Any other return value causes the runnable to fail with `{:invalid_fallback_return, value}`.

  ## Example

      alias Runic.Workflow.SchedulerPolicy

      policies = [
        {:call_llm, %{max_retries: 3, backoff: :exponential, timeout_ms: 30_000}},
        {{:type, Runic.Workflow.Step}, %{max_retries: 1, backoff: :linear}},
        {:default, %{timeout_ms: 10_000}}
      ]

      policy = SchedulerPolicy.resolve(runnable, policies)
  """

  alias Runic.Workflow.Runnable

  @known_keys [
    :max_retries,
    :backoff,
    :base_delay_ms,
    :max_delay_ms,
    :timeout_ms,
    :on_failure,
    :fallback,
    :execution_mode,
    :priority,
    :idempotency_key,
    :deadline_ms,
    :circuit_breaker
  ]

  defstruct max_retries: 0,
            backoff: :none,
            base_delay_ms: 500,
            max_delay_ms: 30_000,
            timeout_ms: :infinity,
            on_failure: :halt,
            fallback: nil,
            execution_mode: :sync,
            priority: :normal,
            idempotency_key: nil,
            deadline_ms: nil,
            circuit_breaker: nil

  @type fallback_return ::
          Runnable.t()
          | {:retry_with, map()}
          | {:value, term()}

  @type fallback_fn :: (Runnable.t(), term() -> fallback_return()) | nil

  @type t :: %__MODULE__{
          max_retries: non_neg_integer(),
          backoff: :none | :linear | :exponential | :jitter,
          base_delay_ms: non_neg_integer(),
          max_delay_ms: non_neg_integer(),
          timeout_ms: non_neg_integer() | :infinity,
          on_failure: :halt | :skip,
          fallback: fallback_fn(),
          execution_mode: :sync | :async | :durable,
          priority: :low | :normal | :high | :critical,
          idempotency_key: term() | nil,
          deadline_ms: non_neg_integer() | nil,
          circuit_breaker: map() | nil
        }

  @doc """
  Creates a new `SchedulerPolicy` from a map or keyword list.

  Raises `ArgumentError` if any unknown keys are provided.
  """
  @spec new(map() | keyword()) :: t()
  def new(opts) when is_map(opts) do
    validate_keys!(Map.keys(opts))
    struct!(__MODULE__, opts)
  end

  def new(opts) when is_list(opts) do
    validate_keys!(Keyword.keys(opts))
    struct!(__MODULE__, opts)
  end

  @doc """
  Returns the default policy struct.
  """
  @spec default_policy() :: t()
  def default_policy, do: %__MODULE__{}

  @doc """
  Resolves a `SchedulerPolicy` for a given runnable by walking a list of
  `{matcher, policy_map}` tuples top-to-bottom. First match wins.

  The matched policy map is merged over the default policy. If no match is
  found or `policies` is `nil` or `[]`, returns the default policy.
  """
  @spec resolve(Runnable.t(), list() | nil) :: t()
  def resolve(%Runnable{}, nil), do: %__MODULE__{}
  def resolve(%Runnable{}, []), do: %__MODULE__{}

  def resolve(%Runnable{node: node}, policies) when is_list(policies) do
    case Enum.find(policies, fn {matcher, _policy_map} -> matches?(matcher, node) end) do
      {_matcher, policy_map} ->
        struct!(__MODULE__, Map.merge(Map.from_struct(%__MODULE__{}), policy_map))

      nil ->
        %__MODULE__{}
    end
  end

  @doc """
  Merges runtime override policies with workflow base policies.

  In `:merge` mode (default), runtime overrides are prepended to the workflow base.
  In `:replace` mode, only the runtime overrides are returned.

  When `runtime_overrides` is `nil` or `[]`, returns `workflow_base` unchanged.
  """
  @spec merge_policies(list() | nil, list()) :: list()
  def merge_policies(runtime_overrides, workflow_base) do
    merge_policies(runtime_overrides, workflow_base, :merge)
  end

  @spec merge_policies(list() | nil, list(), :merge | :replace) :: list()
  def merge_policies(nil, workflow_base, _mode), do: workflow_base
  def merge_policies([], workflow_base, _mode), do: workflow_base
  def merge_policies(overrides, _workflow_base, :replace), do: overrides
  def merge_policies(overrides, workflow_base, :merge), do: overrides ++ workflow_base

  # ---------------------------------------------------------------------------
  # Presets
  # ---------------------------------------------------------------------------

  @doc """
  Policy preset for LLM / external AI model calls.

  Defaults: 3 retries, exponential backoff (1s base, 30s max), 30s timeout, halt on failure.
  Override any default via `opts`.
  """
  @spec llm_policy(keyword()) :: t()
  def llm_policy(opts \\ []) do
    %__MODULE__{
      max_retries: Keyword.get(opts, :max_retries, 3),
      backoff: :exponential,
      base_delay_ms: 1_000,
      max_delay_ms: 30_000,
      timeout_ms: Keyword.get(opts, :timeout_ms, 30_000),
      on_failure: :halt
    }
  end

  @doc """
  Policy preset for I/O-bound operations (HTTP, database, file system).

  Defaults: 2 retries, linear backoff (500ms base), 10s timeout, skip on failure.
  Override any default via `opts`.
  """
  @spec io_policy(keyword()) :: t()
  def io_policy(opts \\ []) do
    %__MODULE__{
      max_retries: Keyword.get(opts, :max_retries, 2),
      backoff: :linear,
      base_delay_ms: 500,
      timeout_ms: Keyword.get(opts, :timeout_ms, 10_000),
      on_failure: :skip
    }
  end

  @doc """
  Policy preset for fast-fail scenarios: no retries, 5s timeout, halt on failure.
  """
  @spec fast_fail() :: t()
  def fast_fail do
    %__MODULE__{max_retries: 0, timeout_ms: 5_000, on_failure: :halt}
  end

  @doc """
  Merges two policy maps, with `overrides` taking precedence over `base`.
  """
  @spec merge(map(), map()) :: map()
  def merge(base, overrides) when is_map(base) and is_map(overrides) do
    Map.merge(base, overrides)
  end

  # ---------------------------------------------------------------------------
  # Matchers
  # ---------------------------------------------------------------------------

  defp matches?(matcher, node) when is_atom(matcher) and matcher != :default do
    case Map.get(node, :name) do
      nil -> false
      name -> normalize_name(name) == matcher
    end
  end

  defp matches?(:default, _node), do: true

  defp matches?({:name, %Regex{} = regex}, node) do
    case Map.get(node, :name) do
      nil -> false
      name -> Regex.match?(regex, to_string(name))
    end
  end

  defp matches?({:type, modules}, node) when is_list(modules) do
    node.__struct__ in modules
  end

  defp matches?({:type, module}, node) when is_atom(module) do
    node.__struct__ == module
  end

  defp matches?(matcher, node) when is_function(matcher, 1) do
    matcher.(node)
  end

  defp normalize_name(name) when is_atom(name), do: name
  defp normalize_name(nil), do: nil

  defp normalize_name(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> name
  end

  defp validate_keys!(keys) do
    unknown = keys -- @known_keys

    unless unknown == [] do
      raise ArgumentError,
            "unknown keys #{inspect(unknown)} in SchedulerPolicy. Known keys: #{inspect(@known_keys)}"
    end
  end
end
