defmodule Runic.Runner.Executor.GenStage.Producer do
  @moduledoc false
  use GenStage

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts)
  end

  def enqueue(producer, event) do
    GenStage.cast(producer, {:enqueue, event})
  end

  @impl true
  def init(opts) do
    buffer_size = Keyword.get(opts, :buffer_size, :infinity)
    {:producer, %{queue: :queue.new(), pending_demand: 0}, buffer_size: buffer_size}
  end

  @impl true
  def handle_cast({:enqueue, event}, state) do
    queue = :queue.in(event, state.queue)
    {events, new_state} = dispatch_events(%{state | queue: queue})
    {:noreply, events, new_state}
  end

  @impl true
  def handle_demand(demand, state) do
    {events, new_state} =
      dispatch_events(%{state | pending_demand: state.pending_demand + demand})

    {:noreply, events, new_state}
  end

  defp dispatch_events(state) do
    {events, queue, remaining_demand} = take_events(state.queue, state.pending_demand, [])
    {Enum.reverse(events), %{state | queue: queue, pending_demand: remaining_demand}}
  end

  defp take_events(queue, 0, acc), do: {acc, queue, 0}

  defp take_events(queue, demand, acc) do
    case :queue.out(queue) do
      {{:value, event}, rest} ->
        take_events(rest, demand - 1, [event | acc])

      {:empty, queue} ->
        {acc, queue, demand}
    end
  end
end
