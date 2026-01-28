defmodule Runic.Workflow.Serializer do
  @moduledoc """
  Behaviour for workflow serialization to various graph formats.

  Implements serializers for:
  - Mermaid (flowcharts and sequence diagrams)
  - DOT (Graphviz)
  - Cytoscape.js (JSON elements)
  - Edgelist (simple edge pairs)

  ## Usage

      # Serialize workflow structure (excludes memory/runtime state)
      Runic.Workflow.Serializer.Mermaid.serialize(workflow)

      # Serialize causal reactions (for sequence diagrams)
      Runic.Workflow.Serializer.Mermaid.serialize_causal(workflow)

  ## Edge Labels

  The workflow graph uses a multigraph with labeled edges:
  - `:flow` - Static dataflow connections between steps
  - `:component_of` - Component hierarchy (with :kind in properties)
  - `:produced` / `:state_produced` / `:reduced` - Causal memory edges
  - `:matchable` / `:runnable` / `:ran` / `:satisfied` - Runtime state edges
  """

  @type serialization_opts :: [
          include_memory: boolean(),
          include_facts: boolean(),
          direction: :TB | :LR | :BT | :RL,
          title: String.t() | nil
        ]

  @callback serialize(Runic.Workflow.t(), serialization_opts()) :: String.t() | map() | list()

  @doc """
  Returns a unique, Mermaid-safe node ID for a vertex.
  """
  def node_id(%{hash: hash}) when is_integer(hash), do: "n#{hash}"
  def node_id(%{hash: hash}) when is_binary(hash), do: "n#{:erlang.phash2(hash)}"
  def node_id(%Runic.Workflow.Root{}), do: "root"
  def node_id(hash) when is_integer(hash), do: "n#{hash}"
  def node_id(other), do: "n#{:erlang.phash2(other)}"

  @doc """
  Returns a display label for a vertex node.
  """
  def node_label(%Runic.Workflow.Root{}), do: "root"
  def node_label(%Runic.Workflow.Step{name: name}) when not is_nil(name), do: escape_label(name)
  def node_label(%Runic.Workflow.Condition{hash: hash}), do: "Condition(#{hash})"

  def node_label(%Runic.Workflow.FanOut{name: name}) when not is_nil(name),
    do: "FanOut: #{escape_label(name)}"

  def node_label(%Runic.Workflow.FanOut{hash: hash}), do: "FanOut(#{hash})"

  def node_label(%Runic.Workflow.FanIn{hash: hash}), do: "FanIn(#{hash})"

  def node_label(%Runic.Workflow.Join{hash: hash}), do: "Join(#{hash})"

  def node_label(%Runic.Workflow.Accumulator{name: name}) when not is_nil(name),
    do: "Acc: #{escape_label(name)}"

  def node_label(%Runic.Workflow.Accumulator{hash: hash}), do: "Accumulator(#{hash})"

  def node_label(%Runic.Workflow.Rule{name: name}) when not is_nil(name),
    do: "Rule: #{escape_label(name)}"

  def node_label(%Runic.Workflow.Rule{hash: hash}), do: "Rule(#{hash})"

  def node_label(%Runic.Workflow.Map{name: name}) when not is_nil(name),
    do: "Map: #{escape_label(name)}"

  def node_label(%Runic.Workflow.Map{hash: hash}), do: "Map(#{hash})"

  def node_label(%Runic.Workflow.Reduce{name: name}) when not is_nil(name),
    do: "Reduce: #{escape_label(name)}"

  def node_label(%Runic.Workflow.Reduce{hash: hash}), do: "Reduce(#{hash})"

  def node_label(%Runic.Workflow.StateMachine{name: name}) when not is_nil(name),
    do: "SM: #{escape_label(name)}"

  def node_label(%Runic.Workflow.StateMachine{hash: hash}), do: "StateMachine(#{hash})"

  def node_label(%Runic.Workflow.Conjunction{hash: hash}), do: "AND(#{hash})"
  def node_label(%Runic.Workflow.MemoryAssertion{hash: hash}), do: "Memory(#{hash})"

  def node_label(%Runic.Workflow.Fact{value: value, hash: hash}) do
    val_str =
      value
      |> inspect(limit: 30, printable_limit: 50)
      |> String.slice(0, 40)

    "Fact: #{val_str} (#{hash})"
  end

  def node_label(%{name: name}) when not is_nil(name), do: escape_label(name)
  def node_label(%{hash: hash}), do: "Node(#{hash})"
  def node_label(other), do: inspect(other, limit: 20)

  @doc """
  Returns the node shape for Mermaid based on node type.
  """
  def node_shape(%Runic.Workflow.Root{}), do: {:circle, "((", "))"}
  def node_shape(%Runic.Workflow.Step{}), do: {:rect, "[", "]"}
  def node_shape(%Runic.Workflow.Condition{}), do: {:diamond, "{", "}"}
  def node_shape(%Runic.Workflow.FanOut{}), do: {:parallelogram, "[/", "/]"}
  def node_shape(%Runic.Workflow.FanIn{}), do: {:parallelogram, "[\\", "\\]"}
  def node_shape(%Runic.Workflow.Join{}), do: {:hexagon, "{{", "}}"}
  def node_shape(%Runic.Workflow.Accumulator{}), do: {:cylinder, "[(", ")]"}
  def node_shape(%Runic.Workflow.Rule{}), do: {:subroutine, "[[", "]]"}
  def node_shape(%Runic.Workflow.Map{}), do: {:stadium, "([", "])"}
  def node_shape(%Runic.Workflow.Reduce{}), do: {:stadium, "([", "])"}
  def node_shape(%Runic.Workflow.StateMachine{}), do: {:cylinder, "[(", ")]"}
  def node_shape(%Runic.Workflow.Conjunction{}), do: {:diamond, "{", "}"}
  def node_shape(%Runic.Workflow.MemoryAssertion{}), do: {:trapezoid, "[/", "\\]"}
  def node_shape(%Runic.Workflow.Fact{}), do: {:rounded, "(", ")"}
  def node_shape(_), do: {:rect, "[", "]"}

  @doc """
  Returns Mermaid CSS class based on node type.
  """
  def node_class(%Runic.Workflow.Root{}), do: "root"
  def node_class(%Runic.Workflow.Step{}), do: "step"
  def node_class(%Runic.Workflow.Condition{}), do: "condition"
  def node_class(%Runic.Workflow.FanOut{}), do: "fanout"
  def node_class(%Runic.Workflow.FanIn{}), do: "fanin"
  def node_class(%Runic.Workflow.Join{}), do: "join"
  def node_class(%Runic.Workflow.Accumulator{}), do: "accumulator"
  def node_class(%Runic.Workflow.Rule{}), do: "rule"
  def node_class(%Runic.Workflow.Map{}), do: "map"
  def node_class(%Runic.Workflow.Reduce{}), do: "reduce"
  def node_class(%Runic.Workflow.StateMachine{}), do: "statemachine"
  def node_class(%Runic.Workflow.Conjunction{}), do: "conjunction"
  def node_class(%Runic.Workflow.MemoryAssertion{}), do: "memory"
  def node_class(%Runic.Workflow.Fact{}), do: "fact"
  def node_class(_), do: "default"

  @doc """
  Escapes special characters for Mermaid labels.
  """
  def escape_label(label) when is_atom(label), do: escape_label(to_string(label))
  def escape_label(label) when is_binary(label) do
    label
    |> String.replace("\"", "'")
    |> String.replace("\n", " ")
    |> String.replace("[", "(")
    |> String.replace("]", ")")
    |> String.replace("{", "(")
    |> String.replace("}", ")")
    |> String.replace("<", "‹")
    |> String.replace(">", "›")
    |> String.replace("#", "♯")
    |> String.slice(0, 60)
  end
  def escape_label(other), do: escape_label(inspect(other))

  @doc """
  Groups vertices by their parent component using :component_of edges.
  Returns a map of %{component => [child_vertices]}.
  """
  def group_by_component(%Runic.Workflow{graph: graph}) do
    component_edges = Graph.edges(graph, by: :component_of)

    # Build parent -> children map
    Enum.reduce(component_edges, %{}, fn %{v1: parent, v2: child}, acc ->
      Map.update(acc, parent, [child], &[child | &1])
    end)
  end

  @doc """
  Returns flow edges only (static dataflow, no memory).
  """
  def flow_edges(%Runic.Workflow{graph: graph}) do
    Graph.edges(graph, by: :flow)
  end

  @doc """
  Returns causal memory edges for sequence diagram generation.
  """
  def causal_edges(%Runic.Workflow{graph: graph}) do
    Graph.edges(graph, by: [:produced, :state_produced, :reduced])
  end

  @doc """
  Returns all vertices that are invokable nodes (not facts or memory).
  """
  def invokable_vertices(%Runic.Workflow{graph: graph}) do
    graph
    |> Graph.vertices()
    |> Enum.reject(&match?(%Runic.Workflow.Fact{}, &1))
  end
end
