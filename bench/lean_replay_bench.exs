# Lean Replay & Resume Pipeline Benchmark
#
# Complements rehydration_bench.exs by measuring what it does NOT cover:
#
#   1. Lean replay speed: from_events(events, nil, fact_mode: :ref) vs full replay
#   2. Full resume pipeline: events → lean replay → classify → resolve_hot
#   3. Peak memory during recovery: process memory snapshots around resume paths
#   4. Fused vs two-pass: direct comparison of rehydrate_fused vs classify+dehydrate
#   5. should_rehydrate? heuristic cost: sampling overhead
#   6. Value stripping cost: strip_fact_values at persist time
#   7. resolve_hot in isolation: post-lean-replay hot resolution
#
# Run with: mix run bench/lean_replay_bench.exs

require Runic

alias Runic.Workflow
alias Runic.Workflow.{Fact, FactRef, Facts, FactResolver, Rehydration}
alias Runic.Workflow.Components
alias Runic.Workflow.Events.FactProduced

IO.puts("\n" <> String.duplicate("=", 80))
IO.puts("LEAN REPLAY & RESUME PIPELINE BENCHMARK")
IO.puts("Date: #{DateTime.utc_now() |> DateTime.to_iso8601()}")
IO.puts(String.duplicate("=", 80))

# ==============================================================================
# Helpers
# ==============================================================================

defmodule LeanBench.Helpers do
  @moduledoc false

  alias Runic.Workflow
  alias Runic.Workflow.{Fact, FactRef, FactResolver, Rehydration}
  alias Runic.Workflow.Events.FactProduced

  def memory_bytes(term), do: :erts_debug.flat_size(term) * :erlang.system_info(:wordsize)
  def total_memory_bytes(term), do: :erlang.external_size(term)

  @doc """
  Executes a workflow with event emission enabled, returning
  {executed_workflow, base_workflow, runtime_events, stripped_runtime_events}.

  base_workflow: the pre-execution workflow structure (for from_events base)
  runtime_events: FactProduced, ActivationConsumed, etc. (with values)
  stripped_runtime_events: same but FactProduced.value set to nil
  """
  def execute_with_events(workflow, inputs) when is_list(inputs) do
    base = workflow
    wf = Workflow.enable_event_emission(workflow)

    executed =
      Enum.reduce(inputs, wf, fn input, w ->
        Workflow.react_until_satisfied(w, input)
      end)

    # Runtime events only (no build_log — ComponentAdded events can't be
    # replayed for runtime-constructed steps without closures)
    runtime_events = Enum.reverse(executed.uncommitted_events)

    stripped_events =
      Enum.map(runtime_events, fn
        %FactProduced{} = e -> %{e | value: nil}
        other -> other
      end)

    {executed, base, runtime_events, stripped_events}
  end

  def execute_with_events(workflow, input) do
    execute_with_events(workflow, [input])
  end

  @doc """
  Builds an ETS-backed fact store from a fully-executed workflow.
  Returns {store_mod, table} tuple compatible with FactResolver.
  """
  def build_fact_store(workflow) do
    table = :ets.new(:lean_bench_facts, [:set, :public, read_concurrency: true])

    for {_hash, v} <- workflow.graph.vertices, is_struct(v, Fact) do
      :ets.insert(table, {v.hash, v.value})
    end

    {LeanBench.FactStore, table}
  end

  def cleanup_store({_, table}) do
    try do
      :ets.delete(table)
    rescue
      _ -> :ok
    end
  end

  @doc "Measures process memory after forcing GC. Returns bytes."
  def process_memory do
    :erlang.garbage_collect()
    {:memory, mem} = Process.info(self(), :memory)
    mem
  end

  @doc """
  Measures peak-ish memory of a function by sampling process memory
  before and after, with GC forced before both measurements.
  The result after the call (before GC) approximates peak since
  intermediaries haven't been collected yet.
  """
  def measure_memory(fun) do
    :erlang.garbage_collect()
    before = process_memory()
    result = fun.()
    # Don't GC — we want to see intermediaries still alive
    {:memory, after_mem} = Process.info(self(), :memory)
    {result, after_mem - before}
  end
