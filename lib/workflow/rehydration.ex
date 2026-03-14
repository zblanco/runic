defmodule Runic.Workflow.Rehydration do
  @moduledoc """
  Lineage classification and hybrid rehydration for checkpointed workflows.

  Classifies facts into hot (needed for forward execution) and cold (historical)
  sets, enabling memory-efficient recovery by keeping only hot fact values in
  memory while replacing cold facts with lightweight `FactRef` structs.

  ## Hot Fact Categories

  1. **Pending runnable inputs** — Facts on `:runnable` or `:matchable` edges,
     waiting to be consumed by downstream nodes.

  2. **Active frontier** — Latest-generation facts in each causal lineage
     (facts that are not parents of any other fact in the graph).

  3. **Meta-ref targets** — Facts produced by nodes referenced via `:meta_ref`
     edges, needed for runtime meta-context resolution. Classification is
     kind-aware: no values needed for `:fact_count` / `:step_ran?` kinds.

  4. **Pending join inputs** — Facts on `:joined` edges waiting for join
     completion.

  ## Usage

      alias Runic.Workflow.Rehydration

      # Classify facts in a rebuilt workflow
      %{hot: hot, cold: cold} = Rehydration.classify(workflow)

      # Dehydrate cold facts to FactRefs (frees memory)
      workflow = Rehydration.dehydrate(workflow, cold)

      # Or use the combined rehydrate/3 for the full flow
      {workflow, resolver} = Rehydration.rehydrate(workflow, {StoreMod, store_state})
  """

  alias Runic.Workflow
  alias Runic.Workflow.{Fact, FactRef, Facts, FactResolver}

  @type classification :: %{hot: MapSet.t(), cold: MapSet.t()}

  @doc """
  Classifies all fact vertices in the workflow into hot and cold sets.

  Hot facts are needed for forward execution. Cold facts are historical
  and can be safely replaced with `FactRef` structs.

  Returns `%{hot: MapSet.t(hash), cold: MapSet.t(hash)}`.
  """
  @spec classify(Workflow.t(), keyword()) :: classification()
  def classify(%Workflow{graph: graph} = workflow, _opts \\ []) do
    # Single O(|V|) scan: collect all fact hashes and parent fact hashes simultaneously
    {all_fact_hashes, parent_hashes} = scan_facts(graph)

    # Category 1: Facts on :runnable/:matchable edges — O(|activation edges|) via index
    pending = pending_runnable_input_hashes(graph)

    # Category 2: Frontier — facts not referenced as parent by any other fact
    frontier = MapSet.difference(all_fact_hashes, parent_hashes)

    # Category 3: Facts produced by meta-ref target nodes (kind-aware)
    meta_targets = meta_ref_target_hashes(workflow)

    # Category 4: Facts on :joined edges (pending join inputs)
    join_inputs = pending_join_input_hashes(graph)

    hot =
      pending
      |> MapSet.union(frontier)
      |> MapSet.union(meta_targets)
      |> MapSet.union(join_inputs)

    cold = MapSet.difference(all_fact_hashes, hot)
    %{hot: hot, cold: cold}
  end

  @doc """
  Replaces cold `Fact` vertices with lightweight `FactRef` structs in the graph.

  Preserves graph topology — edges reference vertex ids (hashes), which are
  identical between a `Fact` and its corresponding `FactRef`. Only the vertex
  value in the vertices map is swapped; no edges are modified.
  """
  @spec dehydrate(Workflow.t(), MapSet.t()) :: Workflow.t()
  def dehydrate(%Workflow{graph: graph} = workflow, cold_hashes) do
    vertices =
      Enum.reduce(cold_hashes, graph.vertices, fn hash, vertices ->
        case Map.get(vertices, hash) do
          %Fact{} = fact ->
            Map.put(vertices, hash, Facts.to_ref(fact))

          _ ->
            vertices
        end
      end)

    %{workflow | graph: %{graph | vertices: vertices}}
  end

  @doc """
  Classifies, dehydrates, and prepares a resolver for a rebuilt workflow.

  Combines `classify/2` and `dehydrate/2` into a single call, returning
  the dehydrated workflow paired with a `FactResolver` that can resolve
  any `FactRef` on demand from the backing store.

  ## Example

      workflow = Workflow.from_events(events)
      {workflow, resolver} = Rehydration.rehydrate(workflow, {ETS, store_state})
  """
  @spec rehydrate(Workflow.t(), {module(), term()}, keyword()) :: {Workflow.t(), FactResolver.t()}
  def rehydrate(%Workflow{} = workflow, store, opts \\ []) do
    rehydrate_fused(workflow, store, opts)
  end

  @doc """
  Single-pass classify+dehydrate. Avoids intermediate hot/cold MapSet allocations.

  Pre-computes edge-based hot criteria, then performs two mini-passes over vertices:
  1. Collect parent hashes (needed for frontier detection)
  2. Dehydrate cold facts inline based on hot criteria

  Returns the dehydrated workflow paired with a `FactResolver`.
  """
  @spec rehydrate_fused(Workflow.t(), {module(), term()}, keyword()) ::
          {Workflow.t(), FactResolver.t()}
  def rehydrate_fused(%Workflow{graph: graph} = workflow, store, _opts \\ []) do
    # Pre-compute edge-based hot sets (bounded by active edges, not total facts)
    pending = pending_runnable_input_hashes(graph)
    join_inputs = pending_join_input_hashes(graph)
    meta_targets = meta_ref_target_hashes(workflow)

    # Pass 1: collect parent hashes from ancestry tuples
    parent_hashes =
      Enum.reduce(graph.vertices, MapSet.new(), fn
        {_hash, %Fact{ancestry: {_, parent}}}, parents -> MapSet.put(parents, parent)
        {_hash, %FactRef{ancestry: {_, parent}}}, parents -> MapSet.put(parents, parent)
        _, parents -> parents
      end)

    # Pass 2: dehydrate cold facts inline
    vertices =
      Enum.reduce(graph.vertices, graph.vertices, fn
        {hash, %Fact{} = fact}, verts ->
          is_hot =
            MapSet.member?(pending, hash) or
              not MapSet.member?(parent_hashes, hash) or
              MapSet.member?(meta_targets, hash) or
              MapSet.member?(join_inputs, hash)

          if is_hot, do: verts, else: Map.put(verts, hash, Facts.to_ref(fact))

        _, verts ->
          verts
      end)

    workflow = %{workflow | graph: %{graph | vertices: vertices}}
    {workflow, FactResolver.new(store)}
  end

  @doc """
  Resolves hot FactRef vertices back to full Fact structs.

  Used after lean replay to load only the values needed for forward execution.
  Cold FactRefs remain as lightweight references.
  """
  @spec resolve_hot(Workflow.t(), MapSet.t(), FactResolver.t()) ::
          {Workflow.t(), FactResolver.t()}
  def resolve_hot(%Workflow{graph: graph} = workflow, hot_hashes, resolver) do
    resolver = FactResolver.preload(resolver, MapSet.to_list(hot_hashes))

    vertices =
      Enum.reduce(hot_hashes, graph.vertices, fn hash, vertices ->
        case Map.get(vertices, hash) do
          %FactRef{} = ref ->
            case FactResolver.resolve(ref, resolver) do
              {:ok, fact} -> Map.put(vertices, hash, fact)
              {:error, _} -> vertices
            end

          _ ->
            vertices
        end
      end)

    {%{workflow | graph: %{graph | vertices: vertices}}, resolver}
  end

  @doc """
  Heuristic check: returns true if hybrid rehydration is likely to produce
  meaningful memory savings for this workflow.

  Samples fact values and checks total fact count against thresholds
  derived from benchmark data.
  """
  @spec should_rehydrate?(Workflow.t(), keyword()) :: boolean()
  def should_rehydrate?(%Workflow{graph: graph}, opts \\ []) do
    min_facts = Keyword.get(opts, :min_facts, 50)
    min_value_bytes = Keyword.get(opts, :min_value_bytes, 256)
    sample_size = Keyword.get(opts, :sample_size, 10)

    facts =
      graph.vertices
      |> Map.values()
      |> Enum.filter(&is_struct(&1, Fact))

    total_facts = length(facts)

    if total_facts < min_facts do
      false
    else
      sample =
        facts
        |> Enum.take_random(sample_size)
        |> Enum.map(fn %Fact{value: v} -> :erlang.external_size(v) end)

      case sample do
        [] -> false
        sizes -> Enum.sum(sizes) / length(sizes) >= min_value_bytes
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Scanning
  # ---------------------------------------------------------------------------

  # Single pass over all vertices: collects fact hashes and the set of hashes
  # that appear as a parent_fact_hash in some other fact's ancestry tuple.
  # O(|V|) time and space.
  defp scan_facts(graph) do
    Enum.reduce(Graph.vertices(graph), {MapSet.new(), MapSet.new()}, fn vertex, {all, parents} ->
      case vertex do
        %Fact{hash: h, ancestry: {_producer, parent_hash}} ->
          {MapSet.put(all, h), MapSet.put(parents, parent_hash)}

        %Fact{hash: h} ->
          {MapSet.put(all, h), parents}

        %FactRef{hash: h, ancestry: {_producer, parent_hash}} ->
          {MapSet.put(all, h), MapSet.put(parents, parent_hash)}

        %FactRef{hash: h} ->
          {MapSet.put(all, h), parents}

        _ ->
          {all, parents}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Category 1 — Pending runnable inputs
  # ---------------------------------------------------------------------------

  # Facts on :runnable or :matchable activation edges.
  # Leverages the multigraph edge adjacency index for O(|activation edges|).
  defp pending_runnable_input_hashes(graph) do
    for %Graph.Edge{v1: fact} <- Graph.edges(graph, by: [:runnable, :matchable]),
        is_struct(fact, Fact) or is_struct(fact, FactRef),
        into: MapSet.new() do
      Facts.hash(fact)
    end
  end

  # ---------------------------------------------------------------------------
  # Category 3 — Meta-ref target facts
  # ---------------------------------------------------------------------------

  # For each :meta_ref edge (source_node → target_node), collects fact hashes
  # produced by the target node. Kind-aware: count/boolean meta-refs don't need
  # values, so their target facts are excluded.
  defp meta_ref_target_hashes(%Workflow{graph: graph}) do
    for %Graph.Edge{v2: target, properties: props} <- Graph.edges(graph, by: :meta_ref),
        kind = Map.get(props || %{}, :kind),
        kind not in [:fact_count, :step_ran?],
        reduce: MapSet.new() do
      acc ->
        target_hash =
          case target do
            %{hash: h} -> h
            h when is_integer(h) -> h
            _ -> nil
          end

        if target_hash do
          collect_produced_fact_hashes(graph, target_hash, acc)
        else
          acc
        end
    end
  end

  @production_labels [:produced, :state_produced, :reduced, :state_initiated]

  defp collect_produced_fact_hashes(graph, node_hash, acc) do
    for %Graph.Edge{v2: fact} <- Graph.out_edges(graph, node_hash, by: @production_labels),
        is_struct(fact, Fact) or is_struct(fact, FactRef),
        into: acc do
      Facts.hash(fact)
    end
  end

  # ---------------------------------------------------------------------------
  # Category 4 — Pending join inputs
  # ---------------------------------------------------------------------------

  # Facts on :joined edges (fact → join_node) that haven't been relabeled yet.
  # Leverages the multigraph edge adjacency index.
  defp pending_join_input_hashes(graph) do
    for %Graph.Edge{v1: fact} <- Graph.edges(graph, by: :joined),
        is_struct(fact, Fact) or is_struct(fact, FactRef),
        into: MapSet.new() do
      Facts.hash(fact)
    end
  end
end
