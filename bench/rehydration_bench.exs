# Rehydration Strategy Benchmark
#
# Compares full, lazy, and hybrid rehydration strategies for
# checkpoint-resumed workflows to measure trade-offs in:
#   - Memory footprint (post-rehydration graph size)
#   - Classification overhead (hot/cold partitioning cost)
#   - Dehydration cost (replacing cold facts with FactRefs)
#   - Resolution cost (hydrating FactRefs from store on demand)
#   - End-to-end rehydration time
#
# Workflow patterns tested:
#   1. Linear pipelines — 5, 20, 50 steps
#   2. Branching — 5, 20 branches
#   3. Rules with conditions — 2, 10 rules
#   4. Joins — simple, deep
#   5. Fan-out / Fan-in — 4, 10 elements
#   6. Long-running (many inputs) — 10, 50, 100 inputs
#
# Run with: mix run bench/rehydration_bench.exs

require Runic

alias Runic.Workflow
alias Runic.Workflow.{Fact, FactRef, Facts, FactResolver, Rehydration}
alias Runic.Workflow.Components
alias Runic.Workflow.Events.FactProduced

IO.puts("\n" <> String.duplicate("=", 80))
IO.puts("RUNIC REHYDRATION STRATEGY BENCHMARK")
IO.puts("Strategies: Full | Lazy | Hybrid")
IO.puts("Date: #{DateTime.utc_now() |> DateTime.to_iso8601()}")
IO.puts(String.duplicate("=", 80))

# ==============================================================================
# Helpers
# ==============================================================================

defmodule RehydrationBench.Helpers do
  @moduledoc false

  alias Runic.Workflow
  alias Runic.Workflow.{Fact, FactRef, Facts, FactResolver, Rehydration}

  def memory_bytes(term), do: :erts_debug.flat_size(term) * :erlang.system_info(:wordsize)

  @doc """
  Total memory including refc binary content. `flat_size` excludes binaries >64 bytes
  which live on a separate heap. `external_size` serializes the full term, giving
  a more accurate picture of actual memory cost for binary-heavy values.
  """
  def total_memory_bytes(term), do: :erlang.external_size(term)

  def count_facts(workflow) do
    workflow.graph.vertices
    |> Map.values()
    |> Enum.count(fn v -> is_struct(v, Fact) end)
  end

  def count_fact_refs(workflow) do
    workflow.graph.vertices
    |> Map.values()
    |> Enum.count(fn v -> is_struct(v, FactRef) end)
  end

  def count_all_facts(workflow) do
    workflow.graph.vertices
    |> Map.values()
    |> Enum.count(fn v -> is_struct(v, Fact) or is_struct(v, FactRef) end)
  end

  @doc """
  Populates an ETS table with all fact values from a workflow, simulating
  what a fact store would contain after checkpointing.
  """
  def build_fact_store(workflow) do
    table = :ets.new(:bench_facts, [:set, :public, read_concurrency: true])

    for v <- Graph.vertices(workflow.graph), is_struct(v, Fact) do
      :ets.insert(table, {v.hash, v.value})
    end

    table
  end

  @doc "Full rehydration: workflow as-is with all fact values in memory."
  def rehydrate_full(workflow) do
    workflow
  end

  @doc "Lazy rehydration: dehydrate ALL facts to FactRefs."
  def rehydrate_lazy(workflow, store) do
    all_fact_hashes =
      for v <- Graph.vertices(workflow.graph),
          is_struct(v, Fact),
          into: MapSet.new() do
        v.hash
      end

    dehydrated = Rehydration.dehydrate(workflow, all_fact_hashes)
    resolver = FactResolver.new(store)
    {dehydrated, resolver}
  end

  @doc "Hybrid rehydration: classify hot/cold, dehydrate cold only."
  def rehydrate_hybrid(workflow, store) do
    Rehydration.rehydrate(workflow, store)
  end

  def cleanup_store(table) do
    try do
      :ets.delete(table)
    rescue
      _ -> :ok
    end
  end
end

# Minimal fact store module for benchmarking
defmodule RehydrationBench.FactStore do
  @moduledoc false

  def load_fact(hash, table) do
    case :ets.lookup(table, hash) do
      [{^hash, value}] -> {:ok, value}
      [] -> {:error, :not_found}
    end
  end

  def save_fact(hash, value, table) do
    :ets.insert(table, {hash, value})
    :ok
  end
end

# ==============================================================================
# Workflow Builders — all use Runic macros with literal names
# ==============================================================================

