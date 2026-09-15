defmodule Multigraph.Serializers.Flowchart do
  @moduledoc """
  This serializer converts a `Multigraph` to a [Mermaid Flowchart](https://mermaid.js.org/syntax/flowchart.html).
  """

  use Multigraph.Serializer
  import Multigraph.Serializer

  @impl Multigraph.Serializer
  def serialize(%Multigraph{} = g) do
    result = """
    flowchart
    #{serialize_vertices(g)}
    #{serialize_edges(g)}
    """

    {:ok, result}
  end

  defp serialize_vertices(g) do
    Enum.map_join(g.vertices, "\n", fn {id, value} ->
      indent(1) <> "#{id}" <> "[" <> get_vertex_label(g, id, value) <> "]"
    end)
  end

  defp serialize_edges(g) do
    arrow =
      case g.type do
        :directed -> "->"
        :undirected -> "-"
      end

    g.vertices
    |> Enum.reduce([], fn {id, _}, acc ->
      g.out_edges
      |> Map.get_lazy(id, &MapSet.new/0)
      |> Enum.flat_map(fn out_edge_id ->
        g.edges
        |> Map.fetch!({id, out_edge_id})
        |> Enum.map(fn
          {nil, weight} -> {id, out_edge_id, weight}
          {label, weight} -> {id, out_edge_id, weight, encode_label(label)}
        end)
      end)
      |> case do
        [] -> acc
        edges -> acc ++ edges
      end
    end)
    |> Enum.map_join("\n", &serialize_edge(&1, arrow))
  end

  defp serialize_edge({id, out_edge_id, weight, label}, arrow) do
    indent(1) <> "#{id} " <> weight_arrow(arrow, weight) <> " |#{label}| " <> "#{out_edge_id}"
  end

  defp serialize_edge({id, out_edge_id, weight}, arrow) do
    indent(1) <> "#{id} " <> weight_arrow(arrow, weight) <> " #{out_edge_id}"
  end

  defp weight_arrow(arrow, weight) do
    String.duplicate("-", weight) <> arrow
  end
end
