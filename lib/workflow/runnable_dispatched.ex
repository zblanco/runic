defmodule Runic.Workflow.RunnableDispatched do
  @moduledoc """
  Event recording that a runnable was dispatched for execution.

  Captures the dispatch moment including the resolved policy (with non-serializable
  fields like `fallback` stripped) and the attempt number.
  """

  @type t :: %__MODULE__{
          runnable_id: term(),
          node_name: atom() | binary() | nil,
          node_hash: non_neg_integer(),
          input_fact: Runic.Workflow.Fact.t(),
          dispatched_at: integer(),
          policy: Runic.Workflow.SchedulerPolicy.t(),
          attempt: non_neg_integer()
        }

  defstruct [
    :runnable_id,
    :node_name,
    :node_hash,
    :input_fact,
    :dispatched_at,
    :policy,
    :attempt
  ]
end
