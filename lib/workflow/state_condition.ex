defmodule Runic.Workflow.StateCondition do
  defstruct [:hash, :work, :state_hash]

  def new(work, state_hash, hash) do
    %__MODULE__{
      state_hash: state_hash,
      work: work,
      hash: hash
    }
  end
end
