defmodule Runic.Workflow.Condition do
  alias Runic.Workflow.Components
  defstruct [:hash, :work, :arity]
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
end
