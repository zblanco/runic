defmodule Runic.Workflow.RunnableDispatched do
  @moduledoc """
  Event recording that a runnable was dispatched for execution.

  Captures the dispatch moment including the resolved policy (with non-serializable
  fields like `fallback` stripped) and the attempt number.

  `order_key` is the stable causal admission order. It is separate from the
  event's actual dispatch and completion order.
  """

  @type t :: %__MODULE__{
          runnable_id: term(),
          activation_id: Runic.Identity.t() | nil,
          attempt_id: Runic.Identity.t() | nil,
          node_name: atom() | binary() | nil,
          node_hash: term(),
          order_key: term(),
          input_fact: Runic.Workflow.Fact.t(),
          dispatched_at: integer(),
          policy: Runic.Workflow.SchedulerPolicy.t(),
          attempt: non_neg_integer()
        }

  defstruct [
    :runnable_id,
    :activation_id,
    :attempt_id,
    :node_name,
    :node_hash,
    :order_key,
    :input_fact,
    :dispatched_at,
    :policy,
    :attempt
  ]
end
