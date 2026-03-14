# Quick memory measurement for rehydration strategies
# Focuses on total memory (including refc binaries) for large-value workflows
# Run with: mix run bench/rehydration_memory_quick.exs

require Runic

alias Runic.Workflow
alias Runic.Workflow.{Fact, FactRef, Facts, FactResolver, Rehydration}
alias Runic.Workflow.Components

defmodule QuickBench.Helpers do
  @moduledoc false
  alias Runic.Workflow.{Fact, FactRef, Facts, FactResolver, Rehydration}

  def flat_bytes(term), do: :erts_debug.flat_size(term) * :erlang.system_info(:wordsize)
  def total_bytes(term), do: :erlang.external_size(term)

  def count_all_facts(wf) do
    wf.graph.vertices |> Map.values()
    |> Enum.count(fn v -> is_struct(v, Fact) or is_struct(v, FactRef) end)
  end

  def build_fact_store(wf) do
    table = :ets.new(:qb_facts, [:set, :public, read_concurrency: true])
    for v <- Graph.vertices(wf.graph), is_struct(v, Fact) do
      :ets.insert(table, {v.hash, v.value})
    end
    table
  end

  def rehydrate_lazy(wf, store) do
    all = for v <- Graph.vertices(wf.graph), is_struct(v, Fact), into: MapSet.new(), do: v.hash
    {Rehydration.dehydrate(wf, all), FactResolver.new(store)}
  end

  def rehydrate_hybrid(wf, store), do: Rehydration.rehydrate(wf, store)
end

defmodule QuickBench.FactStore do
  def load_fact(hash, table) do
    case :ets.lookup(table, hash) do
      [{^hash, value}] -> {:ok, value}
      [] -> {:error, :not_found}
    end
  end
end

defmodule QuickBench.Workflows do
  require Runic
  alias Runic.Workflow

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

  defp make_step(i, prefix) do
    work = fn x -> x + 1 end
    name = :"#{prefix}_#{i}"
    hash = Components.fact_hash({work, name})
    Runic.Workflow.Step.new(work: work, name: name, hash: hash)
  end

  def linear_chain(depth, prefix) do
    steps = for i <- 0..(depth-1), do: make_step(i, prefix)
    chain = Enum.reduce(Enum.reverse(steps), nil, fn s, nil -> s; s, c -> {s, [c]} end)
    Runic.workflow(name: "#{prefix}_#{depth}", steps: [chain])
  end

  def large_linear(depth, payload_size, prefix) do
    steps = for i <- 0..(depth-1), do: make_payload_step(i, prefix, payload_size)
    chain = Enum.reduce(Enum.reverse(steps), nil, fn s, nil -> s; s, c -> {s, [c]} end)
    Runic.workflow(name: "#{prefix}_#{depth}", steps: [chain])
  end

  def large_accumulator(payload_size) do
    padding = :crypto.strong_rand_bytes(payload_size)
    acc = Runic.accumulator([], fn x, state -> [%{input: x, payload: padding} | state] end, name: :lg_acc)
    summary = Runic.step(fn entries -> %{count: length(entries), latest: hd(entries)} end, name: :lg_summary)
    Runic.workflow(name: "lg_acc") |> Workflow.add(acc) |> Workflow.add(summary, to: :lg_acc)
  end

  def small_accumulator do
    acc = Runic.accumulator(0, fn x, state -> x + state end, name: :sm_acc)
    post = Runic.step(fn x -> x * 2 end, name: :sm_post)
    Runic.workflow(name: "sm_acc") |> Workflow.add(acc) |> Workflow.add(post, to: :sm_acc)
  end
end

alias QuickBench.{Helpers, Workflows}

