defmodule Runic.Bench.OwnerExecution.Support do
  @moduledoc false

  @memory_keys [:total, :processes, :binary, :ets]
  @owner_module Runic.Workflow.Dispatch.Admission

  def options!(switches, defaults) do
    {options, arguments, invalid} = OptionParser.parse(System.argv(), strict: switches)

    if arguments != [] or invalid != [] do
      raise ArgumentError,
            "invalid benchmark arguments: #{inspect(arguments ++ invalid)}"
    end

    Keyword.merge(defaults, options)
  end

  def positive_integer!(options, key) do
    case Keyword.fetch!(options, key) do
      value when is_integer(value) and value > 0 -> value
      value -> raise ArgumentError, "--#{key} must be a positive integer, got: #{inspect(value)}"
    end
  end

  def engine!(options) do
    case Keyword.fetch!(options, :engine) do
      "legacy" ->
        :legacy

      "owner" ->
        if Code.ensure_loaded?(@owner_module) do
          :owner
        else
          raise ArgumentError,
                "--engine owner requires the owner-local dispatch implementation"
        end

      value ->
        raise ArgumentError, "--engine must be legacy or owner, got: #{inspect(value)}"
    end
  end

  def measure(work, interval_ms \\ 5) when is_function(work, 0) do
    :erlang.garbage_collect()
    baseline = memory()
    sampler = spawn_link(fn -> sample_loop(baseline, 1, interval_ms) end)
    started_at = System.monotonic_time(:millisecond)

    try do
      result = work.()
      elapsed_ms = System.monotonic_time(:millisecond) - started_at
      {peak, final, samples} = stop_sampler(sampler)

      %{
        result: result,
        elapsed_ms: elapsed_ms,
        baseline: baseline,
        peak: peak,
        peak_increase: difference(peak, baseline),
        final: final,
        samples: samples
      }
    after
      if Process.alive?(sampler), do: send(sampler, :stop)
    end
  end

  def print(title, metadata, report) do
    IO.puts(title)
    Enum.each(metadata, fn {key, value} -> IO.puts("#{key}=#{value}") end)
    IO.puts("elapsed_ms=#{report.elapsed_ms}")
    IO.puts("samples=#{report.samples}")
    IO.puts("memory_bytes=baseline | peak | increase | final")

    Enum.each(@memory_keys, fn key ->
      IO.puts(
        "#{key}=#{report.baseline[key]} | #{report.peak[key]} | " <>
          "#{report.peak_increase[key]} | #{report.final[key]}"
      )
    end)
  end

  defp stop_sampler(sampler) do
    ref = make_ref()
    send(sampler, {:stop, self(), ref})

    receive do
      {^ref, peak, final, samples} -> {peak, final, samples}
    after
      5_000 -> raise "memory sampler did not stop"
    end
  end

  defp sample_loop(peak, samples, interval_ms) do
    receive do
      {:stop, caller, ref} ->
        final = memory()
        send(caller, {ref, maximum(peak, final), final, samples + 1})

      :stop ->
        :ok
    after
      interval_ms ->
        sample_loop(maximum(peak, memory()), samples + 1, interval_ms)
    end
  end

  defp memory do
    :erlang.memory()
    |> Map.new()
    |> Map.take(@memory_keys)
  end

  defp maximum(left, right) do
    Map.new(@memory_keys, fn key -> {key, max(left[key], right[key])} end)
  end

  defp difference(left, right) do
    Map.new(@memory_keys, fn key -> {key, left[key] - right[key]} end)
  end
end
