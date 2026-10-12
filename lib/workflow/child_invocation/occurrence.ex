defmodule Runic.Workflow.ChildInvocation.Occurrence do
  @moduledoc false
  alias Runic.Identity
  alias Runic.Workflow
  alias Runic.Workflow.{CallValue, ChildInvocation, Components, InputBinding, Join, Root}

  defstruct [:hash, :name, :request, :return_to, :entry_hash]

  def new(activation_id, request, return_to) do
    hash = Identity.derive(:node_occurrence, [activation_id, :child])
    entry = CallValue.new(hash, :input, request.input)

    %__MODULE__{
      hash: hash,
      name: "__runic_child__/#{hash}",
      request: request,
      return_to: return_to,
      entry_hash: entry.hash
    }
  end

  def connect(occurrence, parent, workflow) do
    child = ChildInvocation.graph(occurrence.request)
    # Scope graph coordinates, without changing callback code or application config.
    ids =
      Map.new(Multigraph.vertices(child.graph), fn node ->
        id = Components.vertex_id_of(node)
        {id, Identity.derive(:node_occurrence, [occurrence.hash, id])}
      end)

    scoped =
      Map.new(Multigraph.vertices(child.graph), fn node ->
        {Components.vertex_id_of(node), scope(node, ids)}
      end)

    entry = CallValue.new(occurrence.hash, :input, occurrence.request.input)
    collector = Map.fetch!(scoped, CallValue.new(:collector, :output).hash)
    output = Map.fetch!(workflow.graph.vertices, occurrence.return_to)

    workflow = Workflow.add_step(workflow, parent, entry)

    graph =
      Enum.reduce(Multigraph.edges(child.graph, by: [:flow, :meta_ref]), workflow.graph, fn edge,
                                                                                            graph ->
        from =
          if is_struct(edge.v1, Root),
            do: entry,
            else: Map.fetch!(scoped, Components.vertex_id_of(edge.v1))

        to = Map.fetch!(scoped, Components.vertex_id_of(edge.v2))
        Multigraph.add_edge(graph, %{edge | v1: from, v2: to})
      end)

    %{workflow | graph: graph}
    |> Workflow.add_step(collector, output)
    |> Workflow.draw_connection(occurrence, collector, :component_of,
      properties: %{kind: :output, ports: [:out]}
    )
    |> Workflow.draw_connection(occurrence, entry, :compiled_for,
      properties: %{kind: :child_input}
    )
  end

  defp scope(%Root{} = node, _), do: node

  defp scope(node, ids) do
    node = %{node | hash: Map.fetch!(ids, node.hash)}

    case node do
      %Join{} ->
        %{node | joins: Enum.map(node.joins, &Map.fetch!(ids, &1))}

      %InputBinding{} ->
        %{
          node
          | target_component_hash: Map.fetch!(ids, node.target_component_hash),
            source_order: Enum.map(node.source_order, &Map.fetch!(ids, &1)),
            bindings:
              Enum.map(node.bindings, &%{&1 | source_hash: Map.fetch!(ids, &1.source_hash)})
        }

      _ ->
        node
    end
  end
end

defimpl Runic.Component, for: Runic.Workflow.ChildInvocation.Occurrence do
  alias Runic.Workflow.ChildInvocation.Occurrence
  def connectable?(_, _), do: true
  defdelegate connect(node, parent, workflow), to: Occurrence

  def source(node) do
    # Save construction data through the existing ComponentAdded source path.
    binary = :erlang.term_to_binary(node)
    quote do: :erlang.binary_to_term(unquote(binary))
  end

  def hash(node), do: node.hash
  def inputs(_), do: [in: [type: :any]]
  def outputs(_), do: [out: [type: :any]]
end
