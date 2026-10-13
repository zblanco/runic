defmodule Runic.Workflow.LocalFactError do
  @moduledoc "Raised or returned for an invalid native profile or a local export boundary."
  defexception [:field, :path, :reason]

  @type t :: %__MODULE__{field: term(), path: [term()], reason: atom()}

  @impl true
  def message(error) do
    action =
      if error.reason in [:local_fact, :local_identity, :local_scope],
        do: "cannot export local fact",
        else: "invalid local fact profile"

    "#{action} at #{inspect(error.path)}: #{error.reason}"
  end
end