defmodule RehydrationBench.Workflows do
  @moduledoc false
  require Runic
  alias Runic.Workflow
  alias Runic.Workflow.Components

  # --- Linear Pipelines ---
  # Use Step.new for chains to avoid closure replay issues (benchmark
  # measures rehydration, not event replay)

  def make_step(i, prefix) do
    work = fn x -> x + 1 end
    name = :"#{prefix}_#{i}"
    hash = Components.fact_hash({work, name})
    Runic.Workflow.Step.new(work: work, name: name, hash: hash)
  end

  def build_linear_chain(depth, prefix) do
    steps = for i <- 0..(depth - 1), do: make_step(i, prefix)

    Enum.reduce(Enum.reverse(steps), nil, fn step, acc ->
      case acc do
        nil -> step
        child -> {step, [child]}
      end
    end)
  end

  def linear_small do
    chain = build_linear_chain(5, "rls")
    Runic.workflow(name: "linear_small_5", steps: [chain])
  end

  def linear_medium do
    chain = build_linear_chain(20, "rlm")
    Runic.workflow(name: "linear_medium_20", steps: [chain])
  end

  def linear_large do
    chain = build_linear_chain(50, "rll")
    Runic.workflow(name: "linear_large_50", steps: [chain])
  end

  # --- Branching ---

  def branching_small do
    root = make_step(0, "rbs_root")
    children = for i <- 1..4, do: make_step(i, "rbs")
    Runic.workflow(name: "branching_small_5", steps: [{root, children}])
  end

  def branching_medium do
    root = make_step(0, "rbm_root")
    children = for i <- 1..19, do: make_step(i, "rbm")
    Runic.workflow(name: "branching_medium_20", steps: [{root, children}])
  end

  # --- Rules ---

  def rules_small do
    rule1 = Runic.rule(fn x when is_integer(x) and x > 0 -> x * 2 end, name: :rrs_pos)
    rule2 = Runic.rule(fn x when is_integer(x) and x > 10 -> x + 100 end, name: :rrs_gt10)
    Runic.workflow(name: "rules_small_2", rules: [rule1, rule2])
  end

  def rules_medium do
    r1 = Runic.rule(fn x when is_integer(x) and x > 0 -> x + 5 end, name: :rrm_1)
    r2 = Runic.rule(fn x when is_integer(x) and x > 1 -> x + 10 end, name: :rrm_2)
    r3 = Runic.rule(fn x when is_integer(x) and x > 2 -> x + 15 end, name: :rrm_3)
    r4 = Runic.rule(fn x when is_integer(x) and x > 3 -> x + 20 end, name: :rrm_4)
    r5 = Runic.rule(fn x when is_integer(x) and x > 4 -> x + 25 end, name: :rrm_5)
    r6 = Runic.rule(fn x when is_integer(x) and x > 5 -> x + 30 end, name: :rrm_6)
    r7 = Runic.rule(fn x when is_integer(x) and x > 6 -> x + 35 end, name: :rrm_7)
    r8 = Runic.rule(fn x when is_integer(x) and x > 7 -> x + 40 end, name: :rrm_8)
    r9 = Runic.rule(fn x when is_integer(x) and x > 8 -> x + 45 end, name: :rrm_9)
    r10 = Runic.rule(fn x when is_integer(x) and x > 9 -> x + 50 end, name: :rrm_10)
    Runic.workflow(name: "rules_medium_10", rules: [r1, r2, r3, r4, r5, r6, r7, r8, r9, r10])
  end

  # --- Joins ---

  def join_simple do
    a = Runic.step(fn x -> x + 1 end, name: :rja)
    b = Runic.step(fn x -> x * 2 end, name: :rjb)
    join = Runic.step(fn a, b -> a + b end, name: :rj_sum)

    Runic.workflow(name: "join_simple")
    |> Workflow.add(a)
    |> Workflow.add(b)
    |> Workflow.add(join, to: [:rja, :rjb])
  end

  def join_deep do
    a1 = Runic.step(fn x -> x + 1 end, name: :rja1)
    a2 = Runic.step(fn x -> x * 2 end, name: :rja2)
    b1 = Runic.step(fn x -> x - 1 end, name: :rjb1)
    b2 = Runic.step(fn x -> x * 3 end, name: :rjb2)
    join = Runic.step(fn a, b -> a + b end, name: :rj_deep_sum)

    Runic.workflow(name: "join_deep")
    |> Workflow.add(a1)
    |> Workflow.add(a2, to: :rja1)
    |> Workflow.add(b1)
    |> Workflow.add(b2, to: :rjb1)
    |> Workflow.add(join, to: [:rja2, :rjb2])
  end

  # --- Fan-out / Fan-in ---

  def fanout_small do
    source = Runic.step(fn _x -> [1, 2, 3, 4] end, name: :rfo_source)
    mapper = Runic.map(fn num -> num * 2 end, name: :rfo_map)
    reducer = Runic.reduce(0, fn num, acc -> num + acc end, name: :rfo_reduce, map: :rfo_map)
    Runic.workflow(name: "fanout_small_4", steps: [{source, [{mapper, [reducer]}]}])
  end

  def fanout_medium do
    source = Runic.step(fn _x -> Enum.to_list(1..10) end, name: :rfom_source)
    mapper = Runic.map(fn num -> num * 2 end, name: :rfom_map)
    reducer = Runic.reduce(0, fn num, acc -> num + acc end, name: :rfom_reduce, map: :rfom_map)
    Runic.workflow(name: "fanout_medium_10", steps: [{source, [{mapper, [reducer]}]}])
  end

  # --- Long-running (accumulator, many inputs) ---

  def accumulator_long do
    acc = Runic.accumulator(0, fn x, state -> x + state end, name: :rl_sum)
    post = Runic.step(fn x -> x * 2 end, name: :rl_double)

    Runic.workflow(name: "accumulator_long")
    |> Workflow.add(acc)
    |> Workflow.add(post, to: :rl_sum)
  end

  # --- Mixed composite ---

  def mixed_medium do
    s1 = Runic.step(fn x -> x + 1 end, name: :rmm_s1)
    s2 = Runic.step(fn x -> x * 2 end, name: :rmm_s2)
    s3 = Runic.step(fn x -> x - 1 end, name: :rmm_s3)
    acc = Runic.accumulator(0, fn x, state -> x + state end, name: :rmm_acc)
    post = Runic.step(fn x -> x * 3 end, name: :rmm_post)

    Runic.workflow(name: "mixed_medium")
    |> Workflow.add(s1)
    |> Workflow.add(s2, to: :rmm_s1)
    |> Workflow.add(s3, to: :rmm_s1)
    |> Workflow.add(acc, to: :rmm_s2)
    |> Workflow.add(post, to: :rmm_acc)
  end

  # ===========================================================================
  # Large-value workflow builders
  #
  # These simulate realistic data pipeline workloads where fact values are
  # non-trivial: serialized JSON payloads, processed text, binary blobs, etc.
  # ===========================================================================

  defp make_payload_step(i, prefix, payload_size) do
    # Each step appends a payload-sized binary to its input
    padding = :crypto.strong_rand_bytes(payload_size)

    work = fn input ->
      case input do
        %{data: prev} -> %{data: prev <> padding, step: i}
        _ -> %{data: padding, step: i}
      end
    end

    name = :"#{prefix}_#{i}"
    hash = Components.fact_hash({padding, name, i})
    Runic.Workflow.Step.new(work: work, name: name, hash: hash)
  end

  # Linear chain where each step produces a ~payload_size binary
  def large_linear(depth, payload_size, prefix) do
    steps = for i <- 0..(depth - 1), do: make_payload_step(i, prefix, payload_size)

    chain =
      Enum.reduce(Enum.reverse(steps), nil, fn step, acc ->
        case acc do
          nil -> step
          child -> {step, [child]}
        end
      end)

    Runic.workflow(name: "#{prefix}_#{depth}", steps: [chain])
  end

  # Accumulator that collects payload-sized entries over many inputs
  def large_accumulator(payload_size) do
    padding = :crypto.strong_rand_bytes(payload_size)

    acc =
      Runic.accumulator(
        [],
        fn x, state -> [%{input: x, payload: padding} | state] end,
        name: :lg_acc
      )

    summary = Runic.step(fn entries -> %{count: length(entries), latest: hd(entries)} end,
      name: :lg_summary
    )

    Runic.workflow(name: "large_acc_#{payload_size}")
    |> Workflow.add(acc)
    |> Workflow.add(summary, to: :lg_acc)
  end

  # Branching where each branch produces a large payload
  def large_branching(branch_count, payload_size, prefix) do
    root_pad = :crypto.strong_rand_bytes(payload_size)
    root_work = fn input -> %{data: root_pad, input: input} end
    root_name = :"#{prefix}_root"
    root_hash = Components.fact_hash({root_pad, root_name})
    root = Runic.Workflow.Step.new(work: root_work, name: root_name, hash: root_hash)

    children =
      for i <- 1..branch_count do
        pad = :crypto.strong_rand_bytes(payload_size)
        work = fn input -> %{data: pad, branch: i, parent: input} end
        name = :"#{prefix}_b#{i}"
        hash = Components.fact_hash({pad, name, i})
        Runic.Workflow.Step.new(work: work, name: name, hash: hash)
      end

    Runic.workflow(name: "#{prefix}_#{branch_count + 1}", steps: [{root, children}])
  end
