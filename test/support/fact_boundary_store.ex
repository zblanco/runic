defmodule Runic.TestSupport.FactBoundaryStore do
  @moduledoc "A test Store profile for FactProduced data; not a full workflow portability gate."
  @behaviour Runic.Runner.Store

  alias Runic.Examples.FactBoundary
  alias Runic.TestSupport.FailingStore
  alias Runic.Workflow.Events.FactProduced

  @impl true
  defdelegate init_store(opts), to: FailingStore
  @impl true
  defdelegate load(id, state), to: FailingStore
  @impl true
  defdelegate stream(id, state), to: FailingStore

  @impl true
  def save(id, events, state) do
    with :ok <- check_facts(events), do: FailingStore.save(id, events, state)
  end

  @impl true
  def append(id, events, state) do
    with :ok <- check_facts(events), do: FailingStore.append(id, events, state)
  end

  defp check_facts(events) do
    events
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn
      {%FactProduced{value: value, meta: meta}, index}, :ok ->
        case FactBoundary.check(%{index => %{value: value, meta: meta}}, :events) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end

      _, :ok ->
        {:cont, :ok}
    end)
  end
end
