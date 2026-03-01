defmodule Runic.Runner.TestSchedulers.Crashing do
  @moduledoc false
  @behaviour Runic.Runner.Scheduler

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def plan_dispatch(_workflow, _runnables, _state) do
    raise "intentional scheduler crash"
  end
end

defmodule Runic.Runner.TestSchedulers.Tracking do
  @moduledoc false
  @behaviour Runic.Runner.Scheduler

  @impl true
  def init(opts) do
    {:ok, %{test_pid: Keyword.get(opts, :test_pid), completions: []}}
  end

  @impl true
  def plan_dispatch(_workflow, runnables, state) do
    units = Enum.map(runnables, &{:runnable, &1})
    {units, state}
  end

  @impl true
  def on_complete(unit, duration, state) do
    if state.test_pid, do: send(state.test_pid, {:scheduler_on_complete, unit, duration})
    %{state | completions: [{unit, duration} | state.completions]}
  end
end

defmodule Runic.Runner.TestSchedulers.Reversing do
  @moduledoc """
  Test scheduler that reverses runnable order.
  Verifies that reordering still produces correct final results.
  """
  @behaviour Runic.Runner.Scheduler

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def plan_dispatch(_workflow, runnables, state) do
    units = runnables |> Enum.reverse() |> Enum.map(&{:runnable, &1})
    {units, state}
  end
end

defmodule TestParallelScheduler do
  @moduledoc """
  Test scheduler that groups all runnables into a single :parallel Promise.
  Used to test parallel promise resolution via Flow / Task.async_stream.
  """
  @behaviour Runic.Runner.Scheduler

  @impl true
  def init(opts), do: {:ok, %{flow_opts: Keyword.get(opts, :flow_opts, [])}}

  @impl true
  def plan_dispatch(_workflow, runnables, state) do
    case runnables do
      [] ->
        {[], state}

      [single] ->
        {[{:runnable, single}], state}

      multiple ->
        promise =
          Runic.Runner.Promise.new(multiple,
            strategy: :parallel,
            flow_opts: state.flow_opts
          )

        {[{:promise, promise}], state}
    end
  end
end