end

# ==============================================================================
# Build and execute all workflows
# ==============================================================================

IO.puts("\nBuilding and executing workflows...\n")

alias RehydrationBench.{Helpers, Workflows}

workflows = %{
  linear_5: Workflows.linear_small(),
  linear_20: Workflows.linear_medium(),
  linear_50: Workflows.linear_large(),
  branching_5: Workflows.branching_small(),
  branching_20: Workflows.branching_medium(),
  rules_2: Workflows.rules_small(),
  rules_10: Workflows.rules_medium(),
  join_simple: Workflows.join_simple(),
  join_deep: Workflows.join_deep(),
  fanout_4: Workflows.fanout_small(),
  fanout_10: Workflows.fanout_medium(),
  mixed_medium: Workflows.mixed_medium()
}

# Execute each workflow and create fact store
executed =
  Map.new(workflows, fn {name, wf} ->
    input =
      case name do
        n when n in [:fanout_4, :fanout_10] -> :go
        _ -> 5
      end

    result = Workflow.react_until_satisfied(wf, input)
    store_table = Helpers.build_fact_store(result)
    {name, %{workflow: result, store: {RehydrationBench.FactStore, store_table}}}
  end)

# Long-running: same accumulator with increasing input counts
long_running_wf = Workflows.accumulator_long()

