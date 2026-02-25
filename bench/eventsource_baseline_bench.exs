# Canonical Benchmark Suite for Event-Sourced Model Baseline
#
# This benchmark establishes performance baselines for the current (direct-mutation)
# execution model. Results are saved to bench/results/ for comparison against the
# event-sourced aggregate model after migration.
#
# Workflow patterns tested:
#   1. Linear pipelines (Step chains) - small/medium/large
#   2. Branching (fan-out to parallel steps) - small/medium/large
#   3. Rules with Conditions (conditional execution)
#   4. Accumulators (stateful reduction)
#   5. Joins (multi-branch convergence)
#   6. Fan-out / Fan-in (map-reduce)
#   7. Mixed/Composite (combines multiple patterns)
#   8. Long-running (repeated inputs to same workflow)
#
# Run with: mix run bench/eventsource_baseline_bench.exs
#
# Results saved to: bench/results/baseline_TIMESTAMP.json

require Runic

alias Runic.Workflow
alias Runic.Workflow.Step
alias Runic.Workflow.Components

IO.puts("\n" <> String.duplicate("=", 80))
IO.puts("RUNIC EVENT-SOURCE BASELINE BENCHMARK")
IO.puts("Model: Direct Mutation (current)")
IO.puts("Date: #{DateTime.utc_now() |> DateTime.to_iso8601()}")
IO.puts(String.duplicate("=", 80))

# ==============================================================================
# Workflow Builders - Static, Deterministic
# ==============================================================================

