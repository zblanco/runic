defmodule Runic.Workflow.Fact do
  alias Runic.Identity
  alias Runic.Workflow.Components
  alias Runic.Workflow.{FactAncestry, LocalScope}

  defstruct [
    :id,
    :content_digest,
    :payload_digest,
    :hash,
    :value,
    :ancestry,
    :causal_ancestry,
    identity_mode: :portable,
    local_scope: nil,
    meta: %{}
  ]

  @type hash() :: Identity.t() | integer() | binary()

  @type t() :: %__MODULE__{
          id: Identity.t() | nil,
          content_digest: Identity.t() | nil,
          payload_digest: Identity.t() | nil,
          identity_mode: :portable | :local,
          local_scope: LocalScope.t() | nil,
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

  Portable is the default and uses the strict canonical codec. Set
  `identity_mode: :local` to accept live terms directly. A new root receives a
  VM-bound scope and explicitly local identities. It cannot be persisted or
  remotely exported, even if its eventual output is a scalar.
  """
  def new(params) do
    struct!(__MODULE__, params)
    |> put_scope()
    |> put_identities()
  end

  @doc "Constructs a native local root without a value wrapper."
  def local(value, opts \\ []), do: new(Keyword.merge(opts, value: value, identity_mode: :local))

  @doc "Constructs a child and inherits its parents' identity mode and scope."
  def child(parents, params) do
    parents = parents |> List.wrap() |> Enum.reject(&is_nil/1)
    if parents == [], do: raise(ArgumentError, "a child fact requires at least one parent")
    locals = Enum.filter(parents, &(Map.get(&1, :identity_mode, :portable) == :local))
    scopes = locals |> Enum.map(& &1.local_scope) |> Enum.uniq()

    case check_parents(parents) do
      :ok -> :ok
      {:error, error} -> raise error
    end

    mode = if locals == [], do: :portable, else: :local
    scope = List.first(scopes)
    params = Map.new(params)

    if Map.get(params, :identity_mode, mode) != mode or
         Map.get(params, :local_scope, scope) != scope,
       do: raise(ArgumentError, "child facts cannot change their parents' identity mode or scope")

    new(Map.merge(params, %{identity_mode: mode, local_scope: scope}))
  end

  @doc false
  def check_parents(parents) do
    scopes =
      parents
      |> List.wrap()
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&(Map.get(&1, :identity_mode, :portable) == :local))
      |> Enum.map(& &1.local_scope)
      |> Enum.uniq()

    Enum.each(scopes, &LocalScope.validate!/1)

    if length(scopes) > 1,
      do: {:error, %ArgumentError{message: "cannot combine facts from different local scopes"}},
      else: :ok
  end

  @doc false
  def input(value, opts) do
    new(
      value: value,
      identity_mode: Keyword.get(opts, :identity_mode, :portable),
      local_scope: Keyword.get(opts, :local_scope)
    )
  end

  @doc false
  def initial(parent, producer, value) do
    ancestry =
      if Map.get(parent, :identity_mode, :portable) == :local,
        do: {producer, parent.hash},
        else: {producer, Components.fact_hash(value)}

    child(parent, value: value, ancestry: ancestry)
  end

  defp put_scope(%__MODULE__{identity_mode: :portable, local_scope: nil} = fact), do: fact

  defp put_scope(%__MODULE__{identity_mode: :local} = fact) do
    %{fact | local_scope: LocalScope.validate!(fact.local_scope || LocalScope.new())}
  end

  defp put_scope(_),
    do: raise(ArgumentError, "expected portable mode without a scope, or local mode")

  defp identity(%__MODULE__{identity_mode: :local}, domain, doc),
    do: Identity.local_digest(domain, doc)

  defp identity(_, domain, doc), do: Components.identity(domain, doc)

  defp put_identities(%__MODULE__{} = fact) do
    causal_ancestry = fact.causal_ancestry || FactAncestry.from_legacy(fact.ancestry)

    payload_digest = fact.payload_digest || payload_identity(fact)

    content_digest =
      fact.content_digest ||
        identity(fact, :fact_content, %{
          producer_node_id: causal_ancestry.producer_node_id,
          parent_fact_id: causal_ancestry.parent_fact_id,
          output_port: causal_ancestry.output_port,
          output_index: causal_ancestry.output_index,
          payload_digest: payload_digest
        })

    if fact.identity_mode == :local do
      validate_local_digest!(payload_digest, :payload)
      validate_local_digest!(content_digest, :fact_content)
    end

    {id, hash} =
      occurrence_identity(fact, supplied_identity!(fact), causal_ancestry, content_digest)

    %__MODULE__{
      fact
      | id: id,
        hash: hash,
        payload_digest: payload_digest,
        content_digest: content_digest,
        causal_ancestry: causal_ancestry
    }
  end

  defp payload_identity(%__MODULE__{identity_mode: :local} = fact) do
    Identity.local_digest(:payload, %{
      codec: :runic_local_etf,
      schema_version: 1,
      scope: fact.local_scope,
      value: fact.value
    })
  end

  defp payload_identity(fact) do
    Components.identity(:payload, %{codec: :runic_canonical, schema_version: 1, value: fact.value})
  end

  defp validate_local_digest!(
         %Identity{scheme: :local_sha256, version: 1, domain: domain, digest: digest},
         domain
       )
       when is_binary(digest) and byte_size(digest) == 32, do: :ok

  defp validate_local_digest!(_, domain),
    do: raise(ArgumentError, "local facts require a local #{domain} identity")

  defp supplied_identity!(%__MODULE__{id: nil, hash: hash}), do: hash

  defp supplied_identity!(%__MODULE__{id: id, hash: hash} = fact)
       when is_nil(hash) or hash == id do
    validate_occurrence_id!(id, fact.identity_mode)
  end

  defp supplied_identity!(%__MODULE__{}) do
    raise ArgumentError, "Fact id and hash must identify the same occurrence"
  end

  defp validate_occurrence_id!(
         %Identity{
           scheme: scheme,
           version: 1,
           domain: :fact_occurrence,
           digest: digest
         } = id,
         mode
       )
       when is_binary(digest) and byte_size(digest) == 32 and
              ((mode == :portable and scheme == :sha256) or
                 (mode == :local and scheme == :local_sha256)),
       do: id

  defp validate_occurrence_id!(id, _mode) do
    raise ArgumentError, "expected a valid Fact occurrence identity, got: #{inspect(id)}"
  end

  defp occurrence_identity(fact, nil, causal_ancestry, content_digest) do
    id =
      identity(fact, :fact_occurrence, %{
        activation_id: causal_ancestry.activation_id,
        output_port: causal_ancestry.output_port,
        output_index: causal_ancestry.output_index,
        content_digest: content_digest
      })

    {id, id}
  end

  defp occurrence_identity(fact, %Identity{} = id, _ancestry, _content) do
    id = validate_occurrence_id!(id, fact.identity_mode)
    {id, id}
  end

  defp occurrence_identity(%{identity_mode: :portable}, legacy_hash, _ancestry, _content),
    do: {nil, legacy_hash}

  defp occurrence_identity(_, _, _, _),
    do: raise(ArgumentError, "local facts require a local occurrence identity")
end
