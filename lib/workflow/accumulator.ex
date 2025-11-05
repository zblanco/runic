defmodule Runic.Workflow.Accumulator do
  defstruct [
    :reducer,
    :init,
    :hash,
    :reduce_hash,
    :name,
    :closure,
    :inputs,
    :outputs
  ]
end
