defmodule Runic.Workflow.Fact do
  alias Runic.Identity
  alias Runic.Workflow.Components
  alias Runic.Workflow.FactAncestry

  defstruct [
    :id,
    :content_digest,
    :payload_digest,
    :hash,
    :value,
    :ancestry,
    :causal_ancestry,
    meta: %{}
  ]

  @type hash() :: Identity.t() | integer() | binary()

  @type t() :: %__MODULE__{
          id: Identity.t() | nil,
          content_digest: Identity.t() | nil,
          payload_digest: Identity.t() | nil,
          value: term(),
          hash: hash(),
          ancestry: {hash(), hash()} | nil,
          causal_ancestry: FactAncestry.t() | nil,
          meta: map()
        }

  def new(params) do
    struct!(__MODULE__, params)
    |> put_identities()
  end

  defp put_identities(%__MODULE__{} = fact) do
    causal_ancestry = fact.causal_ancestry || FactAncestry.from_legacy(fact.ancestry)

    payload_digest =
      fact.payload_digest ||
        Components.identity(:payload, %{
          codec: :runic_canonical,
          schema_version: 1,
          value: fact.value
        })

    content_digest =
      fact.content_digest ||
        Components.identity(:fact_content, %{
          producer_node_id: causal_ancestry.producer_node_id,
          parent_fact_id: causal_ancestry.parent_fact_id,
          output_port: causal_ancestry.output_port,
          output_index: causal_ancestry.output_index,
          payload_digest: payload_digest
        })

    {id, hash} = occurrence_identity(fact.hash, causal_ancestry, content_digest)

    %__MODULE__{
      fact
      | id: id,
        hash: hash,
        payload_digest: payload_digest,
        content_digest: content_digest,
        causal_ancestry: causal_ancestry
    }
  end

  defp occurrence_identity(nil, causal_ancestry, content_digest) do
    id =
      Components.identity(:fact_occurrence, %{
        activation_id: causal_ancestry.activation_id,
        output_port: causal_ancestry.output_port,
        output_index: causal_ancestry.output_index,
        content_digest: content_digest
      })

    {id, id}
  end

  defp occurrence_identity(%Identity{domain: :fact_occurrence} = id, _ancestry, _content),
    do: {id, id}

  defp occurrence_identity(legacy_hash, _ancestry, _content), do: {nil, legacy_hash}
end
