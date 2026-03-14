defmodule Runic.Workflow.Accumulator do
  @moduledoc """
  Accumulator components aggregate values over time using a reducer function.

  ## Options

  - `:mergeable` - When `true`, indicates this accumulator's reducer has CRDT-like
    properties (commutative, idempotent, associative) and is safe for parallel merge
    without ordering guarantees. Defaults to `false`.

  ## Example

      # A counter is mergeable (addition is commutative and associative)
      accumulator(
        init: fn -> 0 end,
        reducer: fn value, acc -> acc + value end,
        mergeable: true
      )

      # A list accumulator is NOT mergeable (order matters)
      accumulator(
        init: fn -> [] end,
        reducer: fn value, acc -> [value | acc] end,
        mergeable: false
      )

  ## Runtime Context

  Accumulators can reference external runtime values via `context/1` in their
  reducer function. When detected, the reducer is rewritten to arity-3
  `(value, acc, meta_ctx)` and values are resolved from the workflow's `run_context`.

      Runic.accumulator(0, fn x, state -> state + x * context(:factor) end,
        name: :scaled
      )

  Use `context/2` to provide defaults:

      Runic.accumulator(0, fn x, state -> state + x * context(:factor, default: 1) end,
        name: :scaled
      )
  """

  @type t :: %__MODULE__{}

  defstruct [
    :reducer,
    :init,
    :hash,
    :reduce_hash,
    :name,
    :closure,
    :inputs,
    :outputs,
    mergeable: false,
    meta_refs: []
  ]

  @doc """
  Returns whether this accumulator has meta references (e.g., `context/1`)
  that need to be resolved during the prepare phase.
  """
  @spec has_meta_refs?(t()) :: boolean()
  def has_meta_refs?(%__MODULE__{meta_refs: meta_refs}), do: meta_refs != []
end
