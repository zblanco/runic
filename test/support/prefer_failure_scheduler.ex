defmodule Runic.TestSupport.PreferFailureScheduler do
  @moduledoc false
  @behaviour Runic.Runner.Scheduler
  def init(_), do: {:ok, nil}

  def plan_dispatch(_, runnables, state) do
    units =
      runnables
      |> Enum.sort_by(&if(Map.get(&1.node, :name) == :s6, do: 0, else: 1))
      |> Enum.map(&{:runnable, &1})

    {units, state}
  end
end
