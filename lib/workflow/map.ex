defmodule Runic.Workflow.Map do
  @moduledoc """
  Map operations contain a FanOut operator and LambdaStep operations to produce facts split from the input and process each.

  ## Runtime Context

  Steps within a map pipeline support `context/1` expressions. Context values
  are resolved from the workflow's `run_context` using `_global` scope or
  the individual step's name.

      Runic.map(fn x -> x * context(:multiplier) end, name: :mult_map)
  """
  defstruct [
    :hash,
    :name,
    :pipeline,
    :components,
    :closure,
    :inputs,
    :outputs
  ]
end
