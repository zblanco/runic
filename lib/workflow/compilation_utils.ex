defmodule Runic.Workflow.CompilationUtils do
  @moduledoc """
  Macro utilities for compiling expressions into workflow graphs or components.
  """
  require Runic
  alias Runic.Workflow
  alias Runic.Workflow.Components
  alias Runic.Workflow.Join

  @doc """
  Used for testing and debugging purposes, this macro will compile a workflow graph
  from a pipeline expression and return the graph as a quoted expression.

  Expects a tree of lists which may contain a component or a tuple {component, list(components | tuples)}.

  ## Examples

    workflow_of_pipeline([
      {Runic.step(fn _ -> 1..4 end),
        [
          Runic.map([
            Runic.step(fn num -> num * 2 end),
            Runic.step(fn num -> num + 1 end),
            Runic.step(fn num -> num + 4 end)
          ])
        ]}
    ])
  """
  defmacro workflow_of_pipeline(expression, name \\ nil) do
    workflow = workflow_graph_of_pipeline_tree_expression(expression, name)

    quote generated: true do
      unquote(workflow)
    end
  end

  @doc """
  Accepts a tree of lists and two item tuples representing a pipeline expression
  and builds a workflow graph DAG from the expression - expanding components which may
  have further nested pipelines and registering any components as necessary.
  """
  def workflow_graph_of_pipeline_tree_expression(expression, name \\ nil)

  def workflow_graph_of_pipeline_tree_expression(expression, name) do
    workflow_graph_of_pipeline_tree_expression(
      quote generated: true do
        require Runic
        alias Runic.Workflow

        Runic.workflow(name: unquote(name))
      end,
      expression,
      name
    )
  end

  def workflow_graph_of_pipeline_tree_expression(
        wrk_acc,
        {:fn, _, _} = expression,
        _name
      ) do
    step =
      quote do
        Runic.step(unquote(expression))
      end

    quote do
      unquote(wrk_acc)
      |> Workflow.add_step(unquote(step))
    end
  end

  def workflow_graph_of_pipeline_tree_expression(
        wrk_acc,
        {:., _, [_, _, _component]} = expression,
        _name
      ) do
    quote do
      unquote(wrk_acc)
      |> Workflow.add(unquote(expression))
    end
  end

  def workflow_graph_of_pipeline_tree_expression(
        wrk_acc,
        {{:., _, [_, _component]}, _, _} = expression,
        _name
      ) do
    quote do
      unquote(wrk_acc)
      |> Workflow.add(unquote(expression))
    end
  end

  def workflow_graph_of_pipeline_tree_expression(
        wrk_acc,
        {_component, _, _} = expression,
        _name
      ) do
    quote do
      unquote(wrk_acc)
      |> Workflow.add(unquote(expression))
    end
  end

  # with n parents, add a join and add join to each parent
  # then add children to the join
  def workflow_graph_of_pipeline_tree_expression(
        wrk_acc,
        {[_ | _] = parents, children} = pipeline_expression,
        name
      ) do
    parent_steps_with_hashes =
      Enum.map(parents, fn step_ast ->
        {Components.fact_hash(step_ast), pipeline_step(step_ast)}
      end)

    parent_hashes = Enum.map(parent_steps_with_hashes, &elem(&1, 0))

    join_hash = Components.fact_hash(Enum.map(parent_steps_with_hashes, &elem(&1, 0)))

    join =
      quote do
        %Join{
          hash: unquote(join_hash),
          joins: unquote(parent_hashes)
        }
      end

    dependent_pipeline_workflow =
      workflow_graph_of_pipeline_tree_expression(
        children,
        to_string(name) <> "_#{Components.fact_hash(pipeline_expression)}"
      )

    wrk_acc =
      Enum.reduce(parent_steps_with_hashes, wrk_acc, fn {_, parent_step}, acc ->
        quote do
          unquote(acc)
          |> Workflow.add(unquote(parent_step), to: unquote(join))
        end
      end)

    quote do
      unquote(wrk_acc)
      |> Workflow.add(unquote(dependent_pipeline_workflow), to: unquote(join_hash))
    end
  end

  def workflow_graph_of_pipeline_tree_expression(
        wrk_acc,
        {parent_component, children} = pipeline_expression,
        name
      ) do
    dependent_workflow =
      workflow_graph_of_pipeline_tree_expression(
        children,
        to_string(name) <> "_#{Components.fact_hash(pipeline_expression)}"
      )

    quote do
      unquote(wrk_acc)
      |> Workflow.add(unquote(parent_component))
      |> Workflow.add(unquote(dependent_workflow), to: unquote(parent_component))
    end
  end

  def workflow_graph_of_pipeline_tree_expression(
        wrk_acc,
        [_ | _] = expression,
        name
      ) do
    # Traverse the expression tree and build the workflow graph
    # Handle nested components and composite components recursively
    Enum.reduce(expression, wrk_acc, fn item, acc ->
      dependent_workflow =
        workflow_graph_of_pipeline_tree_expression(
          item,
          to_string(name) <> "_#{Components.fact_hash(item)}"
        )

      quote do
        unquote(acc)
        |> Workflow.add(unquote(dependent_workflow))
      end
    end)
  end

  # defp split_map_children(children) when is_list(children) do
  #   Enum.split_with(children, fn
  #     {:map, _, _} -> true
  #     {:., _, [_, _, :map]} -> true
  #     {{:., _, [_, :map]}, _, _} -> true
  #     _otherwise -> false
  #   end)
  # end

  def pipeline_step({:&, _, _} = expression) do
    step_ast_hash = Components.fact_hash(expression)

    quote do
      Runic.step(work: unquote(expression), hash: unquote(step_ast_hash))
    end
  end

  def pipeline_step({:fn, _, _} = expression) do
    step_ast_hash = Components.fact_hash(expression)

    quote do
      Runic.step(work: unquote(expression), hash: unquote(step_ast_hash))
    end
  end

  def pipeline_step({{:., _, [_, :step]}, _, [expression | [rest]]}) do
    step_ast_hash = Components.fact_hash(expression)

    name = rest[:name]

    quote do
      Runic.step(work: unquote(expression), hash: unquote(step_ast_hash), name: unquote(name))
    end
  end

  def pipeline_step({{:., _, [_, :step]}, _, [expression]}) do
    step_ast_hash = Components.fact_hash(expression)

    quote do
      Runic.step(work: unquote(expression), hash: unquote(step_ast_hash))
    end
  end

  def pipeline_step({:step, _, [expression | [rest]]}) do
    step_ast_hash = Components.fact_hash(expression)

    name = rest[:name]

    quote do
      Runic.step(work: unquote(expression), hash: unquote(step_ast_hash), name: unquote(name))
    end
  end

  def pipeline_step({:step, _, [expression]}) do
    step_ast_hash = Components.fact_hash(expression)

    quote do
      Runic.step(work: unquote(expression), hash: unquote(step_ast_hash))
    end
  end
end
