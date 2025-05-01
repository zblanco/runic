defmodule Runic.Workflow.Reduce do
  @moduledoc """
  Component represention of a reduce operation to implement the component protocol
  for connecting a reduce to other components in a workflow.
  """

  defstruct [:name, :fan_in, :hash, :source, :bindings]
end