end

defmodule LeanBench.FactStore do
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
# Workflow Builders (reused patterns from rehydration_bench)
# ==============================================================================

defmodule LeanBench.Workflows do
  @moduledoc false
  require Runic
  alias Runic.Workflow
  alias Runic.Workflow.Components

  defp make_step(i, prefix) do
    work = fn x -> x + 1 end
    name = :"#{prefix}_#{i}"
    hash = Components.fact_hash({work, name})
    Runic.Workflow.Step.new(work: work, name: name, hash: hash)
  end

  defp build_linear_chain(depth, prefix) do
    steps = for i <- 0..(depth - 1), do: make_step(i, prefix)

    Enum.reduce(Enum.reverse(steps), nil, fn step, acc ->
      case acc do
        nil -> step
        child -> {step, [child]}
      end
    end)
  end

  def linear(depth, prefix) do
    chain = build_linear_chain(depth, prefix)
    Runic.workflow(name: "linear_#{depth}", steps: [chain])
  end

  def accumulator do
    acc = Runic.accumulator(0, fn x, state -> x + state end, name: :lb_sum)
    post = Runic.step(fn x -> x * 2 end, name: :lb_double)

    Runic.workflow(name: "accumulator")
    |> Workflow.add(acc)
    |> Workflow.add(post, to: :lb_sum)
  end

  # Large-payload linear chain
  defp make_payload_step(i, prefix, payload_size) do
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

  def large_accumulator(payload_size) do
    padding = :crypto.strong_rand_bytes(payload_size)

    acc =
      Runic.accumulator(
        [],
        fn x, state -> [%{input: x, payload: padding} | state] end,
        name: :lb_lg_acc
      )

    summary =
      Runic.step(fn entries -> %{count: length(entries), latest: hd(entries)} end,
        name: :lb_lg_summary
      )

    Runic.workflow(name: "large_acc_#{payload_size}")
    |> Workflow.add(acc)
    |> Workflow.add(summary, to: :lb_lg_acc)
  end
end

# ==============================================================================
# Build test scenarios
# ==============================================================================

alias LeanBench.{Helpers, Workflows}

IO.puts("\nBuilding and executing workflows with event emission...\n")

scenarios = %{
  # Small-value workflows
  linear_20: {Workflows.linear(20, "lb20"), [5]},
  linear_50: {Workflows.linear(50, "lb50"), [5]},
  long_50: {Workflows.accumulator(), Enum.to_list(1..50)},
  long_100: {Workflows.accumulator(), Enum.to_list(1..100)},

  # Large-value workflows (the key targets)
  lg_linear_10_10k: {Workflows.large_linear(10, 10_240, "lblg10k"), [%{seed: 42}]},
  lg_linear_20_10k: {Workflows.large_linear(20, 10_240, "lblg20_10k"), [%{seed: 42}]},
  lg_long_50_1k: {Workflows.large_accumulator(1_024), Enum.to_list(1..50)},
  lg_long_50_10k: {Workflows.large_accumulator(10_240), Enum.to_list(1..50)},
  lg_long_50_100k: {Workflows.large_accumulator(102_400), Enum.to_list(1..50)}
}

all_data =
  Map.new(scenarios, fn {name, {wf, inputs}} ->
    {executed, base, runtime_events, stripped_events} = Helpers.execute_with_events(wf, inputs)
    store = Helpers.build_fact_store(executed)

    {name, %{
      workflow: executed,
      base: base,
      runtime_events: runtime_events,
      stripped_events: stripped_events,
      store: store
    }}
  end)