defmodule BaselineBench.Workflows do
  @moduledoc false
  require Runic
  alias Runic.Workflow

  # --- Helpers ---

  def make_step(i, prefix) do
    work = fn x -> x + 1 end
    name = :"#{prefix}_#{i}"
    hash = Components.fact_hash({work, name})
    Step.new(work: work, name: name, hash: hash)
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

  def build_branching(count, prefix) do
    root = make_step(0, "#{prefix}_root")
    children = for i <- 1..count, do: make_step(i, prefix)
    {root, children}
  end

  # --- 1. Linear Pipelines ---

  def linear_small do
    chain = build_linear_chain(5, "ls")
    Runic.workflow(name: "linear_small_5", steps: [chain])
  end

  def linear_medium do
    chain = build_linear_chain(20, "lm")
    Runic.workflow(name: "linear_medium_20", steps: [chain])
  end

  def linear_large do
    chain = build_linear_chain(50, "ll")
    Runic.workflow(name: "linear_large_50", steps: [chain])
  end

  def linear_xlarge do
    chain = build_linear_chain(100, "lxl")
    Runic.workflow(name: "linear_xlarge_100", steps: [chain])
  end

  # --- 2. Branching Pipelines ---

  def branching_small do
    tree = build_branching(4, "bs")
    Runic.workflow(name: "branching_small_5", steps: [tree])
  end

  def branching_medium do
    tree = build_branching(19, "bm")
    Runic.workflow(name: "branching_medium_20", steps: [tree])
  end

  def branching_large do
    tree = build_branching(49, "bl")
    Runic.workflow(name: "branching_large_50", steps: [tree])
  end

  # --- 3. Rules with Conditions ---

  def rules_small do
    rule1 = Runic.rule(fn x when is_integer(x) and x > 0 -> x * 2 end, name: :pos_double)
    rule2 = Runic.rule(fn x when is_integer(x) and x > 10 -> x + 100 end, name: :gt10_add)

    Runic.workflow(name: "rules_small_2", rules: [rule1, rule2])
  end

  def rules_medium do
    Runic.workflow(
      name: "rules_medium_10",
      rules: [
        Runic.rule(fn x when is_integer(x) and x > 0 -> x + 5 end, name: :rm1),
        Runic.rule(fn x when is_integer(x) and x > 1 -> x + 10 end, name: :rm2),
        Runic.rule(fn x when is_integer(x) and x > 2 -> x + 15 end, name: :rm3),
        Runic.rule(fn x when is_integer(x) and x > 3 -> x + 20 end, name: :rm4),
        Runic.rule(fn x when is_integer(x) and x > 4 -> x + 25 end, name: :rm5),
        Runic.rule(fn x when is_integer(x) and x > 5 -> x + 30 end, name: :rm6),
        Runic.rule(fn x when is_integer(x) and x > 6 -> x + 35 end, name: :rm7),
        Runic.rule(fn x when is_integer(x) and x > 7 -> x + 40 end, name: :rm8),
        Runic.rule(fn x when is_integer(x) and x > 8 -> x + 45 end, name: :rm9),
        Runic.rule(fn x when is_integer(x) and x > 9 -> x + 50 end, name: :rm10)
      ]
    )
  end

  def rules_large do
    Runic.workflow(
      name: "rules_large_25",
      rules: [
        Runic.rule(fn x when is_integer(x) and x > 0 -> x + 2 end, name: :rl1),
        Runic.rule(fn x when is_integer(x) and x > 1 -> x + 4 end, name: :rl2),
        Runic.rule(fn x when is_integer(x) and x > 2 -> x + 6 end, name: :rl3),
        Runic.rule(fn x when is_integer(x) and x > 3 -> x + 8 end, name: :rl4),
        Runic.rule(fn x when is_integer(x) and x > 4 -> x + 10 end, name: :rl5),
        Runic.rule(fn x when is_integer(x) and x > 5 -> x + 12 end, name: :rl6),
        Runic.rule(fn x when is_integer(x) and x > 6 -> x + 14 end, name: :rl7),
        Runic.rule(fn x when is_integer(x) and x > 7 -> x + 16 end, name: :rl8),
        Runic.rule(fn x when is_integer(x) and x > 8 -> x + 18 end, name: :rl9),
        Runic.rule(fn x when is_integer(x) and x > 9 -> x + 20 end, name: :rl10),
        Runic.rule(fn x when is_integer(x) and x > 10 -> x + 22 end, name: :rl11),
        Runic.rule(fn x when is_integer(x) and x > 11 -> x + 24 end, name: :rl12),
        Runic.rule(fn x when is_integer(x) and x > 12 -> x + 26 end, name: :rl13),
        Runic.rule(fn x when is_integer(x) and x > 13 -> x + 28 end, name: :rl14),
        Runic.rule(fn x when is_integer(x) and x > 14 -> x + 30 end, name: :rl15),
        Runic.rule(fn x when is_integer(x) and x > 15 -> x + 32 end, name: :rl16),
        Runic.rule(fn x when is_integer(x) and x > 16 -> x + 34 end, name: :rl17),
        Runic.rule(fn x when is_integer(x) and x > 17 -> x + 36 end, name: :rl18),
        Runic.rule(fn x when is_integer(x) and x > 18 -> x + 38 end, name: :rl19),
        Runic.rule(fn x when is_integer(x) and x > 19 -> x + 40 end, name: :rl20),
        Runic.rule(fn x when is_integer(x) and x > 20 -> x + 42 end, name: :rl21),
        Runic.rule(fn x when is_integer(x) and x > 21 -> x + 44 end, name: :rl22),
        Runic.rule(fn x when is_integer(x) and x > 22 -> x + 46 end, name: :rl23),
        Runic.rule(fn x when is_integer(x) and x > 23 -> x + 48 end, name: :rl24),
        Runic.rule(fn x when is_integer(x) and x > 24 -> x + 50 end, name: :rl25)
      ]
    )
  end

  # --- 4. Accumulators ---

  def accumulator_simple do
    acc = Runic.accumulator(0, fn x, state -> x + state end, name: :running_sum)

    Runic.workflow(name: "accumulator_simple", steps: [{acc, []}])
  end

  def accumulator_with_downstream do
    acc = Runic.accumulator(0, fn x, state -> x + state end, name: :sum_acc)
    post = Runic.step(fn x -> x * 2 end, name: :post_acc)

    Runic.workflow(name: "accumulator_downstream")
    |> Workflow.add(acc)
    |> Workflow.add(post, to: :sum_acc)
  end

  def accumulator_with_rule do
    acc = Runic.accumulator(0, fn x, state -> x + state end, name: :acc_rule)
    rule = Runic.rule(fn x when is_integer(x) and x > 5 -> x * 3 end, name: :gt5_rule)

    Runic.workflow(name: "accumulator_rule")
    |> Workflow.add(acc)
    |> Workflow.add(rule, to: :acc_rule)
  end

  # --- 5. Joins ---

  def join_simple do
    a = Runic.step(fn x -> x + 1 end, name: :branch_a)
    b = Runic.step(fn x -> x * 2 end, name: :branch_b)
    join = Runic.step(fn a, b -> a + b end, name: :join_sum)

    Runic.workflow(name: "join_simple")
    |> Workflow.add(a)
    |> Workflow.add(b)
    |> Workflow.add(join, to: [:branch_a, :branch_b])
  end

  def join_deep do
    a1 = Runic.step(fn x -> x + 1 end, name: :ja1)
    a2 = Runic.step(fn x -> x * 2 end, name: :ja2)
    b1 = Runic.step(fn x -> x - 1 end, name: :jb1)
    b2 = Runic.step(fn x -> x * 3 end, name: :jb2)
    join = Runic.step(fn a, b -> a + b end, name: :join_deep_sum)

    Runic.workflow(name: "join_deep")
    |> Workflow.add(a1)
    |> Workflow.add(a2, to: :ja1)
    |> Workflow.add(b1)
    |> Workflow.add(b2, to: :jb1)
    |> Workflow.add(join, to: [:ja2, :jb2])
  end

  # --- 6. Fan-out / Fan-in (Map-Reduce) ---

  def fanout_small do
    source = Runic.step(fn _x -> [1, 2, 3, 4] end, name: :fo_source)
    mapper = Runic.map(fn num -> num * 2 end, name: :fo_map)
    reducer = Runic.reduce(0, fn num, acc -> num + acc end, name: :fo_reduce, map: :fo_map)

    Runic.workflow(name: "fanout_small_4", steps: [{source, [{mapper, [reducer]}]}])
  end

  def fanout_medium do
    source = Runic.step(fn _x -> Enum.to_list(1..10) end, name: :fom_source)
    mapper = Runic.map(fn num -> num * 2 end, name: :fom_map)
    reducer = Runic.reduce(0, fn num, acc -> num + acc end, name: :fom_reduce, map: :fom_map)

    Runic.workflow(name: "fanout_medium_10", steps: [{source, [{mapper, [reducer]}]}])
  end

  # --- 7. Mixed / Composite ---

  def mixed_small do
    # Linear chain -> branching with a rule
    step1 = Runic.step(fn x -> x + 1 end, name: :mx_s1)
    step2 = Runic.step(fn x -> x * 2 end, name: :mx_s2)
    rule = Runic.rule(fn x when is_integer(x) and x > 5 -> x * 10 end, name: :mx_rule)

    Runic.workflow(name: "mixed_small")
    |> Workflow.add(step1)
    |> Workflow.add(step2, to: :mx_s1)
    |> Workflow.add(rule, to: :mx_s1)
  end

  def mixed_medium do
    # Steps -> accumulator -> rule -> more steps + join
    s1 = Runic.step(fn x -> x + 1 end, name: :mm_s1)
    s2 = Runic.step(fn x -> x * 2 end, name: :mm_s2)
    s3 = Runic.step(fn x -> x - 1 end, name: :mm_s3)
    acc = Runic.accumulator(0, fn x, state -> x + state end, name: :mm_acc)
    post = Runic.step(fn x -> x * 3 end, name: :mm_post)

    Runic.workflow(name: "mixed_medium")
    |> Workflow.add(s1)
    |> Workflow.add(s2, to: :mm_s1)
    |> Workflow.add(s3, to: :mm_s1)
    |> Workflow.add(acc, to: :mm_s2)
    |> Workflow.add(post, to: :mm_acc)
  end

  def mixed_large do
    # Build a larger mixed workflow: chain of 10 -> branch 5
    chain_steps =
      for i <- 1..10 do
        make_step(i, "mlg_chain")
      end

    branch_steps =
      for i <- 1..5 do
        make_step(i, "mlg_branch")
      end

    # Wire chain: each step connects to the previous
    wrk =
      chain_steps
      |> Enum.with_index()
      |> Enum.reduce(Workflow.new("mixed_large"), fn
        {step, 0}, wrk ->
          Workflow.add(wrk, step)

        {step, i}, wrk ->
          prev_name = :"mlg_chain_#{i}"
          Workflow.add(wrk, step, to: prev_name)
      end)

    # Wire branches off the last chain step
    last_chain_name = :mlg_chain_10

    Enum.reduce(branch_steps, wrk, fn step, wrk ->
      Workflow.add(wrk, step, to: last_chain_name)
    end)
  end
