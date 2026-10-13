defmodule Runic.Workflow.ChildInvocation.Occurrence do
  @moduledoc false
  alias Runic.Identity
  alias Runic.Workflow
  alias Runic.Workflow.{CallValue, ChildInvocation, Components, InputBinding, Join, Root}

  defstruct [:hash, :name, :target, :output_port, :request_fact_hash, :return_to, :entry_hash]

  def new(activation_id, target, output_port, return_to, request_fact_hash) do
    hash = Identity.derive(:node_occurrence, [activation_id, :child])
    entry = CallValue.new(hash, :input)

    %__MODULE__{
      hash: hash,
      name: "__runic_child__/#{hash}",
      target: target,
      output_port: output_port,
      request_fact_hash: request_fact_hash,
      return_to: return_to,
      entry_hash: entry.hash
    }
  end

  def connect(occurrence, parent, workflow) do
    request = %ChildInvocation{
      target: occurrence.target,
      output: occurrence.output_port,
      input: nil
    }

    connect_prepared(occurrence, parent, workflow, prepare(request, occurrence.hash, :occurrence))
  end

  def prepare(request, activation_id),
    do: prepare(request, Identity.derive(:node_occurrence, [activation_id, :child]), :occurrence)

  defp prepare(request, occurrence_hash, :occurrence) do
    child = ChildInvocation.graph(request)
    # Scope graph coordinates, without changing callback code or application config.
    ids =
      Map.new(Multigraph.vertices(child.graph), fn node ->
        id = Components.vertex_id_of(node)
        {id, Identity.derive(:node_occurrence, [occurrence_hash, id])}
      end)

    scoped =
      Map.new(Multigraph.vertices(child.graph), fn node ->
        {Components.vertex_id_of(node), scope(node, ids)}
      end)

    entry = CallValue.new(occurrence_hash, :input)
    collector = Map.fetch!(scoped, CallValue.new(:collector, :output).hash)

    edges =
      Enum.map(Multigraph.edges(child.graph, by: [:flow, :meta_ref]), fn edge ->
        from =
          if is_struct(edge.v1, Root),
            do: entry,
            else: Map.fetch!(scoped, Components.vertex_id_of(edge.v1))

        %{edge | v1: from, v2: Map.fetch!(scoped, Components.vertex_id_of(edge.v2))}
      end)

    %{
      occurrence_hash: occurrence_hash,
      target_hash: request.target.hash,
      output_port: request.output,
      entry: entry,
      collector: collector,
      edges: edges
    }
  end

  def connect_prepared(occurrence, parent, workflow, %{occurrence_hash: hash} = prepared)
      when hash == occurrence.hash do
    output = Map.fetch!(workflow.graph.vertices, occurrence.return_to)
    graph = Enum.reduce(prepared.edges, workflow.graph, &Multigraph.add_edge(&2, &1))

    workflow =
      %{workflow | graph: graph}
      |> Workflow.add_step(parent, prepared.entry)
      |> Workflow.add_step(prepared.collector, output)
      |> Workflow.draw_connection(occurrence, prepared.collector, :component_of,
        properties: %{kind: :output, ports: [:out]}
      )

    nodes =
      [prepared.entry | Enum.flat_map(prepared.edges, &[&1.v1, &1.v2])]
      |> Enum.uniq_by(&Components.vertex_id_of/1)

    Enum.reduce(nodes, workflow, fn node, wf ->
      Workflow.draw_connection(wf, occurrence, node, :compiled_for,
        properties: %{kind: :child_scope}
      )
    end)
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
