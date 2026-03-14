defmodule Runic.Workflow.Events.FanOutFactEmitted do
  @moduledoc """
  Event emitted when a FanOut node splits an enumerable input into individual facts.

  One event is produced per item in the enumerable. During `apply_event/2`, the emitted
  fact is logged, a `:fan_out` edge is drawn, and the `mapped` tracking state is updated
  for downstream FanIn coordination.
  """

  @type t :: %__MODULE__{
          fan_out_hash: term(),
          source_fact_hash: term(),
          emitted_fact_hash: term(),
          emitted_value: term(),
          emitted_ancestry: {term(), term()} | nil,
          weight: non_neg_integer()
        }

  defstruct [
    :fan_out_hash,
    :source_fact_hash,
    :emitted_fact_hash,
    :emitted_value,
    :emitted_ancestry,
    :weight
  ]
end