end

# ==============================================================================
# Build all workflows
# ==============================================================================

IO.puts("\nBuilding canonical test workflows...")

workflows = %{
  # Linear
  linear_small: BaselineBench.Workflows.linear_small(),
  linear_medium: BaselineBench.Workflows.linear_medium(),
  linear_large: BaselineBench.Workflows.linear_large(),
  linear_xlarge: BaselineBench.Workflows.linear_xlarge(),
  # Branching
  branching_small: BaselineBench.Workflows.branching_small(),
  branching_medium: BaselineBench.Workflows.branching_medium(),
  branching_large: BaselineBench.Workflows.branching_large(),
  # Rules
  rules_small: BaselineBench.Workflows.rules_small(),
  rules_medium: BaselineBench.Workflows.rules_medium(),
  rules_large: BaselineBench.Workflows.rules_large(),
  # Accumulators
  accumulator_simple: BaselineBench.Workflows.accumulator_simple(),
  accumulator_downstream: BaselineBench.Workflows.accumulator_with_downstream(),
  accumulator_rule: BaselineBench.Workflows.accumulator_with_rule(),
  # Joins
  join_simple: BaselineBench.Workflows.join_simple(),
  join_deep: BaselineBench.Workflows.join_deep(),
  # Fan-out / Fan-in
  fanout_small: BaselineBench.Workflows.fanout_small(),
  fanout_medium: BaselineBench.Workflows.fanout_medium(),
  # Mixed
  mixed_small: BaselineBench.Workflows.mixed_small(),
  mixed_medium: BaselineBench.Workflows.mixed_medium(),
  mixed_large: BaselineBench.Workflows.mixed_large()
}