# Print scenario stats
IO.puts(
  String.pad_trailing("  Scenario", 24) <>
    String.pad_leading("Events", 8) <>
    String.pad_leading("Facts", 8) <>
    String.pad_leading("Full KB", 10) <>
    String.pad_leading("Ext KB", 10)
)

IO.puts("  " <> String.duplicate("-", 66))

for {name, data} <- Enum.sort(all_data) do
  facts =
    data.workflow.graph.vertices
    |> Map.values()
    |> Enum.count(fn v -> is_struct(v, Fact) end)

  IO.puts(
    String.pad_trailing("  #{name}", 24) <>
      String.pad_leading("#{length(data.runtime_events)}", 8) <>
      String.pad_leading("#{facts}", 8) <>
      String.pad_leading("#{Float.round(Helpers.memory_bytes(data.workflow) / 1024, 1)}", 10) <>
      String.pad_leading("#{Float.round(Helpers.total_memory_bytes(data.workflow) / 1024, 1)}", 10)
  )
end

# ==============================================================================
# BENCHMARK 1: Lean Replay vs Full Replay Speed
# ==============================================================================

IO.puts("\n" <> String.duplicate("=", 80))
IO.puts("BENCHMARK 1: Lean Replay vs Full Replay Speed")
IO.puts("from_events(events) vs from_events(events, nil, fact_mode: :ref)")
IO.puts(String.duplicate("=", 80))

for name <- [:linear_20, :linear_50, :long_50, :long_100,
             :lg_linear_10_10k, :lg_linear_20_10k,
             :lg_long_50_1k, :lg_long_50_10k] do
  data = all_data[name]

  Benchee.run(
    %{
      "#{name} full replay" => fn ->
        Workflow.from_events(data.runtime_events, data.base)
      end,
      "#{name} lean replay (stripped)" => fn ->
        Workflow.from_events(data.stripped_events, data.base, fact_mode: :ref)
      end,
      "#{name} lean replay (full events)" => fn ->
        # Lean replay with events that still have values — tests the fallback
        # apply_event_lean only creates FactRef when value is nil; full-value
        # events fall through to apply_event (creating full Facts)
        Workflow.from_events(data.runtime_events, data.base, fact_mode: :ref)
      end
    },
    time: 2,
    memory_time: 1,
    warmup: 0.5,
    print: [configuration: false]
  )
end

# ==============================================================================
# BENCHMARK 2: Full Resume Pipeline — End-to-End
# ==============================================================================

IO.puts("\n" <> String.duplicate("=", 80))
IO.puts("BENCHMARK 2: Full Resume Pipeline — End-to-End")
IO.puts("Simulates Runner.resume_from_events for each strategy")
IO.puts(String.duplicate("=", 80))

for name <- [:long_100, :lg_linear_10_10k, :lg_linear_20_10k,
             :lg_long_50_1k, :lg_long_50_10k, :lg_long_50_100k] do
  data = all_data[name]

  Benchee.run(
    %{
      "#{name} resume :full" => fn ->
        # Full strategy with stripped events: lean replay + resolve ALL
        wf = Workflow.from_events(data.stripped_events, data.base, fact_mode: :ref)
        all_refs = for {h, %FactRef{}} <- wf.graph.vertices, into: MapSet.new(), do: h
        resolver = FactResolver.new(data.store)
        Rehydration.resolve_hot(wf, all_refs, resolver)
      end,
      "#{name} resume :hybrid" => fn ->
        # Hybrid strategy: lean replay + classify + resolve hot only
        wf = Workflow.from_events(data.stripped_events, data.base, fact_mode: :ref)
        %{hot: hot} = Rehydration.classify(wf)
        resolver = FactResolver.new(data.store)
        Rehydration.resolve_hot(wf, hot, resolver)
      end,
      "#{name} resume :lazy" => fn ->
        # Lazy strategy: lean replay only, no resolution
        wf = Workflow.from_events(data.stripped_events, data.base, fact_mode: :ref)
        {wf, FactResolver.new(data.store)}
      end
    },
    time: 2,
    memory_time: 1,
    warmup: 0.5,
    print: [configuration: false]
  )
