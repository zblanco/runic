defmodule Runic.Workflow.Serializers.Cytoscape do
  @moduledoc """
  Serializes Runic Workflows to Cytoscape.js JSON element format.

  Output is a list of node and edge elements compatible with Cytoscape.js.

  ## Examples

      # Get Cytoscape elements
      elements = Runic.Workflow.Serializers.Cytoscape.serialize(workflow)

      # Use with Kino.Cytoscape in LiveBook
      Kino.Cytoscape.new(elements)

  ## Element Format

  Each element follows Cytoscape.js notation:

      %{
        data: %{
          id: "n123",
          name: "step_name",
          kind: "step",
          parent: "nParentHash",  # for compound nodes
          background_color: "#2d3748",
          shape: "rectangle"
        }
      }

  See: https://js.cytoscape.org/#notation/elements-json
  """

  alias Runic.Workflow
  alias Runic.Workflow.Serializer

  @behaviour Runic.Workflow.Serializer

  @default_opts [
    include_memory: false,
    include_facts: false,
    include_components: true
  ]

  @impl true
  def serialize(%Workflow{} = workflow, opts \\ []) do
    opts = Keyword.merge(@default_opts, opts)

    vertices = build_vertices(workflow, opts)
    edges = build_edges(workflow, opts)

    vertices ++ edges
  end

  defp build_vertices(%Workflow{graph: graph} = workflow, opts) do
    component_groups = Serializer.group_by_component(workflow)

    # Build parent mapping (child_id => parent_id)
    parent_map =
      component_groups
      |> Enum.flat_map(fn {parent, children} ->
        parent_id = Serializer.node_id(parent)
        Enum.map(children, fn child -> {Serializer.node_id(child), parent_id} end)
      end)
      |> Map.new()

    # Get all vertices
    vertices =
      graph
      |> Graph.vertices()
      |> maybe_filter_facts(opts)
      |> Enum.map(fn vertex ->
        build_vertex(vertex, parent_map)
      end)

    # Add component container nodes if requested
    if opts[:include_components] do
      component_nodes =
        component_groups
        |> Map.keys()
        |> Enum.map(&build_component_node/1)

      component_nodes ++ vertices
    else
      vertices
    end
  end

  defp maybe_filter_facts(vertices, opts) do
    if opts[:include_facts] do
      vertices
    else
      Enum.reject(vertices, &match?(%Workflow.Fact{}, &1))
    end
  end

  defp build_vertex(vertex, parent_map) do
    id = Serializer.node_id(vertex)
    label = Serializer.node_label(vertex)
    kind = Serializer.node_class(vertex)
    {shape, color} = node_cytoscape_style(vertex)

    data = %{
      id: id,
      name: label,
      kind: kind,
      background_color: color,
      shape: shape
    }

    data =
      case Map.get(parent_map, id) do
        nil -> data
        parent_id -> Map.put(data, :parent, parent_id)
      end

    data = add_hash_if_present(data, vertex)

    %{data: data}
  end

  defp build_component_node(component) do
    id = Serializer.node_id(component)
    label = Serializer.node_label(component)
    kind = Serializer.node_class(component)
    {_shape, color} = node_cytoscape_style(component)

    %{
      data: %{
        id: id,
        name: label,
        kind: kind,
        background_color: color,
        shape: "roundrectangle",
        is_component: true
      }
    }
  end

  defp add_hash_if_present(data, %{hash: hash}), do: Map.put(data, :hash, hash)
  defp add_hash_if_present(data, _), do: data

  defp build_edges(%Workflow{} = workflow, opts) do
    flow_edges = build_flow_edges(workflow)

    if opts[:include_memory] do
      causal_edges = build_causal_edges(workflow)
      flow_edges ++ causal_edges
    else
      flow_edges
    end
  end

  defp build_flow_edges(%Workflow{} = workflow) do
    workflow
    |> Serializer.flow_edges()
    |> Enum.reject(fn %{v1: v1, v2: v2} ->
      match?(%Workflow.Fact{}, v1) or match?(%Workflow.Fact{}, v2)
    end)
    |> Enum.uniq_by(fn %{v1: v1, v2: v2} ->
      {Serializer.node_id(v1), Serializer.node_id(v2)}
    end)
    |> Enum.map(fn %{v1: v1, v2: v2} ->
      source = Serializer.node_id(v1)
      target = Serializer.node_id(v2)

      %{
        data: %{
          id: "e_#{source}_#{target}",
          source: source,
          target: target,
          label: "flow",
          edge_type: "flow"
        }
      }
    end)
  end

  defp build_causal_edges(%Workflow{} = workflow) do
    workflow
    |> Serializer.causal_edges()
    |> Enum.map(fn %{v1: v1, v2: v2, label: label, weight: weight} ->
      source = Serializer.node_id(v1)
      target = Serializer.node_id(v2)

      %{
        data: %{
          id: "e_#{label}_#{source}_#{target}_#{weight}",
          source: source,
          target: target,
          label: to_string(label),
          edge_type: "causal",
          weight: weight
        }
      }
    end)
  end

  defp node_cytoscape_style(%Workflow.Root{}), do: {"ellipse", "#1a1a2e"}
  defp node_cytoscape_style(%Workflow.Step{}), do: {"rectangle", "#2d3748"}
  defp node_cytoscape_style(%Workflow.Condition{}), do: {"diamond", "#553c9a"}
  defp node_cytoscape_style(%Workflow.FanOut{}), do: {"rhomboid", "#2c5282"}
  defp node_cytoscape_style(%Workflow.FanIn{}), do: {"rhomboid", "#285e61"}
  defp node_cytoscape_style(%Workflow.Join{}), do: {"hexagon", "#744210"}
  defp node_cytoscape_style(%Workflow.Accumulator{}), do: {"barrel", "#22543d"}
  defp node_cytoscape_style(%Workflow.Rule{}), do: {"octagon", "#742a2a"}
  defp node_cytoscape_style(%Workflow.Map{}), do: {"round-rectangle", "#1a365d"}
  defp node_cytoscape_style(%Workflow.Reduce{}), do: {"round-rectangle", "#234e52"}
  defp node_cytoscape_style(%Workflow.StateMachine{}), do: {"barrel", "#44337a"}
  defp node_cytoscape_style(%Workflow.Conjunction{}), do: {"diamond", "#5a3e1b"}
  defp node_cytoscape_style(%Workflow.MemoryAssertion{}), do: {"tag", "#2d3748"}
  defp node_cytoscape_style(%Workflow.Fact{}), do: {"ellipse", "#1e3a5f"}
  defp node_cytoscape_style(_), do: {"rectangle", "#2d3748"}
end