IO.puts("\nWorkflow structure stats:")
IO.puts(
  String.pad_trailing("  Name", 30) <>
    String.pad_leading("Vertices", 10) <>
    String.pad_leading("Edges", 8) <>
    String.pad_leading("Steps", 8) <>
    String.pad_leading("Conditions", 12)
)
IO.puts("  " <> String.duplicate("-", 66))

for {name, wrk} <- Enum.sort(workflows) do
  verts = map_size(wrk.graph.vertices)
  edges = length(Graph.edges(wrk.graph))
  steps = length(Workflow.steps(wrk))
  conds = length(Workflow.conditions(wrk))

  IO.puts(
    String.pad_trailing("  #{name}", 30) <>
      String.pad_leading("#{verts}", 10) <>
      String.pad_leading("#{edges}", 8) <>
      String.pad_leading("#{steps}", 8) <>
      String.pad_leading("#{conds}", 12)
  )
end

# ==============================================================================
# Helpers
# ==============================================================================

defmodule BaselineBench.Helpers do
  @moduledoc false

  def memory_bytes(term), do: :erts_debug.flat_size(term) * :erlang.system_info(:wordsize)

  def run_multi_input(workflow, count) do
    Enum.reduce(1..count, workflow, fn i, w ->
      Workflow.react_until_satisfied(w, i)
    end)
  end

  def count_productions(workflow), do: length(Workflow.productions(workflow))

  def count_facts(workflow) do
    workflow.graph.vertices
    |> Map.values()
    |> Enum.count(&is_struct(&1, Runic.Workflow.Fact))
  end
end

# ==============================================================================
# Verify all workflows produce expected results (sanity check)
# ==============================================================================

IO.puts("\nSanity checking all workflows produce results...")

sanity_results =
  for {name, wrk} <- Enum.sort(workflows) do
    input =
      case name do
        n when n in [:fanout_small, :fanout_medium] -> :go
        _ -> 5
      end

    result = Workflow.react_until_satisfied(wrk, input)
    prods = BaselineBench.Helpers.count_productions(result)
    facts = BaselineBench.Helpers.count_facts(result)
    runnable? = Workflow.is_runnable?(result)

    IO.puts("  #{name}: #{prods} productions, #{facts} total facts, runnable?=#{runnable?}")
    {name, prods}
  end

