defmodule Runic.Workflow.Events.FactProduced do
  @moduledoc """
  Event emitted when a fact is produced during workflow execution.

  The `producer_label` indicates what kind of production edge should be drawn:
  `:produced`, `:state_produced`, `:state_initiated`, `:reduced`, `:fan_out`, `:joined`, or `:input`.

  At runtime, `value` is always present. For journal persistence, the Store adapter
  may extract values to a content-addressed fact store keyed by hash.
  """

  @type t :: %__MODULE__{
          hash: term(),
          value: term(),
          ancestry: {term(), term()} | nil,
          producer_label: atom(),
          weight: non_neg_integer()
        }

  defstruct [:hash, :value, :ancestry, :producer_label, :weight]
end
