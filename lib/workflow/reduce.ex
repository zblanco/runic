defmodule Runic.Workflow.Reduce do
  @moduledoc """
  Component represention of a reduce operation to implement the component protocol
  for connecting a reduce to other components in a workflow.

  ## Runtime Context

  Reduce components support `context/1` in their reducer function. Context is
  resolved via the reduce component's name in the workflow's `run_context`.

      Runic.reduce(0, fn x, acc -> acc + x * context(:weight) end, name: :weighted_sum)
  """
  defstruct [
    :name,
    :fan_in,
    :hash,
    :closure,
    :inputs,
    :outputs
  ]
end
