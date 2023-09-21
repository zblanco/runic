defmodule Runic.Workflow.Condition do
  alias Runic.Workflow.Components
  defstruct [:hash, :work, :arity]

  def new(work) when is_function(work) do
    new(work, Function.info(work, :arity) |> elem(1))
  end

  def new(work, arity) when is_function(work) do
    %__MODULE__{
      work: work,
      hash: Components.work_hash(work),
      arity: arity
    }
  end
end
