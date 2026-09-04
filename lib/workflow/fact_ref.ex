defmodule Runic.Workflow.FactRef do
  @moduledoc """
  A lightweight reference to a Fact without its value.

  Used during lean replay / hybrid rehydration to reconstruct graph
  topology without loading all fact values into memory.
  """

  @type t :: %__MODULE__{
          id: Runic.Identity.t() | nil,
          content_digest: Runic.Identity.t() | nil,
          payload_digest: Runic.Identity.t() | nil,
          hash: Runic.Workflow.Fact.hash(),
          ancestry: {Runic.Workflow.Fact.hash(), Runic.Workflow.Fact.hash()} | nil,
          causal_ancestry: Runic.Workflow.FactAncestry.t() | nil
        }

  defstruct [:id, :content_digest, :payload_digest, :hash, :ancestry, :causal_ancestry]
end