end

# ==============================================================================
# BENCHMARK 3: Peak Memory During Recovery
# ==============================================================================

IO.puts("\n" <> String.duplicate("=", 80))
IO.puts("PEAK MEMORY DURING RECOVERY")
IO.puts("Process memory snapshots around resume paths")
IO.puts("(external_size of result workflow = steady-state memory)")
IO.puts(String.duplicate("=", 80))

IO.puts(
  "\n" <>
    String.pad_trailing("  Scenario", 24) <>
    String.pad_leading("Strategy", 10) <>
    String.pad_leading("Proc ΔKB", 10) <>
    String.pad_leading("Result KB", 10) <>
    String.pad_leading("Full KB", 10) <>
    String.pad_leading("Ratio", 8)
)

IO.puts("  " <> String.duplicate("-", 76))

for name <- [:long_100, :lg_linear_10_10k, :lg_linear_20_10k,
             :lg_long_50_1k, :lg_long_50_10k, :lg_long_50_100k] do
  data = all_data[name]
  full_ext = Helpers.total_memory_bytes(data.workflow)

  for {strategy, label} <- [
    {:full, "full"},
    {:hybrid, "hybrid"},
    {:lazy, "lazy"}
  ] do
    {result, proc_delta} =
      Helpers.measure_memory(fn ->
        case strategy do
          :full ->
            wf = Workflow.from_events(data.stripped_events, data.base, fact_mode: :ref)
            all_refs = for {h, %FactRef{}} <- wf.graph.vertices, into: MapSet.new(), do: h
            resolver = FactResolver.new(data.store)
            {wf2, _} = Rehydration.resolve_hot(wf, all_refs, resolver)
            wf2

          :hybrid ->
            wf = Workflow.from_events(data.stripped_events, data.base, fact_mode: :ref)
            %{hot: hot} = Rehydration.classify(wf)
            resolver = FactResolver.new(data.store)
            {wf2, _} = Rehydration.resolve_hot(wf, hot, resolver)
            wf2

          :lazy ->
            Workflow.from_events(data.stripped_events, data.base, fact_mode: :ref)
        end
      end)

    result_ext = Helpers.total_memory_bytes(result)

    ratio =
      if full_ext > 0 do
        Float.round(result_ext / full_ext * 100, 1)
      else
        0.0
      end

    IO.puts(
      String.pad_trailing("  #{name}", 24) <>
        String.pad_leading(label, 10) <>
        String.pad_leading("#{Float.round(proc_delta / 1024, 1)}", 10) <>
        String.pad_leading("#{Float.round(result_ext / 1024, 1)}", 10) <>
        String.pad_leading("#{Float.round(full_ext / 1024, 1)}", 10) <>
        String.pad_leading("#{ratio}%", 8)
    )
  end
end

# ==============================================================================
# BENCHMARK 4: Fused vs Two-Pass Direct Comparison
# ==============================================================================

IO.puts("\n" <> String.duplicate("=", 80))
IO.puts("BENCHMARK 4: Fused vs Two-Pass Rehydration — Direct Comparison")
IO.puts(String.duplicate("=", 80))

for name <- [:long_100, :lg_long_50_1k, :lg_long_50_10k] do
  data = all_data[name]

  Benchee.run(
    %{
      "#{name} two-pass (classify+dehydrate)" => fn ->
        %{cold: cold} = Rehydration.classify(data.workflow)
        Rehydration.dehydrate(data.workflow, cold)
      end,
      "#{name} fused (rehydrate_fused)" => fn ->
        Rehydration.rehydrate_fused(data.workflow, data.store)
      end
    },
    time: 2,
    memory_time: 1,
    warmup: 0.5,
    print: [configuration: false]
  )
