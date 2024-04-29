# defmodule Runic.Workflow.FanIn do
#   @moduledoc """
#   FanIn steps are part of a reduce operator that combines multiple facts into a single fact
#     by applying the reducer function to return the accumulator with the parent.
#   """
#   defstruct [:hash, :fan_ins, :reducer]
# end
