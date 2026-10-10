defmodule Runic.TestSupport.FailureBatchScheduler do
  @behaviour Runic.Runner.Scheduler

  @impl true
  def init(_opts), do: {:ok, nil}

  @impl true
  def plan_dispatch(_workflow, runnables, state) do
    {members, singles} = Enum.split_with(runnables, &(&1.node.name in [:pa, :pb]))

    batch =
      if members == [],
        do: [],
        else: [
          {:promise,
           Runic.Runner.Promise.new(members,
             strategy: :parallel,
             flow_opts: [stages: 2, max_demand: 1]
           )}
        ]

    singles = Enum.sort_by(singles, &(&1.node.name != :fail))
    {batch ++ Enum.map(singles, &{:runnable, &1}), state}
  end
end
