defmodule Runic.Workflow.Events.ConditionSatisfied do
  @moduledoc """
  Event emitted when a condition (or conjunction) is satisfied by a fact.
  """

  @type t :: %__MODULE__{
          fact_hash: term(),
          condition_hash: term(),
          weight: non_neg_integer(),
          meta_parents: [Runic.Workflow.Fact.t()]
        }

  defstruct [:fact_hash, :condition_hash, :weight, meta_parents: []]
end