long_running =
  for count <- [10, 50, 100], into: %{} do
    result =
      Enum.reduce(1..count, long_running_wf, fn i, wf ->
        Workflow.react_until_satisfied(wf, i)
      end)

    store_table = Helpers.build_fact_store(result)
    {:"long_#{count}", %{workflow: result, store: {RehydrationBench.FactStore, store_table}}}
  end

all_executed = Map.merge(executed, long_running)

# ==============================================================================
# Large-value workflows
# ==============================================================================

IO.puts("Building large-value workflows...\n")

# Payload sizes: 1KB, 10KB, 100KB
payload_1k = 1_024
payload_10k = 10_240
payload_100k = 102_400

large_value_workflows = %{
  # Linear chains with large payloads — 10 steps
  lg_linear_10_1k:   Workflows.large_linear(10, payload_1k, "lgl1k"),
  lg_linear_10_10k:  Workflows.large_linear(10, payload_10k, "lgl10k"),
  lg_linear_10_100k: Workflows.large_linear(10, payload_100k, "lgl100k"),
  # Linear chains — 20 steps with 10KB payload
  lg_linear_20_10k:  Workflows.large_linear(20, payload_10k, "lgl20_10k"),
  # Branching with large payloads — 10 branches
  lg_branch_10_1k:   Workflows.large_branching(10, payload_1k, "lgb1k"),
  lg_branch_10_10k:  Workflows.large_branching(10, payload_10k, "lgb10k"),
  lg_branch_10_100k: Workflows.large_branching(10, payload_100k, "lgb100k"),
}

large_executed =
  Map.new(large_value_workflows, fn {name, wf} ->
    result = Workflow.react_until_satisfied(wf, %{seed: 42})
    store_table = Helpers.build_fact_store(result)
    {name, %{workflow: result, store: {RehydrationBench.FactStore, store_table}}}
  end)

# Large-value long-running: accumulator with 1KB/10KB payloads over many inputs
large_long_running =
  for {suffix, size} <- [{"1k", payload_1k}, {"10k", payload_10k}],
      count <- [10, 50],
      into: %{} do
    wf = Workflows.large_accumulator(size)

    result =
      Enum.reduce(1..count, wf, fn i, w ->
        Workflow.react_until_satisfied(w, i)
      end)

    store_table = Helpers.build_fact_store(result)
    name = :"lg_long_#{count}_#{suffix}"
    {name, %{workflow: result, store: {RehydrationBench.FactStore, store_table}}}
  end

all_large = Map.merge(large_executed, large_long_running)
all_executed = Map.merge(all_executed, all_large)

# ==============================================================================
# Workflow Stats
# ==============================================================================

IO.puts(
  String.pad_trailing("  Workflow", 22) <>
    String.pad_leading("Vertices", 10) <>
    String.pad_leading("Edges", 8) <>
    String.pad_leading("Facts", 8) <>
    String.pad_leading("Mem (KB)", 10)
)

IO.puts("  " <> String.duplicate("-", 56))

for {name, %{workflow: wf}} <- Enum.sort(all_executed) do
  verts = map_size(wf.graph.vertices)
  edges = length(Graph.edges(wf.graph))
  facts = Helpers.count_all_facts(wf)
  mem = Helpers.memory_bytes(wf)

  IO.puts(
    String.pad_trailing("  #{name}", 22) <>
      String.pad_leading("#{verts}", 10) <>
      String.pad_leading("#{edges}", 8) <>
      String.pad_leading("#{facts}", 8) <>
      String.pad_leading("#{Float.round(mem / 1024, 1)}", 10)
  )
end

IO.puts("")

# ==============================================================================
# BENCHMARK 1: End-to-End Rehydration Time (all strategies, all patterns)
# ==============================================================================

IO.puts(String.duplicate("=", 80))
IO.puts("BENCHMARK 1: End-to-End Rehydration Time — Single-Input Workflows")
IO.puts(String.duplicate("=", 80))

