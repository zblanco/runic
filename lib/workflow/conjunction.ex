defmodule Runic.Workflow.Conjunction do
  @moduledoc """
  Logical AND gate that requires all referenced conditions to be satisfied.

  A Conjunction holds `condition_hashes` (a MapSet of resolved condition hashes)
  and optionally `condition_refs` (a list of named condition references that are
  resolved at connect-time when the rule is added to a workflow).
  """

  alias Runic.Workflow.Components

  defstruct [:hash, :condition_hashes, condition_refs: []]

  @doc """
  Creates a conjunction from a list of condition structs.

  This is the original constructor used by existing rule compilation.
  """
  def new(conditions) when is_list(conditions) do
    condition_hashes = conditions |> MapSet.new(& &1.hash)

    %__MODULE__{
      hash: condition_hashes |> Components.fact_hash(),
      condition_hashes: condition_hashes
    }
  end

  @doc """
  Creates a conjunction from inline condition hashes and named condition refs.

  The hash is computed from a sorted list of `{:hash, int} | {:ref, atom}` tuples,
  making it stable at compile-time even when refs are not yet resolved.

  At connect-time, `condition_hashes` is populated with resolved hashes.
  """
  def new(inline_hashes, condition_refs)
      when is_list(inline_hashes) and is_list(condition_refs) do
    condition_hashes = MapSet.new(inline_hashes)
    sorted_refs = Enum.sort(condition_refs)

    hash_basis =
      (Enum.sort(inline_hashes) |> Enum.map(&{:hash, &1})) ++
        Enum.map(sorted_refs, &{:ref, &1})

    %__MODULE__{
      hash: Components.fact_hash(hash_basis),
      condition_hashes: condition_hashes,
      condition_refs: sorted_refs
    }
  end
end