failed = Enum.filter(sanity_results, fn {_name, prods} -> prods == 0 end)

if length(failed) > 0 do
  IO.puts("\n⚠ WARNING: Some workflows produced 0 results:")
  for {name, _} <- failed, do: IO.puts("  - #{name}")
end

IO.puts("")

# ==============================================================================
# BENCHMARK GROUP 1: Linear Pipelines
# ==============================================================================

IO.puts(String.duplicate("=", 80))
IO.puts("BENCHMARK 1: Linear Pipelines (react_until_satisfied)")
IO.puts(String.duplicate("=", 80))

Benchee.run(
  %{
    "linear_5" => fn -> Workflow.react_until_satisfied(workflows.linear_small, 1) end,
    "linear_20" => fn -> Workflow.react_until_satisfied(workflows.linear_medium, 1) end,
    "linear_50" => fn -> Workflow.react_until_satisfied(workflows.linear_large, 1) end,
    "linear_100" => fn -> Workflow.react_until_satisfied(workflows.linear_xlarge, 1) end
  },
  time: 3,
  memory_time: 1,
  warmup: 1,
  print: [configuration: false]
)

# ==============================================================================
# BENCHMARK GROUP 2: Branching Pipelines
# ==============================================================================

IO.puts(String.duplicate("=", 80))
IO.puts("BENCHMARK 2: Branching Pipelines")
IO.puts(String.duplicate("=", 80))

Benchee.run(
  %{
    "branching_5" => fn -> Workflow.react_until_satisfied(workflows.branching_small, 1) end,
    "branching_20" => fn -> Workflow.react_until_satisfied(workflows.branching_medium, 1) end,
    "branching_50" => fn -> Workflow.react_until_satisfied(workflows.branching_large, 1) end
  },
  time: 3,
  memory_time: 1,
  warmup: 1,
  print: [configuration: false]
)

# ==============================================================================
# BENCHMARK GROUP 3: Rules with Conditions
# ==============================================================================

IO.puts(String.duplicate("=", 80))
IO.puts("BENCHMARK 3: Rules with Conditions")
IO.puts(String.duplicate("=", 80))

Benchee.run(
  %{
    "rules_2" => fn -> Workflow.react_until_satisfied(workflows.rules_small, 5) end,
    "rules_10" => fn -> Workflow.react_until_satisfied(workflows.rules_medium, 5) end,
    "rules_25" => fn -> Workflow.react_until_satisfied(workflows.rules_large, 5) end
  },
  time: 3,
  memory_time: 1,
  warmup: 1,
  print: [configuration: false]
)

# ==============================================================================
# BENCHMARK GROUP 4: Accumulators (Stateful)
# ==============================================================================

IO.puts(String.duplicate("=", 80))
IO.puts("BENCHMARK 4: Accumulators")
IO.puts(String.duplicate("=", 80))

Benchee.run(
  %{
    "accumulator_simple" => fn -> Workflow.react_until_satisfied(workflows.accumulator_simple, 5) end,
    "accumulator_downstream" => fn ->
      Workflow.react_until_satisfied(workflows.accumulator_downstream, 5)
    end,
    "accumulator_rule" => fn -> Workflow.react_until_satisfied(workflows.accumulator_rule, 5) end,
    "accumulator_10_inputs" => fn ->
      BaselineBench.Helpers.run_multi_input(workflows.accumulator_simple, 10)
    end,
    "accumulator_50_inputs" => fn ->
      BaselineBench.Helpers.run_multi_input(workflows.accumulator_simple, 50)
    end
  },
  time: 3,
  memory_time: 1,
  warmup: 1,
  print: [configuration: false]
)

# ==============================================================================
# BENCHMARK GROUP 5: Joins
# ==============================================================================

IO.puts(String.duplicate("=", 80))
IO.puts("BENCHMARK 5: Joins")
IO.puts(String.duplicate("=", 80))

