defmodule Runic.Workflow.Map do
  @moduledoc """
  Map steps are part of a map operator that expands enumerable facts into separate facts.

  Map just splits input facts - separate steps as defined in the map expression will do the processing.
  """
  alias Runic.Workflow.FanOut
  defstruct [:hash, :name, :pipeline, :components]

  # def build_named_components(%__MODULE__{pipeline: pipeline} = map) do
  #   %__MODULE__{map | components: named_steps(pipeline, %{})}
  # end

  def build_named_components(%__MODULE__{pipeline: pipeline} = map) do
    %__MODULE__{
      map
      | components:
          pipeline.graph
          |> Graph.Reducers.Bfs.reduce(%{}, fn
            %FanOut{name: nil} = step, components ->
              {:next, components |> Map.put(:fan_out, step)}

            %FanOut{name: name} = step, components ->
              {:next, components |> Map.put(:fan_out, step) |> Map.put(name, step)}

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