single_input_names = [:linear_5, :linear_20, :linear_50, :branching_5, :branching_20,
                       :rules_2, :rules_10, :join_simple, :join_deep, :fanout_4, :fanout_10,
                       :mixed_medium]

rehydration_targets =
  for name <- single_input_names, into: %{} do
    %{workflow: wf, store: store} = all_executed[name]

    {"#{name}", {
      fn -> Helpers.rehydrate_full(wf) end,
      fn -> Helpers.rehydrate_lazy(wf, store) end,
      fn -> Helpers.rehydrate_hybrid(wf, store) end
    }}
  end

for {name, {full_fn, lazy_fn, hybrid_fn}} <- Enum.sort(rehydration_targets) do
  Benchee.run(
    %{
      "#{name} full" => full_fn,
      "#{name} lazy" => lazy_fn,
      "#{name} hybrid" => hybrid_fn
    },
    time: 2,
    memory_time: 1,
    warmup: 0.5,
    print: [configuration: false]
  )
end

# ==============================================================================
# BENCHMARK 2: Long-Running — Rehydration scales with fact count
# ==============================================================================

IO.puts(String.duplicate("=", 80))
IO.puts("BENCHMARK 2: Long-Running Accumulator — Rehydration Scaling")
IO.puts("(This is where hybrid should show its advantage)")
IO.puts(String.duplicate("=", 80))

for count <- [10, 50, 100] do
  name = :"long_#{count}"
  %{workflow: wf, store: store} = all_executed[name]

  Benchee.run(
    %{
      "long_#{count} full" => fn -> Helpers.rehydrate_full(wf) end,
      "long_#{count} lazy" => fn -> Helpers.rehydrate_lazy(wf, store) end,
      "long_#{count} hybrid" => fn -> Helpers.rehydrate_hybrid(wf, store) end
    },
    time: 2,
    memory_time: 1,
    warmup: 0.5,
    print: [configuration: false]
  )
end

# ==============================================================================
# BENCHMARK 3: Classification Overhead — Isolated
# ==============================================================================

IO.puts(String.duplicate("=", 80))
IO.puts("BENCHMARK 3: Classification Overhead (Rehydration.classify/1)")
IO.puts(String.duplicate("=", 80))

classify_targets =
  for {name, %{workflow: wf}} <- Enum.sort(all_executed), into: %{} do
    {"classify #{name}", fn -> Rehydration.classify(wf) end}
  end

Benchee.run(classify_targets,
  time: 2,
  memory_time: 1,
  warmup: 0.5,
  print: [configuration: false]
)

# ==============================================================================
# BENCHMARK 4: Dehydration Overhead — Isolated
# ==============================================================================

IO.puts(String.duplicate("=", 80))
IO.puts("BENCHMARK 4: Dehydration Overhead (Rehydration.dehydrate/2)")
IO.puts(String.duplicate("=", 80))

dehydrate_targets =
  for {name, %{workflow: wf}} <- Enum.sort(all_executed), into: %{} do
    %{cold: cold} = Rehydration.classify(wf)
    cold_count = MapSet.size(cold)
    {"dehydrate #{name} (#{cold_count} cold)", fn -> Rehydration.dehydrate(wf, cold) end}
  end

Benchee.run(dehydrate_targets,
  time: 2,
  memory_time: 1,
  warmup: 0.5,
  print: [configuration: false]
)

# ==============================================================================
# BENCHMARK 5: FactResolver — Single resolve + batch preload
# ==============================================================================

IO.puts(String.duplicate("=", 80))
IO.puts("BENCHMARK 5: FactResolver Performance")
IO.puts(String.duplicate("=", 80))

# Pick a long-running workflow to test resolution
lr100 = all_executed[:long_100]
{dehydrated_100, resolver_100} = Helpers.rehydrate_hybrid(lr100.workflow, lr100.store)

# Collect some FactRefs to resolve
fact_refs_100 =
  Graph.vertices(dehydrated_100.graph)
  |> Enum.filter(fn v -> is_struct(v, FactRef) end)

cold_ref = List.first(fact_refs_100)

# Build a resolver with preloaded cache
cold_hashes = Enum.map(fact_refs_100, fn ref -> ref.hash end)
preloaded_resolver = FactResolver.preload(resolver_100, cold_hashes)

Benchee.run(
  %{
    "resolve single (store hit)" => fn ->
      FactResolver.resolve(cold_ref, resolver_100)
    end,
    "resolve single (cache hit)" => fn ->
      FactResolver.resolve(cold_ref, preloaded_resolver)
    end,
    "preload #{length(cold_hashes)} hashes" => fn ->
      FactResolver.preload(resolver_100, cold_hashes)
    end,
    "resolve all #{length(fact_refs_100)} refs (cold)" => fn ->
      Enum.each(fact_refs_100, fn ref ->
        FactResolver.resolve(ref, resolver_100)
      end)
    end
  },
  time: 2,
  memory_time: 1,
  warmup: 0.5,
  print: [configuration: false]
)

