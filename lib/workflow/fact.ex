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

  @doc """
  Constructs a Fact and its payload, content, and occurrence identities.

  Supply a `:fact_occurrence` Identity in `:id` to distinguish equal inputs.
  The compatibility `:hash` field mirrors that ID; supplying both fields with
  different identities raises. Legacy integer or binary hashes remain accepted
  when no `:id` is supplied.
  """
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

    {id, hash} = occurrence_identity(supplied_identity!(fact), causal_ancestry, content_digest)

    %__MODULE__{
      fact
      | id: id,
        hash: hash,
        payload_digest: payload_digest,
        content_digest: content_digest,
        causal_ancestry: causal_ancestry
    }
  end

  defp supplied_identity!(%__MODULE__{id: nil, hash: hash}), do: hash

  defp supplied_identity!(%__MODULE__{id: id, hash: hash}) when is_nil(hash) or hash == id do
    validate_occurrence_id!(id)
  end

  defp supplied_identity!(%__MODULE__{}) do
    raise ArgumentError, "Fact id and hash must identify the same occurrence"
  end

  defp validate_occurrence_id!(
         %Identity{
           scheme: :sha256,
           version: 1,
           domain: :fact_occurrence,
           digest: digest
         } = id
       )
       when is_binary(digest) and byte_size(digest) == 32,
       do: id

  defp validate_occurrence_id!(id) do
    raise ArgumentError, "expected a valid Fact occurrence identity, got: #{inspect(id)}"
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

  defp occurrence_identity(%Identity{} = id, _ancestry, _content) do
    id = validate_occurrence_id!(id)
    {id, id}
  end

  defp occurrence_identity(legacy_hash, _ancestry, _content), do: {nil, legacy_hash}
end
