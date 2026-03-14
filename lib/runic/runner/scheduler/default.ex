defmodule Runic.Runner.Scheduler.Default do
  @moduledoc """
  Default scheduler strategy that dispatches each runnable individually.

  This is the zero-overhead default. Each prepared runnable becomes a
  `{:runnable, r}` dispatch unit — identical to the pre-scheduler Worker
  behavior.
  """

  @behaviour Runic.Runner.Scheduler

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def plan_dispatch(_workflow, runnables, state) do
    units = Enum.map(runnables, &{:runnable, &1})
    {units, state}
  end
end
