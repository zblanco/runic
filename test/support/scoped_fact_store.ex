defmodule Runic.TestSupport.ScopedFactStore do
  @behaviour Runic.Runner.Store

  def start_link(_opts) do
    Agent.start_link(fn -> %{events: %{}, facts: %{}, logs: %{}} end)
  end

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def data(agent), do: Agent.get(agent, & &1)

  @impl Runic.Runner.Store
  def init_store(opts), do: {:ok, Keyword.fetch!(opts, :agent)}

  @impl Runic.Runner.Store
  def for_workflow(workflow_id, agent), do: {agent, workflow_id}

  @impl Runic.Runner.Store
  def save(workflow_id, log, {agent, scoped_id}) when workflow_id == scoped_id do
    Agent.update(agent, &put_in(&1, [:logs, workflow_id], log))
  end

  @impl Runic.Runner.Store
  def load(workflow_id, {agent, scoped_id}) when workflow_id == scoped_id,
    do: fetch(agent, :logs, workflow_id)

  @impl Runic.Runner.Store
  def append(workflow_id, events, {agent, scoped_id}) when workflow_id == scoped_id do
    Agent.get_and_update(agent, fn data ->
      stored = Map.get(data.events, workflow_id, []) ++ events
      {{:ok, length(stored)}, put_in(data, [:events, workflow_id], stored)}
    end)
  end

  @impl Runic.Runner.Store
  def stream(workflow_id, {agent, scoped_id}) when workflow_id == scoped_id,
    do: fetch(agent, :events, workflow_id)

  @impl Runic.Runner.Store
  def save_fact(hash, value, {agent, workflow_id}) do
    Agent.update(agent, &put_in(&1, [:facts, {workflow_id, hash}], value))
  end

  @impl Runic.Runner.Store
  def load_fact(hash, {agent, workflow_id}), do: fetch(agent, :facts, {workflow_id, hash})

  defp fetch(agent, collection, key) do
    Agent.get(agent, fn data ->
      case Map.fetch(Map.fetch!(data, collection), key) do
        {:ok, value} -> {:ok, value}
        :error -> {:error, :not_found}
      end
    end)
  end
end
