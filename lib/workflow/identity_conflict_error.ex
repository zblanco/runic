defmodule Runic.Workflow.IdentityConflictError do
  @moduledoc """
  Raised when distinct workflow vertices claim the same identity.

  Runic treats an identity match as an optimization only when the available
  identity evidence is equivalent. A conflict is raised before graph mutation
  so an existing vertex cannot be silently substituted for a new one.
  """

  defexception [:identity, :existing, :incoming, :context]

  @type t :: %__MODULE__{
          identity: term(),
          existing: map() | nil,
          incoming: map() | nil,
          context: atom() | nil
        }

  @impl Exception
  def message(%__MODULE__{} = error) do
    context = error.context || :vertex_insertion

    "workflow identity conflict at #{inspect(error.identity)} during #{context}"
  end
end
