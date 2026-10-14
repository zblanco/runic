defmodule Runic.TestSupport.SnapshotTailStore do
  @behaviour Runic.Runner.Store

  @impl Runic.Runner.Store
  def init_store(opts) do
    runner_name = Keyword.fetch!(opts, :runner_name)

    events_table = Module.concat(runner_name, SnapshotTailEvents)
    counters_table = Module.concat(runner_name, SnapshotTailCounters)
    snapshots_table = Module.concat(runner_name, SnapshotTailSnapshots)
    calls_table = Module.concat(runner_name, SnapshotTailCalls)
    facts_table = Module.concat(runner_name, SnapshotTailFacts)

    ensure_table(events_table, [:ordered_set])
    ensure_table(counters_table, [:set])
    ensure_table(snapshots_table, [:set])
    ensure_table(calls_table, [:set])
    ensure_table(facts_table, [:set])

    {:ok,
     %{
       events_table: events_table,
       counters_table: counters_table,
       snapshots_table: snapshots_table,
       calls_table: calls_table,
       facts_table: facts_table
     }}
  end

  @impl Runic.Runner.Store
  def save_fact(hash, value, %{facts_table: facts_table}) do
    :ets.insert(facts_table, {hash, value})
    :ok
  end

  @impl Runic.Runner.Store
  def load_fact(hash, %{facts_table: facts_table}) do
    case :ets.lookup(facts_table, hash) do
      [{^hash, value}] -> {:ok, value}
      [] -> {:error, :not_found}
    end
  end

  @impl Runic.Runner.Store
  def save(_workflow_id, _log, _state), do: :ok

  @impl Runic.Runner.Store
  def load(_workflow_id, _state), do: {:error, :not_found}

  @impl Runic.Runner.Store
  def append(workflow_id, events, %{events_table: events_table, counters_table: counters_table})
      when is_list(events) do
    count = length(events)
    cursor = :ets.update_counter(counters_table, workflow_id, {2, count}, {workflow_id, 0})
    start_seq = cursor - count + 1

    events
    |> Enum.with_index(start_seq)
    |> Enum.each(fn {event, seq} ->
      :ets.insert(events_table, {{workflow_id, seq}, event})
    end)

    {:ok, cursor}
  end

  @impl Runic.Runner.Store
  def stream(workflow_id, %{calls_table: calls_table} = state) do
    increment_call(calls_table, {:stream, workflow_id})
    stream_from(workflow_id, 1, state)
  end

  @impl Runic.Runner.Store
  def stream(workflow_id, %{calls_table: calls_table} = state, opts) when is_list(opts) do
    cursor = Keyword.get(opts, :after_cursor, 0)
    increment_call(calls_table, {:stream, workflow_id, opts_key(opts)})
    stream_from(workflow_id, cursor + 1, state)
  end

  @impl Runic.Runner.Store
  def save_snapshot(workflow_id, cursor, snapshot, %{snapshots_table: snapshots_table})
      when is_integer(cursor) and is_binary(snapshot) do
    :ets.insert(snapshots_table, {workflow_id, cursor, snapshot})
    :ok
  end

  @impl Runic.Runner.Store
  def load_snapshot(workflow_id, %{snapshots_table: snapshots_table}) do
    case :ets.lookup(snapshots_table, workflow_id) do
      [{^workflow_id, cursor, snapshot}] -> {:ok, {cursor, snapshot}}
      [] -> {:error, :not_found}
    end
  end

  def call_count(%{calls_table: calls_table}, key) do
    case :ets.lookup(calls_table, key) do
      [{^key, count}] -> count
      [] -> 0
    end
  end

  defp stream_from(workflow_id, start_seq, %{
         events_table: events_table,
         counters_table: counters_table
       }) do
    case :ets.lookup(counters_table, workflow_id) do
      [] ->
        {:error, :not_found}

      [{^workflow_id, count}] ->
        stream =
          Stream.resource(
            fn -> start_seq end,
            fn
              seq when seq > count ->
                {:halt, seq}

              seq ->
                case :ets.lookup(events_table, {workflow_id, seq}) do
                  [{{^workflow_id, ^seq}, event}] -> {[event], seq + 1}
                  [] -> {:halt, seq}
                end
            end,
            fn _acc -> :ok end
          )

        {:ok, stream}
    end
  end

  defp increment_call(calls_table, key) do
    :ets.update_counter(calls_table, key, {2, 1}, {key, 0})
  end

  defp opts_key(opts) do
    cond do
      Keyword.has_key?(opts, :after_cursor) -> :after_cursor
      true -> :opts
    end
  end

  defp ensure_table(table, opts) do
    if :ets.whereis(table) == :undefined do
      :ets.new(table, [:named_table, :public, read_concurrency: true] ++ opts)
    end
  end
end
