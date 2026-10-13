defmodule Runic.Workflow.LocalFactError do
  @moduledoc "Raised or returned when a native local fact crosses an export boundary."
  defexception [:field, :path, :reason]

  @type t :: %__MODULE__{field: term(), path: [term()], reason: atom()}

  @impl true
  def message(error) do
    "cannot export local fact at #{inspect(error.path)}: #{error.reason}"
  end
end
