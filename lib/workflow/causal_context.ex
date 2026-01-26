defmodule Runic.Workflow.CausalContext do
  @moduledoc """
  Minimal immutable context for executing a runnable without the full workflow.

  Built during the prepare phase and consumed during execute phase.
  Contains only what's needed for the specific node type being invoked.

  ## Design Goals

  1. **Minimal footprint** - Only include data needed for execution
  2. **Immutable** - Safe to pass across process boundaries
  3. **Self-contained** - No workflow reference, all needed state captured
  4. **Content-addressed** - Uses causal ancestry rather than generation counters

  ## Node-Specific Context Fields

  Different node types populate different context fields:

  - **Step**: `fan_out_context` for mapped pipeline tracking
  - **Condition/Conjunction**: `satisfied_conditions` for gate logic
  - **StateReaction/Accumulator**: `last_known_state` for stateful operations
  - **Join**: `join_context` with satisfaction tracking
  - **FanOut**: `fan_out_context` with reduce tracking
  - **FanIn**: `fan_in_context` with readiness and sister values
  """

  alias Runic.Workflow.Fact

  @type t :: %__MODULE__{
          node_hash: integer() | nil,
          input_fact: Fact.t() | nil,
          ancestry_depth: non_neg_integer(),
          hooks: {list(), list()},
          last_known_state: term() | nil,
          is_state_initialized: boolean(),
          satisfied_conditions: MapSet.t() | nil,
          join_context: map() | nil,
          fan_out_context: map() | nil,
          fan_in_context: map() | nil,
          mergeable: boolean()
        }

  defstruct [
    :node_hash,
    :input_fact,
    ancestry_depth: 0,
    hooks: {[], []},
    last_known_state: nil,
    is_state_initialized: false,
    satisfied_conditions: nil,
    join_context: nil,
    fan_out_context: nil,
    fan_in_context: nil,
    mergeable: false
  ]

  @doc """
  Creates a new CausalContext with the given attributes.
  """
  @spec new(keyword()) :: t()
  def new(attrs \\ []) do
    struct!(__MODULE__, attrs)
  end

  @doc """
  Builds a basic context with node hash, input fact, and ancestry depth.
  """
  @spec basic(integer(), Fact.t(), non_neg_integer()) :: t()
  def basic(node_hash, input_fact, ancestry_depth) do
    %__MODULE__{
      node_hash: node_hash,
      input_fact: input_fact,
      ancestry_depth: ancestry_depth
    }
  end

  @doc """
  Adds hooks to the context.
  """
  @spec with_hooks(t(), {list(), list()}) :: t()
  def with_hooks(%__MODULE__{} = ctx, {before_hooks, after_hooks}) do
    %{ctx | hooks: {before_hooks, after_hooks}}
  end

  @doc """
  Adds state context for stateful nodes.
  """
  @spec with_state(t(), term(), boolean()) :: t()
  def with_state(%__MODULE__{} = ctx, last_known_state, is_initialized \\ true) do
    %{ctx | last_known_state: last_known_state, is_state_initialized: is_initialized}
  end

  @doc """
  Adds fan_out context for mapped pipeline tracking.
  """
  @spec with_fan_out_context(t(), map()) :: t()
  def with_fan_out_context(%__MODULE__{} = ctx, fan_out_context) do
    %{ctx | fan_out_context: fan_out_context}
  end

  @doc """
  Adds fan_in context for reduction coordination.
  """
  @spec with_fan_in_context(t(), map()) :: t()
  def with_fan_in_context(%__MODULE__{} = ctx, fan_in_context) do
    %{ctx | fan_in_context: fan_in_context}
  end

  @doc """
  Adds join context for join coordination.
  """
  @spec with_join_context(t(), map()) :: t()
  def with_join_context(%__MODULE__{} = ctx, join_context) do
    %{ctx | join_context: join_context}
  end

  @doc """
  Adds satisfied conditions for conjunction gates.
  """
  @spec with_satisfied_conditions(t(), MapSet.t()) :: t()
  def with_satisfied_conditions(%__MODULE__{} = ctx, satisfied_conditions) do
    %{ctx | satisfied_conditions: satisfied_conditions}
  end

  @doc """
  Returns the before hooks from the context.
  """
  @spec before_hooks(t()) :: list()
  def before_hooks(%__MODULE__{hooks: {before, _after}}), do: before

  @doc """
  Returns the after hooks from the context.
  """
  @spec after_hooks(t()) :: list()
  def after_hooks(%__MODULE__{hooks: {_before, after_hooks}}), do: after_hooks

  @doc """
  Sets the mergeable flag on the context.

  Components with `mergeable: true` have CRDT-like properties
  (commutative, idempotent, associative) and are safe for parallel
  merge without ordering guarantees.
  """
  @spec with_mergeable(t(), boolean()) :: t()
  def with_mergeable(%__MODULE__{} = ctx, mergeable) when is_boolean(mergeable) do
    %{ctx | mergeable: mergeable}
  end

  @doc """
  Returns whether this context's node is mergeable (parallel-safe).
  """
  @spec mergeable?(t()) :: boolean()
  def mergeable?(%__MODULE__{mergeable: mergeable}), do: mergeable
end
