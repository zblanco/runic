defmodule Runic.Workflow.Events.MapReduceTracked do
  @moduledoc """
  Event emitted when a step in a fan-out pipeline tracks its result
  for downstream fan-in coordination.
  """

  @type t :: %__MODULE__{
          source_fact_hash: term(),
          fan_out_hash: term(),
          fan_out_fact_hash: term(),
          step_hash: term(),
          result_fact_hash: term()
        }

  defstruct [:source_fact_hash, :fan_out_hash, :fan_out_fact_hash, :step_hash, :result_fact_hash]
end
