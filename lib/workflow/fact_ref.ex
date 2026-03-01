defmodule Runic.Workflow.FactRef do
  @moduledoc """
  A lightweight reference to a Fact without its value.

  Used during lean replay / hybrid rehydration to reconstruct graph
  topology without loading all fact values into memory.
  """

  @type t :: %__MODULE__{
          hash: Runic.Workflow.Fact.hash(),
          ancestry: {Runic.Workflow.Fact.hash(), Runic.Workflow.Fact.hash()} | nil
        }

  defstruct [:hash, :ancestry]
end