Benchee.run(
  %{
    "join_simple" => fn -> Workflow.react_until_satisfied(workflows.join_simple, 5) end,
    "join_deep" => fn -> Workflow.react_until_satisfied(workflows.join_deep, 5) end
  },
  time: 3,
  memory_time: 1,
  warmup: 1,
  print: [configuration: false]
)

# ==============================================================================
# BENCHMARK GROUP 6: Fan-out / Fan-in
# ==============================================================================

IO.puts(String.duplicate("=", 80))
IO.puts("BENCHMARK 6: Fan-out / Fan-in (Map-Reduce)")
IO.puts(String.duplicate("=", 80))

Benchee.run(
  %{
    "fanout_4_items" => fn -> Workflow.react_until_satisfied(workflows.fanout_small, :go) end,
    "fanout_10_items" => fn -> Workflow.react_until_satisfied(workflows.fanout_medium, :go) end
  },
  time: 3,
  memory_time: 1,
  warmup: 1,
  print: [configuration: false]
)

# ==============================================================================
# BENCHMARK GROUP 7: Mixed / Composite
# ==============================================================================

IO.puts(String.duplicate("=", 80))
IO.puts("BENCHMARK 7: Mixed / Composite Workflows")
IO.puts(String.duplicate("=", 80))

Benchee.run(
  %{
    "mixed_small" => fn -> Workflow.react_until_satisfied(workflows.mixed_small, 5) end,
    "mixed_medium" => fn -> Workflow.react_until_satisfied(workflows.mixed_medium, 5) end,
    "mixed_large" => fn -> Workflow.react_until_satisfied(workflows.mixed_large, 5) end
  },
  time: 3,
  memory_time: 1,
  warmup: 1,
  print: [configuration: false]
)

# ==============================================================================
# BENCHMARK GROUP 8: Long-Running (Multiple Inputs)
# ==============================================================================

IO.puts(String.duplicate("=", 80))
IO.puts("BENCHMARK 8: Long-Running Workflows (Multiple Inputs)")
IO.puts(String.duplicate("=", 80))

Benchee.run(
  %{
    "linear_20x10_inputs" => fn ->
      BaselineBench.Helpers.run_multi_input(workflows.linear_medium, 10)
    end,
    "linear_20x50_inputs" => fn ->
      BaselineBench.Helpers.run_multi_input(workflows.linear_medium, 50)
    end,
    "branching_20x10_inputs" => fn ->
      BaselineBench.Helpers.run_multi_input(workflows.branching_medium, 10)
    end,
    "branching_20x50_inputs" => fn ->
      BaselineBench.Helpers.run_multi_input(workflows.branching_medium, 50)
    end,
    "mixed_medium_x10_inputs" => fn ->
      BaselineBench.Helpers.run_multi_input(workflows.mixed_medium, 10)
    end
  },
  time: 3,
  memory_time: 1,
  warmup: 1,
  print: [configuration: false]
)

# ==============================================================================
# BENCHMARK GROUP 9: Three-Phase Dispatch Overhead
# ==============================================================================

IO.puts(String.duplicate("=", 80))
IO.puts("BENCHMARK 9: Prepare/Execute/Apply Overhead (per-cycle)")
IO.puts(String.duplicate("=", 80))
IO.puts("Measures the individual phases of a single reaction cycle.\n")

# Pre-plan workflows to isolate phase performance
planned_linear = Workflow.plan_eagerly(workflows.linear_medium, 1)
planned_branching = Workflow.plan_eagerly(workflows.branching_medium, 1)

Benchee.run(
  %{
    "prepare_dispatch (linear_20)" => fn ->
      Workflow.prepare_for_dispatch(planned_linear)
    end,
    "prepare_dispatch (branching_20)" => fn ->
      Workflow.prepare_for_dispatch(planned_branching)
    end,
    "full_react_cycle (linear_20)" => fn ->
      {wrk, runnables} = Workflow.prepare_for_dispatch(planned_linear)

      Enum.reduce(runnables, wrk, fn runnable, wrk ->
        executed = Runic.Workflow.Invokable.execute(runnable.node, runnable)
        Workflow.apply_runnable(wrk, executed)
      end)
    end,
    "full_react_cycle (branching_20)" => fn ->
      {wrk, runnables} = Workflow.prepare_for_dispatch(planned_branching)

      Enum.reduce(runnables, wrk, fn runnable, wrk ->
        executed = Runic.Workflow.Invokable.execute(runnable.node, runnable)
        Workflow.apply_runnable(wrk, executed)
      end)
    end
  },
  time: 3,
  memory_time: 1,
  warmup: 1,
  print: [configuration: false]
)

