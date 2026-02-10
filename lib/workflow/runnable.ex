defmodule Runic.Workflow.Runnable do
  @moduledoc """
  A prepared unit of work ready for execution.

  Contains everything needed to execute independently of the source workflow.
  After execute/2, contains result and apply_fn for reducing back into workflow.

  ## Three-Phase Execution Model

  1. **Prepare** - Extract minimal context from workflow, build a Runnable
  2. **Execute** - Run the node's work function in isolation (potentially parallel)
  3. **Apply** - Reduce the execution result back into the workflow's memory

  The Runnable struct is the carrier between these phases, holding:
  - The node to invoke
  - The input fact triggering invocation
  - Minimal causal context (no full workflow reference)
  - After execution: result, status, and apply_fn for reducing into workflow
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
          apply_fn: (Runic.Workflow.t() -> Runic.Workflow.t()) | nil,
          error: term() | nil
        }

  defstruct [
    :id,
    :node,
    :input_fact,
    :context,
    :status,
    :result,
    :apply_fn,
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
  Marks a runnable as completed with result and apply_fn.
  """
  @spec complete(t(), term(), (Runic.Workflow.t() -> Runic.Workflow.t())) :: t()
  def complete(%__MODULE__{} = runnable, result, apply_fn) do
    %{runnable | status: :completed, result: result, apply_fn: apply_fn}
  end

  @doc """
  Marks a runnable as failed with an error.
  """
  @spec fail(t(), term()) :: t()
  def fail(%__MODULE__{} = runnable, error) do
    %{runnable | status: :failed, error: error}
  end

  @doc """
  Marks a runnable as skipped with an apply_fn that handles the skip.
  """
  @spec skip(t(), (Runic.Workflow.t() -> Runic.Workflow.t())) :: t()
  def skip(%__MODULE__{} = runnable, apply_fn) do
    %{runnable | status: :skipped, apply_fn: apply_fn}
  end
end
