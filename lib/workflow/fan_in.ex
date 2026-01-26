defmodule Runic.Workflow.FanIn do
  @moduledoc """
  FanIn steps are part of a reduce operator that combines multiple facts into a single fact
  by applying the reducer function to return the accumulator with the parent.

  ## Options

  - `:mergeable` - When `true`, indicates this fan-in's reducer has CRDT-like
    properties (commutative, idempotent, associative) and is safe for parallel merge
    without ordering guarantees. Defaults to `false`.
  """
  defstruct [:hash, :init, :reducer, :map, mergeable: false]
end
