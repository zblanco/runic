defmodule Runic.Runner.Scheduler.Adaptive do
  @moduledoc """
  Self-tuning scheduler that adjusts dispatch strategy based on runtime profiling.

  Tracks per-node execution statistics via `on_complete/3` callbacks and classifies
  nodes into capabilities for optimal dispatch grouping. During a warmup period
  (insufficient samples), falls back to structural analysis only — equivalent to
  `ChainBatching` / `FlowBatch` behavior.

  ## Capabilities

  The scheduler maintains a registry of known dispatch capabilities, evaluated
  in priority order (lowest priority number first):

    * `:fast` — average duration below `fast_threshold_ms`. Dispatched individually
      to avoid batching overhead. Nodes classified as fast are ideal candidates for
      `:inline` executor via `SchedulerPolicy`.
    * `:unreliable` — error rate above `error_rate_threshold`. Dispatched individually
      to contain failure blast radius and prevent chain contamination.
    * `:batchable` — default classification. Eligible for chain batching (sequential
      Promises) and parallel batching (parallel Promises via Flow).

  Nodes with insufficient samples (below `warmup_samples`) are classified as
  `:batchable` and participate in structural chain/parallel detection without
  profiling-based overrides.

  ## Profiling

  Duration tracking uses an exponential moving average (EMA) to weight recent
  observations more heavily than historical ones. The `ema_alpha` parameter
  controls the smoothing factor — higher values make the average more responsive
  to recent changes.

  Error rates are computed as `error_count / sample_count` — a simple running ratio.

  For Promise dispatch units, the total duration is distributed equally across
  all node hashes in the promise. This is a rough estimate that converges as
  nodes are also observed via individual dispatch.

  ## Options

    * `:fast_threshold_ms` — duration threshold for `:fast` classification (default: `1.0`)
    * `:error_rate_threshold` — error rate threshold for `:unreliable` (default: `0.1`)
    * `:warmup_samples` — minimum samples before profiling influences decisions (default: `3`)
    * `:ema_alpha` — EMA smoothing factor, 0..1; higher = more reactive (default: `0.3`)
    * `:min_chain_length` — minimum chain length for sequential Promises (default: `2`)
    * `:min_batch_size` — minimum batch size for parallel Promises (default: `4`)
    * `:flow_stages` — max Flow stages for parallel Promises (default: `System.schedulers_online()`)
    * `:flow_max_demand` — Flow max_demand per stage (default: `1`)
    * `:capabilities` — list of `%Capability{}` structs to override default classifications
    * `:classifier` — custom `(NodeProfile.t(), Runnable.t() -> atom())` function that
      bypasses capability matching entirely

  ## Example

      # Adaptive scheduler with aggressive inline threshold
      Runic.Runner.start_workflow(runner, :my_workflow, workflow,
        scheduler: Runic.Runner.Scheduler.Adaptive,
        scheduler_opts: [
          fast_threshold_ms: 5.0,
          warmup_samples: 5,
          min_chain_length: 3
        ]
      )
  """

  @behaviour Runic.Runner.Scheduler

  alias Runic.Runner.{Promise, PromiseBuilder}

  # --- Node Profile ---

  defmodule NodeProfile do
    @moduledoc """
    Per-node execution statistics tracked by the Adaptive scheduler.

    Uses exponential moving average (EMA) for duration tracking and
    a running count for error rate calculation.
    """

    @type t :: %__MODULE__{
            sample_count: non_neg_integer(),
            avg_duration_ms: float(),
            error_count: non_neg_integer(),
            last_seen: integer()
          }

    defstruct sample_count: 0,
              avg_duration_ms: 0.0,
              error_count: 0,
              last_seen: 0
  end

  # --- Capability ---

  defmodule Capability do
    @moduledoc """
    A registered dispatch capability that the Adaptive scheduler can assign to nodes.

    Each capability has a name, description, priority (lower = evaluated first),
    and a classifier function that receives a `%NodeProfile{}` and returns
    `true` if the node matches.

    ## Example

        %Capability{
          name: :cpu_bound,
          description: "CPU-intensive nodes that benefit from dedicated processes",
          priority: 5,
          classifier: fn profile -> profile.avg_duration_ms > 100.0 end
        }
    """

    @type t :: %__MODULE__{
            name: atom(),
            description: String.t(),
            priority: non_neg_integer(),
            classifier: (NodeProfile.t() -> boolean())
          }

    defstruct [:name, :description, :priority, :classifier]
  end

  # --- Scheduler Callbacks ---

  @impl true
  def init(opts) do
    config = %{
      fast_threshold_ms: Keyword.get(opts, :fast_threshold_ms, 1.0),
      error_rate_threshold: Keyword.get(opts, :error_rate_threshold, 0.1),
      warmup_samples: Keyword.get(opts, :warmup_samples, 3),
      ema_alpha: Keyword.get(opts, :ema_alpha, 0.3),
      min_chain_length: Keyword.get(opts, :min_chain_length, 2),
      min_batch_size: Keyword.get(opts, :min_batch_size, 4),
      flow_stages: Keyword.get(opts, :flow_stages, System.schedulers_online()),
      flow_max_demand: Keyword.get(opts, :flow_max_demand, 1),
      classifier: Keyword.get(opts, :classifier)
    }

    capabilities = Keyword.get(opts, :capabilities, default_capabilities(config))

    {:ok, %{profiles: %{}, config: config, capabilities: capabilities}}
  end

  @impl true
  def plan_dispatch(_workflow, [], state), do: {[], state}

  def plan_dispatch(workflow, runnables, state) do
    classified = Enum.map(runnables, fn r -> {r, classify_node(r, state)} end)

    # Fast and unreliable nodes dispatch individually; batchable go through
    # structural analysis (chain detection + parallel batch detection).
    {individual, batchable} =
      Enum.split_with(classified, fn {_r, cap} -> cap in [:fast, :unreliable] end)

    individual_units = Enum.map(individual, fn {r, _} -> {:runnable, r} end)
    batchable_runnables = Enum.map(batchable, fn {r, _} -> r end)

    # Chain detection on batchable runnables
    {chain_promises, standalone} =
      PromiseBuilder.build_promises(workflow, batchable_runnables,
        min_chain_length: state.config.min_chain_length
      )

    # Parallel batch detection on standalone batchable runnables
    {parallel_promises, remaining} =
      build_parallel_batches(workflow, standalone, state)

    units =
      individual_units ++
        Enum.map(chain_promises, &{:promise, &1}) ++
        Enum.map(parallel_promises, &{:promise, &1}) ++
        Enum.map(remaining, &{:runnable, &1})

    {units, state}
  end

  @impl true
  def on_complete(dispatch_unit, duration_ms, state) do
    case dispatch_unit do
      {:runnable, runnable} ->
        failed? = runnable.status == :failed
        update_profile(state, runnable.node.hash, duration_ms, failed?)

      {:promise, promise} ->
        # Distribute total promise duration equally across all covered nodes.
        # This is a rough estimate that converges as the EMA incorporates
        # more accurate per-node observations from individual dispatch.
        hashes = MapSet.to_list(promise.node_hashes)
        count = max(length(hashes), 1)
        per_node_ms = duration_ms / count

        Enum.reduce(hashes, state, fn hash, acc ->
          update_profile(acc, hash, per_node_ms, false)
        end)
    end
  end

  # --- Public API ---

  @doc """
  Returns the current node profile for a given node hash, or nil if untracked.
  """
  @spec get_profile(map(), term()) :: NodeProfile.t() | nil
  def get_profile(state, node_hash) do
    Map.get(state.profiles, node_hash)
  end

  @doc """
  Returns the classification for a runnable given the current scheduler state.

  During warmup (insufficient samples), returns `:batchable`.
  After warmup, evaluates registered capabilities in priority order.
  """
  @spec classify_node(Runic.Workflow.Runnable.t(), map()) :: atom()
  def classify_node(runnable, state) do
    node_hash = runnable.node.hash
    profile = Map.get(state.profiles, node_hash, %NodeProfile{})

    if state.config.classifier do
      state.config.classifier.(profile, runnable)
    else
      if profile.sample_count < state.config.warmup_samples do
        :batchable
      else
        match_capability(profile, state.capabilities)
      end
    end
  end

  @doc """
  Returns a summary of current profiling state for observability.

  Useful for debugging and monitoring adaptive scheduler behavior.
  """
  @spec profile_summary(map()) :: %{
          total_tracked: non_neg_integer(),
          classifications: %{atom() => non_neg_integer()}
        }
  def profile_summary(state) do
    tracked = Map.keys(state.profiles)

    classifications =
      Enum.frequencies_by(tracked, fn hash ->
        profile = Map.fetch!(state.profiles, hash)

        if profile.sample_count < state.config.warmup_samples do
          :warmup
        else
          match_capability(profile, state.capabilities)
        end
      end)

    %{
      total_tracked: length(tracked),
      classifications: classifications
    }
  end

  # --- Default Capabilities ---

  defp default_capabilities(config) do
    [
      %Capability{
        name: :fast,
        description: "Sub-threshold duration, dispatch individually",
        priority: 1,
        classifier: fn profile ->
          profile.avg_duration_ms < config.fast_threshold_ms
        end
      },
      %Capability{
        name: :unreliable,
        description: "High error rate, dispatch individually to contain failures",
        priority: 2,
        classifier: fn profile ->
          error_rate =
            if profile.sample_count > 0,
              do: profile.error_count / profile.sample_count,
              else: 0.0

          error_rate > config.error_rate_threshold
        end
      },
      %Capability{
        name: :batchable,
        description: "Default — eligible for chain/parallel batching",
        priority: 100,
        classifier: fn _profile -> true end
      }
    ]
  end

  # --- Classification ---

  defp match_capability(profile, capabilities) do
    capabilities
    |> Enum.sort_by(& &1.priority)
    |> Enum.find_value(:batchable, fn cap ->
      if cap.classifier.(profile), do: cap.name
    end)
  end

  # --- Profile Updates ---

  defp update_profile(state, node_hash, duration_ms, failed?) do
    alpha = state.config.ema_alpha
    now = System.monotonic_time(:millisecond)

    profile = Map.get(state.profiles, node_hash, %NodeProfile{})

    new_avg =
      if profile.sample_count == 0 do
        duration_ms * 1.0
      else
        alpha * duration_ms + (1 - alpha) * profile.avg_duration_ms
      end

    updated = %NodeProfile{
      sample_count: profile.sample_count + 1,
      avg_duration_ms: new_avg,
      error_count: if(failed?, do: profile.error_count + 1, else: profile.error_count),
      last_seen: now
    }

    %{state | profiles: Map.put(state.profiles, node_hash, updated)}
  end

  # --- Parallel Batch Detection ---
  # Adapted from FlowBatch — groups independent standalone runnables into
  # parallel Promises for concurrent execution via Flow.

  defp build_parallel_batches(_workflow, [], _state), do: {[], []}
  defp build_parallel_batches(_workflow, [single], _state), do: {[], [single]}

  defp build_parallel_batches(workflow, standalone, state) do
    graph = workflow.graph

    {eligible, ineligible} =
      Enum.split_with(standalone, &eligible_for_parallel?(graph, &1))

    eligible_hashes = MapSet.new(eligible, & &1.node.hash)
    connected_pairs = find_connected_pairs(graph, eligible, eligible_hashes)
    groups = find_independent_groups(eligible, connected_pairs)

    {singletons, dependent_groups} =
      Enum.split_with(groups, fn group -> length(group) == 1 end)

    independent = List.flatten(singletons)

    parallel_promises =
      if length(independent) >= state.config.min_batch_size do
        [
          Promise.new(independent,
            strategy: :parallel,
            flow_opts: [
              stages: min(length(independent), state.config.flow_stages),
              max_demand: state.config.flow_max_demand
            ]
          )
        ]
      else
        []
      end

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
      has_meta_refs?(graph, node_hash) -> false
      true -> true
    end
  end

  defp has_meta_refs?(graph, node_hash) do
    graph
    |> Graph.out_edges(node_hash, by: :meta_ref)
    |> Enum.any?()
  end

  defp find_connected_pairs(graph, eligible, eligible_hashes) do
    Enum.reduce(eligible, MapSet.new(), fn runnable, pairs ->
      hash = runnable.node.hash

      successors =
        graph
        |> Graph.out_edges(hash, by: :flow)
        |> Enum.map(&extract_hash_v2/1)
        |> Enum.filter(&MapSet.member?(eligible_hashes, &1))

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

  defp extract_hash_v2(edge) do
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

  defp find_independent_groups(eligible, connected_pairs) do
    initial_parents = Map.new(eligible, &{&1.node.hash, &1.node.hash})

    parents =
      Enum.reduce(connected_pairs, initial_parents, fn {h1, h2}, parents ->
        union(parents, h1, h2)
      end)

    eligible
    |> Enum.group_by(fn r -> find_root(parents, r.node.hash) end)
    |> Map.values()
  end

  defp find_root(parents, node) do
    parent = Map.fetch!(parents, node)
    if parent == node, do: node, else: find_root(parents, parent)
  end

  defp union(parents, a, b) do
    root_a = find_root(parents, a)
    root_b = find_root(parents, b)
    if root_a == root_b, do: parents, else: Map.put(parents, root_a, root_b)
  end
end
