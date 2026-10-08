defmodule Runic.Workflow.Events.FactProduced do
  @moduledoc """
  Event emitted when a fact is produced during workflow execution.

  The `producer_label` indicates what kind of production edge should be drawn:
  `:produced`, `:state_produced`, `:state_initiated`, `:reduced`, `:fan_out`, `:joined`, or `:input`.

  At runtime, `value` is always present. For journal persistence, the Store adapter
  may extract values to a content-addressed fact store keyed by hash.
  """

  @type t :: %__MODULE__{
          hash: term(),
          content_digest: Runic.Identity.t() | nil,
          payload_digest: Runic.Identity.t() | nil,
          value: term(),
          ancestry: {term(), term()} | nil,
          causal_ancestry: Runic.Workflow.FactAncestry.t() | nil,
          producer_label: atom(),
          weight: non_neg_integer(),
          meta: map()
        }

  defstruct [
    :hash,
    :content_digest,
    :payload_digest,
    :value,
    :ancestry,
    :causal_ancestry,
    :producer_label,
    :weight,
    meta: %{}
  ]

  @doc "Builds a versioned identity-bearing event from a Fact."
  @spec new(Runic.Workflow.Fact.t(), keyword()) :: t()
  def new(%Runic.Workflow.Fact{} = fact, attrs) when is_list(attrs) do
    struct!(
      __MODULE__,
      [
        hash: fact.hash,
        content_digest: fact.content_digest,
        payload_digest: fact.payload_digest,
        value: fact.value,
        ancestry: fact.ancestry,
        causal_ancestry: fact.causal_ancestry,
        meta: fact.meta
      ] ++ attrs
    )
  end
end
