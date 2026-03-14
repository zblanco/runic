defmodule Runic.Workflow.ComponentRemoved do
  @moduledoc false
  # Serializable event representing the removal of a component from a workflow.

  @type t :: %__MODULE__{
          name: atom() | String.t(),
          hash: integer() | nil
        }

  defstruct [:name, :hash]
end
