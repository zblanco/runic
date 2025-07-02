defmodule Runic.Workflow.Accumulator do
  defstruct [:reducer, :init, :hash, :name, :binds, :source, :inputs, :outputs]
end
