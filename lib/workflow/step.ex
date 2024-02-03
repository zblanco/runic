defmodule Runic.Workflow.Step do
  alias Runic.Workflow.Step
  alias Runic.Workflow.Fact
  alias Runic.Workflow.Components

  defstruct [:name, :work, :hash]

  def new(params) do
    struct!(__MODULE__, params)
    |> maybe_hash_work()
    |> maybe_set_name()
  end

  defp maybe_set_name(%__MODULE__{name: nil, hash: hash, work: work} = step) do
    fun_name = work |> Function.info(:name) |> elem(1)
    %__MODULE__{step | name: "#{fun_name}-#{hash}"}
  end

  defp maybe_set_name(%__MODULE__{name: nil, hash: hash} = step),
    do: %__MODULE__{step | name: to_string(hash)}

  defp maybe_set_name(%__MODULE__{name: name} = step) when not is_nil(name), do: step

  defp maybe_hash_work(%Step{work: work, hash: nil} = step),
    do: Map.put(step, :hash, Components.work_hash(work))

  defp maybe_hash_work(%Step{work: _work, hash: _} = step), do: step

  def run(%__MODULE__{} = step, input) when not is_struct(input, Fact) do
    Components.run(step.work, input)
  end
end