# ==============================================================================
# BENCHMARK 6: Large-Value Rehydration — Where Hybrid Shines
# ==============================================================================

IO.puts(String.duplicate("=", 80))
IO.puts("BENCHMARK 6: Large-Value Rehydration — Linear Chains")
IO.puts("(Payload sizes: 1KB, 10KB, 100KB per step)")
IO.puts(String.duplicate("=", 80))

for name <- [:lg_linear_10_1k, :lg_linear_10_10k, :lg_linear_10_100k, :lg_linear_20_10k] do
  %{workflow: wf, store: store} = all_executed[name]

  Benchee.run(
    %{
      "#{name} full" => fn -> Helpers.rehydrate_full(wf) end,
      "#{name} lazy" => fn -> Helpers.rehydrate_lazy(wf, store) end,
      "#{name} hybrid" => fn -> Helpers.rehydrate_hybrid(wf, store) end
    },
    time: 2,
    memory_time: 1,
    warmup: 0.5,
    print: [configuration: false]
  )
end

# ==============================================================================
# BENCHMARK 7: Large-Value Rehydration — Branching
# ==============================================================================

IO.puts(String.duplicate("=", 80))
IO.puts("BENCHMARK 7: Large-Value Rehydration — Branching")
IO.puts(String.duplicate("=", 80))

for name <- [:lg_branch_10_1k, :lg_branch_10_10k, :lg_branch_10_100k] do
  %{workflow: wf, store: store} = all_executed[name]

  Benchee.run(
    %{
      "#{name} full" => fn -> Helpers.rehydrate_full(wf) end,
      "#{name} lazy" => fn -> Helpers.rehydrate_lazy(wf, store) end,
      "#{name} hybrid" => fn -> Helpers.rehydrate_hybrid(wf, store) end
    },
    time: 2,
    memory_time: 1,
    warmup: 0.5,
    print: [configuration: false]
  )
end

# ==============================================================================
# BENCHMARK 8: Large-Value Long-Running — Accumulating large payloads
# ==============================================================================

IO.puts(String.duplicate("=", 80))
IO.puts("BENCHMARK 8: Large-Value Long-Running Accumulator")
IO.puts(String.duplicate("=", 80))

for name <- [:lg_long_10_1k, :lg_long_50_1k, :lg_long_10_10k, :lg_long_50_10k] do
  %{workflow: wf, store: store} = all_executed[name]

  Benchee.run(
    %{
      "#{name} full" => fn -> Helpers.rehydrate_full(wf) end,
      "#{name} lazy" => fn -> Helpers.rehydrate_lazy(wf, store) end,
      "#{name} hybrid" => fn -> Helpers.rehydrate_hybrid(wf, store) end
    },
    time: 2,
    memory_time: 1,
    warmup: 0.5,
    print: [configuration: false]
  )
end

# ==============================================================================
# BENCHMARK 9: Large-Value FactResolver
# ==============================================================================

IO.puts(String.duplicate("=", 80))
IO.puts("BENCHMARK 9: Large-Value FactResolver Performance")
IO.puts(String.duplicate("=", 80))

for name <- [:lg_linear_10_10k, :lg_long_50_10k] do
  %{workflow: wf, store: store} = all_executed[name]
  {dehydrated, resolver} = Helpers.rehydrate_hybrid(wf, store)

  refs =
    Graph.vertices(dehydrated.graph)
    |> Enum.filter(fn v -> is_struct(v, FactRef) end)

  if length(refs) > 0 do
    sample_ref = List.first(refs)
    ref_hashes = Enum.map(refs, & &1.hash)
    preloaded = FactResolver.preload(resolver, ref_hashes)

    Benchee.run(
      %{
        "#{name} resolve 1 (store)" => fn ->
          FactResolver.resolve(sample_ref, resolver)
        end,
        "#{name} resolve 1 (cache)" => fn ->
          FactResolver.resolve(sample_ref, preloaded)
        end,
        "#{name} preload #{length(refs)}" => fn ->
          FactResolver.preload(resolver, ref_hashes)
        end
      },
      time: 2,
      memory_time: 1,
      warmup: 0.5,
      print: [configuration: false]
    )
  end
end

# ==============================================================================
# Memory Footprint Comparison
# ==============================================================================

IO.puts(String.duplicate("=", 80))
IO.puts("MEMORY FOOTPRINT COMPARISON")
IO.puts(String.duplicate("=", 80))

IO.puts(
  "\n" <>
    String.pad_trailing("  Workflow", 22) <>
    String.pad_leading("Full KB", 10) <>
    String.pad_leading("Lazy KB", 10) <>
    String.pad_leading("Hybrid KB", 10) <>
    String.pad_leading("Savings%", 10) <>
    String.pad_leading("Hot", 6) <>
    String.pad_leading("Cold", 6) <>
    String.pad_leading("Total", 6)
)

