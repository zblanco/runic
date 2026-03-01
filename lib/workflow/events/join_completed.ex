defmodule Runic.Workflow.Events.JoinCompleted do
  @moduledoc """
  Derived event emitted when a Join node has all required branches satisfied.

  Produced during `apply_runnable/2`'s coordination finalization step,
  NOT during `execute/2`. Contains the result fact (collected join values)
  which gets logged into the graph and connected with a `:produced` edge.

  During replay via `apply_event/2`, this event is folded directly without
  re-deriving — the completion check only runs during live execution.
  """

  @type t :: %__MODULE__{
          join_hash: term(),
          result_fact_hash: term(),
          result_value: term(),
          result_ancestry: {term(), term()} | nil,
          weight: non_neg_integer()
        }

  defstruct [:join_hash, :result_fact_hash, :result_value, :result_ancestry, :weight]
end
