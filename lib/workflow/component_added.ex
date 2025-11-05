defmodule Runic.Workflow.ComponentAdded do
  # To be used as a serializable event log for rebuilding workflows from logs

  alias Runic.Closure

  @derive {Inspect, only: [:name, :closure]}

  # New format uses :closure field (fully serializable)
  # Old format uses :source + :bindings with __caller_context__ (deprecated)
  @type t :: %__MODULE__{
          name: String.t() | atom(),
          closure: Closure.t() | nil,
          source: term() | nil,
          bindings: map(),
          to: term()
        }

  defstruct [
    :name,
    :closure,
    # Deprecated fields (kept for backward compatibility)
    :source,
    :bindings,
    :to
  ]

  # defimpl JSON.Encoder, for: __MODULE__ do
  #   def encode(%Runic.Workflow.ComponentAdded{} = event, _encoder) do
  #     %{
  #       "source" => event.source |> :erlang.term_to_binary() |> Base.encode64(),
  #       "to" => event.to,
  #       "bindings" => event.bindings
  #     }
  #     |> JSON.encode!()
  #   end
  # end
end
