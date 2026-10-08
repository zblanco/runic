defmodule Runic.Bench.Issue19.Measure do
  @moduledoc false
  alias Runic.Bench.Issue19.Runner

  def timing(config) do
    isolated(fn ->
      {microseconds, result} = :timer.tc(fn -> Runner.run(config) end)
      Map.put(result, :elapsed_us, microseconds)
    end)
  end

  def envelopes(config), do: isolated(fn -> Runner.run(config, true) end)

  def isolated(fun) do
    parent = self()
    {pid, ref} = spawn_monitor(fn -> send(parent, {:done, self(), fun.()}) end)

    receive do
      {:done, ^pid, result} ->
        receive do
          {:DOWN, ^ref, :process, ^pid, :normal} -> result
        end

      {:DOWN, ^ref, :process, ^pid, reason} ->
        raise inspect(reason)
    after
      300_000 ->
        Process.exit(pid, :kill)
        raise "sample timeout"
    end
  end

  def memory(config) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        receive do
          :go ->
            result = Runner.run(config)
            send(parent, {:done, self(), result})
        end
      end)

    :erlang.trace(pid, true, [:procs, :set_on_spawn])
    send(pid, :go)

    sample(
      pid,
      ref,
      MapSet.new([pid]),
      %{
        owner_peak_bytes: 0,
        tree_peak_bytes: 0,
        referenced_binary_peak_bytes: 0,
        descendant_count: 0
      },
      System.monotonic_time(:millisecond)
    )
  end

  defp sample(pid, ref, live, peaks, last) do
    now = System.monotonic_time(:millisecond)
    {peaks, last} = if now - last >= 2, do: {observe(pid, live, peaks), now}, else: {peaks, last}

    receive do
      {:trace, _, :spawn, child, _} ->
        sample(
          pid,
          ref,
          MapSet.put(live, child),
          %{peaks | descendant_count: peaks.descendant_count + 1},
          last
        )

      {:trace, exited, :exit, _} ->
        sample(pid, ref, MapSet.delete(live, exited), peaks, last)

      {:trace, _, _, _} ->
        sample(pid, ref, live, peaks, last)

      {:done, ^pid, result} ->
        receive do
          {:DOWN, ^ref, :process, ^pid, :normal} -> Map.merge(result, peaks)
        end

      {:DOWN, ^ref, :process, ^pid, reason} ->
        raise inspect(reason)
    after
      2 -> sample(pid, ref, live, peaks, last)
    end
  end

  defp observe(owner, live, peaks) do
    {total, owner_bytes, binaries} =
      Enum.reduce(live, {0, 0, %{}}, fn pid, {total, own, bins} ->
        case Process.info(pid, [:memory, :binary]) do
          nil ->
            {total, own, bins}

          info ->
            bytes = info[:memory]

            bins =
              Enum.reduce(info[:binary], bins, fn {id, size, _refs}, acc ->
                Map.put(acc, id, size)
              end)

            {total + bytes, if(pid == owner, do: bytes, else: own), bins}
        end
      end)

    %{
      peaks
      | owner_peak_bytes: max(peaks.owner_peak_bytes, owner_bytes),
        tree_peak_bytes: max(peaks.tree_peak_bytes, total),
        referenced_binary_peak_bytes:
          max(peaks.referenced_binary_peak_bytes, Enum.sum(Map.values(binaries)))
    }
  end
end
