defmodule Runic.Runner.Store.ETS do
  @moduledoc """
  Default in-memory persistence adapter using ETS.

  Survives worker restarts within the same VM but not VM restarts.
  The GenServer owns the ETS tables, while Store callbacks operate
  on the :public tables directly for zero-overhead reads and writes.

  ## Stream Semantics

  Supports event-sourced `append/3` and `stream/2` via a second
  `:ordered_set` ETS table keyed by `{workflow_id, sequence}`.
  A counter table tracks the next sequence number per workflow.
  """

  @behaviour Runic.Runner.Store
  use GenServer

  # --- Store Behaviour (snapshot) ---

  @impl Runic.Runner.Store
  def init_store(opts) do
    runner_name = Keyword.fetch!(opts, :runner_name)
    table_name = Module.concat(runner_name, StoreTable)
    events_table = Module.concat(runner_name, StoreEvents)
    counters_table = Module.concat(runner_name, StoreCounters)
    facts_table = Module.concat(runner_name, FactTable)

    {:ok,
     %{
       table: table_name,
       events_table: events_table,
       counters_table: counters_table,
       facts_table: facts_table,
       runner_name: runner_name
     }}
  end

  @impl Runic.Runner.Store
  def save(workflow_id, log, %{table: table}) do
    :ets.insert(table, {workflow_id, log, System.monotonic_time(:millisecond)})
    :ok
  end

  @impl Runic.Runner.Store
  def load(workflow_id, %{table: table}) do
    case :ets.lookup(table, workflow_id) do
      [{^workflow_id, log, _updated_at}] -> {:ok, log}
      [] -> {:error, :not_found}
    end
  end

  @impl Runic.Runner.Store
  def checkpoint(workflow_id, log, state), do: save(workflow_id, log, state)

  # --- Store Behaviour (stream semantics) ---

  @impl Runic.Runner.Store
  def append(workflow_id, events, %{events_table: events_table, counters_table: counters_table})
      when is_list(events) do
    count = length(events)

    cursor =
      :ets.update_counter(counters_table, workflow_id, {2, count}, {workflow_id, 0})

    start_seq = cursor - count + 1

    events
    |> Enum.with_index(start_seq)
    |> Enum.each(fn {event, seq} ->
      :ets.insert(events_table, {{workflow_id, seq}, event})
    end)

    {:ok, cursor}
  end

  @impl Runic.Runner.Store
  def stream(workflow_id, %{events_table: events_table, counters_table: counters_table}) do
    case :ets.lookup(counters_table, workflow_id) do
      [] ->
        {:error, :not_found}

      [{^workflow_id, _count}] ->
        stream =
          Stream.resource(
            fn -> {workflow_id, 1} end,
            fn {wf_id, seq} ->
              case :ets.lookup(events_table, {wf_id, seq}) do
                [{{^wf_id, ^seq}, event}] -> {[event], {wf_id, seq + 1}}
                [] -> {:halt, {wf_id, seq}}
              end
            end,
            fn _acc -> :ok end
          )

        {:ok, stream}
    end
  end

  # --- Store Behaviour (fact storage) ---

  @impl Runic.Runner.Store
  def save_fact(fact_hash, value, %{facts_table: facts_table}) do
    :ets.insert(facts_table, {fact_hash, value})
    :ok
  end

  @impl Runic.Runner.Store
  def load_fact(fact_hash, %{facts_table: facts_table}) do
    case :ets.lookup(facts_table, fact_hash) do
      [{^fact_hash, value}] -> {:ok, value}
      [] -> {:error, :not_found}
    end
  end

  # --- Lifecycle ---

  @impl Runic.Runner.Store
  def delete(workflow_id, %{table: table} = state) do
    :ets.delete(table, workflow_id)
    delete_events(workflow_id, state)
    :ok
  end

  @impl Runic.Runner.Store
  def list(%{table: table}) do
    ids = :ets.select(table, [{{:"$1", :_, :_}, [], [:"$1"]}])
    {:ok, ids}
  end

  @impl Runic.Runner.Store
  def exists?(workflow_id, %{table: table, counters_table: counters_table}) do
    :ets.member(table, workflow_id) or :ets.member(counters_table, workflow_id)
  end

  defp delete_events(workflow_id, %{events_table: events_table, counters_table: counters_table}) do
    case :ets.lookup(counters_table, workflow_id) do
      [{^workflow_id, count}] ->
        for seq <- 1..count do
          :ets.delete(events_table, {workflow_id, seq})
        end

        :ets.delete(counters_table, workflow_id)

      [] ->
        :ok
    end
  end

  # --- GenServer (ETS table owner) ---

  def start_link(opts) do
    runner_name = Keyword.fetch!(opts, :runner_name)
    GenServer.start_link(__MODULE__, opts, name: Module.concat(runner_name, Store))
  end

  def child_spec(opts) do
    runner_name = Keyword.fetch!(opts, :runner_name)

    %{
      id: {__MODULE__, runner_name},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @impl GenServer
  def init(opts) do
    runner_name = Keyword.fetch!(opts, :runner_name)
    table_name = Module.concat(runner_name, StoreTable)
    events_table = Module.concat(runner_name, StoreEvents)
    counters_table = Module.concat(runner_name, StoreCounters)
    facts_table = Module.concat(runner_name, FactTable)

    _table = :ets.new(table_name, [:named_table, :set, :public, read_concurrency: true])

    _events =
      :ets.new(events_table, [:named_table, :ordered_set, :public, read_concurrency: true])

    _counters =
      :ets.new(counters_table, [
        :named_table,
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    _facts = :ets.new(facts_table, [:named_table, :set, :public, read_concurrency: true])

    {:ok,
     %{
       table: table_name,
       events_table: events_table,
       counters_table: counters_table,
       facts_table: facts_table,
       runner_name: runner_name
     }}
  end
end
