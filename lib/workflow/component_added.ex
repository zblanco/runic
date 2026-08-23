defmodule Runic.Workflow.ComponentAdded do
  @moduledoc """
  Serializable construction event used to rebuild a workflow from its log.

  Executable components use `closure`; nested workflows use a versioned
  `workflow_definition` that retains their boundary ports and child build log.
  `input_ports` and `output_ports` retain contracts applied outside the source
  expression that originally constructed an executable component.
  The `source` and `bindings` fields remain as a compatibility path for older
  component events.
  """

  alias Runic.Closure

  @derive {Inspect, only: [:name, :closure]}

  @type t :: %__MODULE__{
          name: String.t() | atom(),
          closure: Closure.t() | nil,
          source: term() | nil,
          bindings: map(),
          to: term(),
          connections: list(Runic.Workflow.Connection.t()) | nil,
          input_ports: keyword() | nil,
          output_ports: keyword() | nil,
          workflow_definition: Runic.Workflow.Definition.t() | nil,
          hash: term()
        }

  defstruct [
    :name,
    :closure,
    # Deprecated fields (kept for backward compatibility)
    :source,
    :bindings,
    :to,
    :connections,
    :input_ports,
    :output_ports,
    :workflow_definition,
    :hash
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
