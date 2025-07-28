defmodule Runic.Workflow.Components do
  # common functions across workflow components
  @doc false
  @max_phash 4_294_967_296

  def fact_hash(value), do: :erlang.phash2(value, @max_phash)

  def vertex_id_of(%{hash: hash}), do: hash
  def vertex_id_of(hash) when is_integer(hash), do: hash
  def vertex_id_of(anything_otherwise), do: fact_hash(anything_otherwise)

  def memory_vertex_id(%{hash: hash}), do: hash
  def memory_vertex_id(hash) when is_integer(hash), do: hash
  def memory_vertex_id(anything_otherwise), do: fact_hash(anything_otherwise)

  def work_hash({m, f}),
    do: work_hash({m, f, 1})

  def work_hash({m, f, a}),
    do: fact_hash(:erlang.term_to_binary(Function.capture(m, f, a)))

  def work_hash(work) when is_function(work),
    do: fact_hash(:erlang.term_to_binary(work))

  def arity_of({:fn, _, [{:->, _, [[{:when, _when_meta, lhs}] | _rhs]}]}) do
    Enum.count(lhs, fn
      {_, _, child_ast} when is_list(child_ast) -> false
      {_, _, _} -> true
    end)
  end

  def arity_of({:fn, _, [{:->, _, [lhs, _rhs]}]}), do: Enum.count(lhs)

  def arity_of(fun) when is_function(fun), do: Function.info(fun, :arity) |> elem(1)

  def arity_of([
        {:->, _meta, [[{:when, _when_meta, lhs_expression}] | _rhs]} | _
      ]) do
    lhs_expression
    |> Enum.reject(&(not match?({_arg_name, _meta, nil}, &1)))
    |> length()
  end

  def arity_of([{:->, _meta, [lhs | _rhs]} | _]), do: arity_of(lhs)

  def arity_of(args) when is_list(args), do: length(args)

  def arity_of(%{work: work}), do: arity_of(work)

  def arity_of(_term), do: 1

  def is_of_arity?(arity) do
    fn
      args when is_list(args) ->
        if(arity == 1, do: true, else: length(args) == arity)

      args ->
        arity_of(args) == arity
    end
  end

  def run({m, f}, fact_value) when is_list(fact_value), do: run({m, f}, fact_value, 1)

  def run(work, fact_value) when is_function(work), do: run(work, fact_value, arity_of(work))

  def run({m, f}, [] = fact_value, a) do
    work = Function.capture(m, f, a)
    run(work, fact_value, arity_of(work))
  end

  def run(work, _fact_value, 0) when is_function(work), do: apply(work, [])

  def run(work, fact_value, 1) when is_function(work) and is_list(fact_value),
    do: apply(work, [fact_value])

  def run(work, fact_value, _arity) when is_function(work) and is_list(fact_value),
    do: apply(work, fact_value)

  def run(work, fact_value, _arity) when is_function(work), do: apply(work, [fact_value])

  @doc """
  Validates enumerable protocol implementation of values as a NimbleOptions custom type.
  """
  def enumerable_type(values, _args) do
    case Enumerable.impl_for(values) do
      nil ->
        {:error, "#{inspect(values)} is not Enumerable"}

      _impl ->
        {:ok, values}
    end
  end

  def component_impls do
    case Runic.Component.__protocol__(:impls) do
      :not_consolidated -> []
      {:consolidated, impls} -> impls
    end
  end

  def invokable_impls do
    case Runic.Workflow.Invokable.__protocol__(:impls) do
      :not_consolidated -> []
      {:consolidated, impls} -> impls
    end
  end
end
