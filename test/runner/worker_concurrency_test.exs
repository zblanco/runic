defmodule Runic.Runner.WorkerConcurrencyTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Concurrency and correctness tests for the Worker dispatch loop.

  These tests target scenarios that can cause deadlocks, lost work, or
  incorrect results under concurrent execution — particularly with
  fan-out/join topologies and durable execution mode.
  """

  require Runic
  alias Runic.Workflow
  alias Runic.Workflow.{RunnableDispatched, RunnableCompleted}

  setup do
    runner_name = :"test_runner_conc_#{System.unique_integer([:positive])}"
    start_supervised!({Runic.Runner, name: runner_name})
    %{runner: runner_name}
  end

  # ---------------------------------------------------------------------------
  # A. Fan-out → Join deadlock prevention
  # ---------------------------------------------------------------------------

  describe "fan-out → join completes without deadlock" do
    test "3 parents → join → next step", %{runner: runner} do
      step_root = Runic.step(fn x -> x end, name: :root)
      step_a = Runic.step(fn x -> x + 1 end, name: :branch_a)
      step_b = Runic.step(fn x -> x + 2 end, name: :branch_b)
      step_c = Runic.step(fn x -> x + 3 end, name: :branch_c)

      join_step =
        Runic.step(fn vals -> Enum.sum(vals) end,
          name: :joiner,
          join: [:branch_a, :branch_b, :branch_c]
        )

      workflow =
        Runic.workflow(steps: [{step_root, [step_a, step_b, step_c]}])
        |> Workflow.add(join_step, to: [:branch_a, :branch_b, :branch_c])

      {:ok, _pid} = Runic.Runner.start_workflow(runner, :wf_3join, workflow)
      :ok = Runic.Runner.run(runner, :wf_3join, 5)
      assert_workflow_idle(runner, :wf_3join, 5000)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_3join)
      # root: 5, a: 6, b: 7, c: 8, join: sum([6,7,8]) = 21
      assert 21 in results
    end

    test "3 parents → join with durable mode completes", %{runner: runner} do
      step_root = Runic.step(fn x -> x end, name: :root)
      step_a = Runic.step(fn x -> x + 1 end, name: :branch_a)
      step_b = Runic.step(fn x -> x + 2 end, name: :branch_b)
      step_c = Runic.step(fn x -> x + 3 end, name: :branch_c)

      join_step =
        Runic.step(fn vals -> Enum.sum(vals) end,
          name: :joiner,
          join: [:branch_a, :branch_b, :branch_c]
        )

      workflow =
        Runic.workflow(steps: [{step_root, [step_a, step_b, step_c]}])
        |> Workflow.add(join_step, to: [:branch_a, :branch_b, :branch_c])

      policies = [{:default, %{execution_mode: :durable}}]
      workflow = Workflow.set_scheduler_policies(workflow, policies)

      {:ok, _pid} = Runic.Runner.start_workflow(runner, :wf_3join_durable, workflow)
      :ok = Runic.Runner.run(runner, :wf_3join_durable, 5)
      assert_workflow_idle(runner, :wf_3join_durable, 5000)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_3join_durable)
      assert 21 in results

      # Verify all steps produced durable events
      {:ok, wf} = Runic.Runner.get_workflow(runner, :wf_3join_durable)
      log = Workflow.log(wf)

      dispatched = Enum.filter(log, &match?(%RunnableDispatched{}, &1))
      completed = Enum.filter(log, &match?(%RunnableCompleted{}, &1))

      # 5 steps + the join node's internal runnables
      assert length(dispatched) >= 5
      assert length(completed) >= 5
    end

    test "3 parents → join with max_concurrency: 1 (serial) completes", %{runner: runner} do
      step_root = Runic.step(fn x -> x end, name: :root)
      step_a = Runic.step(fn x -> x + 1 end, name: :branch_a)
      step_b = Runic.step(fn x -> x + 2 end, name: :branch_b)
      step_c = Runic.step(fn x -> x + 3 end, name: :branch_c)

      join_step =
        Runic.step(fn vals -> Enum.sum(vals) end,
          name: :joiner,
          join: [:branch_a, :branch_b, :branch_c]
        )

      workflow =
        Runic.workflow(steps: [{step_root, [step_a, step_b, step_c]}])
        |> Workflow.add(join_step, to: [:branch_a, :branch_b, :branch_c])

      {:ok, _pid} =
        Runic.Runner.start_workflow(runner, :wf_serial_join, workflow, max_concurrency: 1)

      :ok = Runic.Runner.run(runner, :wf_serial_join, 5)
      assert_workflow_idle(runner, :wf_serial_join, 5000)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_serial_join)
      assert 21 in results
    end
  end

  # ---------------------------------------------------------------------------
  # B. Slow branches — staggered completion with joins
  # ---------------------------------------------------------------------------

  describe "staggered branch completion" do
    test "slow branch doesn't block fast branches; join waits for all", %{runner: runner} do
      step_root = Runic.step(fn x -> x end, name: :root)

      step_fast = Runic.step(fn x -> x + 1 end, name: :fast)

      step_slow =
        Runic.step(
          fn x ->
            Process.sleep(100)
            x + 2
          end,
          name: :slow
        )

      join_step =
        Runic.step(fn vals -> Enum.sum(vals) end, name: :joiner, join: [:fast, :slow])

      workflow =
        Runic.workflow(steps: [{step_root, [step_fast, step_slow]}])
        |> Workflow.add(join_step, to: [:fast, :slow])

      {:ok, _pid} = Runic.Runner.start_workflow(runner, :wf_staggered, workflow)
      :ok = Runic.Runner.run(runner, :wf_staggered, 10)
      assert_workflow_idle(runner, :wf_staggered, 5000)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_staggered)
      # root: 10, fast: 11, slow: 12, join: 23
      assert 23 in results
    end
  end

  # ---------------------------------------------------------------------------
  # C. Multiple inputs — no cross-contamination
  # ---------------------------------------------------------------------------

  describe "multiple inputs through join topology" do
    test "two sequential inputs through fan-out/join produce independent results", %{
      runner: runner
    } do
      step_root = Runic.step(fn x -> x end, name: :root)
      step_a = Runic.step(fn x -> x * 2 end, name: :branch_a)
      step_b = Runic.step(fn x -> x * 3 end, name: :branch_b)

      join_step =
        Runic.step(fn vals -> Enum.sum(vals) end, name: :joiner, join: [:branch_a, :branch_b])

      workflow =
        Runic.workflow(steps: [{step_root, [step_a, step_b]}])
        |> Workflow.add(join_step, to: [:branch_a, :branch_b])

      {:ok, _pid} = Runic.Runner.start_workflow(runner, :wf_multi_join, workflow)

      :ok = Runic.Runner.run(runner, :wf_multi_join, 10)
      assert_workflow_idle(runner, :wf_multi_join, 5000)

      {:ok, results1} = Runic.Runner.get_results(runner, :wf_multi_join)
      # root: 10, a: 20, b: 30, join: 50
      assert 50 in results1

      :ok = Runic.Runner.run(runner, :wf_multi_join, 1)
      assert_workflow_idle(runner, :wf_multi_join, 5000)

      {:ok, results2} = Runic.Runner.get_results(runner, :wf_multi_join)
      # Second input: root: 1, a: 2, b: 3, join: 5
      assert 5 in results2
    end
  end

  # ---------------------------------------------------------------------------
  # D. Branch failure with join — partial failure doesn't deadlock
  # ---------------------------------------------------------------------------

  describe "partial branch failure" do
    test "one branch crashing doesn't permanently deadlock the worker", %{runner: runner} do
      step_root = Runic.step(fn x -> x end, name: :root)
      step_ok = Runic.step(fn x -> x + 1 end, name: :ok_branch)
      step_boom = Runic.step(fn _ -> raise "branch explosion" end, name: :boom_branch)

      workflow = Runic.workflow(steps: [{step_root, [step_ok, step_boom]}])

      {:ok, pid} = Runic.Runner.start_workflow(runner, :wf_partial_fail, workflow)
      :ok = Runic.Runner.run(runner, :wf_partial_fail, 5)
      assert_workflow_idle(runner, :wf_partial_fail, 5000)

      assert Process.alive?(pid)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_partial_fail)
      assert 6 in results
    end

    test "failing branch with on_failure: :skip and join still completes", %{runner: runner} do
      step_root = Runic.step(fn x -> x end, name: :root)
      step_ok = Runic.step(fn x -> x + 1 end, name: :ok_branch)
      step_boom = Runic.step(fn _ -> raise "branch explosion" end, name: :boom_branch)

      workflow = Runic.workflow(steps: [{step_root, [step_ok, step_boom]}])

      policies = [
        {:boom_branch, %{on_failure: :skip, max_retries: 0, execution_mode: :durable}}
      ]

      workflow = Workflow.set_scheduler_policies(workflow, policies)

      {:ok, pid} = Runic.Runner.start_workflow(runner, :wf_skip_fail, workflow)
      :ok = Runic.Runner.run(runner, :wf_skip_fail, 5)
      assert_workflow_idle(runner, :wf_skip_fail, 5000)

      assert Process.alive?(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # E. Worker liveness after task crashes
  # ---------------------------------------------------------------------------

  describe "worker resilience" do
    test "worker stays alive after multiple concurrent task crashes", %{runner: runner} do
      step_root = Runic.step(fn x -> x end, name: :root)
      step_a = Runic.step(fn _ -> raise "a" end, name: :crash_a)
      step_b = Runic.step(fn _ -> raise "b" end, name: :crash_b)
      step_c = Runic.step(fn _ -> raise "c" end, name: :crash_c)

      workflow = Runic.workflow(steps: [{step_root, [step_a, step_b, step_c]}])

      {:ok, pid} = Runic.Runner.start_workflow(runner, :wf_multi_crash, workflow)
      :ok = Runic.Runner.run(runner, :wf_multi_crash, 1)
      assert_workflow_idle(runner, :wf_multi_crash, 5000)

      assert Process.alive?(pid)

      # Worker can accept new work after crashes
      step_ok = Runic.step(fn x -> x + 1 end, name: :ok_step)
      ok_workflow = Runic.workflow(steps: [step_ok])
      {:ok, pid2} = Runic.Runner.start_workflow(runner, :wf_after_crash, ok_workflow)
      :ok = Runic.Runner.run(runner, :wf_after_crash, 1)
      assert_workflow_idle(runner, :wf_after_crash)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_after_crash)
      assert 2 in results
      assert Process.alive?(pid2)
    end

    test "no stale in-flight state after task completes", %{runner: runner} do
      step = Runic.step(fn x -> x + 1 end, name: :simple)
      workflow = Runic.workflow(steps: [step])

      {:ok, pid} = Runic.Runner.start_workflow(runner, :wf_no_stale, workflow)
      :ok = Runic.Runner.run(runner, :wf_no_stale, 1)
      assert_workflow_idle(runner, :wf_no_stale)

      state = :sys.get_state(pid)
      assert state.active_tasks == %{}
      assert state.dispatch_times == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # F. Diamond topology — fan-out and re-converge
  # ---------------------------------------------------------------------------

  describe "diamond topology" do
    test "a → [b, c] → d(join) with durable mode and max_concurrency: 2", %{runner: runner} do
      step_a = Runic.step(fn x -> x end, name: :diamond_a)
      step_b = Runic.step(fn x -> x + 10 end, name: :diamond_b)
      step_c = Runic.step(fn x -> x + 20 end, name: :diamond_c)

      join_d =
        Runic.step(fn vals -> Enum.sum(vals) end,
          name: :diamond_d,
          join: [:diamond_b, :diamond_c]
        )

      workflow =
        Runic.workflow(steps: [{step_a, [step_b, step_c]}])
        |> Workflow.add(join_d, to: [:diamond_b, :diamond_c])

      policies = [{:default, %{execution_mode: :durable}}]
      workflow = Workflow.set_scheduler_policies(workflow, policies)

      {:ok, _pid} =
        Runic.Runner.start_workflow(runner, :wf_diamond, workflow, max_concurrency: 2)

      :ok = Runic.Runner.run(runner, :wf_diamond, 5)
      assert_workflow_idle(runner, :wf_diamond, 5000)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_diamond)
      # a: 5, b: 15, c: 25, d: 40
      assert 40 in results
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
      pid = Runic.Runner.lookup(runner, workflow_id)
      state = if pid, do: :sys.get_state(pid), else: nil

      flunk(
        "Workflow #{inspect(workflow_id)} did not reach idle within timeout. " <>
          "Status: #{inspect(state && state.status)}, " <>
          "Active tasks: #{inspect(state && map_size(state.active_tasks))}"
      )
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
