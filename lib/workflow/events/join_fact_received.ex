defmodule Runic.Workflow.Events.JoinFactReceived do
  @moduledoc """
  Event emitted when a fact arrives at a Join node from a parent branch.

  Drawing a `:joined` edge from the fact to the join node.
  The join may or may not complete after this event — completion is
  checked separately in `apply_runnable/2` via `maybe_finalize_coordination/2`.
  """

  @type t :: %__MODULE__{
          fact_hash: term(),
          join_hash: term(),
          parent_hash: term(),
          weight: non_neg_integer()
        }

  defstruct [:fact_hash, :join_hash, :parent_hash, :weight]
end
