defmodule Runic.Workflow.Serializers.Edgelist do
  @moduledoc """
  Serializes Runic Workflows to simple edgelist format.

  Produces a list of tuples `{from, to, label}` or a string with one edge per line.

  ## Examples

      # Get list of edge tuples
      edges = Runic.Workflow.Serializers.Edgelist.serialize(workflow)
      # => [{:root, :tokenize, :flow}, {:tokenize, :count_words, :flow}, ...]

      # Get string format
      str = Runic.Workflow.Serializers.Edgelist.to_string(workflow)
      # => "root -> tokenize [flow]\\ntokenize -> count_words [flow]\\n..."
  """

  alias Runic.Workflow
  alias Runic.Workflow.Serializer

  @behaviour Runic.Workflow.Serializer

  @default_opts [
    include_memory: false,
    include_facts: false,
    format: :tuples
  ]

  @impl true
  def serialize(%Workflow{} = workflow, opts \\ []) do
    opts = Keyword.merge(@default_opts, opts)

    edges = collect_edges(workflow, opts)

    case opts[:format] do
      :tuples -> edges
      :string -> edges_to_string(edges)
      _ -> edges
    end
  end

  @doc """
  Returns a string representation of the edgelist.
  """
  def to_string(%Workflow{} = workflow, opts \\ []) do
    opts = Keyword.put(opts, :format, :string)
    serialize(workflow, opts)
  end

  defp collect_edges(%Workflow{} = workflow, opts) do
    flow_edges =
      workflow
      |> Serializer.flow_edges()
      |> maybe_filter_facts(opts)
      |> Enum.map(&edge_to_tuple/1)

    if opts[:include_memory] do
      causal_edges =
        workflow
        |> Serializer.causal_edges()
        |> Enum.map(&edge_to_tuple/1)

      flow_edges ++ causal_edges
    else
      flow_edges
    end
    |> Enum.uniq()
  end

  defp maybe_filter_facts(edges, opts) do
    if opts[:include_facts] do
      edges
    else
      Enum.reject(edges, fn %{v1: v1, v2: v2} ->
        match?(%Workflow.Fact{}, v1) or match?(%Workflow.Fact{}, v2)
      end)
    end
  end

  defp edge_to_tuple(%{v1: v1, v2: v2, label: label}) do
    from = vertex_name(v1)
    to = vertex_name(v2)
    {from, to, label}
  end

  defp vertex_name(%Workflow.Root{}), do: :root
  defp vertex_name(%{name: name}) when not is_nil(name), do: name
  defp vertex_name(%{hash: hash}), do: hash
  defp vertex_name(other), do: :erlang.phash2(other)

  defp edges_to_string(edges) do
    edges
    |> Enum.map(fn {from, to, label} ->
      "#{format_name(from)} -> #{format_name(to)} [#{label}]"
    end)
    |> Enum.join("\n")
  end

  defp format_name(name) when is_atom(name), do: Atom.to_string(name)
  defp format_name(name) when is_binary(name), do: name
  defp format_name(name) when is_integer(name), do: "n#{name}"
  defp format_name(name), do: inspect(name)
end
