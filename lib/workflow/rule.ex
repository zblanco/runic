defmodule Runic.Workflow.Rule do
  defstruct name: nil,
            arity: nil,
            workflow: nil,
            expression: nil

  def new(opts \\ []) do
    __MODULE__
    |> struct!(opts)
    |> Map.put_new(:name, Uniq.UUID.uuid4())
  end

  # def check(%__MODULE__{} = rule, fact) do

  # end
end
