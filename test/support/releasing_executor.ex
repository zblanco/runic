defmodule Runic.TestSupport.ReleasingExecutor do
  @behaviour Runic.Runner.Executor

  @impl true
  def init(opts) do
    {:ok,
     %{
       test_pid: Keyword.fetch!(opts, :test_pid),
       task_supervisor: Keyword.fetch!(opts, :task_supervisor),
       label: Keyword.get(opts, :label, :default),
       outcome: Keyword.get(opts, :outcome, :result),
       release_error: Keyword.get(opts, :release_error, false),
       cleanup_error: Keyword.get(opts, :cleanup_error, false),
       handles: MapSet.new()
     }}
  end

  @impl true
  def dispatch(work_fn, _opts, state) do
    handle = make_ref()
    caller = self()

    case state.outcome do
      outcome when outcome in [:result, :deferred] ->
        result = work_fn.()
        send(state.test_pid, {:executor_result, caller, handle, result})
        if outcome == :result, do: send(caller, {handle, result})

      :crash ->
        send(caller, {:DOWN, handle, :process, self(), :test_crash})
    end

    {handle, %{state | handles: MapSet.put(state.handles, handle)}}
  end

  @impl true
  def release(handle, state) do
    send(state.test_pid, {:executor_released, handle})
    if state.release_error, do: raise("release failed")
    %{state | handles: MapSet.delete(state.handles, handle)}
  end

  @impl true
  def cleanup(state) do
    send(state.test_pid, {:executor_cleaned, state.label})
    if state.cleanup_error, do: throw(:cleanup_failed)
    :ok
  end
end
