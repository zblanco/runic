defmodule Runic.Workflow.Serializers.DOT do
  @moduledoc """
  Serializes Runic Workflows to DOT (Graphviz) format.

  ## Examples

      # Generate DOT graph
      dot = Runic.Workflow.Serializers.DOT.serialize(workflow)

      # Write to file and render
      File.write!("workflow.dot", dot)
      System.cmd("dot", ["-Tpng", "workflow.dot", "-o", "workflow.png"])
  """

  alias Runic.Workflow
  alias Runic.Workflow.Serializer

  @behaviour Runic.Workflow.Serializer

  @default_opts [
    direction: :TB,
    include_memory: false,
    include_facts: false,
    title: nil
  ]

  @impl true
  def serialize(%Workflow{} = workflow, opts \\ []) do
    opts = Keyword.merge(@default_opts, opts)
    rankdir = direction_to_rankdir(opts[:direction])

    name = workflow.name || "Workflow"
    name = escape_dot(name)

    lines = [
      "digraph \"#{name}\" {",
      "    rankdir=#{rankdir};",
      "    node [fontname=\"Arial\", fontsize=10];",
      "    edge [fontname=\"Arial\", fontsize=9];",
      ""
    ]

    # Add node style definitions
    lines = lines ++ node_style_defs()

    # Get component groupings
    component_groups = Serializer.group_by_component(workflow)

    # Add subgraphs for components
    lines = add_subgraphs(lines, workflow, component_groups)

    # Add standalone nodes
    lines = add_standalone_nodes(lines, workflow, component_groups)

    # Add edges
    lines = add_edges(lines, workflow, opts)

    lines = lines ++ ["}"]

    Enum.join(lines, "\n")
  end

  defp direction_to_rankdir(:TB), do: "TB"
  defp direction_to_rankdir(:LR), do: "LR"
  defp direction_to_rankdir(:BT), do: "BT"
  defp direction_to_rankdir(:RL), do: "RL"
  defp direction_to_rankdir(_), do: "TB"

  defp node_style_defs do
    [
      "    // Node styles",
      "    node [shape=box, style=\"rounded,filled\"];",
      ""
    ]
  end

  defp add_subgraphs(lines, _workflow, component_groups) do
    {lines, _idx} =
      Enum.reduce(component_groups, {lines, 0}, fn {component, children}, {acc, idx} ->
        component_label =
          component
          |> Serializer.node_label()
          |> escape_dot()

        invokable_children =
          children
          |> Enum.reject(&match?(%Workflow.Fact{}, &1))
          |> Enum.uniq_by(&Serializer.node_id/1)

        if Enum.empty?(invokable_children) do
          {acc, idx}
        else
          subgraph_lines = [
            "",
            "    subgraph cluster_#{idx} {",
            "        label=\"#{component_label}\";",
            "        style=filled;",
            "        fillcolor=\"#1a202c\";",
            "        fontcolor=white;",
            ""
          ]

          child_lines = Enum.map(invokable_children, &render_node(&1, 2))

          subgraph_lines = subgraph_lines ++ child_lines ++ ["    }"]
          {acc ++ subgraph_lines, idx + 1}
        end
      end)

    lines
  end

  defp add_standalone_nodes(lines, %Workflow{graph: graph}, component_groups) do
    grouped_hashes =
      component_groups
      |> Map.values()
      |> List.flatten()
      |> MapSet.new(&Serializer.node_id/1)

    standalone =
      graph
      |> Graph.vertices()
      |> Enum.reject(&match?(%Workflow.Fact{}, &1))
      |> Enum.reject(fn v -> MapSet.member?(grouped_hashes, Serializer.node_id(v)) end)
      |> Enum.reject(fn v -> Map.has_key?(component_groups, v) end)

    if Enum.empty?(standalone) do
      lines
    else
      lines ++ [""] ++ Enum.map(standalone, &render_node(&1, 1))
    end
  end

  defp add_edges(lines, %Workflow{} = workflow, opts) do
    flow_edges = Serializer.flow_edges(workflow)

    flow_lines =
      flow_edges
      |> Enum.reject(fn %{v1: v1, v2: v2} ->
        match?(%Workflow.Fact{}, v1) or match?(%Workflow.Fact{}, v2)
      end)
      |> Enum.uniq_by(fn %{v1: v1, v2: v2} ->
        {Serializer.node_id(v1), Serializer.node_id(v2)}
      end)
      |> Enum.map(fn %{v1: v1, v2: v2} ->
        from_id = Serializer.node_id(v1)
        to_id = Serializer.node_id(v2)
        "    #{from_id} -> #{to_id};"
      end)

    lines = lines ++ ["", "    // Flow edges"] ++ flow_lines

    if opts[:include_memory] do
      causal_edges = Serializer.causal_edges(workflow)

      causal_lines =
        Enum.map(causal_edges, fn %{v1: v1, v2: v2, label: label} ->
          from_id = Serializer.node_id(v1)
          to_id = Serializer.node_id(v2)
          "    #{from_id} -> #{to_id} [label=\"#{label}\", style=dashed, color=gray];"
        end)

      lines ++ ["", "    // Causal edges"] ++ causal_lines
    else
      lines
    end
  end

  defp render_node(node, indent_level) do
    id = Serializer.node_id(node)
    label = Serializer.node_label(node) |> escape_dot()
    {shape, fill, font} = node_style(node)
    indent = String.duplicate("    ", indent_level)

    "#{indent}#{id} [label=\"#{label}\", shape=#{shape}, fillcolor=\"#{fill}\", fontcolor=\"#{font}\"];"
  end

  defp node_style(%Workflow.Root{}), do: {"circle", "#1a1a2e", "white"}
  defp node_style(%Workflow.Step{}), do: {"box", "#2d3748", "white"}
  defp node_style(%Workflow.Condition{}), do: {"diamond", "#553c9a", "white"}
  defp node_style(%Workflow.FanOut{}), do: {"parallelogram", "#2c5282", "white"}
  defp node_style(%Workflow.FanIn{}), do: {"parallelogram", "#285e61", "white"}
  defp node_style(%Workflow.Join{}), do: {"hexagon", "#744210", "white"}
  defp node_style(%Workflow.Accumulator{}), do: {"cylinder", "#22543d", "white"}
  defp node_style(%Workflow.Rule{}), do: {"doubleoctagon", "#742a2a", "white"}
  defp node_style(%Workflow.Map{}), do: {"component", "#1a365d", "white"}
  defp node_style(%Workflow.Reduce{}), do: {"component", "#234e52", "white"}
  defp node_style(%Workflow.StateMachine{}), do: {"cylinder", "#44337a", "white"}
  defp node_style(%Workflow.Conjunction{}), do: {"diamond", "#5a3e1b", "white"}
  defp node_style(%Workflow.MemoryAssertion{}), do: {"trapezium", "#2d3748", "white"}
  defp node_style(%Workflow.Fact{}), do: {"ellipse", "#1e3a5f", "white"}
  defp node_style(_), do: {"box", "#2d3748", "white"}

  defp escape_dot(str) when is_atom(str), do: escape_dot(to_string(str))

  defp escape_dot(str) when is_binary(str) do
    str
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.slice(0, 60)
  end

  defp escape_dot(other), do: escape_dot(inspect(other))
end
