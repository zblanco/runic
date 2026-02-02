defmodule Runic.Workflow.Step do
  alias Runic.Workflow.Step
  alias Runic.Workflow.Fact
  alias Runic.Workflow.Components
  alias Runic.Closure

  @type t :: %__MODULE__{
          name: String.t() | atom(),
          work: function(),
          hash: String.t() | nil,
          work_hash: String.t() | nil,
          closure: Closure.t() | nil,
          inputs: term(),
          outputs: term()
        }

  defstruct [
    :name,
    :work,
    :hash,
    :work_hash,
    :closure,
    :inputs,
    :outputs
  ]

  def new(params) do
    params_map = if Keyword.keyword?(params), do: Map.new(params), else: params

    struct!(__MODULE__, params_map)
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

  @doc """
  Executes the work function of the Lambda step returning the raw unwrapped value.
  """
  def run(%__MODULE__{} = step, input) when not is_struct(input, Fact) do
    Components.run(step.work, input)
  end
end