IO.puts("  " <> String.duplicate("-", 78))

for {name, %{workflow: wf, store: store}} <- Enum.sort(all_executed) do
  full_wf = Helpers.rehydrate_full(wf)
  {lazy_wf, _} = Helpers.rehydrate_lazy(wf, store)
  {hybrid_wf, _} = Helpers.rehydrate_hybrid(wf, store)

  full_mem = Helpers.memory_bytes(full_wf)
  lazy_mem = Helpers.memory_bytes(lazy_wf)
  hybrid_mem = Helpers.memory_bytes(hybrid_wf)

  %{hot: hot, cold: cold} = Rehydration.classify(wf)
  total = MapSet.size(hot) + MapSet.size(cold)

  savings =
    if full_mem > 0 do
      Float.round((1.0 - hybrid_mem / full_mem) * 100, 1)
    else
      0.0
    end

  IO.puts(
    String.pad_trailing("  #{name}", 22) <>
      String.pad_leading("#{Float.round(full_mem / 1024, 1)}", 10) <>
      String.pad_leading("#{Float.round(lazy_mem / 1024, 1)}", 10) <>
      String.pad_leading("#{Float.round(hybrid_mem / 1024, 1)}", 10) <>
      String.pad_leading("#{savings}%", 10) <>
      String.pad_leading("#{MapSet.size(hot)}", 6) <>
      String.pad_leading("#{MapSet.size(cold)}", 6) <>
      String.pad_leading("#{total}", 6)
  )
end

# ==============================================================================
# Hot/Cold Classification Detail
# ==============================================================================

IO.puts("\n" <> String.duplicate("=", 80))
IO.puts("HOT/COLD CLASSIFICATION DETAIL")
IO.puts(String.duplicate("=", 80))

IO.puts(
  "\n" <>
    String.pad_trailing("  Workflow", 22) <>
    String.pad_leading("Total", 8) <>
    String.pad_leading("Hot", 8) <>
    String.pad_leading("Cold", 8) <>
    String.pad_leading("Hot%", 8) <>
    String.pad_leading("Cold%", 8)
)

IO.puts("  " <> String.duplicate("-", 60))

for {name, %{workflow: wf}} <- Enum.sort(all_executed) do
  %{hot: hot, cold: cold} = Rehydration.classify(wf)
  total = MapSet.size(hot) + MapSet.size(cold)

  hot_pct = if total > 0, do: Float.round(MapSet.size(hot) / total * 100, 1), else: 0.0
  cold_pct = if total > 0, do: Float.round(MapSet.size(cold) / total * 100, 1), else: 0.0

  IO.puts(
    String.pad_trailing("  #{name}", 22) <>
      String.pad_leading("#{total}", 8) <>
      String.pad_leading("#{MapSet.size(hot)}", 8) <>
      String.pad_leading("#{MapSet.size(cold)}", 8) <>
      String.pad_leading("#{hot_pct}%", 8) <>
      String.pad_leading("#{cold_pct}%", 8)
  )
end

# ==============================================================================
# Per-Fact Memory Cost
# ==============================================================================

IO.puts("\n" <> String.duplicate("=", 80))
IO.puts("PER-FACT MEMORY COST")
IO.puts(String.duplicate("=", 80))

IO.puts(
  "\n" <>
    String.pad_trailing("  Workflow", 22) <>
    String.pad_leading("B/Fact(F)", 12) <>
    String.pad_leading("B/Fact(L)", 12) <>
    String.pad_leading("B/Fact(H)", 12) <>
    String.pad_leading("B/FactRef", 12)
)

IO.puts("  " <> String.duplicate("-", 68))

for {name, %{workflow: wf, store: store}} <- Enum.sort(all_executed) do
  {lazy_wf, _} = Helpers.rehydrate_lazy(wf, store)
  {hybrid_wf, _} = Helpers.rehydrate_hybrid(wf, store)

  total_facts = Helpers.count_all_facts(wf)

  if total_facts > 0 do
    full_per = div(Helpers.memory_bytes(wf), total_facts)
    lazy_per = div(Helpers.memory_bytes(lazy_wf), total_facts)
    hybrid_per = div(Helpers.memory_bytes(hybrid_wf), total_facts)

    # Size of a single FactRef vs Fact
    sample_fact =
      Graph.vertices(wf.graph)
      |> Enum.find(fn v -> is_struct(v, Fact) end)

    ref_size =
      if sample_fact do
        ref = Facts.to_ref(sample_fact)
        Helpers.memory_bytes(ref)
      else
        0
      end

    IO.puts(
      String.pad_trailing("  #{name}", 22) <>
        String.pad_leading("#{full_per}", 12) <>
        String.pad_leading("#{lazy_per}", 12) <>
        String.pad_leading("#{hybrid_per}", 12) <>
        String.pad_leading("#{ref_size}", 12)
    )
  end
