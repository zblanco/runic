defmodule Runic.Workflow.StateReaction do
  @moduledoc """
  A state reaction is a step that depends on and produces state.

  ## Options

  - `:mergeable` - When `true`, indicates this state reaction has CRDT-like
    properties (commutative, idempotent, associative) and is safe for parallel merge
    without ordering guarantees. Defaults to `false`.
  """

  defstruct [:hash, :state_hash, :work, :arity, :ast, mergeable: false]

  def new(opts) do
    struct!(__MODULE__, opts)
  end
end