# ==============================================================================
# BENCHMARK GROUP 10: Serial vs Async (Branching / Rules)
# ==============================================================================

concurrency = System.schedulers_online()

IO.puts(String.duplicate("=", 80))
IO.puts("BENCHMARK 10: Serial vs Async — Branching & Rules")
IO.puts("System schedulers: #{concurrency}")
IO.puts(String.duplicate("=", 80))

Benchee.run(
  %{
    "branching_20 serial" => fn ->
      Workflow.react_until_satisfied(workflows.branching_medium, 1)
    end,
    "branching_20 async" => fn ->
      Workflow.react_until_satisfied(workflows.branching_medium, 1,
        async: true, max_concurrency: concurrency, timeout: :infinity)
    end,
    "branching_50 serial" => fn ->
      Workflow.react_until_satisfied(workflows.branching_large, 1)
    end,
    "branching_50 async" => fn ->
      Workflow.react_until_satisfied(workflows.branching_large, 1,
        async: true, max_concurrency: concurrency, timeout: :infinity)
    end,
    "rules_25 serial" => fn ->
      Workflow.react_until_satisfied(workflows.rules_large, 5)
    end,
    "rules_25 async" => fn ->
      Workflow.react_until_satisfied(workflows.rules_large, 5,
        async: true, max_concurrency: concurrency, timeout: :infinity)
    end
  },
  time: 3,
  memory_time: 1,
  warmup: 1,
  print: [configuration: false]
)

# ==============================================================================
# BENCHMARK GROUP 11: Serial vs Async — Joins
# ==============================================================================

IO.puts(String.duplicate("=", 80))
IO.puts("BENCHMARK 11: Serial vs Async — Joins")
IO.puts(String.duplicate("=", 80))

Benchee.run(
  %{
    "join_simple serial" => fn ->
      Workflow.react_until_satisfied(workflows.join_simple, 5)
    end,
    "join_simple async" => fn ->
      Workflow.react_until_satisfied(workflows.join_simple, 5,
        async: true, max_concurrency: concurrency, timeout: :infinity)
    end,
    "join_deep serial" => fn ->
      Workflow.react_until_satisfied(workflows.join_deep, 5)
    end,
    "join_deep async" => fn ->
      Workflow.react_until_satisfied(workflows.join_deep, 5,
        async: true, max_concurrency: concurrency, timeout: :infinity)
    end
  },
  time: 3,
  memory_time: 1,
  warmup: 1,
  print: [configuration: false]
)

# ==============================================================================
# BENCHMARK GROUP 12: Serial vs Async — Fan-out / Fan-in
# ==============================================================================

IO.puts(String.duplicate("=", 80))
IO.puts("BENCHMARK 12: Serial vs Async — Fan-out / Fan-in")
IO.puts(String.duplicate("=", 80))

Benchee.run(
  %{
    "fanout_4 serial" => fn ->
      Workflow.react_until_satisfied(workflows.fanout_small, :go)
    end,
    "fanout_4 async" => fn ->
      Workflow.react_until_satisfied(workflows.fanout_small, :go,
        async: true, max_concurrency: concurrency, timeout: :infinity)
    end,
    "fanout_10 serial" => fn ->
      Workflow.react_until_satisfied(workflows.fanout_medium, :go)
    end,
    "fanout_10 async" => fn ->
      Workflow.react_until_satisfied(workflows.fanout_medium, :go,
        async: true, max_concurrency: concurrency, timeout: :infinity)
    end
  },
  time: 3,
  memory_time: 1,
  warmup: 1,
  print: [configuration: false]
)

# ==============================================================================
# BENCHMARK GROUP 13: Serial vs Async — Mixed Composite
# ==============================================================================

IO.puts(String.duplicate("=", 80))
IO.puts("BENCHMARK 13: Serial vs Async — Mixed Composite")
IO.puts(String.duplicate("=", 80))

