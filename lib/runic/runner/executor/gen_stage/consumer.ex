defmodule Runic.Runner.Executor.GenStage.Consumer do
  @moduledoc false
  use GenStage

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    producer = Keyword.fetch!(opts, :producer)
    {:consumer, %{}, subscribe_to: [{producer, max_demand: 1, min_demand: 0}]}
  end

  @impl true
  def handle_events(events, _from, state) do
    for {handle, work_fn, caller} <- events do
      try do
        result = work_fn.()
        send(caller, {handle, result})
      catch
        kind, reason ->
          send(caller, {:DOWN, handle, :process, self(), {kind, reason}})
      end
    end

    {:noreply, [], state}
  end
end