end

# ==============================================================================
# BENCHMARK 5: should_rehydrate? Heuristic Cost
# ==============================================================================

IO.puts("\n" <> String.duplicate("=", 80))
IO.puts("BENCHMARK 5: should_rehydrate? Heuristic Sampling Cost")
IO.puts(String.duplicate("=", 80))

heuristic_targets = %{}

heuristic_targets =
  for name <- [:linear_20, :long_100, :lg_linear_10_10k, :lg_long_50_1k, :lg_long_50_10k],
      into: heuristic_targets do
    data = all_data[name]
    result = Rehydration.should_rehydrate?(data.workflow)
    {"#{name} (→#{result})", fn -> Rehydration.should_rehydrate?(data.workflow) end}
  end

Benchee.run(heuristic_targets,
  time: 2,
  memory_time: 1,
  warmup: 0.5,
  print: [configuration: false]
)

# ==============================================================================
# BENCHMARK 6: Value Stripping Cost
# ==============================================================================

IO.puts("\n" <> String.duplicate("=", 80))
IO.puts("BENCHMARK 6: Value Stripping Cost (strip_fact_values at persist time)")
IO.puts(String.duplicate("=", 80))

strip_targets =
  for name <- [:long_100, :lg_linear_10_10k, :lg_long_50_10k, :lg_long_50_100k],
      into: %{} do
    data = all_data[name]
    fact_count = Enum.count(data.runtime_events, &is_struct(&1, FactProduced))

    {"strip #{name} (#{fact_count} FP events)",
     fn ->
       Enum.map(data.runtime_events, fn
         %FactProduced{} = e -> %{e | value: nil}
         other -> other
       end)
     end}
  end

Benchee.run(strip_targets,
  time: 2,
  memory_time: 1,
  warmup: 0.5,
  print: [configuration: false]
)

# ==============================================================================
# BENCHMARK 7: resolve_hot in Isolation
# ==============================================================================

IO.puts("\n" <> String.duplicate("=", 80))
IO.puts("BENCHMARK 7: resolve_hot Performance (post-lean-replay)")
IO.puts(String.duplicate("=", 80))

for name <- [:long_100, :lg_linear_10_10k, :lg_linear_20_10k,
             :lg_long_50_1k, :lg_long_50_10k] do
  data = all_data[name]

  # Pre-build the lean-replayed workflow (all FactRefs)
  lean_wf = Workflow.from_events(data.stripped_events, data.base, fact_mode: :ref)
  %{hot: hot} = Rehydration.classify(lean_wf)
  all_refs = for {h, %FactRef{}} <- lean_wf.graph.vertices, into: MapSet.new(), do: h
  resolver = FactResolver.new(data.store)

  hot_count = MapSet.size(hot)
  all_count = MapSet.size(all_refs)

  Benchee.run(
    %{
      "#{name} resolve_hot (#{hot_count} hot)" => fn ->
        Rehydration.resolve_hot(lean_wf, hot, resolver)
      end,
      "#{name} resolve_all (#{all_count} refs)" => fn ->
        Rehydration.resolve_hot(lean_wf, all_refs, resolver)
      end
    },
    time: 2,
    memory_time: 1,
    warmup: 0.5,
    print: [configuration: false]
  )
end

# ==============================================================================
# SUMMARY: Event Stream Size Comparison
# ==============================================================================

IO.puts("\n" <> String.duplicate("=", 80))
IO.puts("EVENT STREAM SIZE: Full vs Stripped")
IO.puts(String.duplicate("=", 80))

IO.puts(
  "\n" <>
    String.pad_trailing("  Scenario", 24) <>
    String.pad_leading("Events", 8) <>
    String.pad_leading("FP evts", 8) <>
    String.pad_leading("Full KB", 10) <>
    String.pad_leading("Strip KB", 10) <>
    String.pad_leading("Savings%", 10)
)

