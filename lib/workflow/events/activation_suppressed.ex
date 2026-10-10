defmodule Runic.Workflow.Events.ActivationSuppressed do
  @moduledoc """
  Event emitted when an upstream failure or skip suppresses a pending edge.

  Records a `:runnable` or `:joined` edge changing to `:upstream_failed`.
  Replay uses the recorded source label, so applying the event again is a no-op.
  """

  @type t :: %__MODULE__{
          fact_hash: term(),
          node_hash: term(),
          from_label: :runnable | :joined
        }

  defstruct [:fact_hash, :node_hash, :from_label]
end
