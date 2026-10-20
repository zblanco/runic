defmodule Runic.Workflow.RunnableDispatched do
  @moduledoc """
  Event recording that a runnable was dispatched for execution.

  In managed durable execution, this is an attempt-admission record. The Worker
  saves it and requires Store acknowledgement before it gives the attempt to an
  executor. Immediate execution emits it just before invocation.

  It includes the resolved policy, with non-serializable fields such as
  `fallback` removed, and the zero-based attempt number. `event_id` is stable
  for one activation and attempt. Version 1 events use this admission contract.

  `order_key` is the stable causal admission order. It is separate from the
  event's actual dispatch and completion order.
  """

  @type t :: %__MODULE__{
          version: pos_integer(),
          event_id: Runic.Identity.t() | nil,
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
    :attempt,
    version: 1,
    event_id: nil
  ]
end
