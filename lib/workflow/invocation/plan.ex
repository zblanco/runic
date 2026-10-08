defmodule Runic.Workflow.Invocation.Plan do
  @moduledoc false

  alias Runic.Workflow.CallContract

  @type t :: %__MODULE__{
          version: pos_integer(),
          contract: CallContract.t()
        }

  @enforce_keys [:contract]
  defstruct [:contract, version: 1]
end
