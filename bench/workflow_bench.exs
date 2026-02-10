# Runic Workflow Benchmark Suite
#
# Run with: mix run bench/workflow_bench.exs

alias Runic.Workflow
alias Runic.Workflow.Step
alias Runic.Workflow.Components

IO.puts("\n" <> String.duplicate("=", 80))
IO.puts("RUNIC WORKFLOW BENCHMARKS")
IO.puts(String.duplicate("=", 80))

defmodule BenchWorkflows do
  alias Runic.Workflow.Step
  alias Runic.Workflow.Components

  def make_unique_step(i, prefix \\ "s") do
    work = &Function.identity/1
    name = :"#{prefix}_#{i}"
    hash = Components.fact_hash({work, name})
    Step.new(work: work, name: name, hash: hash)
  end

  def build_linear_chain(depth, prefix) do
    steps =
      for i <- 0..(depth - 1) do
        make_unique_step(i, prefix)
      end

    Enum.reduce(Enum.reverse(steps), nil, fn step, acc ->
      case acc do
        nil -> step
        child -> {step, [child]}
      end
    end)
  end

  def build_branching(count, prefix) do
    root = make_unique_step(0, "#{prefix}_root")
    children = for i <- 1..count, do: make_unique_step(i, prefix)
    {root, children}
  end

  def small_linear do
    chain = build_linear_chain(5, "sl")
    Runic.workflow(name: "small_linear_5", steps: [chain])
  end

  def small_branching do
    tree = build_branching(4, "sb")
    Runic.workflow(name: "small_branching_5", steps: [tree])
  end

  def medium_linear do
    chain = build_linear_chain(20, "ml")
    Runic.workflow(name: "medium_linear_20", steps: [chain])
  end

  def medium_branching do
    tree = build_branching(19, "mb")
    Runic.workflow(name: "medium_branching_20", steps: [tree])
  end

  def large_linear do
    chain = build_linear_chain(50, "ll")
    Runic.workflow(name: "large_linear_50", steps: [chain])
  end

  def large_branching do
    tree = build_branching(49, "lb")
    Runic.workflow(name: "large_branching_50", steps: [tree])
  end

  def xlarge_linear do
    chain = build_linear_chain(200, "xl")
    Runic.workflow(name: "xlarge_linear_200", steps: [chain])
  end
end

defmodule BenchHelpers do
  def get_deepest_fact(workflow) do
    prods = Workflow.productions(workflow)
    if Enum.empty?(prods), do: nil, else: Enum.max_by(prods, &Workflow.ancestry_depth(workflow, &1))
  end

  def count_facts(workflow), do: length(Workflow.productions(workflow))
  def vertex_count(workflow), do: map_size(workflow.graph.vertices)
  def edge_count(workflow), do: length(Graph.edges(workflow.graph))
  def memory_size(term), do: :erts_debug.flat_size(term) * :erlang.system_info(:wordsize)
end

IO.puts("\nBuilding test workflows...")

workflows = %{
  small_linear: BenchWorkflows.small_linear(),
  small_branching: BenchWorkflows.small_branching(),
  medium_linear: BenchWorkflows.medium_linear(),
  medium_branching: BenchWorkflows.medium_branching(),
  large_linear: BenchWorkflows.large_linear(),
  large_branching: BenchWorkflows.large_branching(),
  xlarge_linear: BenchWorkflows.xlarge_linear()
}

IO.puts("\nWorkflow stats:")

for {name, wrk} <- Enum.sort(workflows) do
  IO.puts("  #{name}: #{BenchHelpers.vertex_count(wrk)} vertices, #{BenchHelpers.edge_count(wrk)} edges")
end

IO.puts("")

# ==============================================================================
# BENCHMARK 1: Ancestry Depth Traversal
# ==============================================================================

IO.puts(String.duplicate("-", 80))
IO.puts("BENCHMARK 1: Ancestry Depth Traversal Performance")
IO.puts(String.duplicate("-", 80))
IO.puts("Measures ancestry_depth/2 recursion across causal chains.\n")

ancestry_data =
  for {label, wrk} <- [
        {:small, workflows.small_linear},
        {:medium, workflows.medium_linear},
        {:large, workflows.large_linear},
        {:xlarge, workflows.xlarge_linear}
      ],
      into: %{} do
    executed = Workflow.react_until_satisfied(wrk, 1)
    deepest = BenchHelpers.get_deepest_fact(executed)
    depth = if deepest, do: Workflow.ancestry_depth(executed, deepest), else: 0
    IO.puts("  #{label}: depth=#{depth}, facts=#{BenchHelpers.count_facts(executed)}")
    {label, {executed, deepest}}
  end

IO.puts("")

