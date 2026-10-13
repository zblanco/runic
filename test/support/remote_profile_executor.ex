defmodule Runic.TestSupport.RemoteProfileExecutor do
  @moduledoc false
  @behaviour Runic.Runner.Executor
  alias Runic.Runner.Executor.Task, as: TaskExecutor

  @impl true
  def locality, do: :remote

  @impl true
  def init(opts) do
    {:ok, task} = TaskExecutor.init(opts)
    {:ok, %{task: task, observer: Keyword.fetch!(opts, :observer)}}
  end

  @impl true
  def dispatch(work, opts, state) do
    # A transport spy: positive controls run locally, not over a network.
    send(state.observer, :remote_dispatch_called)
    {handle, task} = TaskExecutor.dispatch(work, opts, state.task)
    {handle, %{state | task: task}}
  end

  @impl true
  def release(handle, state), do: %{state | task: TaskExecutor.release(handle, state.task)}
  @impl true
  def cleanup(state), do: TaskExecutor.cleanup(state.task)
end
