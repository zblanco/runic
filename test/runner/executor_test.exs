defmodule Runic.Runner.ExecutorTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  require Runic
  alias Runic.Workflow

  setup do
    runner_name = :"test_runner_exec_#{System.unique_integer([:positive])}"
    start_supervised!({Runic.Runner, name: runner_name})
    %{runner: runner_name}
  end

  # ---------------------------------------------------------------------------
  # A. Executor.Task — explicit configuration
  # ---------------------------------------------------------------------------

  describe "explicit Executor.Task" do
    test "produces identical results to default (no executor specified)", %{runner: runner} do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      workflow = Runic.workflow(steps: [{step_a, [step_b]}])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_explicit_exec, workflow,
          executor: Runic.Runner.Executor.Task
        )

      :ok = Runic.Runner.run(runner, :wf_explicit_exec, 5)
      assert_workflow_idle(runner, :wf_explicit_exec)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_explicit_exec)
      # 5 -> 6 -> 12
      assert 12 in results
    end

    test "Worker state contains executor fields", %{runner: runner} do
      workflow = build_single_step_workflow()

      {:ok, pid} =
        Runic.Runner.start_workflow(runner, :wf_exec_state, workflow,
          executor: Runic.Runner.Executor.Task
        )

      state = :sys.get_state(pid)
      assert state.executor == Runic.Runner.Executor.Task
      assert is_map(state.executor_state)
      assert Map.has_key?(state.executor_state, :task_supervisor)
    end
  end

  # ---------------------------------------------------------------------------
  # B. Inline executor
  # ---------------------------------------------------------------------------

  describe "inline executor" do
    test "executes synchronously in Worker process", %{runner: runner} do
      test_pid = self()

      step =
        Runic.step(
          fn x ->
            send(test_pid, {:executor_pid, self()})
            x + 1
          end,
          name: :inline_step
        )

      workflow = Runic.workflow(steps: [step])

      {:ok, worker_pid} =
        Runic.Runner.start_workflow(runner, :wf_inline, workflow, executor: :inline)

      :ok = Runic.Runner.run(runner, :wf_inline, 5)
      assert_workflow_idle(runner, :wf_inline)

      # The step executed in the Worker process (inline), not a spawned task
      assert_receive {:executor_pid, exec_pid}
      assert exec_pid == worker_pid

      {:ok, results} = Runic.Runner.get_results(runner, :wf_inline)
      assert 6 in results
    end

    test "inline pipeline processes multi-step chain", %{runner: runner} do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      step_c = Runic.step(fn x -> x - 1 end, name: :c)

      workflow = Runic.workflow(steps: [{step_a, [{step_b, [step_c]}]}])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_inline_pipe, workflow, executor: :inline)

      :ok = Runic.Runner.run(runner, :wf_inline_pipe, 5)
      assert_workflow_idle(runner, :wf_inline_pipe)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_inline_pipe)
      # 5 -> 6 -> 12 -> 11
      assert 11 in results
    end

    test "inline executor skips timeout but preserves retry", %{runner: runner} do
      counter = :counters.new(1, [:atomics])

      flaky_fn = fn x ->
        count = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)

        if count < 1 do
          raise "flaky failure"
        else
          x * 10
        end
      end

      step = Runic.step(flaky_fn, name: :flaky_inline)
      workflow = Runic.workflow(steps: [step])
      policies = [{:flaky_inline, %{max_retries: 2, timeout_ms: 1}}]
      workflow = Workflow.set_scheduler_policies(workflow, policies)

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_inline_retry, workflow, executor: :inline)

      :ok = Runic.Runner.run(runner, :wf_inline_retry, 7)
      assert_workflow_idle(runner, :wf_inline_retry)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_inline_retry)
      # Should succeed on retry despite 1ms timeout (timeout is skipped for inline)
      assert 70 in results
    end
  end

  # ---------------------------------------------------------------------------
  # C. Per-component executor overrides (Phase 3)
  # ---------------------------------------------------------------------------

  describe "per-component executor overrides" do
    test "policy executor: :inline runs that runnable inline while others use Task", %{
      runner: runner
    } do
      test_pid = self()

      step_a =
        Runic.step(
          fn x ->
            send(test_pid, {:step_a_pid, self()})
            x + 1
          end,
          name: :task_step
        )

      step_b =
        Runic.step(
          fn x ->
            send(test_pid, {:step_b_pid, self()})
            x * 2
          end,
          name: :inline_step
        )

      workflow = Runic.workflow(steps: [{step_a, [step_b]}])
      policies = [{:inline_step, %{executor: :inline}}]
      workflow = Workflow.set_scheduler_policies(workflow, policies)

      {:ok, worker_pid} =
        Runic.Runner.start_workflow(runner, :wf_mixed, workflow)

      :ok = Runic.Runner.run(runner, :wf_mixed, 5)
      assert_workflow_idle(runner, :wf_mixed)

      # step_a ran in a Task (different pid)
      assert_receive {:step_a_pid, step_a_pid}
      assert step_a_pid != worker_pid

      # step_b ran inline in the Worker (same pid)
      assert_receive {:step_b_pid, step_b_pid}
      assert step_b_pid == worker_pid

      {:ok, results} = Runic.Runner.get_results(runner, :wf_mixed)
      # 5 -> 6 -> 12
      assert 12 in results
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp build_single_step_workflow do
    step = Runic.step(fn x -> x + 1 end, name: :add_one)
    Runic.workflow(steps: [step])
  end

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
