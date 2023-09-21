defmodule Runic.Workflow.StateCondition do
  alias Runic.Workflow.Components
  defstruct [:hash, :work, :state_hash]

  def new(work, state_hash) do
    %__MODULE__{
      state_hash: state_hash,
      work: work,
      hash: Components.fact_hash({work, state_hash})
    }
  end
end
