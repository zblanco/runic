defmodule Runic.Workflow.Rule do
  alias Runic.Workflow

  defstruct name: nil,
            arity: nil,
            workflow: nil,
            bindings: %{},
            source: nil,
            inputs: nil,
            outputs: nil

  @typedoc """
  A rule.
  """
  @type t() :: %__MODULE__{
          name: String.t(),
          arity: arity(),
          workflow: Workflow.t(),
          bindings: map(),
          source: tuple()
        }

  @typedoc """
  The left hand side of a clause correlating with the pattern or condition of a function.
  """
  @type lhs() :: any()

  @typedoc """
  The right hand side of a clause correlating with the block or reaction of a function.
  """
  @type rhs() :: any()

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
