defmodule Runic.Workflow.Rule do
  alias Runic.Workflow
  alias Runic.Closure

  defstruct name: nil,
            arity: nil,
            workflow: nil,
            closure: nil,
            condition_hash: nil,
            reaction_hash: nil,
            hash: nil,
            inputs: nil,
            outputs: nil,
            condition_refs: []

  @typedoc """
  A rule.

  The `condition_refs` field carries compile-time condition reference markers
  that need to be resolved at connect-time. Each entry is a `{ref_name, target_hash}`
  tuple where `target_hash` is the hash of the node (Conjunction or reaction Step)
  that the resolved condition should wire to.
  """
  @type t() :: %__MODULE__{
          name: String.t(),
          arity: arity(),
          workflow: Workflow.t(),
          hash: integer(),
          condition_hash: integer(),
          reaction_hash: integer(),
          closure: Closure.t() | nil,
          condition_refs: [{atom(), integer()}]
        }

  def new(opts \\ []) do
    __MODULE__
    |> struct!(opts)
    |> Map.put_new(:name, Uniq.UUID.uuid4())
  end

  @spec check(Runic.Workflow.Rule.t(), any) :: boolean
  @doc """
  Checks a rule's left hand side.
  """
  def check(%__MODULE__{} = rule, input) do
    rule
    |> Runic.transmute()
    |> Workflow.plan_eagerly(input)
    |> Workflow.is_runnable?()
  end

  @spec run(Runic.Workflow.Rule.t(), any) :: any
  @doc """
  Evaluates a rule, checking its left hand side, then evaluating the right.
  """
  def run(%__MODULE__{} = rule, input) do
    rule
    |> Runic.transmute()
    |> Workflow.plan_eagerly(input)
    |> Workflow.react()
    |> Workflow.raw_productions()
    |> List.first()
    |> case do
      nil -> {:error, :no_conditions_satisfied}
      result_otherwise -> result_otherwise
    end
  end
end
