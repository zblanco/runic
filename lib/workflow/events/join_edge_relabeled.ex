defmodule Runic.Workflow.Events.JoinEdgeRelabeled do
  @moduledoc """
  Derived event emitted when a join edge is relabeled upon join completion.

  Captures the relabeling of `:joined` → `:join_satisfied` edges that occurs
  when a Join node completes. Produced during `apply_runnable/2`'s
  coordination finalization, alongside `JoinCompleted`.
  """

  @type t :: %__MODULE__{
          fact_hash: term(),
          join_hash: term(),
          from_label: atom(),
          to_label: atom()
        }

  defstruct [:fact_hash, :join_hash, :from_label, :to_label]
end
