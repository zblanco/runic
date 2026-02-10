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
  """

  defstruct [
    :reducer,
    :init,
    :hash,
    :reduce_hash,
    :name,
    :closure,
    :inputs,
    :outputs,
    mergeable: false
  ]
end
