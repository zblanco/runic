defmodule Runic.Workflow.StateReaction do
  alias Runic.Workflow.Components
  defstruct [:hash, :state_hash, :work, :arity, :ast]

  def new(work, state_hash, ast) do
    %__MODULE__{
      state_hash: state_hash,
      ast: ast,
      work: work,
      hash: Components.fact_hash({work, state_hash}),
      arity: Components.arity_of(work)
    }
  end
end
