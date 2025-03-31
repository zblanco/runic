defmodule Runic.Workflow.ComponentAdded do
  @derive JSON.Encoder
  defstruct [:source, :to, :bindings]

  defimpl JSON.Encoder, for: __MODULE__ do
    def encode(%Runic.Workflow.ComponentAdded{} = event, _encoder) do
      %{
        "source" => event.source |> :erlang.term_to_binary() |> Base.encode64(),
        "to" => event.to,
        "bindings" => event.bindings
      }
      |> JSON.encode!()
    end
  end
end
