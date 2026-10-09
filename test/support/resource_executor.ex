defmodule Runic.TestSupport.ResourceExecutor do
  @moduledoc false
  @behaviour Runic.Runner.Executor

  @impl true
  def init(opts) do
    pool_supervisor = Keyword.fetch!(opts, :pool_supervisor)
    spec = Supervisor.child_spec({Agent, fn -> :ready end}, restart: :temporary)
    {:ok, pool} = DynamicSupervisor.start_child(pool_supervisor, spec)
    observer = Keyword.fetch!(opts, :observer)
    label = Keyword.fetch!(opts, :label)
    send(observer, {:pool_started, label, pool})

    {:ok,
     %{
       pool: pool,
       observer: observer,
       label: label,
       task_supervisor: Keyword.fetch!(opts, :task_supervisor),
       tasks: %{},
       cleanup: Keyword.get(opts, :cleanup, :ok)
     }}
  end

  @impl true
  def dispatch(work, _opts, state) do
    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        Agent.get(state.pool, fn _ -> work.() end)
      end)

    {task.ref, %{state | tasks: Map.put(state.tasks, task.ref, task.pid)}}
  end

  @impl true
  def release(ref, state), do: %{state | tasks: Map.delete(state.tasks, ref)}

  @impl true
  def cleanup(state) do
    send(state.observer, {:cleanup_started, state.label, self()})
    if state.cleanup == :block, do: receive(do: (:finish_cleanup -> :ok))
    Runic.TaskScope.kill([state.pool | Map.values(state.tasks)])

    case state.cleanup do
      :raise -> raise "cleanup failed"
      :throw -> throw(:cleanup_failed)
      _ -> send(state.observer, {:cleanup_finished, state.label})
    end

    :ok
  end
end
