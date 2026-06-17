defmodule Runic.Workflow.SchedulerPolicy.Layers do
  @moduledoc false

  defstruct workflow: [], runtime: []

  @type t :: %__MODULE__{
          workflow: list(),
          runtime: list()
        }
end
