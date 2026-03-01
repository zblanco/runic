defmodule Runic.Workflow.Events.StateInitiated do
  @moduledoc """
  Event emitted when an accumulator initializes its state for the first time.

  Contains the initial fact's hash, value, and ancestry so that
  `apply_event/2` can log the init fact and draw a `:state_initiated` edge.
  """

  @type t :: %__MODULE__{
          accumulator_hash: term(),
          init_fact_hash: term(),
          init_value: term(),
          init_ancestry: {term(), term()} | nil,
          weight: non_neg_integer()
        }

  defstruct [:accumulator_hash, :init_fact_hash, :init_value, :init_ancestry, :weight]
end
