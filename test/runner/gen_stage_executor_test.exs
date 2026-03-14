defmodule Runic.Runner.Executor.GenStageTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  require Runic
  alias Runic.Runner.Executor.GenStage, as: GenStageExecutor

  # ---------------------------------------------------------------------------
  # A. Unit tests — Executor behaviour
  # ---------------------------------------------------------------------------

  describe "init/1" do
    test "starts producer and consumers" do
      {:ok, state} = GenStageExecutor.init(max_demand: 2)

      assert is_pid(state.producer)
      assert Process.alive?(state.producer)
      assert length(state.consumers) == 2
      assert Enum.all?(state.consumers, &Process.alive?/1)

      GenStageExecutor.cleanup(state)
    end

    test "defaults max_demand to System.schedulers_online()" do
      {:ok, state} = GenStageExecutor.init([])

      assert length(state.consumers) == System.schedulers_online()

      GenStageExecutor.cleanup(state)
    end
  end

  describe "dispatch/3" do
    test "dispatches work and receives result" do
      {:ok, state} = GenStageExecutor.init(max_demand: 2)

      work_fn = fn -> {:ok, 42} end
      {handle, _state} = GenStageExecutor.dispatch(work_fn, [], state)

      assert is_reference(handle)
      assert_receive {^handle, {:ok, 42}}, 1000

      GenStageExecutor.cleanup(state)
    end

    test "dispatches multiple work items concurrently" do
      {:ok, state} = GenStageExecutor.init(max_demand: 4)

      handles =
        for i <- 1..4 do
          work_fn = fn -> {:result, i} end
          {handle, _state} = GenStageExecutor.dispatch(work_fn, [], state)
          handle
        end

      results =
        for handle <- handles do
          assert_receive {^handle, result}, 1000
          result
        end

      assert Enum.sort(results) == [{:result, 1}, {:result, 2}, {:result, 3}, {:result, 4}]

      GenStageExecutor.cleanup(state)
    end

    test "sends synthetic :DOWN on work_fn crash" do
      {:ok, state} = GenStageExecutor.init(max_demand: 2)

      work_fn = fn -> raise "intentional failure" end
      {handle, _state} = GenStageExecutor.dispatch(work_fn, [], state)

      assert_receive {:DOWN, ^handle, :process, _pid, {:error, %RuntimeError{}}}, 1000

      GenStageExecutor.cleanup(state)
    end

    test "sends synthetic :DOWN on work_fn throw" do
      {:ok, state} = GenStageExecutor.init(max_demand: 2)

      work_fn = fn -> throw(:bad_value) end
      {handle, _state} = GenStageExecutor.dispatch(work_fn, [], state)

      assert_receive {:DOWN, ^handle, :process, _pid, {:throw, :bad_value}}, 1000

      GenStageExecutor.cleanup(state)
    end

    test "sends synthetic :DOWN on work_fn exit" do
      {:ok, state} = GenStageExecutor.init(max_demand: 2)

      work_fn = fn -> exit(:abnormal) end
      {handle, _state} = GenStageExecutor.dispatch(work_fn, [], state)

      assert_receive {:DOWN, ^handle, :process, _pid, {:exit, :abnormal}}, 1000

      GenStageExecutor.cleanup(state)
    end

    test "consumer continues processing after a failure" do
      {:ok, state} = GenStageExecutor.init(max_demand: 1)

      # First: failing work
      fail_fn = fn -> raise "fail" end
      {fail_handle, state} = GenStageExecutor.dispatch(fail_fn, [], state)
      assert_receive {:DOWN, ^fail_handle, :process, _, _}, 1000

      # Second: successful work (same consumer should handle it)
      ok_fn = fn -> :success end
      {ok_handle, _state} = GenStageExecutor.dispatch(ok_fn, [], state)
      assert_receive {^ok_handle, :success}, 1000

      GenStageExecutor.cleanup(state)
    end
  end

  describe "back-pressure" do
    test "max_demand limits concurrent execution" do
      {:ok, state} = GenStageExecutor.init(max_demand: 2)

      parent = self()
      barrier = :erlang.make_ref()

      # Dispatch 4 work items that block until released
      handles =
        for i <- 1..4 do
          work_fn = fn ->
            send(parent, {:started, i, self()})

            receive do
              ^barrier -> :ok
            end

            {:done, i}
          end

          {handle, _state} = GenStageExecutor.dispatch(work_fn, [], state)
          handle
        end

      # Only 2 should start (max_demand: 2)
      assert_receive {:started, _, pid1}, 1000
      assert_receive {:started, _, pid2}, 1000
      refute_receive {:started, _, _}, 100

      # Release the first wave
      send(pid1, barrier)
      send(pid2, barrier)

      # Next 2 should start
      assert_receive {:started, _, pid3}, 1000
      assert_receive {:started, _, pid4}, 1000

      # Release the second wave
      send(pid3, barrier)
      send(pid4, barrier)

      # Wait for all 4 to complete
      for handle <- handles do
        assert_receive {^handle, {:done, _}}, 2000
      end

      GenStageExecutor.cleanup(state)
    end
  end

  describe "cleanup/1" do
    test "stops all processes" do
      {:ok, state} = GenStageExecutor.init(max_demand: 2)

      assert Process.alive?(state.producer)
      assert Enum.all?(state.consumers, &Process.alive?/1)

      GenStageExecutor.cleanup(state)

      Process.sleep(50)
      refute Process.alive?(state.producer)
      refute Enum.any?(state.consumers, &Process.alive?/1)
    end
  end

  # ---------------------------------------------------------------------------
  # B. Integration tests — Worker + GenStage Executor
  # ---------------------------------------------------------------------------

  describe "integration with Worker" do
    setup do
      runner_name = :"test_runner_gs_exec_#{System.unique_integer([:positive])}"
      start_supervised!({Runic.Runner, name: runner_name})
      %{runner: runner_name}
    end

    test "basic pipeline produces correct results", %{runner: runner} do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      workflow = Runic.workflow(steps: [{step_a, [step_b]}])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_gs_basic, workflow,
          executor: GenStageExecutor,
          executor_opts: [max_demand: 2]
        )

      :ok = Runic.Runner.run(runner, :wf_gs_basic, 5)
      assert_workflow_idle(runner, :wf_gs_basic)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_gs_basic)
      # 5 → 6 → 12
      assert 12 in results
    end

    test "parallel independent steps", %{runner: runner} do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      step_c = Runic.step(fn x -> x + 10 end, name: :c)

      workflow = Runic.workflow(steps: [step_a, step_b, step_c])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_gs_parallel, workflow,
          executor: GenStageExecutor,
          executor_opts: [max_demand: 4]
        )

      :ok = Runic.Runner.run(runner, :wf_gs_parallel, 5)
      assert_workflow_idle(runner, :wf_gs_parallel)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_gs_parallel)
      assert 6 in results
      assert 10 in results
      assert 15 in results
    end

    test "behavioral equivalence with Task executor", %{runner: runner} do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      step_c = Runic.step(fn x -> x - 1 end, name: :c)
      workflow = Runic.workflow(steps: [{step_a, [{step_b, [step_c]}]}])

      # Default Task executor
      {:ok, _} = Runic.Runner.start_workflow(runner, :wf_gs_equiv_task, workflow)
      :ok = Runic.Runner.run(runner, :wf_gs_equiv_task, 10)
      assert_workflow_idle(runner, :wf_gs_equiv_task)
      {:ok, task_results} = Runic.Runner.get_results(runner, :wf_gs_equiv_task)

      # GenStage executor
      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_gs_equiv_gs, workflow,
          executor: GenStageExecutor,
          executor_opts: [max_demand: 4]
        )

      :ok = Runic.Runner.run(runner, :wf_gs_equiv_gs, 10)
      assert_workflow_idle(runner, :wf_gs_equiv_gs)
      {:ok, gs_results} = Runic.Runner.get_results(runner, :wf_gs_equiv_gs)

      assert Enum.sort(task_results) == Enum.sort(gs_results)
    end

    test "handles runnable failures gracefully", %{runner: runner} do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)

      step_b =
        Runic.step(fn _x -> raise "intentional" end, name: :b)

      workflow = Runic.workflow(steps: [{step_a, [step_b]}])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_gs_fail, workflow,
          executor: GenStageExecutor,
          executor_opts: [max_demand: 2]
        )

      :ok = Runic.Runner.run(runner, :wf_gs_fail, 5)
      assert_workflow_idle(runner, :wf_gs_fail)

      # step_a completes, step_b fails — should not crash the Worker
      {:ok, results} = Runic.Runner.get_results(runner, :wf_gs_fail)
      assert 6 in results
    end

    test "fan-out workflow", %{runner: runner} do
      root = Runic.step(fn x -> x + 1 end, name: :root)
      branch_a = Runic.step(fn x -> x * 2 end, name: :br_a)
      branch_b = Runic.step(fn x -> x * 3 end, name: :br_b)

      workflow = Runic.workflow(steps: [{root, [branch_a, branch_b]}])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_gs_fanout, workflow,
          executor: GenStageExecutor,
          executor_opts: [max_demand: 4]
        )

      :ok = Runic.Runner.run(runner, :wf_gs_fanout, 5)
      assert_workflow_idle(runner, :wf_gs_fanout)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_gs_fanout)
      # 5 → 6, then 12 and 18
      assert 12 in results
      assert 18 in results
    end

    test "works with ChainBatching scheduler", %{runner: runner} do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      step_c = Runic.step(fn x -> x - 1 end, name: :c)
      workflow = Runic.workflow(steps: [{step_a, [{step_b, [step_c]}]}])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_gs_chain, workflow,
          executor: GenStageExecutor,
          executor_opts: [max_demand: 2],
          scheduler: Runic.Runner.Scheduler.ChainBatching,
          scheduler_opts: [min_chain_length: 2]
        )

      :ok = Runic.Runner.run(runner, :wf_gs_chain, 5)
      assert_workflow_idle(runner, :wf_gs_chain)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_gs_chain)
      # 5 → 6 → 12 → 11
      assert 11 in results
    end

    test "cleanup stops internal processes on workflow stop", %{runner: runner} do
      step = Runic.step(fn x -> x + 1 end, name: :a)
      workflow = Runic.workflow(steps: [step])

      {:ok, pid} =
        Runic.Runner.start_workflow(runner, :wf_gs_cleanup, workflow,
          executor: GenStageExecutor,
          executor_opts: [max_demand: 2]
        )

      state = :sys.get_state(pid)
      producer = state.executor_state.producer
      consumers = state.executor_state.consumers

      assert Process.alive?(producer)
      assert Enum.all?(consumers, &Process.alive?/1)

      Runic.Runner.stop(runner, :wf_gs_cleanup)
      Process.sleep(100)

      refute Process.alive?(producer)
      refute Enum.any?(consumers, &Process.alive?/1)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp assert_workflow_idle(runner, workflow_id, timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll_until_idle(runner, workflow_id, deadline)
  end

  defp poll_until_idle(runner, workflow_id, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      flunk("Workflow #{inspect(workflow_id)} did not reach idle within timeout")
    end

    case Runic.Runner.lookup(runner, workflow_id) do
      nil ->
        flunk("Workflow #{inspect(workflow_id)} not found")

      pid ->
        state = :sys.get_state(pid)

        if state.status == :idle and map_size(state.active_tasks) == 0 do
          :ok
        else
          Process.sleep(10)
          poll_until_idle(runner, workflow_id, deadline)
        end
    end
  end
end
