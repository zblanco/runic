defmodule Runic.TestSupport.FailingStore do
  @behaviour Runic.Runner.Store

  def start_link(_opts) do
    Agent.start_link(fn ->
      %{failures: %{}, calls: [], events: %{}, cursors: %{}, logs: %{}, facts: %{}, payloads: %{}}
    end)
  end

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @impl true
  def init_store(opts), do: {:ok, Keyword.fetch!(opts, :agent)}

  def fail(agent, operation, reason \\ :storage_unavailable) do
    Agent.update(agent, &put_in(&1, [:failures, operation], reason))
  end

  def recover(agent), do: Agent.update(agent, &%{&1 | failures: %{}})
  def data(agent), do: Agent.get(agent, & &1)

  @impl true
  def append(id, events, agent) do
    write(agent, :append, {id, events}, fn data ->
      # Deliberately not a local event count: the Worker must use the Store cursor.
      cursor = Map.get(data.cursors, id, 0) + 10 * length(events)

      next = %{
        data
        | events: Map.update(data.events, id, events, &(&1 ++ events)),
          cursors: Map.put(data.cursors, id, cursor)
      }

      {{:ok, cursor}, next}
    end)
  end

  @impl true
  def stream(id, agent), do: read(agent, :events, id)

  @impl true
  def save(id, log, agent), do: save_log(:save, id, log, agent)

  def save_log(operation, id, log, agent) do
    write(agent, operation, {id, log}, fn data ->
      {:ok, %{data | logs: Map.put(data.logs, id, log)}}
    end)
  end

  @impl true
  def load(id, agent), do: read(agent, :logs, id)

  @impl true
  def save_fact(hash, value, agent) do
    write(agent, :save_fact, {hash, value}, fn data ->
      {:ok, %{data | facts: Map.put(data.facts, hash, value)}}
    end)
  end

  @impl true
  def load_fact(hash, agent), do: read(agent, :facts, hash)

  @impl true
  def save_payload(digest, bytes, agent) do
    write(agent, :save_payload, {digest, bytes}, fn data ->
      {:ok, %{data | payloads: Map.put(data.payloads, digest, bytes)}}
    end)
  end

  @impl true
  def load_payload(digest, agent), do: read(agent, :payloads, digest)

  defp read(agent, collection, key) do
    Agent.get(agent, fn data ->
      case Map.fetch(Map.fetch!(data, collection), key) do
        {:ok, value} -> {:ok, value}
        :error -> {:error, :not_found}
      end
    end)
  end

  defp write(agent, operation, args, fun) do
    Agent.get_and_update(agent, fn data ->
      data = %{data | calls: data.calls ++ [{operation, args}]}

      case Map.fetch(data.failures, operation) do
        {:ok, reason} -> {{:error, reason}, data}
        :error -> fun.(data)
      end
    end)
  end
end