# Build and execute workflows
scenarios = [
  # Small-value baselines
  {"linear_50 (int)", Workflows.linear_chain(50, "sm"), [5]},
  {"long_100 (int)", Workflows.small_accumulator(), Enum.to_list(1..100)},

  # Large-value: linear chains
  {"linear_10×1KB", Workflows.large_linear(10, 1_024, "l1k"), [%{seed: 1}]},
  {"linear_10×10KB", Workflows.large_linear(10, 10_240, "l10k"), [%{seed: 1}]},
  {"linear_10×100KB", Workflows.large_linear(10, 102_400, "l100k"), [%{seed: 1}]},
  {"linear_20×10KB", Workflows.large_linear(20, 10_240, "l20_10k"), [%{seed: 1}]},

  # Large-value: long-running accumulators
  {"long_10×1KB", Workflows.large_accumulator(1_024), Enum.to_list(1..10)},
  {"long_50×1KB", Workflows.large_accumulator(1_024), Enum.to_list(1..50)},
  {"long_10×10KB", Workflows.large_accumulator(10_240), Enum.to_list(1..10)},
  {"long_50×10KB", Workflows.large_accumulator(10_240), Enum.to_list(1..50)},
  {"long_10×100KB", Workflows.large_accumulator(102_400), Enum.to_list(1..10)},
  {"long_50×100KB", Workflows.large_accumulator(102_400), Enum.to_list(1..50)},
]

IO.puts("\n" <> String.duplicate("=", 80))
IO.puts("TOTAL MEMORY COMPARISON (flat_size vs external_size)")
IO.puts("flat_size: struct overhead only (excludes refc binaries >64B)")
IO.puts("external_size: full serialized size (includes all binary content)")
IO.puts(String.duplicate("=", 80))

IO.puts(
  "\n" <>
    String.pad_trailing("  Scenario", 24) <>
    String.pad_leading("Facts", 6) <>
    String.pad_leading("Hot", 5) <>
    String.pad_leading("Cold", 5) <>
    "  │" <>
    String.pad_leading("Full(flat)", 11) <>
    String.pad_leading("Hyb(flat)", 11) <>
    String.pad_leading("Δ flat", 8) <>
    "  │" <>
    String.pad_leading("Full(ext)", 11) <>
    String.pad_leading("Hyb(ext)", 11) <>
    String.pad_leading("Δ ext", 8) <>
    String.pad_leading("Lazy(ext)", 11) <>
    String.pad_leading("Δ lazy", 8)
)

IO.puts("  " <> String.duplicate("-", 128))

for {label, wf, inputs} <- scenarios do
  executed = Enum.reduce(inputs, wf, fn i, w -> Workflow.react_until_satisfied(w, i) end)
  table = Helpers.build_fact_store(executed)
  store = {QuickBench.FactStore, table}

  {hybrid_wf, _} = Helpers.rehydrate_hybrid(executed, store)
  {lazy_wf, _} = Helpers.rehydrate_lazy(executed, store)

  %{hot: hot, cold: cold} = Rehydration.classify(executed)
  total_facts = Helpers.count_all_facts(executed)

  full_flat = Helpers.flat_bytes(executed)
  hybrid_flat = Helpers.flat_bytes(hybrid_wf)
  full_ext = Helpers.total_bytes(executed)
  hybrid_ext = Helpers.total_bytes(hybrid_wf)
  lazy_ext = Helpers.total_bytes(lazy_wf)

  flat_pct = if full_flat > 0, do: Float.round((1 - hybrid_flat/full_flat) * 100, 1), else: 0.0
  ext_pct = if full_ext > 0, do: Float.round((1 - hybrid_ext/full_ext) * 100, 1), else: 0.0
  lazy_pct = if full_ext > 0, do: Float.round((1 - lazy_ext/full_ext) * 100, 1), else: 0.0

  fmt_kb = fn bytes -> "#{Float.round(bytes / 1024, 1)}KB" end

  IO.puts(
    String.pad_trailing("  #{label}", 24) <>
      String.pad_leading("#{total_facts}", 6) <>
      String.pad_leading("#{MapSet.size(hot)}", 5) <>
      String.pad_leading("#{MapSet.size(cold)}", 5) <>
      "  │" <>
      String.pad_leading(fmt_kb.(full_flat), 11) <>
      String.pad_leading(fmt_kb.(hybrid_flat), 11) <>
      String.pad_leading("#{flat_pct}%", 8) <>
      "  │" <>
      String.pad_leading(fmt_kb.(full_ext), 11) <>
      String.pad_leading(fmt_kb.(hybrid_ext), 11) <>
      String.pad_leading("#{ext_pct}%", 8) <>
      String.pad_leading(fmt_kb.(lazy_ext), 11) <>
      String.pad_leading("#{lazy_pct}%", 8)
  )

  :ets.delete(table)
end

IO.puts("\n" <> String.duplicate("=", 80))
IO.puts("DONE")
IO.puts(String.duplicate("=", 80))
