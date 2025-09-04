defmodule Runic.Workflow.CompilationUtils do
  @moduledoc """
  Macro utilities for compiling expressions into workflow graphs or components.
  """
  require Runic
  alias Runic.Workflow

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
      |> Workflow.add(unquote(step))
    end
  end

  def workflow_graph_of_pipeline_tree_expression(
        wrk_acc,
        {component, _, _} = expression,
        _name
      )
      when component in [:step, :map, :reduce, :state_machine, :rule] do
    quote do
      unquote(wrk_acc)
      |> Workflow.add(unquote(expression))
    end
  end

  def workflow_graph_of_pipeline_tree_expression(
        wrk_acc,
        {:., _, [_, _, component]} = expression,
        _name
      )
      when component in [:step, :map, :reduce, :state_machine, :rule] do
    quote do
      unquote(wrk_acc)
      |> Workflow.add(unquote(expression))
    end
  end

  def workflow_graph_of_pipeline_tree_expression(
        wrk_acc,
        {{:., _, [_, component]}, _, _} = expression,
        _name
      )
      when component in [:step, :map, :reduce, :state_machine, :rule] do
    quote do
      unquote(wrk_acc)
      |> Workflow.add(unquote(expression))
    end
  end

  def workflow_graph_of_pipeline_tree_expression(
        wrk_acc,
        {[_ | _] = parents, children} = _expression,
        name
      ) do
    # Handle multiple parent components with shared children
    Enum.reduce(parents, wrk_acc, fn parent_component, acc ->
      parent_acc = workflow_graph_of_pipeline_tree_expression(acc, parent_component, name)
      workflow_graph_of_pipeline_tree_expression(parent_acc, children, name)
    end)
  end

  def workflow_graph_of_pipeline_tree_expression(
        wrk_acc,
        {parent_component, children},
        name
      ) do
    # Handle single parent component with children
    # First add the parent component, then add children connected to it
    parent_acc = workflow_graph_of_pipeline_tree_expression(wrk_acc, parent_component, name)

    workflow_graph_of_pipeline_tree_expression(parent_acc, children, name)
  end

  def workflow_graph_of_pipeline_tree_expression(
        wrk_acc,
        [_ | _] = expression,
        name
      ) do
    # Traverse the expression tree and build the workflow graph
    # Handle nested components and composite components recursively
    Enum.reduce(expression, wrk_acc, fn item, acc ->
      workflow_graph_of_pipeline_tree_expression(acc, item, name)
    end)
  end
end