Benchee.run(
  %{
    "ancestry_depth (depth 5)" => fn ->
      {wrk, fact} = ancestry_data.small
      Workflow.ancestry_depth(wrk, fact)
    end,
    "ancestry_depth (depth 20)" => fn ->
      {wrk, fact} = ancestry_data.medium
      Workflow.ancestry_depth(wrk, fact)
    end,
    "ancestry_depth (depth 50)" => fn ->
      {wrk, fact} = ancestry_data.large
      Workflow.ancestry_depth(wrk, fact)
    end,
    "ancestry_depth (depth 200)" => fn ->
      {wrk, fact} = ancestry_data.xlarge
      Workflow.ancestry_depth(wrk, fact)
    end
  },
  time: 2,
  memory_time: 1,
  warmup: 0.5,
  print: [configuration: false]
)

# ==============================================================================
# BENCHMARK 2: Legacy vs Three-Phase React (Small)
# ==============================================================================

IO.puts(String.duplicate("-", 80))
IO.puts("BENCHMARK 2: Legacy vs Three-Phase React (Small)")
IO.puts(String.duplicate("-", 80))

Benchee.run(
  %{
    "legacy (small_linear)" => fn -> Workflow.react_until_satisfied(workflows.small_linear, 1) end,
    "three_phase (small_linear)" => fn -> Workflow.react_until_satisfied_three_phase(workflows.small_linear, 1) end,
    "legacy (small_branching)" => fn -> Workflow.react_until_satisfied(workflows.small_branching, 1) end,
    "three_phase (small_branching)" => fn -> Workflow.react_until_satisfied_three_phase(workflows.small_branching, 1) end
  },
  time: 2,
  memory_time: 1,
  warmup: 0.5,
  print: [configuration: false]
)

# ==============================================================================
# BENCHMARK 3: Legacy vs Three-Phase React (Medium/Large)
# ==============================================================================

IO.puts(String.duplicate("-", 80))
IO.puts("BENCHMARK 3: Legacy vs Three-Phase React (Medium/Large)")
IO.puts(String.duplicate("-", 80))

Benchee.run(
  %{
    "legacy (medium_linear)" => fn -> Workflow.react_until_satisfied(workflows.medium_linear, 1) end,
    "three_phase (medium_linear)" => fn -> Workflow.react_until_satisfied_three_phase(workflows.medium_linear, 1) end,
    "legacy (large_linear)" => fn -> Workflow.react_until_satisfied(workflows.large_linear, 1) end,
    "three_phase (large_linear)" => fn -> Workflow.react_until_satisfied_three_phase(workflows.large_linear, 1) end
  },
  time: 2,
  memory_time: 1,
  warmup: 0.5,
  print: [configuration: false]
)

Benchee.run(
  %{
    "legacy (medium_branching)" => fn -> Workflow.react_until_satisfied(workflows.medium_branching, 1) end,
    "three_phase (medium_branching)" => fn -> Workflow.react_until_satisfied_three_phase(workflows.medium_branching, 1) end,
    "legacy (large_branching)" => fn -> Workflow.react_until_satisfied(workflows.large_branching, 1) end,
    "three_phase (large_branching)" => fn -> Workflow.react_until_satisfied_three_phase(workflows.large_branching, 1) end
  },
  time: 2,
  memory_time: 1,
  warmup: 0.5,
  print: [configuration: false]
)

# ==============================================================================
# BENCHMARK 4: Serial vs Parallel Execution
# ==============================================================================

IO.puts(String.duplicate("-", 80))
IO.puts("BENCHMARK 4: Serial vs Parallel Execution")
IO.puts(String.duplicate("-", 80))

concurrency = System.schedulers_online()
IO.puts("System schedulers: #{concurrency}\n")

Benchee.run(
  %{
    "serial (medium_branching)" => fn -> Workflow.react_until_satisfied_three_phase(workflows.medium_branching, 1) end,
    "parallel (medium_branching)" => fn -> Workflow.react_until_satisfied_parallel(workflows.medium_branching, 1, max_concurrency: concurrency) end,
    "serial (large_branching)" => fn -> Workflow.react_until_satisfied_three_phase(workflows.large_branching, 1) end,
    "parallel (large_branching)" => fn -> Workflow.react_until_satisfied_parallel(workflows.large_branching, 1, max_concurrency: concurrency) end
  },
  time: 2,
  memory_time: 1,
  warmup: 0.5,
  print: [configuration: false]
)

# ==============================================================================
# BENCHMARK 5: Long-Running (Multiple Inputs)
# ==============================================================================

IO.puts(String.duplicate("-", 80))
IO.puts("BENCHMARK 5: Long-Running Workflows")
IO.puts(String.duplicate("-", 80))

defmodule LongRunning do
  def run_legacy(workflow, count) do
    Enum.reduce(1..count, workflow, fn i, w -> Workflow.react_until_satisfied(w, i) end)
  end

  def run_three_phase(workflow, count) do
    Enum.reduce(1..count, workflow, fn i, w -> Workflow.react_until_satisfied_three_phase(w, i) end)
  end
end

