defmodule Runic.TestSupport.PromiseProgressScheduler do
  @behaviour Runic.Runner.Scheduler
  def init(opts), do: {:ok, %{observer: Keyword.fetch!(opts, :observer), active: MapSet.new()}}

  def plan_dispatch(workflow, runnables, state) do
    {promises, standalone} = Runic.Runner.PromiseBuilder.build_promises(workflow, runnables)
    {Enum.map(promises, &{:promise, &1}) ++ Enum.map(standalone, &{:runnable, &1}), state}
  end

  def on_dispatch({:promise, promise}, state) do
    send(state.observer, {:scheduler_dispatch, promise})
    %{state | active: Enum.reduce(promise.runnables, state.active, &MapSet.put(&2, &1.id))}
  end

  def on_dispatch(_, state), do: state

  def on_complete({:promise, promise}, _, state) do
    send(state.observer, {:scheduler_complete, promise})
    %{state | active: Enum.reduce(promise.runnables, state.active, &MapSet.delete(&2, &1.id))}
  end

  def on_complete(_, _, state), do: state
end
