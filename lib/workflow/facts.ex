defmodule Runic.Workflow.Facts do
  @moduledoc """
  Unified accessors for `Fact` and `FactRef` structs.

  Avoids pattern-matching on struct types throughout the codebase when
  only the hash, ancestry, or "has a value?" predicate is needed.
  """

  alias Runic.Workflow.{Fact, FactRef}

  @doc "Returns the hash of a Fact or FactRef."
  @spec hash(Fact.t() | FactRef.t()) :: Fact.hash()
  def hash(%Fact{hash: h}), do: h
  def hash(%FactRef{hash: h}), do: h

  @doc "Returns the ancestry of a Fact or FactRef."
  @spec ancestry(Fact.t() | FactRef.t()) :: {Fact.hash(), Fact.hash()} | nil
  def ancestry(%Fact{ancestry: a}), do: a
  def ancestry(%FactRef{ancestry: a}), do: a

  @doc "Returns true if the struct carries a concrete value (only true for Facts with non-nil values)."
  @spec value?(Fact.t() | FactRef.t()) :: boolean()
  def value?(%Fact{value: v}) when not is_nil(v), do: true
  def value?(_), do: false

  @doc "Converts a Fact to a FactRef, discarding the value."
  @spec to_ref(Fact.t()) :: FactRef.t()
  def to_ref(%Fact{hash: h, ancestry: a}), do: %FactRef{hash: h, ancestry: a}
end