Benchee.run(
  %{
    "legacy 10 inputs" => fn -> LongRunning.run_legacy(workflows.small_linear, 10) end,
    "three_phase 10 inputs" => fn -> LongRunning.run_three_phase(workflows.small_linear, 10) end,
    "legacy 50 inputs" => fn -> LongRunning.run_legacy(workflows.small_linear, 50) end,
    "three_phase 50 inputs" => fn -> LongRunning.run_three_phase(workflows.small_linear, 50) end
  },
  time: 2,
  memory_time: 1,
  warmup: 0.5,
  print: [configuration: false]
)

# Test ancestry depth on accumulated workflows
IO.puts("\nAncestry depth scaling with accumulated facts:")

for input_count <- [10, 50, 100] do
  accumulated = LongRunning.run_legacy(workflows.small_linear, input_count)
  deepest = BenchHelpers.get_deepest_fact(accumulated)
  fact_count = BenchHelpers.count_facts(accumulated)
  vertex_count = BenchHelpers.vertex_count(accumulated)
  depth = Workflow.ancestry_depth(accumulated, deepest)
  IO.puts("  #{input_count} inputs: #{fact_count} facts, #{vertex_count} vertices, deepest_depth=#{depth}")
end

accumulated_100 = LongRunning.run_legacy(workflows.small_linear, 100)
deepest_100 = BenchHelpers.get_deepest_fact(accumulated_100)

Benchee.run(
  %{
    "ancestry_depth (100 inputs)" => fn -> Workflow.ancestry_depth(accumulated_100, deepest_100) end
  },
  time: 2,
  memory_time: 1,
  warmup: 0.5,
  print: [configuration: false]
)

# ==============================================================================
# BENCHMARK 6: Multigraph Index Lookup
# ==============================================================================

IO.puts(String.duplicate("-", 80))
IO.puts("BENCHMARK 6: Graph Edge Lookup (Index vs Filter)")
IO.puts(String.duplicate("-", 80))

planned_small = Workflow.plan_eagerly(workflows.small_linear, 1)
planned_medium = Workflow.plan_eagerly(workflows.medium_linear, 1)
planned_large = Workflow.plan_eagerly(workflows.large_linear, 1)

IO.puts("Edges: small=#{BenchHelpers.edge_count(planned_small)}, medium=#{BenchHelpers.edge_count(planned_medium)}, large=#{BenchHelpers.edge_count(planned_large)}\n")

Benchee.run(
  %{
    "indexed (small)" => fn -> Graph.edges(planned_small.graph, by: [:runnable, :matchable]) end,
    "filter (small)" => fn -> planned_small.graph |> Graph.edges() |> Enum.filter(&(&1.label in [:runnable, :matchable])) end,
    "indexed (medium)" => fn -> Graph.edges(planned_medium.graph, by: [:runnable, :matchable]) end,
    "filter (medium)" => fn -> planned_medium.graph |> Graph.edges() |> Enum.filter(&(&1.label in [:runnable, :matchable])) end,
    "indexed (large)" => fn -> Graph.edges(planned_large.graph, by: [:runnable, :matchable]) end,
    "filter (large)" => fn -> planned_large.graph |> Graph.edges() |> Enum.filter(&(&1.label in [:runnable, :matchable])) end
  },
  time: 2,
  memory_time: 1,
  warmup: 0.5,
  print: [configuration: false]
)

# ==============================================================================
# Memory Footprint
# ==============================================================================

IO.puts(String.duplicate("-", 80))
IO.puts("MEMORY FOOTPRINT")
IO.puts(String.duplicate("-", 80))

IO.puts("\n" <>
  String.pad_trailing("Workflow", 20) <>
  String.pad_leading("Pre", 10) <>
  String.pad_leading("Post", 10) <>
  String.pad_leading("Growth", 10) <>
  String.pad_leading("Facts", 8) <>
  String.pad_leading("B/Fact", 10))
IO.puts(String.duplicate("-", 68))

for {name, wrk} <- Enum.sort(workflows) do
  executed = Workflow.react_until_satisfied(wrk, 1)
  pre = BenchHelpers.memory_size(wrk)
  post = BenchHelpers.memory_size(executed)
  facts = BenchHelpers.count_facts(executed)
  growth = post - pre
  per_fact = if facts > 0, do: div(growth, facts), else: 0

  IO.puts(
    String.pad_trailing(to_string(name), 20) <>
    String.pad_leading(Integer.to_string(pre), 10) <>
    String.pad_leading(Integer.to_string(post), 10) <>
    String.pad_leading(Integer.to_string(growth), 10) <>
    String.pad_leading(Integer.to_string(facts), 8) <>
    String.pad_leading(Integer.to_string(per_fact), 10))
end

IO.puts("\n" <> String.duplicate("=", 80))
IO.puts("BENCHMARK COMPLETE")
IO.puts(String.duplicate("=", 80))
