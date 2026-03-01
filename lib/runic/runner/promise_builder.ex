defmodule Runic.Runner.PromiseBuilder do
  @moduledoc """
  Analyzes workflow graphs to construct Promises from linear chain patterns.

  Given a set of prepared runnables, identifies structural chains by following
  `:flow` edges forward from each runnable. A chain is a sequence of nodes where
  each has exactly one successor and each successor has exactly one predecessor
  via `:flow` edges.

  The Promise captures the full chain's node hashes but only contains the
  currently-prepared head runnable. The resolve loop inside the Worker executes
  each step, applies it to a local workflow copy, prepares the next runnable
  in the chain, and continues.

  ## Chain Exclusions

  The following nodes are excluded from chains:

    * Join/FanIn nodes — they synchronize external inputs
    * Nodes with `:meta_ref` edges — they read mutable workflow state

  ## Usage

      {promises, standalone} = PromiseBuilder.build_promises(workflow, runnables)
  """

  alias Runic.Runner.Promise
  alias Runic.Workflow

  @doc """
  Given a set of prepared runnables, identifies structural linear chains
  that can be batched into Promises.

  Returns `{[Promise.t()], [Runnable.t()]}` — promises + standalone runnables
  that could not be chained.

  ## Options

    * `:min_chain_length` — minimum chain length to form a Promise (default: 2)
  """
  @spec build_promises(Workflow.t(), [Runic.Workflow.Runnable.t()], keyword()) ::
          {[Promise.t()], [Runic.Workflow.Runnable.t()]}
  def build_promises(%Workflow{} = workflow, runnables, opts \\ []) do
    min_chain_length = Keyword.get(opts, :min_chain_length, 2)
    graph = workflow.graph

    # For each runnable, walk forward via structural :flow edges to find the chain
    {promises, chained_hashes} =
      Enum.reduce(runnables, {[], MapSet.new()}, fn runnable, {promises, used} ->
        node_hash = runnable.node.hash

        # Skip if this node is already part of another chain
        if MapSet.member?(used, node_hash) do
          {promises, used}
        else
          chain_hashes = walk_structural_chain(graph, node_hash)

          if length(chain_hashes) >= min_chain_length do
            promise = Promise.new([runnable], node_hashes: MapSet.new(chain_hashes))
            {[promise | promises], MapSet.union(used, MapSet.new(chain_hashes))}
          else
            {promises, used}
          end
        end
      end)

    standalone = Enum.reject(runnables, &MapSet.member?(chained_hashes, &1.node.hash))

    {Enum.reverse(promises), standalone}
  end

  # Walk forward from a node via :flow edges to build a structural chain.
  # A chain continues as long as:
  # - Current node has exactly 1 :flow successor
  # - That successor has exactly 1 :flow predecessor
  # - The successor is not excluded (Join, FanIn, meta_ref)
  defp walk_structural_chain(graph, start_hash) do
    if excluded_node?(graph, start_hash) do
      [start_hash]
    else
      do_walk_structural(graph, start_hash, [start_hash])
    end
  end

  defp do_walk_structural(graph, current_hash, chain) do
    successors = flow_successors(graph, current_hash)

    case successors do
      [single_succ] ->
        # Check successor has exactly 1 flow predecessor
        preds = flow_predecessors(graph, single_succ)

        if length(preds) == 1 and not excluded_node?(graph, single_succ) do
          do_walk_structural(graph, single_succ, chain ++ [single_succ])
        else
          chain
        end

      _ ->
        chain
    end
  end

  defp flow_successors(graph, node_hash) do
    graph
    |> Graph.out_edges(node_hash, by: :flow)
    |> Enum.map(fn edge ->
      case edge.v2 do
        %{hash: h} -> h
        h when is_integer(h) -> h
        _ -> edge.v2
      end
    end)
    |> Enum.uniq()
  end

  defp flow_predecessors(graph, node_hash) do
    graph
    |> Graph.in_edges(node_hash, by: :flow)
    |> Enum.map(fn edge ->
      case edge.v1 do
        %{hash: h} -> h
        h when is_integer(h) -> h
        _ -> edge.v1
      end
    end)
    |> Enum.uniq()
  end

  defp excluded_node?(graph, node_hash) do
    node = Map.get(graph.vertices, node_hash)

    cond do
      is_nil(node) -> true
      is_struct(node, Runic.Workflow.Join) -> true
      is_struct(node, Runic.Workflow.FanIn) -> true
      has_meta_refs?(graph, node_hash) -> true
      true -> false
    end
  end

  defp has_meta_refs?(graph, node_hash) do
    graph
    |> Graph.out_edges(node_hash, by: :meta_ref)
    |> Enum.any?()
  end
end
