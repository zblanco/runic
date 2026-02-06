defmodule Runic.Workflow.Condition do
  @moduledoc """
  Condition nodes are predicate checks that gate flow in a workflow.

  A Condition receives a fact and evaluates to true/false. If true, downstream
  nodes become runnable; if false, the fact is consumed without propagation.

  ## Meta Expression Support

  Conditions can reference workflow state through meta expressions like `state_of(:component)`.
  When a Condition has meta references, the `:meta_refs` field is populated during
  macro compilation, and `:meta_ref` edges are drawn during `Component.connect/3`.

  During the prepare phase, these edges are traversed to populate `meta_context` in
  the `CausalContext`, making the referenced state available during execution.
  """

  alias Runic.Workflow.Components

  @type meta_ref :: %{
          kind: atom(),
          target: atom() | integer() | {atom(), atom()},
          field_path: list(atom()),
          context_key: atom()
        }

  @type t :: %__MODULE__{
          hash: integer() | nil,
          work: function(),
          arity: non_neg_integer(),
          meta_refs: list(meta_ref())
        }

  defstruct [:hash, :work, :arity, meta_refs: []]

  require Logger

  def new(work) when is_function(work) do
    new(work, Function.info(work, :arity) |> elem(1))
  end

  def new(opts) do
    struct!(__MODULE__, opts)
  end

  def new(work, arity) when is_function(work) do
    %__MODULE__{
      work: work,
      hash: Components.work_hash(work),
      arity: arity
    }
  end

  def check(%__MODULE__{work: work, arity: arity}, %Runic.Workflow.Fact{} = fact) do
    try_to_run_work(work, fact.value, arity)
  end

  def check(%__MODULE__{work: work, arity: arity}, value) do
    try_to_run_work(work, value, arity)
  end

  def try_to_run_work(work, fact_value, arity) do
    try do
      run_work(work, fact_value, arity)
    rescue
      FunctionClauseError -> false
      BadArityError -> false
    catch
      true ->
        true

      any ->
        Logger.error(
          "something other than FunctionClauseError happened in Condition invoke/3 -> try_to_run_work/3: \n\n #{inspect(any)}"
        )

        false
    end
  end

  defp run_work(work, fact_value, 1) when is_list(fact_value) do
    apply(work, [fact_value])
  end

  defp run_work(work, fact_value, arity) when arity > 1 and is_list(fact_value) do
    Components.run(work, fact_value)
  end

  defp run_work(_work, _fact_value, arity) when arity > 1 do
    false
  end

  defp run_work(work, fact_value, _arity) do
    Components.run(work, fact_value)
  end

  @doc """
  Returns whether this condition has meta references that need to be resolved
  during the prepare phase.
  """
  @spec has_meta_refs?(t()) :: boolean()
  def has_meta_refs?(%__MODULE__{meta_refs: meta_refs}), do: meta_refs != []

  @doc """
  Checks a condition with meta context available.

  When a condition has meta references, its work function is arity 2,
  receiving `(input, meta_context)`.
  """
  @spec check_with_meta_context(t(), term(), map()) :: boolean()
  def check_with_meta_context(%__MODULE__{work: work, arity: 2} = _condition, value, meta_context)
      when is_map(meta_context) do
    try do
      work.(value, meta_context)
    rescue
      FunctionClauseError -> false
      BadArityError -> false
    catch
      _ -> false
    end
  end

  def check_with_meta_context(%__MODULE__{} = condition, value, _meta_context) do
    check(condition, value)
  end
end
