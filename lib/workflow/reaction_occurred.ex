defmodule Runic.Workflow.ReactionOccurred do
  @derive JSON.Encoder
  defstruct [:from, :to, :reaction, :properties, :weight]
end
