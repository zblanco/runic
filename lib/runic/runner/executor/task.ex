defmodule Runic.Runner.Executor.Task do
  @moduledoc """
  Default executor using `Task.Supervisor.async_nolink`.

  This is the zero-overhead default. The Worker's dispatch loop
  delegates to this executor when no custom executor is configured.
  """

  @behaviour Runic.Runner.Executor

  @impl true
  def init(opts) do
    task_supervisor = Keyword.fetch!(opts, :task_supervisor)
    {:ok, %{task_supervisor: task_supervisor}}
  end

  @impl true
  def dispatch(work_fn, _opts, %{task_supervisor: sup} = state) do
    task = Task.Supervisor.async_nolink(sup, work_fn)
    {task.ref, state}
  end

  @impl true
  def cleanup(_state), do: :ok
end
