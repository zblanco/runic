defmodule Runic.Workflow.StateReaction do
  defstruct [:hash, :state_hash, :work, :arity, :ast]

  def new(opts) do
    struct!(__MODULE__, opts)
  end
end
