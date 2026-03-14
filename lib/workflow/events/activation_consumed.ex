defmodule Runic.Workflow.Events.ActivationConsumed do
  @moduledoc """
  Event emitted when a node consumes its activation edge (marks it as :ran).

  `from_label` is the edge label being consumed: `:runnable` or `:matchable`.
  """

  @type t :: %__MODULE__{
          fact_hash: term(),
          node_hash: term(),
          from_label: :runnable | :matchable
        }

  defstruct [:fact_hash, :node_hash, :from_label]
end
