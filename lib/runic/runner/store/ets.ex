defmodule Runic.Runner.Store.ETS do
  @moduledoc """
  Default in-memory persistence adapter using ETS.

  Survives worker restarts within the same VM but not VM restarts.
  The GenServer owns the ETS table, while Store callbacks operate
  on the :public table directly for zero-overhead reads and writes.
  """

  @behaviour Runic.Runner.Store
  use GenServer

  # --- Store Behaviour ---

  @impl Runic.Runner.Store
  def init_store(opts) do
    runner_name = Keyword.fetch!(opts, :runner_name)
    table_name = Module.concat(runner_name, StoreTable)
    {:ok, %{table: table_name, runner_name: runner_name}}
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

  @impl Runic.Runner.Store
  def delete(workflow_id, %{table: table}) do
    :ets.delete(table, workflow_id)
    :ok
  end

  @impl Runic.Runner.Store
  def list(%{table: table}) do
    ids = :ets.select(table, [{{:"$1", :_, :_}, [], [:"$1"]}])
    {:ok, ids}
  end

  @impl Runic.Runner.Store
  def exists?(workflow_id, %{table: table}) do
    :ets.member(table, workflow_id)
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
    _table = :ets.new(table_name, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table_name, runner_name: runner_name}}
  end
end