end

# ==============================================================================
# TOTAL MEMORY (including refc binaries) — Large-Value Workflows
# ==============================================================================

IO.puts("\n" <> String.duplicate("=", 80))
IO.puts("TOTAL MEMORY (including refc binary content)")
IO.puts("flat_size excludes binaries >64B; external_size includes them")
IO.puts(String.duplicate("=", 80))

IO.puts(
  "\n" <>
    String.pad_trailing("  Workflow", 24) <>
    String.pad_leading("Full KB", 10) <>
    String.pad_leading("Lazy KB", 10) <>
    String.pad_leading("Hybrid KB", 10) <>
    String.pad_leading("Savings%", 10) <>
    String.pad_leading("Cold", 6) <>
    String.pad_leading("Full(f)", 10) <>
    String.pad_leading("Δ method", 10)
)

IO.puts("  " <> String.duplicate("-", 88))

# Show large-value + some small-value workflows for contrast
compare_names = [
  :linear_50, :long_100,
  :lg_linear_10_1k, :lg_linear_10_10k, :lg_linear_10_100k,
  :lg_linear_20_10k,
  :lg_branch_10_1k, :lg_branch_10_10k, :lg_branch_10_100k,
  :lg_long_10_1k, :lg_long_50_1k,
  :lg_long_10_10k, :lg_long_50_10k
]

for name <- compare_names do
  %{workflow: wf, store: store} = all_executed[name]

  {lazy_wf, _} = Helpers.rehydrate_lazy(wf, store)
  {hybrid_wf, _} = Helpers.rehydrate_hybrid(wf, store)

  full_total = Helpers.total_memory_bytes(wf)
  lazy_total = Helpers.total_memory_bytes(lazy_wf)
  hybrid_total = Helpers.total_memory_bytes(hybrid_wf)
  full_flat = Helpers.memory_bytes(wf)

  %{cold: cold} = Rehydration.classify(wf)

  savings =
    if full_total > 0 do
      Float.round((1.0 - hybrid_total / full_total) * 100, 1)
    else
      0.0
    end

  flat_savings =
    if full_flat > 0 do
      Float.round((1.0 - Helpers.memory_bytes(hybrid_wf) / full_flat) * 100, 1)
    else
      0.0
    end

  delta = "#{flat_savings}→#{savings}%"

  IO.puts(
    String.pad_trailing("  #{name}", 24) <>
      String.pad_leading("#{Float.round(full_total / 1024, 1)}", 10) <>
      String.pad_leading("#{Float.round(lazy_total / 1024, 1)}", 10) <>
      String.pad_leading("#{Float.round(hybrid_total / 1024, 1)}", 10) <>
      String.pad_leading("#{savings}%", 10) <>
      String.pad_leading("#{MapSet.size(cold)}", 6) <>
      String.pad_leading("#{Float.round(full_flat / 1024, 1)}", 10) <>
      String.pad_leading(delta, 10)
  )
end

# ==============================================================================
# Struct Size Comparison: Fact vs FactRef
# ==============================================================================

IO.puts("\n" <> String.duplicate("=", 80))
IO.puts("STRUCT SIZE: Fact vs FactRef (raw struct, no graph overhead)")
IO.puts(String.duplicate("=", 80))

# Sample facts from different workflows (small + large values)
for {name, %{workflow: wf}} <- [
  long_100: all_executed[:long_100],
  linear_50: all_executed[:linear_50],
  lg_linear_10_10k: all_executed[:lg_linear_10_10k],
  lg_linear_10_100k: all_executed[:lg_linear_10_100k]
] do
  facts = Enum.filter(Graph.vertices(wf.graph), fn v -> is_struct(v, Fact) end)
  sample = List.first(facts)

  if sample do
    fact_size = Helpers.memory_bytes(sample)
    ref = Facts.to_ref(sample)
    ref_size = Helpers.memory_bytes(ref)
    savings = Float.round((1.0 - ref_size / fact_size) * 100, 1)

    IO.puts("  #{name}: Fact=#{fact_size}B, FactRef=#{ref_size}B, savings=#{savings}%")
    val_preview = inspect(sample.value, limit: 3, printable_limit: 40)
    IO.puts("    value=#{val_preview}, hash=#{inspect(sample.hash)}")
  end
end

# ==============================================================================
# Cleanup
# ==============================================================================

for {_name, %{store: {_, table}}} <- all_executed do
  Helpers.cleanup_store(table)
end

IO.puts("\n" <> String.duplicate("=", 80))
IO.puts("REHYDRATION BENCHMARK COMPLETE")
IO.puts(String.duplicate("=", 80))
