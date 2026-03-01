defmodule Runic.Workflow.FactResolver do
  @moduledoc """
  Runtime resolver that hydrates `FactRef` structs via a Store adapter.

  Maintains a process-local cache to avoid repeated store round-trips.
  The cache lives in the Worker process memory and is cleared on Worker stop.
  """

  alias Runic.Workflow.{Fact, FactRef}

  defstruct [:store, cache: %{}]

  @type t :: %__MODULE__{
          store: {module(), term()},
          cache: %{optional(term()) => term()}
        }

  @doc "Creates a new FactResolver backed by the given store tuple."
  @spec new({module(), term()}) :: t()
  def new(store), do: %__MODULE__{store: store, cache: %{}}

  @doc """
  Resolves a Fact or FactRef to a full Fact with its value.

  - Full `Fact` structs with a value are returned as-is (passthrough).
  - `FactRef` structs are resolved by checking the cache first, then
    falling back to the store's `load_fact/2`.

  Returns `{:ok, %Fact{}}` or `{:error, reason}`.
  """
  @spec resolve(Fact.t() | FactRef.t(), t()) :: {:ok, Fact.t()} | {:error, term()}
  def resolve(%Fact{value: v} = fact, _resolver) when not is_nil(v), do: {:ok, fact}

  def resolve(%FactRef{hash: h, ancestry: a}, %__MODULE__{} = resolver) do
    case Map.get(resolver.cache, h) do
      nil ->
        {mod, st} = resolver.store

        case mod.load_fact(h, st) do
          {:ok, value} -> {:ok, %Fact{hash: h, ancestry: a, value: value}}
          {:error, _} = err -> err
        end

      value ->
        {:ok, %Fact{hash: h, ancestry: a, value: value}}
    end
  end

  @doc "Like `resolve/2` but raises on error."
  @spec resolve!(Fact.t() | FactRef.t(), t()) :: Fact.t()
  def resolve!(fact_or_ref, resolver) do
    {:ok, fact} = resolve(fact_or_ref, resolver)
    fact
  end

  @doc """
  Batch-loads a list of fact hashes into the resolver's cache.

  Hashes already present in the cache are skipped. Returns an updated
  resolver with the newly loaded values in its cache.
  """
  @spec preload(t(), [term()]) :: t()
  def preload(%__MODULE__{} = resolver, fact_hashes) when is_list(fact_hashes) do
    {mod, st} = resolver.store

    loaded =
      Enum.reduce(fact_hashes, resolver.cache, fn hash, cache ->
        if Map.has_key?(cache, hash) do
          cache
        else
          case mod.load_fact(hash, st) do
            {:ok, value} -> Map.put(cache, hash, value)
            {:error, _} -> cache
          end
        end
      end)

    %{resolver | cache: loaded}
  end
end
