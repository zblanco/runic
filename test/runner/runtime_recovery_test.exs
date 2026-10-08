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
       handles: MapSet.new()
     }}
  end

  @impl true
  def dispatch(work_fn, _opts, state) do
    handle = make_ref()
    caller = self()

    case state.outcome do
      :result -> send(caller, {handle, work_fn.()})
      :crash -> send(caller, {:DOWN, handle, :process, self(), :test_crash})
    end

    {handle, %{state | handles: MapSet.put(state.handles, handle)}}
  end

  @impl true
  def release(handle, state) do
    send(state.test_pid, {:executor_released, handle})
    %{state | handles: MapSet.delete(state.handles, handle)}
  end

  @impl true
  def cleanup(state) do
    send(state.test_pid, {:executor_cleaned, state.label})
    :ok
  end
end

defmodule Runic.Runner.RuntimeRecoveryTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  require Runic

  alias Runic.Runner
  alias Runic.TestSupport.ReleasingExecutor
  alias Runic.Workflow
  alias Runic.Workflow.RunnableFailed

  describe "resume runtime options" do
    setup do
      runner = unique_runner(:resume)
      start_supervised!({Runner, name: runner})
      %{runner: runner}
    end

    test "applies run context before pending work is recovered", %{runner: runner} do
      first = Runic.step(fn value -> value end, name: :first)
      second = Runic.step(fn value -> value + context(:offset) end, name: :second)
      workflow = Runic.workflow(steps: [{first, [second]}])

      persist_after_first_step(runner, :context_resume, workflow)

      assert {:ok, _pid} =
               Runner.resume(runner, :context_resume, run_context: %{second: %{offset: 7}})

      wait_until_idle(runner, :context_resume)
      assert {:ok, results} = Runner.get_results(runner, :context_resume)
      assert 12 in results
    end

    test "applies scheduler policies before pending work is recovered", %{runner: runner} do
      first = Runic.step(fn value -> value end, name: :first)

      second =
        Runic.step(
          fn value ->
            Process.sleep(50)
            value + 1
          end,
          name: :slow_second
        )

      workflow = Runic.workflow(steps: [{first, [second]}])

      persist_after_first_step(runner, :policy_resume, workflow)

      assert {:ok, _pid} =
               Runner.resume(runner, :policy_resume,
                 scheduler_policies: [
                   {:slow_second, %{timeout_ms: 1, on_failure: :skip}}
                 ]
               )

      wait_until_idle(runner, :policy_resume)
      assert {:ok, results} = Runner.get_results(runner, :policy_resume)
      refute 6 in results

      assert {:ok, resumed} = Runner.get_workflow(runner, :policy_resume)
      assert [{:slow_second, %{timeout_ms: 1, on_failure: :skip}}] = resumed.scheduler_policies
    end

    test "snapshot encoding removes run context" do
      workflow =
        Workflow.new()
        |> Workflow.put_run_context(%{_global: %{token: "secret-token"}})

      encoded = Runner.encode_snapshot(workflow)

      refute encoded =~ "secret-token"
      assert {:ok, restored} = Runner.decode_snapshot(encoded)
      assert restored.run_context == %{}
    end

    test "decodes a version one snapshot without the halted-state field" do
      failure = %RunnableFailed{
        runnable_id: :legacy,
        node_hash: :node,
        error: :failed,
        failed_at: 1,
        attempts: 1,
        failure_action: :halt
      }

      legacy_workflow =
        Workflow.new()
        |> Map.put(:runnable_events, [failure])
        |> Map.delete(:halted_by_failure)

      snapshot = :erlang.term_to_binary({:runic_workflow_snapshot, 1, legacy_workflow})

      assert {:ok, restored} = Runner.decode_snapshot(snapshot)
      assert restored.halted_by_failure
    end
  end

  describe "partitioned task supervision" do
    test "injects the workflow task supervisor into a custom executor" do
      runner = unique_runner(:partitioned)
      start_supervised!({Runner, name: runner, task_supervisor: {:partition, 2}})

      workflow = Runic.workflow(steps: [Runic.step(fn value -> value + 1 end, name: :add)])

      assert {:ok, pid} =
               Runner.start_workflow(runner, :partitioned_workflow, workflow,
                 executor: ReleasingExecutor,
                 executor_opts: [test_pid: self()]
               )

      state = :sys.get_state(pid)

      assert {:via, PartitionSupervisor, {supervisor, :partitioned_workflow}} =
               state.task_supervisor

      assert state.executor_state.task_supervisor == state.task_supervisor
      assert supervisor == Module.concat(runner, TaskSupervisor)

      :ok = Runner.run(runner, :partitioned_workflow, 5)
      assert_receive {:executor_released, _handle}, 1_000
      wait_until_idle(runner, :partitioned_workflow)

      assert {:ok, results} = Runner.get_results(runner, :partitioned_workflow)
      assert 6 in results
    end
  end

  describe "executor handle lifecycle" do
    setup do
      runner = unique_runner(:executor)
      start_supervised!({Runner, name: runner})
      %{runner: runner}
    end

    test "releases a default executor handle after a result", %{runner: runner} do
      workflow = Runic.workflow(steps: [Runic.step(fn value -> value + 1 end, name: :add)])

      assert {:ok, pid} =
               Runner.start_workflow(runner, :release_result, workflow,
                 executor: ReleasingExecutor,
                 executor_opts: [test_pid: self()]
               )

      :ok = Runner.run(runner, :release_result, 1)
      assert_receive {:executor_released, _handle}, 1_000
      wait_until_idle(runner, :release_result)

      state = :sys.get_state(pid)
      assert state.active_executors == %{}
      assert state.executor_state.handles == MapSet.new()
    end

    test "releases a default executor handle after a crash", %{runner: runner} do
      workflow =
        Runic.workflow(steps: [Runic.step(fn value -> value end, name: :identity)])
        |> Workflow.set_scheduler_policies([
          {:default, %{execution_mode: :durable, on_failure: :halt}}
        ])

      assert {:ok, pid} =
               Runner.start_workflow(runner, :release_crash, workflow,
                 executor: ReleasingExecutor,
                 executor_opts: [test_pid: self(), outcome: :crash]
               )

      :ok = Runner.run(runner, :release_crash, 1)
      assert_receive {:executor_released, _handle}, 1_000
      wait_until_idle(runner, :release_crash)

      state = :sys.get_state(pid)
      assert state.active_executors == %{}
      assert state.executor_state.handles == MapSet.new()

      assert [
               %RunnableFailed{
                 error: {:task_crashed, :test_crash},
                 attempts: 1,
                 failure_action: :halt
               }
             ] = Enum.filter(state.workflow.runnable_events, &match?(%RunnableFailed{}, &1))
    end

    test "releases a policy override executor handle", %{runner: runner} do
      workflow =
        Runic.workflow(steps: [Runic.step(fn value -> value + 1 end, name: :override)])
        |> Workflow.set_scheduler_policies([
          {:override,
           %{
             executor: ReleasingExecutor,
             executor_opts: [test_pid: self()]
           }}
        ])

      assert {:ok, pid} = Runner.start_workflow(runner, :release_override, workflow)

      :ok = Runner.run(runner, :release_override, 1)
      assert_receive {:executor_released, _handle}, 1_000
      wait_until_idle(runner, :release_override)

      state = :sys.get_state(pid)
      assert state.active_executors == %{}
      assert override_state(state, :default).handles == MapSet.new()
    end

    test "keeps default and same-module override executor state separate", %{runner: runner} do
      workflow =
        Runic.workflow(steps: [Runic.step(fn value -> value + 1 end, name: :override)])
        |> Workflow.set_scheduler_policies([
          {:override,
           %{
             executor: ReleasingExecutor,
             executor_opts: [test_pid: self(), label: :override]
           }}
        ])

      assert {:ok, pid} =
               Runner.start_workflow(runner, :same_module_override, workflow,
                 executor: ReleasingExecutor,
                 executor_opts: [test_pid: self(), label: :default]
               )

      :ok = Runner.run(runner, :same_module_override, 1)
      assert_receive {:executor_released, _handle}, 1_000
      wait_until_idle(runner, :same_module_override)

      state = :sys.get_state(pid)
      assert state.executor_state.label == :default
      assert state.executor_state.handles == MapSet.new()
      assert override_state(state, :override).handles == MapSet.new()
    end

    test "keeps same-module override options in separate executor states", %{runner: runner} do
      first = Runic.step(fn value -> value + 1 end, name: :first_override)
      second = Runic.step(fn value -> value + 2 end, name: :second_override)

      workflow =
        Runic.workflow(steps: [first, second])
        |> Workflow.set_scheduler_policies([
          {:first_override,
           %{
             executor: ReleasingExecutor,
             executor_opts: [test_pid: self(), label: :first]
           }},
          {:second_override,
           %{
             executor: ReleasingExecutor,
             executor_opts: [test_pid: self(), label: :second]
           }}
        ])

      assert {:ok, pid} = Runner.start_workflow(runner, :two_override_configs, workflow)

      :ok = Runner.run(runner, :two_override_configs, 1)
      assert_receive {:executor_released, _first_handle}, 1_000
      assert_receive {:executor_released, _second_handle}, 1_000
      wait_until_idle(runner, :two_override_configs)

      state = :sys.get_state(pid)
      assert map_size(state.override_executors) == 2
      assert override_state(state, :first).handles == MapSet.new()
      assert override_state(state, :second).handles == MapSet.new()
    end

    test "releases an executor handle after a promise completes", %{runner: runner} do
      first = Runic.step(fn value -> value + 1 end, name: :first)
      second = Runic.step(fn value -> value * 2 end, name: :second)
      workflow = Runic.workflow(steps: [{first, [second]}])

      assert {:ok, pid} =
               Runner.start_workflow(runner, :release_promise, workflow,
                 executor: ReleasingExecutor,
                 executor_opts: [test_pid: self()],
                 promise_opts: [min_chain_length: 2]
               )

      :ok = Runner.run(runner, :release_promise, 1)
      assert_receive {:executor_released, _handle}, 1_000
      wait_until_idle(runner, :release_promise)

      state = :sys.get_state(pid)
      assert state.active_executors == %{}
      assert state.executor_state.handles == MapSet.new()
      assert {:ok, results} = Runner.get_results(runner, :release_promise)
      assert 4 in results
    end

    test "cleans an executor once when the Worker stops", %{runner: runner} do
      workflow = Runic.workflow(steps: [Runic.step(fn value -> value end, name: :identity)])

      assert {:ok, _pid} =
               Runner.start_workflow(runner, :cleanup_once, workflow,
                 executor: ReleasingExecutor,
                 executor_opts: [test_pid: self(), label: :cleanup_once]
               )

      assert :ok = Runner.stop(runner, :cleanup_once, persist: false)
      assert_receive {:executor_cleaned, :cleanup_once}, 1_000
      refute_receive {:executor_cleaned, :cleanup_once}, 50
    end
  end

  defp persist_after_first_step(runner, workflow_id, workflow) do
    assert {:ok, pid} =
             Runner.start_workflow(runner, workflow_id, workflow, dispatch_mode: :manual)

    :ok = Runner.run(runner, workflow_id, 5)
    :ok = Runner.step(runner, workflow_id)
    wait_until(pid, &(&1.active_tasks == %{}))

    assert Workflow.is_runnable?(:sys.get_state(pid).workflow)
    :ok = Runner.stop(runner, workflow_id)
    wait_until_stopped(pid)
  end

  defp unique_runner(label) do
    String.to_atom("runtime_recovery_#{label}_#{System.unique_integer([:positive])}")
  end

  defp wait_until_idle(runner, workflow_id) do
    pid = Runner.lookup(runner, workflow_id)
    wait_until(pid, &(&1.status == :idle and &1.active_tasks == %{}))
  end

  defp wait_until(pid, predicate, attempts \\ 100)
  defp wait_until(_pid, _predicate, 0), do: flunk("worker did not reach the expected state")

  defp wait_until(pid, predicate, attempts) do
    if predicate.(:sys.get_state(pid)) do
      :ok
    else
      Process.sleep(10)
      wait_until(pid, predicate, attempts - 1)
    end
  end

  defp wait_until_stopped(pid, attempts \\ 100)
  defp wait_until_stopped(_pid, 0), do: flunk("worker did not stop")

  defp wait_until_stopped(pid, attempts) do
    if Process.alive?(pid) do
      Process.sleep(10)
      wait_until_stopped(pid, attempts - 1)
    else
      :ok
    end
  end

  defp override_state(state, label) do
    Enum.find_value(state.override_executors, fn
      {_key, %{label: ^label} = executor_state} -> executor_state
      _entry -> nil
    end)
  end
end