Benchee.run(
  %{
    "mixed_medium serial" => fn ->
      Workflow.react_until_satisfied(workflows.mixed_medium, 5)
    end,
    "mixed_medium async" => fn ->
      Workflow.react_until_satisfied(workflows.mixed_medium, 5,
        async: true, max_concurrency: concurrency, timeout: :infinity)
    end,
    "mixed_large serial" => fn ->
      Workflow.react_until_satisfied(workflows.mixed_large, 5)
    end,
    "mixed_large async" => fn ->
      Workflow.react_until_satisfied(workflows.mixed_large, 5,
        async: true, max_concurrency: concurrency, timeout: :infinity)
    end
  },
  time: 3,
  memory_time: 1,
  warmup: 1,
  print: [configuration: false]
)

# ==============================================================================
# BENCHMARK GROUP 14: Serial vs Async — Long-Running with Concurrency
# ==============================================================================

IO.puts(String.duplicate("=", 80))
IO.puts("BENCHMARK 14: Serial vs Async — Long-Running (Multiple Inputs)")
IO.puts(String.duplicate("=", 80))

defmodule BaselineBench.AsyncHelpers do
  @moduledoc false

  def run_multi_input_async(workflow, count, opts) do
    Enum.reduce(1..count, workflow, fn i, w ->
      Workflow.react_until_satisfied(w, i, opts)
    end)
  end
end

async_opts = [async: true, max_concurrency: concurrency, timeout: :infinity]

Benchee.run(
  %{
    "branching_20x10 serial" => fn ->
      BaselineBench.Helpers.run_multi_input(workflows.branching_medium, 10)
    end,
    "branching_20x10 async" => fn ->
      BaselineBench.AsyncHelpers.run_multi_input_async(workflows.branching_medium, 10, async_opts)
    end,
    "mixed_medium_x10 serial" => fn ->
      BaselineBench.Helpers.run_multi_input(workflows.mixed_medium, 10)
    end,
    "mixed_medium_x10 async" => fn ->
      BaselineBench.AsyncHelpers.run_multi_input_async(workflows.mixed_medium, 10, async_opts)
    end
  },
  time: 3,
  memory_time: 1,
  warmup: 1,
  print: [configuration: false]
)

# ==============================================================================
# Memory Footprint Summary
# ==============================================================================

IO.puts(String.duplicate("=", 80))
IO.puts("MEMORY FOOTPRINT")
IO.puts(String.duplicate("=", 80))

IO.puts(
  "\n" <>
    String.pad_trailing("  Workflow", 30) <>
    String.pad_leading("Pre (KB)", 10) <>
    String.pad_leading("Post (KB)", 10) <>
    String.pad_leading("Growth", 10) <>
    String.pad_leading("Facts", 8) <>
    String.pad_leading("B/Fact", 10)
)

IO.puts("  " <> String.duplicate("-", 76))

for {name, wrk} <- Enum.sort(workflows) do
  input =
    case name do
      n when n in [:fanout_small, :fanout_medium] -> :go
      _ -> 5
    end

  executed = Workflow.react_until_satisfied(wrk, input)
  pre = BaselineBench.Helpers.memory_bytes(wrk)
  post = BaselineBench.Helpers.memory_bytes(executed)
  facts = BaselineBench.Helpers.count_facts(executed)
  growth = post - pre
  per_fact = if facts > 0, do: div(growth, facts), else: 0

  IO.puts(
    String.pad_trailing("  #{name}", 30) <>
      String.pad_leading("#{Float.round(pre / 1024, 1)}", 10) <>
      String.pad_leading("#{Float.round(post / 1024, 1)}", 10) <>
      String.pad_leading("#{Float.round(growth / 1024, 1)}", 10) <>
      String.pad_leading("#{facts}", 8) <>
      String.pad_leading("#{per_fact}", 10)
  )
end

IO.puts("\n" <> String.duplicate("=", 80))
IO.puts("BASELINE BENCHMARK COMPLETE")
IO.puts(String.duplicate("=", 80))
IO.puts("\nTo compare against the event-sourced model, save this output and re-run")
IO.puts("after implementing the event-sourced aggregate model.")
