defmodule Runic.TestSupport.AdmissionScheduler do
  @behaviour Runic.Runner.Scheduler

  @impl true
  def init(opts), do: {:ok, %{owner: Keyword.fetch!(opts, :owner), active: MapSet.new()}}

  @impl true
  def plan_dispatch(_workflow, runnables, state) do
    send(state.owner, {:planned, Enum.map(runnables, & &1.id)})
    {Enum.map(runnables, &{:runnable, &1}), state}
  end

  @impl true
  def on_dispatch({:runnable, runnable}, state) do
    send(state.owner, {:admitted, runnable.id})
    %{state | active: MapSet.put(state.active, runnable.id)}
  end

  @impl true
  def on_complete({:runnable, runnable}, _duration, state) do
    send(
      state.owner,
      {:admission_completed, runnable.id, MapSet.member?(state.active, runnable.id)}
    )

    %{state | active: MapSet.delete(state.active, runnable.id)}
  end
end
