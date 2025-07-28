defmodule Runic.Workflow.Map do
  @moduledoc """
  Map operations contain a FanOut operator and LambdaStep operations to produce facts split from the input and process each.
  """
  alias Runic.Workflow.FanOut
  defstruct [:hash, :name, :pipeline, :components, :source, :bindings, :inputs, :outputs]

  # def build_named_components(%__MODULE__{pipeline: pipeline} = map) do
  #   %__MODULE__{map | components: named_steps(pipeline, %{})}
  # end

  # def build_named_components(%__MODULE__{pipeline: pipeline} = map) do

  # end

  def build_named_components(%__MODULE__{pipeline: pipeline} = map) do
    %__MODULE__{
      map
      | components:
          pipeline.graph
          |> Graph.Reducers.Bfs.reduce(%{}, fn
            %FanOut{name: nil} = step, components ->
              if Runic.Workflow.root() in Graph.in_neighbors(pipeline.graph, step) do
                {:next, components |> Map.put(:fan_out, step)}
              else
                {:next, components}
              end

            %FanOut{name: name} = step, components ->
              if Runic.Workflow.root() in Graph.in_neighbors(pipeline.graph, step) do
                {:next, components |> Map.put(:fan_out, step) |> Map.put(name, step)}
              else
                {:next, components}
              end

            %{name: nil}, components ->
              {:next, components}

            %{name: name} = step, components ->
              {:next, components |> Map.put(name, step) |> maybe_add_leaf(step, pipeline.graph)}

            _otherwise, components ->
              {:next, components}
          end)
    }
  end

  defp maybe_add_leaf(components, step, pipeline) do
    if is_leaf?(pipeline, step) do
      Map.put(components, :leaf, step)
    else
      components
    end
  end

  defp is_leaf?(g, v), do: Graph.out_degree(g, v) == 0
end
