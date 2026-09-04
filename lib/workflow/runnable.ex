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
  - A compact, data-only invocation plan when the node has a call contract
  - After execution: result, status, and events for reducing into workflow
  """

  alias Runic.Identity
  alias Runic.Workflow.{CausalContext, Fact}
  alias Runic.Workflow.Invocation.Plan

  @type status :: :pending | :completed | :failed | :skipped

  @type t :: %__MODULE__{
          id: term() | nil,
          activation_id: Identity.t() | nil,
          attempt_id: Identity.t() | nil,
          attempt_number: non_neg_integer(),
          node: struct(),
          input_fact: Fact.t(),
          context: CausalContext.t() | nil,
          invocation: map() | nil,
          status: status(),
          result: term() | nil,
          events: [struct()] | nil,
          hook_apply_fns: [function()] | nil,
          error: term() | nil
        }

  defstruct [
    :id,
    :activation_id,
    :attempt_id,
    :attempt_number,
    :node,
    :input_fact,
    :context,
    :invocation,
    :status,
    :result,
    :events,
    :hook_apply_fns,
    :error
  ]

  @doc """
  Creates a new Runnable in pending state.

  The id is a domain-separated hash of the node and Fact identities for
  idempotency tracking.
  """
  @spec new(struct(), Fact.t(), CausalContext.t()) :: t()
  def new(node, fact, context) do
    activation_id = runnable_id(node, fact)

    %__MODULE__{
      id: activation_id,
      activation_id: activation_id,
      attempt_id: Identity.derive(:attempt, [activation_id, 0]),
      attempt_number: 0,
      node: node,
      input_fact: fact,
      context: context,
      status: :pending
    }
  end

  @doc """
  Creates a new Runnable with explicit id.
  """
  @spec new(term(), struct(), Fact.t(), CausalContext.t()) :: t()
  def new(id, node, fact, context) do
    %__MODULE__{
      id: id,
      activation_id: if(is_struct(id, Identity), do: id),
      attempt_id: if(is_struct(id, Identity), do: Identity.derive(:attempt, [id, 0])),
      attempt_number: 0,
      node: node,
      input_fact: fact,
      context: context,
      status: :pending
    }
  end

  @doc false
  @spec with_invocation(t(), Plan.t()) :: t()
  def with_invocation(%__MODULE__{} = runnable, %Plan{} = invocation) do
    %{runnable | invocation: invocation}
  end

  @doc """
  Generates a stable runnable id from node and fact hashes.
  """
  @spec runnable_id(struct(), Fact.t()) :: Identity.t()
  def runnable_id(node, fact) do
    Identity.derive(:activation, [:local, fact.hash, node.hash])
  end

  @doc false
  @spec for_attempt(t(), non_neg_integer()) :: t()
  def for_attempt(%__MODULE__{activation_id: %Identity{} = activation_id} = runnable, attempt) do
    %{
      runnable
      | attempt_number: attempt,
        attempt_id: Identity.derive(:attempt, [activation_id, attempt])
    }
  end

  def for_attempt(%__MODULE__{} = runnable, attempt), do: %{runnable | attempt_number: attempt}

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
