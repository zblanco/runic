defprotocol Runic.Component do
  @moduledoc """
  Protocol defining common behaviour of Runic components such as reflection, sub components or how the can be composed with others.
  """

  # def component_of(component, sub_component_name)

  # def connectables(component)

  def connect(component, to, workflow)

  # def remove(component, workflow)

  # def components(component)
end

defimpl Runic.Component, for: Runic.Workflow.Map do
  alias Runic.Workflow
  alias Runic.Workflow.Root

  def connect(
        %Runic.Workflow.Map{
          pipeline: pipeline_workflow,
          components: %{fan_out: fan_out} = components
        },
        to,
        workflow
      ) do
    wrk =
      workflow
      # only add top level fanout in cases with nested map expressions
      |> Workflow.add_step(to, fan_out)

    wrk =
      pipeline_workflow.graph
      |> Graph.edges()
      |> Enum.reduce(wrk, fn
        %{v1: %Root{}, v2: _fan_out}, wrk ->
          wrk

        %{v1: v1, v2: v2}, wrk ->
          Workflow.add_step(wrk, v1, v2)
      end)

    Enum.reduce(components, wrk, fn {name, component}, wrk ->
      Map.put(wrk, :components, Map.put(wrk.components, name, component))
    end)
  end

  # def remove(%Runic.Workflow.Map{pipeline: map_wrk} = map, workflow) do
  #   # for vertices in the map workflow, remove them but only if they're not also involved in separate components

  #   map_wrk.graph
  #   |> Graph.vertices()
  #   |> Enum.reduce(workflow, fn vertex, wrk ->
  #     case Graph.out_edges(wrk.graph, vertex) do

  #     end
  #   end)
  # end
end

defimpl Runic.Component, for: Runic.Workflow.Reduce do
  alias Runic.Workflow

  def connect(reduce, %Runic.Workflow.Map{components: components}, workflow) do
    wrk =
      workflow
      |> Workflow.add_step(components.leaf, reduce.fan_in)
      |> Workflow.draw_connection(components.fan_out, reduce.fan_in, :fan_in)

    path_to_fan_out =
      wrk.graph
      |> Graph.get_shortest_path(components.fan_out, reduce.fan_in)

    wrk
    |> Map.put(
      :mapped,
      Map.put(
        wrk.mapped,
        :mapped_paths,
        Enum.reduce(path_to_fan_out, wrk.mapped.mapped_paths, fn node, mapset ->
          MapSet.put(mapset, node.hash)
        end)
      )
    )
  end

  def connect(reduce, to, workflow) do
    Workflow.add_step(workflow, to, reduce.fan_in)
  end
end

defimpl Runic.Component, for: Runic.Workflow.Step do
  def connect(step, to, workflow) do
    Runic.Workflow.add_step(workflow, to, step)
  end
end

defimpl Runic.Component, for: Runic.Workflow.Rule do
  alias Runic.Workflow

  def connect(rule, _to, workflow) do
    Workflow.merge(workflow, rule.workflow)
  end
end
