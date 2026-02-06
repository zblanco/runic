defmodule Runic.Workflow.Step do
  @moduledoc """
  Step nodes transform input facts into output facts.

  A Step receives a fact, applies its work function, and produces a new fact
  with the result. Steps are the primary computation nodes in a workflow.

  ## Meta Expression Support

  Steps can reference workflow state through meta expressions like `state_of(:component)`.
  When a Step has meta references, the `:meta_refs` field is populated during
  macro compilation, and `:meta_ref` edges are drawn during `Component.connect/3`.

  During the prepare phase, these edges are traversed to populate `meta_context` in
  the `CausalContext`, making the referenced state available during execution.
  """

  alias Runic.Workflow.Step
  alias Runic.Workflow.Fact
  alias Runic.Workflow.Components
  alias Runic.Closure

  @type meta_ref :: %{
          kind: atom(),
          target: atom() | integer() | {atom(), atom()},
          field_path: list(atom()),
          context_key: atom()
        }

  @type t :: %__MODULE__{
          name: String.t() | atom(),
          work: function(),
          hash: String.t() | nil,
          work_hash: String.t() | nil,
          closure: Closure.t() | nil,
          inputs: term(),
          outputs: term(),
          meta_refs: list(meta_ref())
        }

  defstruct [
    :name,
    :work,
    :hash,
    :work_hash,
    :closure,
    :inputs,
    :outputs,
    meta_refs: []
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

  @doc """
  Returns whether this step has meta references that need to be resolved
  during the prepare phase.
  """
  @spec has_meta_refs?(t()) :: boolean()
  def has_meta_refs?(%__MODULE__{meta_refs: meta_refs}), do: meta_refs != []

  @doc """
  Runs the step work function with meta context available.

  When a step has meta references, its work function is arity 2,
  receiving `(input, meta_context)`.
  """
  @spec run_with_meta_context(t(), term(), map()) :: term()
  def run_with_meta_context(%__MODULE__{work: work}, input, meta_context)
      when is_map(meta_context) do
    arity = Function.info(work, :arity) |> elem(1)

    case arity do
      2 -> work.(input, meta_context)
      1 -> work.(input)
      0 -> work.()
    end
  end
end
