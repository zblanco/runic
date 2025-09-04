defmodule Runic.Workflow.Map do
  @moduledoc """
  Map operations contain a FanOut operator and LambdaStep operations to produce facts split from the input and process each.
  """
  defstruct [:hash, :name, :pipeline, :components, :source, :bindings, :inputs, :outputs]
end
