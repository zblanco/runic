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
    {:ok, %{table: table_name, runner_name: runner_name}}
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

  @impl Runic.Runner.Store
  def delete(workflow_id, %{table: table}) do
    case :mnesia.transaction(fn -> :mnesia.delete({table, workflow_id}) end) do
      {:atomic, :ok} -> :ok
      {:aborted, reason} -> {:error, {:mnesia_delete_failed, reason}}
    end
  end

  @impl Runic.Runner.Store
  def list(%{table: table}) do
    ids = :mnesia.dirty_all_keys(table)
    {:ok, ids}
  end

  @impl Runic.Runner.Store
  def exists?(workflow_id, %{table: table}) do
    case :mnesia.dirty_read(table, workflow_id) do
      [_ | _] -> true
      [] -> false
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

    ensure_schema(disc_copies?, nodes)
    ensure_mnesia_started()
    ensure_table(table, disc_copies?, nodes)

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

  defp table_name(runner_name) do
    Module.concat(runner_name, WorkflowStore)
  end
end
