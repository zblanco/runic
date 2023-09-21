defmodule Runic.Workflow.Conjunction do
  alias Runic.Workflow.Components
  defstruct [:hash, :condition_hashes]

  def new(conditions) do
    condition_hashes = conditions |> MapSet.new(& &1.hash)

    %__MODULE__{
      hash: condition_hashes |> Components.fact_hash(),
      condition_hashes: condition_hashes
    }
  end
end
