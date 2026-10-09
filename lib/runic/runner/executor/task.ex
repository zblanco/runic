defmodule Runic.Runner.Executor.Task do
  @moduledoc """
  Default executor using supervised tasks in an owned task scope.

  Task failures are isolated from the Worker. Cleanup waits for native work
  to stop, including work that traps exits. The scope also stops work when
  its Worker dies without running cleanup.
  """

  @behaviour Runic.Runner.Executor

  @impl true
  def init(opts) do
    task_supervisor = Keyword.fetch!(opts, :task_supervisor)

    scope =
      case Keyword.get(opts, :task_scope) do
        nil ->
          {:ok, scope} = Runic.TaskScope.start(owner: self())
          scope

        scope ->
          scope
      end

    {:ok, %{task_supervisor: task_supervisor, scope: scope, tasks: %{}}}
  end

  @impl true
  def dispatch(work_fn, _opts, %{task_supervisor: sup} = state) do
    {handle, pid} = Runic.TaskScope.dispatch(state.scope, work_fn, sup)
    {handle, %{state | tasks: Map.put(state.tasks, handle, pid)}}
  end

  @impl true
  def release(handle, state), do: %{state | tasks: Map.delete(state.tasks, handle)}

  @impl true
  def cleanup(state) do
    Runic.TaskScope.close(state.scope)
    Runic.TaskScope.kill(Map.values(state.tasks))
    :ok
  end
end
