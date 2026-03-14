defmodule Runic.Workflow.Events.FanInCompleted do
  @moduledoc """
  Event derived during `maybe_finalize_coordination/2` when a FanIn node
  determines that all expected fan-out items have been processed.

  This event is produced during the apply phase (not execute), similar to
  `JoinCompleted`. It logs the reduced result fact, draws the `:reduced`
  edge, marks completion in mapped state, and cleans up tracking keys.
  """

  @type t :: %__MODULE__{
          fan_in_hash: term(),
          source_fact_hash: term(),
          result_fact_hash: term(),
          result_value: term(),
          result_ancestry: {term(), term()} | nil,
          expected_key: {term(), term()},
          seen_key: {term(), term()},
          weight: non_neg_integer()
        }

  defstruct [
    :fan_in_hash,
    :source_fact_hash,
    :result_fact_hash,
    :result_value,
    :result_ancestry,
    :expected_key,
    :seen_key,
    :weight
  ]
end
