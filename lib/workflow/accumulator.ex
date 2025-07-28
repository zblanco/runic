defmodule Runic.Workflow.Accumulator do
  defstruct [:reducer, :init, :hash, :reduce_hash, :name, :binds, :source, :inputs, :outputs]
end
