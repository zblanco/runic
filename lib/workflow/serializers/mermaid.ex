defmodule Runic.Workflow.Serializers.Mermaid do
  @moduledoc """
  Serializes Runic Workflows to Mermaid diagram format.

  Supports two diagram types:
  - **Flowchart**: Shows static workflow structure with components as subgraphs
  - **Sequence**: Shows causal reactions between facts and steps

  ## Examples

      # Generate flowchart of workflow structure
      mermaid = Runic.Workflow.Serializers.Mermaid.serialize(workflow)

      # Generate sequence diagram of causal reactions
      mermaid = Runic.Workflow.Serializers.Mermaid.serialize_causal(workflow)

      # With options
      mermaid = Runic.Workflow.Serializers.Mermaid.serialize(workflow,
        direction: :LR,
        include_memory: false,
        title: "My Workflow"
      )
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
    direction = opts[:direction] |> to_string() |> String.upcase()

    lines = ["flowchart #{direction}"]

    lines = add_title(lines, opts[:title])
    lines = add_style_definitions(lines)

    # Get component groupings
    component_groups = Serializer.group_by_component(workflow)

    # Add subgraphs for components
    lines = add_component_subgraphs(lines, workflow, component_groups)

    # Add remaining nodes not in subgraphs
    lines = add_standalone_nodes(lines, workflow, component_groups)

    # Add flow edges
    lines = add_flow_edges(lines, workflow)

    # Optionally add memory edges
    lines =
      if opts[:include_memory] do
        add_memory_edges(lines, workflow)
      else
        lines
      end

    # Add class assignments
    lines = add_class_assignments(lines, workflow)

    Enum.join(lines, "\n")
  end

  @doc """
  Generates a sequence diagram showing causal reactions.

  Shows how facts flow through top-level components (or standalone nodes).
  Each column represents a top-level component with sub-component details.
  Edges show facts traveling across nodes with cycle information.
  Originating input facts (no ancestry) are displayed with their raw values.
  """
  def serialize_causal(%Workflow{} = workflow, opts \\ []) do
    opts = Keyword.merge(@default_opts, opts)

    lines = ["sequenceDiagram"]
    lines = add_title(lines, opts[:title])

    causal_edges =
      Serializer.causal_edges(workflow)
      |> Enum.sort_by(& &1.weight)

    if Enum.empty?(causal_edges) do
      lines ++ ["    Note over Workflow: No causal reactions yet"]
    else
      component_groups = Serializer.group_by_component(workflow)
      component_info = build_component_info(workflow, component_groups)

      participants = build_participants(workflow, causal_edges, component_info)
      lines = add_participants(lines, participants)

      input_facts = find_input_facts(workflow, causal_edges)
      lines = add_input_facts(lines, input_facts, participants)

      lines = add_causal_sequence(lines, workflow, causal_edges, component_info, participants)

      lines
    end
    |> Enum.join("\n")
  end

  defp build_component_info(%Workflow{graph: graph}, component_groups) do
    component_edges = Graph.edges(graph, by: :component_of)

    child_to_parent =
      Enum.reduce(component_edges, %{}, fn %{v1: parent, v2: child, properties: props}, acc ->
        kind = Map.get(props || %{}, :kind, :unknown)
        Map.put(acc, Serializer.node_id(child), {parent, kind})
      end)

    top_level_components = Map.keys(component_groups) |> MapSet.new(&Serializer.node_id/1)

    %{
      child_to_parent: child_to_parent,
      top_level: top_level_components,
      groups: component_groups
    }
  end

  defp build_participants(%Workflow{graph: graph}, causal_edges, component_info) do
    producers =
      causal_edges
      |> Enum.map(& &1.v1)
      |> Enum.reject(&match?(%Workflow.Fact{}, &1))

    consumers =
      causal_edges
      |> Enum.flat_map(fn %{v2: fact} ->
        case fact do
          %Workflow.Fact{ancestry: {_producer_hash, _}} ->
            graph
            |> Graph.out_edges(fact)
            |> Enum.map(& &1.v2)
            |> Enum.reject(&match?(%Workflow.Fact{}, &1))

          _ ->
            []
        end
      end)

    all_nodes = (producers ++ consumers) |> Enum.uniq()

    all_nodes
    |> Enum.map(fn node ->
      node_id = Serializer.node_id(node)

      case Map.get(component_info.child_to_parent, node_id) do
        {parent, kind} ->
          parent_id = Serializer.node_id(parent)

          if MapSet.member?(component_info.top_level, parent_id) do
            {parent, node, kind}
          else
            {node, node, :standalone}
          end

        _ ->
          {node, node, :standalone}
      end
    end)
    |> Enum.group_by(fn {parent, _, _} -> Serializer.node_id(parent) end)
    |> Enum.map(fn {parent_id, entries} ->
      {parent, _, _} = hd(entries)

      children =
        entries
        |> Enum.map(fn {_, child, kind} -> {child, kind} end)
        |> Enum.uniq_by(fn {child, _} -> Serializer.node_id(child) end)

      label = build_participant_label(parent, children)
      %{id: parent_id, parent: parent, children: children, label: label}
    end)
    |> Enum.sort_by(fn %{id: id} -> id end)
  end

  defp build_participant_label(parent, children) do
    parent_name = Serializer.node_label(parent) |> Serializer.escape_label()

    child_details =
      children
      |> Enum.reject(fn {child, _} -> Serializer.node_id(child) == Serializer.node_id(parent) end)
      |> Enum.map(fn {child, kind} ->
        child_name =
          case child do
            %{name: name} when not is_nil(name) -> to_string(name)
            _ -> nil
          end

        case {kind, child_name} do
          {:standalone, _} -> nil
          {k, nil} -> "[#{k}]"
          {k, name} -> "[#{k}: #{name}]"
        end
      end)
      |> Enum.reject(&is_nil/1)

    case child_details do
      [] -> parent_name
      details -> "#{parent_name}<br/>#{Enum.join(details, ", ")}"
    end
  end

  defp add_participants(lines, participants) do
    Enum.reduce(participants, lines, fn %{id: id, label: label}, acc ->
      escaped = Serializer.escape_label(label)
      acc ++ ["    participant #{id} as #{escaped}"]
    end)
  end

  defp find_input_facts(%Workflow{graph: graph}, causal_edges) do
    all_vertices = Graph.vertices(graph)

    causal_edges
    |> Enum.flat_map(fn %{v2: fact} ->
      case fact do
        %Workflow.Fact{ancestry: {_producer_hash, parent_fact_hash}} ->
          Enum.filter(all_vertices, fn
            %Workflow.Fact{hash: ^parent_fact_hash, ancestry: nil} -> true
            _ -> false
          end)

        _ ->
          []
      end
    end)
    |> Enum.filter(&match?(%Workflow.Fact{}, &1))
    |> Enum.uniq_by(& &1.hash)
  end

  defp add_input_facts(lines, [], _participants), do: lines

  defp add_input_facts(lines, input_facts, participants) do
    first_participant =
      case participants do
        [%{id: id} | _] -> id
        _ -> "Workflow"
      end

    lines = lines ++ ["    Note left of #{first_participant}: Input Facts"]

    Enum.reduce(input_facts, lines, fn %Workflow.Fact{value: value}, acc ->
      fact_str =
        value
        |> inspect(limit: 50, printable_limit: 100)
        |> Serializer.escape_label()

      acc ++ ["    Note left of #{first_participant}: #{fact_str}"]
    end)
  end

  defp add_causal_sequence(
         lines,
         %Workflow{graph: graph},
         causal_edges,
         _component_info,
         participants
       ) do
    participant_lookup =
      participants
      |> Enum.flat_map(fn %{id: parent_id, children: children} = p ->
        [{parent_id, p} | Enum.map(children, fn {child, _} -> {Serializer.node_id(child), p} end)]
      end)
      |> Map.new()

    edges_by_cycle =
      causal_edges
      |> Enum.group_by(& &1.weight)
      |> Enum.sort_by(fn {cycle, _} -> cycle end)

    Enum.reduce(edges_by_cycle, lines, fn {cycle, edges}, acc ->
      acc =
        acc ++
          [
            "    rect rgb(40, 40, 60)",
            "        Note right of #{hd(participants).id}: Cycle #{cycle}"
          ]

      acc =
        Enum.reduce(edges, acc, fn %{v1: producer, v2: fact, label: label}, inner_acc ->
          producer_id = Serializer.node_id(producer)
          producer_participant = Map.get(participant_lookup, producer_id)

          {fact_label, consumers} = get_fact_info(graph, fact, participant_lookup)

          case {producer_participant, consumers} do
            {nil, _} ->
              inner_acc

            {%{id: from_id}, []} ->
              inner_acc ++ ["        #{from_id}->>#{from_id}: #{label}: #{fact_label}"]

            {%{id: from_id}, consumer_list} ->
              Enum.reduce(consumer_list, inner_acc, fn %{id: to_id}, edge_acc ->
                edge_acc ++ ["        #{from_id}->>#{to_id}: #{label}: #{fact_label}"]
              end)
          end
        end)

      acc ++ ["    end"]
    end)
  end

  defp get_fact_info(graph, fact, participant_lookup) do
    fact_label =
      case fact do
        %Workflow.Fact{value: value} ->
          value
          |> inspect(limit: 30, printable_limit: 50)
          |> String.slice(0, 40)
          |> Serializer.escape_label()

        _ ->
          Serializer.node_label(fact)
      end

    consumers =
      graph
      |> Graph.out_edges(fact)
      |> Enum.map(& &1.v2)
      |> Enum.reject(&match?(%Workflow.Fact{}, &1))
      |> Enum.map(fn consumer ->
        Map.get(participant_lookup, Serializer.node_id(consumer))
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.id)

    {fact_label, consumers}
  end

  # Private helpers

  defp add_title(lines, nil), do: lines
  defp add_title(lines, title), do: lines ++ ["    %% #{title}"]

  defp add_style_definitions(lines) do
    lines ++
      [
        "",
        "    %% Node styles",
        "    classDef root fill:#1a1a2e,stroke:#00d9ff,color:#fff",
        "    classDef step fill:#2d3748,stroke:#4fd1c5,color:#fff",
        "    classDef condition fill:#553c9a,stroke:#b794f4,color:#fff",
        "    classDef fanout fill:#2c5282,stroke:#63b3ed,color:#fff",
        "    classDef fanin fill:#285e61,stroke:#4fd1c5,color:#fff",
        "    classDef join fill:#744210,stroke:#f6ad55,color:#fff",
        "    classDef accumulator fill:#22543d,stroke:#68d391,color:#fff",
        "    classDef rule fill:#742a2a,stroke:#fc8181,color:#fff",
        "    classDef map fill:#1a365d,stroke:#90cdf4,color:#fff",
        "    classDef reduce fill:#234e52,stroke:#81e6d9,color:#fff",
        "    classDef statemachine fill:#44337a,stroke:#d6bcfa,color:#fff",
        "    classDef conjunction fill:#5a3e1b,stroke:#ecc94b,color:#fff",
        "    classDef memory fill:#2d3748,stroke:#a0aec0,color:#fff",
        "    classDef fact fill:#1e3a5f,stroke:#63b3ed,color:#fff,stroke-dasharray:3",
        "    classDef default fill:#2d3748,stroke:#718096,color:#fff",
        ""
      ]
  end

  defp add_component_subgraphs(lines, _workflow, component_groups) do
    Enum.reduce(component_groups, lines, fn {component, children}, acc ->
      component_id = Serializer.node_id(component)

      component_label =
        component
        |> Serializer.node_label()
        |> Serializer.escape_label()

      # Filter children to only invokables (not facts) and exclude self-references
      invokable_children =
        children
        |> Enum.reject(&match?(%Workflow.Fact{}, &1))
        |> Enum.reject(fn child -> Serializer.node_id(child) == component_id end)
        |> Enum.uniq_by(&Serializer.node_id/1)

      case invokable_children do
        [] ->
          # No children other than self - render as standalone node
          acc ++ ["", render_node(component, 1)]

        _ ->
          subgraph_lines = [
            "",
            "    subgraph #{component_id}[\"#{component_label}\"]"
          ]

          child_lines =
            Enum.map(invokable_children, fn child ->
              render_node(child, 2)
            end)

          subgraph_lines = subgraph_lines ++ child_lines ++ ["    end"]
          acc ++ subgraph_lines
      end
    end)
  end

  defp add_standalone_nodes(lines, %Workflow{graph: graph}, component_groups) do
    # Find vertices not in any subgraph
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

  defp add_flow_edges(lines, %Workflow{} = workflow) do
    edges = Serializer.flow_edges(workflow)

    if Enum.empty?(edges) do
      lines
    else
      edge_lines =
        edges
        |> Enum.reject(fn %{v1: v1, v2: v2} ->
          match?(%Workflow.Fact{}, v1) or match?(%Workflow.Fact{}, v2)
        end)
        |> Enum.uniq_by(fn %{v1: v1, v2: v2} ->
          {Serializer.node_id(v1), Serializer.node_id(v2)}
        end)
        |> Enum.map(fn %{v1: v1, v2: v2} ->
          from_id = Serializer.node_id(v1)
          to_id = Serializer.node_id(v2)
          "    #{from_id} --> #{to_id}"
        end)

      lines ++ ["", "    %% Flow edges"] ++ edge_lines
    end
  end

  defp add_memory_edges(lines, %Workflow{} = workflow) do
    edges = Serializer.causal_edges(workflow)

    if Enum.empty?(edges) do
      lines
    else
      edge_lines =
        Enum.map(edges, fn %{v1: v1, v2: v2, label: label} ->
          from_id = Serializer.node_id(v1)
          to_id = Serializer.node_id(v2)
          "    #{from_id} -.->|#{label}| #{to_id}"
        end)

      lines ++ ["", "    %% Causal edges"] ++ edge_lines
    end
  end

  defp add_class_assignments(lines, %Workflow{graph: graph}) do
    class_groups =
      graph
      |> Graph.vertices()
      |> Enum.reject(&match?(%Workflow.Fact{}, &1))
      |> Enum.group_by(&Serializer.node_class/1)

    class_lines =
      Enum.flat_map(class_groups, fn {class, vertices} ->
        ids = Enum.map(vertices, &Serializer.node_id/1) |> Enum.join(",")
        ["    class #{ids} #{class}"]
      end)

    if Enum.empty?(class_lines) do
      lines
    else
      lines ++ [""] ++ class_lines
    end
  end

  defp render_node(node, indent_level) do
    id = Serializer.node_id(node)
    label = Serializer.node_label(node) |> Serializer.escape_label()
    {_shape, open, close} = Serializer.node_shape(node)
    indent = String.duplicate("    ", indent_level)

    "#{indent}#{id}#{open}\"#{label}\"#{close}"
  end
end
