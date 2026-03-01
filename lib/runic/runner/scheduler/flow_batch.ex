defmodule Runic.Runner.Scheduler.FlowBatch do
  @moduledoc """
  Scheduler strategy that detects both sequential chains and parallel batch
  opportunities.

  Extends the chain-detection logic from `Runic.Runner.PromiseBuilder` with
  independent-runnable grouping: after sequential chains are extracted, any
  remaining standalone runnables that share no graph edges are grouped into a
  single `:parallel` Promise for concurrent execution via Flow (or
  `Task.async_stream` as fallback).

  ## Options

    * `:min_chain_length` — minimum chain length to form a sequential Promise (default: 2)
    * `:min_batch_size` — minimum group size to form a parallel Promise (default: 4)
    * `:flow_stages` — max Flow stages for parallel Promises (default: `System.schedulers_online()`)
    * `:flow_max_demand` — Flow max_demand per stage (default: 1)
  """

  @behaviour Runic.Runner.Scheduler

  alias Runic.Runner.{Promise, PromiseBuilder}

  @impl true
  def init(opts) do
    {:ok,
     %{
       min_chain_length: Keyword.get(opts, :min_chain_length, 2),
       min_batch_size: Keyword.get(opts, :min_batch_size, 4),
       flow_stages: Keyword.get(opts, :flow_stages, System.schedulers_online()),
       flow_max_demand: Keyword.get(opts, :flow_max_demand, 1)
     }}
  end

  @impl true
  def plan_dispatch(workflow, runnables, state) do
    # Step 1: Extract sequential chains (reuse PromiseBuilder)
    {seq_promises, standalone} =
      PromiseBuilder.build_promises(workflow, runnables, min_chain_length: state.min_chain_length)

    # Step 2: From standalone runnables, find independent groups for parallel batching
    {parallel_promises, remaining} =
      build_parallel_batches(workflow, standalone, state)

    units =
      Enum.map(seq_promises, &{:promise, &1}) ++
        Enum.map(parallel_promises, &{:promise, &1}) ++
        Enum.map(remaining, &{:runnable, &1})

    {units, state}
  end

  # --- Parallel Batch Detection ---

  defp build_parallel_batches(_workflow, [], _state), do: {[], []}

  defp build_parallel_batches(_workflow, [single], _state), do: {[], [single]}

  defp build_parallel_batches(workflow, standalone, state) do
    graph = workflow.graph

    # Filter out runnables that are excluded from parallel batching
    {eligible, ineligible} =
      Enum.split_with(standalone, &eligible_for_parallel?(graph, &1))

    # Build an adjacency set: which eligible runnables share graph edges?
    eligible_hashes = MapSet.new(eligible, & &1.node.hash)

    # For each eligible runnable, check if it has any :flow edge connections
    # to other eligible runnables. If not, it's independent.
    connected_pairs = find_connected_pairs(graph, eligible, eligible_hashes)

    # Group into connected components using union-find.
    # Runnables in the same component share :flow edges and cannot be parallelized.
    # Runnables in different components (especially singletons) are independent.
    groups = find_independent_groups(eligible, connected_pairs)

    # Separate truly independent runnables (singleton components — no edges to
    # other eligibles) from dependent groups (components with internal edges).
    {singletons, dependent_groups} =
      Enum.split_with(groups, fn group -> length(group) == 1 end)

    # All singletons are independent → merge into one parallel batch candidate
    independent = List.flatten(singletons)

    parallel_promises =
      if length(independent) >= state.min_batch_size do
        [
          Promise.new(independent,
            strategy: :parallel,
            flow_opts: [
              stages: min(length(independent), state.flow_stages),
              max_demand: state.flow_max_demand
            ]
          )
        ]
      else
        []
      end

    # Remaining: below-threshold independents + dependent group members + ineligibles
    remaining =
      if parallel_promises == [] do
        independent
      else
        []
      end ++
        List.flatten(dependent_groups) ++ ineligible

    {parallel_promises, remaining}
  end

  defp eligible_for_parallel?(graph, runnable) do
    node_hash = runnable.node.hash
    node = Map.get(graph.vertices, node_hash)

    cond do
      is_nil(node) -> false
      is_struct(node, Runic.Workflow.Join) -> false
      is_struct(node, Runic.Workflow.FanIn) -> false
      has_meta_refs?(graph, node_hash) -> false
      true -> true
    end
  end

  defp has_meta_refs?(graph, node_hash) do
    graph
    |> Graph.out_edges(node_hash, by: :meta_ref)
    |> Enum.any?()
  end

  # Find pairs of eligible runnables that are connected via :flow edges
  # (directly or transitively through the graph).
  # Two runnables are "connected" if there's any :flow edge path between them.
  defp find_connected_pairs(graph, eligible, eligible_hashes) do
    Enum.reduce(eligible, MapSet.new(), fn runnable, pairs ->
      hash = runnable.node.hash

      # Check :flow successors that are also in the eligible set
      successors =
        graph
        |> Graph.out_edges(hash, by: :flow)
        |> Enum.map(&extract_hash/1)
        |> Enum.filter(&MapSet.member?(eligible_hashes, &1))

      # Check :flow predecessors that are also in the eligible set
      predecessors =
        graph
        |> Graph.in_edges(hash, by: :flow)
        |> Enum.map(&extract_hash_v1/1)
        |> Enum.filter(&MapSet.member?(eligible_hashes, &1))

      connected = successors ++ predecessors

      Enum.reduce(connected, pairs, fn other_hash, acc ->
        pair = if hash < other_hash, do: {hash, other_hash}, else: {other_hash, hash}
        MapSet.put(acc, pair)
      end)
    end)
  end

  defp extract_hash(edge) do
    case edge.v2 do
      %{hash: h} -> h
      h when is_integer(h) -> h
      other -> other
    end
  end

  defp extract_hash_v1(edge) do
    case edge.v1 do
      %{hash: h} -> h
      h when is_integer(h) -> h
      other -> other
    end
  end

  # Group runnables into connected components using union-find.
  # Runnables with no connections to other eligible runnables form singleton groups
  # initially, and connected pairs merge their groups.
  defp find_independent_groups(eligible, connected_pairs) do
    # Initialize: each runnable is its own group, keyed by node hash
    initial_parents = Map.new(eligible, &{&1.node.hash, &1.node.hash})

    # Union connected pairs
    parents =
      Enum.reduce(connected_pairs, initial_parents, fn {h1, h2}, parents ->
        union(parents, h1, h2)
      end)

    # Group by root
    eligible
    |> Enum.group_by(fn r -> find_root(parents, r.node.hash) end)
    |> Map.values()
  end

  # Union-find: find root
  defp find_root(parents, node) do
    parent = Map.fetch!(parents, node)
    if parent == node, do: node, else: find_root(parents, parent)
  end

  # Union-find: union two sets
  defp union(parents, a, b) do
    root_a = find_root(parents, a)
    root_b = find_root(parents, b)
    if root_a == root_b, do: parents, else: Map.put(parents, root_a, root_b)
  end
end
