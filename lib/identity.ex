defmodule Runic.Identity do
  @moduledoc """
  A versioned, domain-separated content identity.

  Identities contain the complete scheme and domain alongside the digest. Two
  equal digest byte strings in different domains are therefore different keys.
  Use `digest/2` for canonical identity documents and `derive/2` for identities
  derived from ordered causal coordinates.
  """

  alias Runic.Identity.{Canonical, Preimage}

  @enforce_keys [:scheme, :version, :domain, :digest]
  defstruct scheme: :sha256, version: 1, domain: nil, digest: nil

  @domains [
    :component_definition,
    :node_occurrence,
    :connection_definition,
    :workflow_artifact,
    :payload,
    :fact_content,
    :fact_occurrence,
    :execution,
    :input_command,
    :activation,
    :attempt,
    :transaction,
    :event,
    :event_data,
    :snapshot,
    :segment
  ]

  @typedoc "A registered identity domain."
  @type domain ::
          :component_definition
          | :node_occurrence
          | :connection_definition
          | :workflow_artifact
          | :payload
          | :fact_content
          | :fact_occurrence
          | :execution
          | :input_command
          | :activation
          | :attempt
          | :transaction
          | :event
          | :event_data
          | :snapshot
          | :segment

  @type t :: %__MODULE__{
          scheme: :sha256,
          version: 1,
          domain: domain(),
          digest: <<_::256>>
        }

  @doc "Returns the registered identity domains."
  @spec domains() :: [domain()]
  def domains, do: @domains

  @doc "Builds a SHA-256 identity from a canonical identity document."
  @spec digest(domain(), term()) :: t()
  def digest(domain, identity_document) do
    identity_document
    |> Canonical.encode!()
    |> then(&digest_bytes(domain, &1))
  end

  @doc "Derives an identity from an ordered collection of identities and scalars."
  @spec derive(domain(), term()) :: t()
  def derive(domain, coordinates), do: digest(domain, {:derive, coordinates})

  @doc "Builds an identity from a value's explicit portable projection."
  @spec project(domain(), term()) :: t()
  def project(domain, value) do
    digest(domain, Runic.Identity.Projectable.identity_document(value))
  end

  @doc "Builds an identity from bytes already encoded with the canonical codec."
  @spec digest_bytes(domain(), binary()) :: t()
  def digest_bytes(domain, canonical_bytes)
      when domain in @domains and is_binary(canonical_bytes) do
    %__MODULE__{
      scheme: :sha256,
      version: 1,
      domain: domain,
      digest: :crypto.hash(:sha256, Preimage.frame_v1(domain, canonical_bytes))
    }
  end

  def digest_bytes(domain, canonical_bytes) when is_binary(canonical_bytes) do
    raise ArgumentError, "unknown Runic identity domain: #{inspect(domain)}"
  end

  @doc "Returns the compact binary form used inside canonical identity documents."
  @spec to_binary(t()) :: binary()
  def to_binary(%__MODULE__{scheme: :sha256, version: version, domain: domain, digest: digest})
      when byte_size(digest) == 32 do
    domain_bytes = Atom.to_string(domain)

    <<1, version::unsigned-16, byte_size(domain_bytes)::unsigned-16, domain_bytes::binary,
      digest::binary>>
  end

  @doc "Verifies that an identity document reproduces the expected identity."
  @spec verify(t(), term()) :: :ok | {:error, Runic.Identity.IntegrityError.t()}
  def verify(%__MODULE__{} = expected, identity_document) do
    actual = digest(expected.domain, identity_document)

    if actual == expected do
      :ok
    else
      {:error, %Runic.Identity.IntegrityError{expected: expected, actual: actual}}
    end
  end

  @doc "Verifies an identity document, raising on mismatch."
  @spec verify!(t(), term()) :: :ok
  def verify!(%__MODULE__{} = expected, identity_document) do
    case verify(expected, identity_document) do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end

  @doc "Returns the full tagged text representation of an identity."
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{} = identity) do
    "runic:sha256:v#{identity.version}:#{identity.domain}:" <>
      Base.encode16(identity.digest, case: :lower)
  end

  @doc "Returns a bounded display string. It must not be used for lookup."
  @spec short_string(t(), pos_integer()) :: String.t()
  def short_string(%__MODULE__{} = identity, length \\ 20)
      when is_integer(length) and length > 0 do
    digest = identity.digest |> Base.encode16(case: :lower) |> binary_part(0, min(length, 64))
    "#{identity.domain}_#{digest}"
  end
end
