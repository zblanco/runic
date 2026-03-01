defmodule Runic.Workflow.Runnable do
  @moduledoc """
  A prepared unit of work ready for execution.

  Contains everything needed to execute independently of the source workflow.
  After execute/2, contains result and events for reducing back into workflow.

  ## Three-Phase Execution Model

  1. **Prepare** - Extract minimal context from workflow, build a Runnable
  2. **Execute** - Run the node's work function in isolation (potentially parallel)
  3. **Apply** - Fold events back into the workflow via `apply_event/2`

  The Runnable struct is the carrier between these phases, holding:
  - The node to invoke
  - The input fact triggering invocation
  - Minimal causal context (no full workflow reference)
  - After execution: result, status, and events for reducing into workflow
  """

  alias Runic.Workflow.{Fact, CausalContext}

  @type status :: :pending | :completed | :failed | :skipped

  @type t :: %__MODULE__{
          id: integer() | nil,
          node: struct(),
          input_fact: Fact.t(),
          context: CausalContext.t() | nil,
          status: status(),
          result: term() | nil,
          events: [struct()] | nil,
          hook_apply_fns: [function()] | nil,
          error: term() | nil
        }

  defstruct [
    :id,
    :node,
    :input_fact,
    :context,
    :status,
    :result,
    :events,
    :hook_apply_fns,
    :error
  ]

  @doc """
  Creates a new Runnable in pending state.

  The id is a hash of {node.hash, fact.hash} for idempotency tracking.
  """
  @spec new(struct(), Fact.t(), CausalContext.t()) :: t()
  def new(node, fact, context) do
    %__MODULE__{
      id: :erlang.phash2({node.hash, fact.hash}),
      node: node,
      input_fact: fact,
      context: context,
      status: :pending
    }
  end

  @doc """
  Creates a new Runnable with explicit id.
  """
  @spec new(integer(), struct(), Fact.t(), CausalContext.t()) :: t()
  def new(id, node, fact, context) do
    %__MODULE__{
      id: id,
      node: node,
      input_fact: fact,
      context: context,
      status: :pending
    }
  end

  @doc """
  Generates a stable runnable id from node and fact hashes.
  """
  @spec runnable_id(struct(), Fact.t()) :: integer()
  def runnable_id(node, fact) do
    :erlang.phash2({node.hash, fact.hash})
  end

  @doc """
  Marks a runnable as completed with result and events.

  Events are the list of event structs produced by `Invokable.execute/2`.
  They will be folded into the workflow via `apply_event/2` during the apply phase.
  """
  @spec complete(t(), term(), [struct()]) :: t()
  def complete(%__MODULE__{} = runnable, result, events) when is_list(events) do
    %{runnable | status: :completed, result: result, events: events}
  end

  @doc """
  Marks a runnable as completed with events and hook apply_fns.
  """
  @spec complete(t(), term(), [struct()], [function()]) :: t()
  def complete(%__MODULE__{} = runnable, result, events, hook_apply_fns)
      when is_list(events) and is_list(hook_apply_fns) do
    %{
      runnable
      | status: :completed,
        result: result,
        events: events,
        hook_apply_fns: hook_apply_fns
    }
  end

  @doc """
  Marks a runnable as failed with an error.
  """
  @spec fail(t(), term()) :: t()
  def fail(%__MODULE__{} = runnable, error) do
    %{runnable | status: :failed, error: error}
  end

  @doc """
  Marks a runnable as skipped with events.

  The events (typically just `ActivationConsumed`) are folded during apply,
  and downstream nodes are marked as `:upstream_failed`.
  """
  @spec skip(t(), [struct()]) :: t()
  def skip(%__MODULE__{} = runnable, events) when is_list(events) do
    %{runnable | status: :skipped, events: events}
  end
end
