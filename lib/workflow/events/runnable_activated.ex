defmodule Runic.Workflow.Events.RunnableActivated do
  @moduledoc """
  Event emitted when a downstream node is activated by a produced fact.

  `activation_kind` is `:runnable` for execute-type nodes or `:matchable` for match-type nodes.
  """

  @type t :: %__MODULE__{
          fact_hash: term(),
          node_hash: term(),
          activation_kind: :runnable | :matchable
        }

  defstruct [:fact_hash, :node_hash, :activation_kind]
end
