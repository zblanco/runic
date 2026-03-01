defmodule Runic.Runner.Store.Mnesia do
  @moduledoc """
  Mnesia-backed persistence adapter for the Runner.

  Uses Erlang/OTP's built-in Mnesia database for workflow log storage.
  Provides persistence across VM restarts (via `disc_copies`) and
  distributed storage across Erlang clusters.

  ## Usage

      {:ok, _} = Runic.Runner.start_link(
        name: MyApp.Runner,
        store: Runic.Runner.Store.Mnesia,
        store_opts: [disc_copies: true]
      )

  ## Options

    * `:runner_name` — (required) the Runner name, used to derive the Mnesia table name
    * `:disc_copies` — when `true` (default), persists to disk on this node.
      Set to `false` for RAM-only tables (faster, lost on VM restart).
    * `:nodes` — list of nodes for distributed tables.
      Defaults to `[node()]`.

  ## Mnesia Schema

  If Mnesia has not been initialized with a schema directory on this node,
  one will be created automatically. For production use, configure the
  Mnesia directory via the `:mnesia` application env:

      config :mnesia, dir: ~c"/var/data/mnesia/\#{node()}"

  ## Distributed Operation

  For multi-node Mnesia clusters, ensure `:mnesia.change_config(:extra_db_nodes, nodes)`
  is called before starting the Runner, or pass `:nodes` in store opts.

  ## Stream Semantics

  Supports event-sourced `append/3` and `stream/2` via a second Mnesia table
  (`*EventStream`) with `{workflow_id, sequence}` compound keys for ordered
  event retrieval.

  ## Design Notes

    * Write operations use `:mnesia.transaction/1` for ACID guarantees.
    * Read operations use `:mnesia.dirty_read/2` — no transaction overhead,
      eventually consistent during concurrent writes (sufficient for workflow
      log reads, which are dominated by the owning Worker process).
    * `checkpoint/3` delegates to `save/3` — Mnesia's transaction log already
      provides write-ahead durability.
  """

  @behaviour Runic.Runner.Store
  use GenServer

  require Logger

  # --- Store Behaviour ---

  @impl Runic.Runner.Store
  def init_store(opts) do
    runner_name = Keyword.fetch!(opts, :runner_name)
    table_name = table_name(runner_name)
    events_table = events_table_name(runner_name)
    counters_table = counters_table_name(runner_name)
    facts_table = facts_table_name(runner_name)

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
    record = {table, workflow_id, log, System.monotonic_time(:millisecond)}

    case :mnesia.transaction(fn -> :mnesia.write(record) end) do
      {:atomic, :ok} -> :ok
      {:aborted, reason} -> {:error, {:mnesia_write_failed, reason}}
    end
  end

  @impl Runic.Runner.Store
  def load(workflow_id, %{table: table}) do
    case :mnesia.dirty_read(table, workflow_id) do
      [{^table, ^workflow_id, log, _updated_at}] -> {:ok, log}
      [] -> {:error, :not_found}
    end
  end

  @impl Runic.Runner.Store
  def checkpoint(workflow_id, log, state), do: save(workflow_id, log, state)

  # --- Stream semantics ---

  @impl Runic.Runner.Store
  def append(workflow_id, events, %{events_table: events_table, counters_table: counters_table})
      when is_list(events) do
    case :mnesia.transaction(fn ->
           # Atomically increment counter and write events
           cursor =
             case :mnesia.read(counters_table, workflow_id) do
               [{^counters_table, ^workflow_id, current}] -> current
               [] -> 0
             end

           count = length(events)
           new_cursor = cursor + count
           :mnesia.write({counters_table, workflow_id, new_cursor})

           events
           |> Enum.with_index(cursor + 1)
           |> Enum.each(fn {event, seq} ->
             :mnesia.write({events_table, {workflow_id, seq}, event})
           end)

           new_cursor
         end) do
      {:atomic, cursor} -> {:ok, cursor}
      {:aborted, reason} -> {:error, {:mnesia_append_failed, reason}}
    end
  end

  @impl Runic.Runner.Store
  def stream(workflow_id, %{events_table: events_table, counters_table: counters_table}) do
    case :mnesia.dirty_read(counters_table, workflow_id) do
      [] ->
        {:error, :not_found}

      [{^counters_table, ^workflow_id, count}] ->
        stream =
          Stream.resource(
            fn -> 1 end,
            fn
              seq when seq > count ->
                {:halt, seq}

              seq ->
                case :mnesia.dirty_read(events_table, {workflow_id, seq}) do
                  [{^events_table, {^workflow_id, ^seq}, event}] -> {[event], seq + 1}
                  [] -> {:halt, seq}
                end
            end,
            fn _acc -> :ok end
          )

        {:ok, stream}
    end
  end

  # --- Fact storage ---

  @impl Runic.Runner.Store
  def save_fact(fact_hash, value, %{facts_table: facts_table}) do
    record = {facts_table, fact_hash, value}

    case :mnesia.transaction(fn -> :mnesia.write(record) end) do
      {:atomic, :ok} -> :ok
      {:aborted, reason} -> {:error, {:mnesia_write_failed, reason}}
    end
  end

  @impl Runic.Runner.Store
  def load_fact(fact_hash, %{facts_table: facts_table}) do
    case :mnesia.dirty_read(facts_table, fact_hash) do
      [{^facts_table, ^fact_hash, value}] -> {:ok, value}
      [] -> {:error, :not_found}
    end
  end

  # --- Lifecycle ---

  @impl Runic.Runner.Store
  def delete(workflow_id, %{table: table} = state) do
    result =
      case :mnesia.transaction(fn -> :mnesia.delete({table, workflow_id}) end) do
        {:atomic, :ok} -> :ok
        {:aborted, reason} -> {:error, {:mnesia_delete_failed, reason}}
      end

    delete_events(workflow_id, state)
    result
  end

  @impl Runic.Runner.Store
  def list(%{table: table}) do
    ids = :mnesia.dirty_all_keys(table)
    {:ok, ids}
  end

  @impl Runic.Runner.Store
  def exists?(workflow_id, %{table: table, counters_table: counters_table}) do
    case :mnesia.dirty_read(table, workflow_id) do
      [_ | _] ->
        true

      [] ->
        case :mnesia.dirty_read(counters_table, workflow_id) do
          [_ | _] -> true
          [] -> false
        end
    end
  end

  defp delete_events(workflow_id, %{events_table: events_table, counters_table: counters_table}) do
    case :mnesia.dirty_read(counters_table, workflow_id) do
      [{^counters_table, ^workflow_id, count}] ->
        :mnesia.transaction(fn ->
          for seq <- 1..count do
            :mnesia.delete({events_table, {workflow_id, seq}})
          end

          :mnesia.delete({counters_table, workflow_id})
        end)

      [] ->
        :ok
    end
  end

  # --- GenServer (table lifecycle) ---

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
    disc_copies? = Keyword.get(opts, :disc_copies, true)
    nodes = Keyword.get(opts, :nodes, [node()])

    table = table_name(runner_name)
    events_table = events_table_name(runner_name)
    counters_table = counters_table_name(runner_name)
    facts_table = facts_table_name(runner_name)

    ensure_schema(disc_copies?, nodes)
    ensure_mnesia_started()
    ensure_table(table, disc_copies?, nodes)
    ensure_events_table(events_table, disc_copies?, nodes)
    ensure_counters_table(counters_table, disc_copies?, nodes)
    ensure_facts_table(facts_table, disc_copies?, nodes)

    {:ok, %{table: table, runner_name: runner_name}}
  end

  # --- Mnesia Setup ---

  defp ensure_schema(true = _disc_copies?, nodes) do
    # create_schema fails if already exists — that's fine
    case :mnesia.create_schema(nodes) do
      :ok -> :ok
      {:error, {_, {:already_exists, _}}} -> :ok
      {:error, reason} -> raise "Failed to create Mnesia schema: #{inspect(reason)}"
    end
  end

  defp ensure_schema(false, _nodes), do: :ok

  defp ensure_mnesia_started do
    case Application.ensure_all_started(:mnesia) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "Failed to start Mnesia: #{inspect(reason)}"
    end
  end

  defp ensure_table(table, disc_copies?, nodes) do
    storage_type = if disc_copies?, do: :disc_copies, else: :ram_copies

    table_def =
      [
        {storage_type, nodes},
        attributes: [:workflow_id, :log, :updated_at],
        type: :set
      ]

    case :mnesia.create_table(table, table_def) do
      {:atomic, :ok} ->
        :ok

      {:aborted, {:already_exists, ^table}} ->
        :ok

      {:aborted, reason} ->
        raise "Failed to create Mnesia table #{inspect(table)}: #{inspect(reason)}"
    end

    :ok = :mnesia.wait_for_tables([table], 15_000)
  end

  defp ensure_events_table(table, disc_copies?, nodes) do
    storage_type = if disc_copies?, do: :disc_copies, else: :ram_copies

    table_def =
      [
        {storage_type, nodes},
        attributes: [:key, :event],
        type: :ordered_set
      ]

    case :mnesia.create_table(table, table_def) do
      {:atomic, :ok} ->
        :ok

      {:aborted, {:already_exists, ^table}} ->
        :ok

      {:aborted, reason} ->
        raise "Failed to create Mnesia events table #{inspect(table)}: #{inspect(reason)}"
    end

    :ok = :mnesia.wait_for_tables([table], 15_000)
  end

  defp ensure_counters_table(table, disc_copies?, nodes) do
    storage_type = if disc_copies?, do: :disc_copies, else: :ram_copies

    table_def =
      [
        {storage_type, nodes},
        attributes: [:workflow_id, :count],
        type: :set
      ]

    case :mnesia.create_table(table, table_def) do
      {:atomic, :ok} ->
        :ok

      {:aborted, {:already_exists, ^table}} ->
        :ok

      {:aborted, reason} ->
        raise "Failed to create Mnesia counters table #{inspect(table)}: #{inspect(reason)}"
    end

    :ok = :mnesia.wait_for_tables([table], 15_000)
  end

  defp table_name(runner_name) do
    Module.concat(runner_name, WorkflowStore)
  end

  defp events_table_name(runner_name) do
    Module.concat(runner_name, EventStream)
  end

  defp counters_table_name(runner_name) do
    Module.concat(runner_name, EventCounters)
  end

  defp facts_table_name(runner_name) do
    Module.concat(runner_name, FactStore)
  end

  defp ensure_facts_table(table, disc_copies?, nodes) do
    storage_type = if disc_copies?, do: :disc_copies, else: :ram_copies

    table_def =
      [
        {storage_type, nodes},
        attributes: [:fact_hash, :value],
        type: :set
      ]

    case :mnesia.create_table(table, table_def) do
      {:atomic, :ok} ->
        :ok

      {:aborted, {:already_exists, ^table}} ->
        :ok

      {:aborted, reason} ->
        raise "Failed to create Mnesia facts table #{inspect(table)}: #{inspect(reason)}"
    end

    :ok = :mnesia.wait_for_tables([table], 15_000)
  end
end