IO.puts("  " <> String.duplicate("-", 72))

for {name, data} <- Enum.sort(all_data) do
  full_size = Helpers.total_memory_bytes(data.runtime_events)
  strip_size = Helpers.total_memory_bytes(data.stripped_events)
  fp_count = Enum.count(data.runtime_events, &is_struct(&1, FactProduced))

  savings =
    if full_size > 0 do
      Float.round((1.0 - strip_size / full_size) * 100, 1)
    else
      0.0
    end

  IO.puts(
    String.pad_trailing("  #{name}", 24) <>
      String.pad_leading("#{length(data.runtime_events)}", 8) <>
      String.pad_leading("#{fp_count}", 8) <>
      String.pad_leading("#{Float.round(full_size / 1024, 1)}", 10) <>
      String.pad_leading("#{Float.round(strip_size / 1024, 1)}", 10) <>
      String.pad_leading("#{savings}%", 10)
  )
end

# ==============================================================================
# SUMMARY: Lean Replay Memory Savings
# ==============================================================================

IO.puts("\n" <> String.duplicate("=", 80))
IO.puts("LEAN REPLAY MEMORY: Workflow size after each replay mode")
IO.puts("(external_size — includes binary content)")
IO.puts(String.duplicate("=", 80))

IO.puts(
  "\n" <>
    String.pad_trailing("  Scenario", 24) <>
    String.pad_leading("Full KB", 10) <>
    String.pad_leading("Lean KB", 10) <>
    String.pad_leading("Hybrid KB", 12) <>
    String.pad_leading("Lean sav%", 10) <>
    String.pad_leading("Hybr sav%", 10) <>
    String.pad_leading("Hot", 6) <>
    String.pad_leading("Cold", 6)
)

IO.puts("  " <> String.duplicate("-", 86))

for {name, data} <- Enum.sort(all_data) do
  # Full replay (traditional)
  full_wf = Workflow.from_events(data.runtime_events, data.base)
  full_ext = Helpers.total_memory_bytes(full_wf)

  # Lean replay (all FactRefs)
  lean_wf = Workflow.from_events(data.stripped_events, data.base, fact_mode: :ref)
  lean_ext = Helpers.total_memory_bytes(lean_wf)

  # Hybrid resume: lean replay + classify + resolve hot
  %{hot: hot, cold: cold} = Rehydration.classify(lean_wf)
  resolver = FactResolver.new(data.store)
  {hybrid_wf, _} = Rehydration.resolve_hot(lean_wf, hot, resolver)
  hybrid_ext = Helpers.total_memory_bytes(hybrid_wf)

  lean_sav = if full_ext > 0, do: Float.round((1.0 - lean_ext / full_ext) * 100, 1), else: 0.0
  hybrid_sav = if full_ext > 0, do: Float.round((1.0 - hybrid_ext / full_ext) * 100, 1), else: 0.0

  IO.puts(
    String.pad_trailing("  #{name}", 24) <>
      String.pad_leading("#{Float.round(full_ext / 1024, 1)}", 10) <>
      String.pad_leading("#{Float.round(lean_ext / 1024, 1)}", 10) <>
      String.pad_leading("#{Float.round(hybrid_ext / 1024, 1)}", 12) <>
      String.pad_leading("#{lean_sav}%", 10) <>
      String.pad_leading("#{hybrid_sav}%", 10) <>
      String.pad_leading("#{MapSet.size(hot)}", 6) <>
      String.pad_leading("#{MapSet.size(cold)}", 6)
  )
end

# ==============================================================================
# Cleanup
# ==============================================================================

for {_name, data} <- all_data do
  Helpers.cleanup_store(data.store)
end

IO.puts("\n" <> String.duplicate("=", 80))
IO.puts("LEAN REPLAY BENCHMARK COMPLETE")
IO.puts(String.duplicate("=", 80))
