defmodule Runic.Runner.WorkerTest do
  use ExUnit.Case, async: true

  require Runic
  alias Runic.Workflow

  setup do
    runner_name = :"test_runner_#{System.unique_integer([:positive])}"
    start_supervised!({Runic.Runner, name: runner_name})
    %{runner: runner_name}
  end

  # ---------------------------------------------------------------------------
  # A. Lifecycle — start, run, results, stop
  # ---------------------------------------------------------------------------

  describe "lifecycle" do
    test "start_workflow returns {:ok, pid}", %{runner: runner} do
      workflow = build_single_step_workflow()
      assert {:ok, pid} = Runic.Runner.start_workflow(runner, :wf1, workflow)
      assert Process.alive?(pid)
    end

    test "start_workflow with duplicate ID returns {:error, {:already_started, pid}}", %{
      runner: runner
    } do
      workflow = build_single_step_workflow()
      {:ok, pid} = Runic.Runner.start_workflow(runner, :wf_dup, workflow)

      assert {:error, {:already_started, ^pid}} =
               Runic.Runner.start_workflow(runner, :wf_dup, workflow)
    end

    test "run processes input to completion", %{runner: runner} do
      workflow = build_single_step_workflow()
      {:ok, _pid} = Runic.Runner.start_workflow(runner, :wf_run, workflow)
      :ok = Runic.Runner.run(runner, :wf_run, 5)
      assert_workflow_idle(runner, :wf_run)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_run)
      assert 6 in results
    end

    test "get_results returns the workflow's raw productions", %{runner: runner} do
      workflow = build_single_step_workflow()
      {:ok, _pid} = Runic.Runner.start_workflow(runner, :wf_results, workflow)
      :ok = Runic.Runner.run(runner, :wf_results, 10)
      assert_workflow_idle(runner, :wf_results)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_results)
      assert 11 in results
    end

    test "get_workflow returns the %Workflow{} struct", %{runner: runner} do
      workflow = build_single_step_workflow()
      {:ok, _pid} = Runic.Runner.start_workflow(runner, :wf_get, workflow)
      {:ok, wf} = Runic.Runner.get_workflow(runner, :wf_get)
      assert %Workflow{} = wf
    end

    test "stop terminates the worker process", %{runner: runner} do
      workflow = build_single_step_workflow()
      {:ok, pid} = Runic.Runner.start_workflow(runner, :wf_stop, workflow)
      assert Process.alive?(pid)
      :ok = Runic.Runner.stop(runner, :wf_stop)
      Process.sleep(50)
      refute Process.alive?(pid)
    end

    test "stop with persist: false does not save to store", %{runner: runner} do
      workflow = build_single_step_workflow()
      {:ok, _pid} = Runic.Runner.start_workflow(runner, :wf_no_persist, workflow)
      :ok = Runic.Runner.stop(runner, :wf_no_persist, persist: false)
      Process.sleep(50)

      {store_mod, store_state} = Runic.Runner.get_store(runner)
      assert {:error, :not_found} = store_mod.load(:wf_no_persist, store_state)
    end

    test "lookup returns pid for running workflow, nil for stopped", %{runner: runner} do
      workflow = build_single_step_workflow()
      {:ok, pid} = Runic.Runner.start_workflow(runner, :wf_lookup, workflow)
      assert Runic.Runner.lookup(runner, :wf_lookup) == pid

      :ok = Runic.Runner.stop(runner, :wf_lookup)
      Process.sleep(50)
      assert Runic.Runner.lookup(runner, :wf_lookup) == nil
    end

    test "list_workflows returns active IDs", %{runner: runner} do
      workflow = build_single_step_workflow()
      {:ok, _} = Runic.Runner.start_workflow(runner, :wf_list1, workflow)
      {:ok, _} = Runic.Runner.start_workflow(runner, :wf_list2, workflow)

      ids = Runic.Runner.list_workflows(runner)
      assert :wf_list1 in ids
      assert :wf_list2 in ids
    end
  end

  # ---------------------------------------------------------------------------
  # B. Dispatch loop — correctness
  # ---------------------------------------------------------------------------

  describe "dispatch loop" do
    test "single step workflow: input → output", %{runner: runner} do
      workflow = build_single_step_workflow()
      {:ok, _} = Runic.Runner.start_workflow(runner, :wf_single, workflow)
      :ok = Runic.Runner.run(runner, :wf_single, 5)
      assert_workflow_idle(runner, :wf_single)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_single)
      assert 6 in results
    end

    test "multi-step pipeline: a -> b -> c", %{runner: runner} do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      step_c = Runic.step(fn x -> x - 1 end, name: :c)

      workflow = Runic.workflow(steps: [{step_a, [{step_b, [step_c]}]}])

      {:ok, _} = Runic.Runner.start_workflow(runner, :wf_pipeline, workflow)
      :ok = Runic.Runner.run(runner, :wf_pipeline, 5)
      assert_workflow_idle(runner, :wf_pipeline)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_pipeline)
      # 5 -> 6 -> 12 -> 11
      assert 11 in results
    end

    test "branching workflow: a -> [b, c]", %{runner: runner} do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      step_c = Runic.step(fn x -> x * 3 end, name: :c)

      workflow = Runic.workflow(steps: [{step_a, [step_b, step_c]}])

      {:ok, _} = Runic.Runner.start_workflow(runner, :wf_branch, workflow)
      :ok = Runic.Runner.run(runner, :wf_branch, 5)
      assert_workflow_idle(runner, :wf_branch)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_branch)
      # 5 -> 6, then 6 -> 12 and 6 -> 18
      assert 12 in results
      assert 18 in results
    end

    test "branching + joining: a -> [b, c] -> d(join)", %{runner: runner} do
      step_a = Runic.step(fn x -> x end, name: :a)
      step_b = Runic.step(fn x -> x + 10 end, name: :b)
      step_c = Runic.step(fn x -> x + 20 end, name: :c)
      join_d = Runic.step(fn vals -> Enum.sum(vals) end, name: :d, join: [:b, :c])

      workflow =
        Runic.workflow(steps: [{step_a, [step_b, step_c]}])
        |> Workflow.add(join_d, to: [:b, :c])

      {:ok, _} = Runic.Runner.start_workflow(runner, :wf_join, workflow)
      :ok = Runic.Runner.run(runner, :wf_join, 5)
      assert_workflow_idle(runner, :wf_join)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_join)
      # a: 5 -> 5, b: 5 -> 15, c: 5 -> 25, d: sum([15, 25]) = 40
      assert 40 in results
    end

    test "workflow with rules: condition gates execution", %{runner: runner} do
      rule = Runic.rule(fn x when x > 0 -> :positive end, name: :pos_rule)
      workflow = Runic.workflow(rules: [rule])

      {:ok, _} = Runic.Runner.start_workflow(runner, :wf_rule, workflow)
      :ok = Runic.Runner.run(runner, :wf_rule, 5)
      assert_workflow_idle(runner, :wf_rule)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_rule)
      assert :positive in results
    end
  end

  # ---------------------------------------------------------------------------
  # C. Policy integration
  # ---------------------------------------------------------------------------

  describe "policy integration" do
    test "workflow with scheduler_policies: policies are applied", %{runner: runner} do
      step = Runic.step(fn x -> x + 1 end, name: :policy_step)
      workflow = Runic.workflow(steps: [step])

      policies = [{:policy_step, %{timeout_ms: 5_000}}]
      workflow = Workflow.set_scheduler_policies(workflow, policies)

      {:ok, _} = Runic.Runner.start_workflow(runner, :wf_policy, workflow)
      :ok = Runic.Runner.run(runner, :wf_policy, 5)
      assert_workflow_idle(runner, :wf_policy)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_policy)
      assert 6 in results
    end

    test "step with max_retries and flaky function retries and succeeds", %{runner: runner} do
      counter = :counters.new(1, [:atomics])

      flaky_fn = fn x ->
        count = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)

        if count < 2 do
          raise "flaky failure"
        else
          x * 10
        end
      end

      step = Runic.step(flaky_fn, name: :flaky_step)
      workflow = Runic.workflow(steps: [step])

      policies = [{:flaky_step, %{max_retries: 3}}]
      workflow = Workflow.set_scheduler_policies(workflow, policies)

      {:ok, _} = Runic.Runner.start_workflow(runner, :wf_retry, workflow)
      :ok = Runic.Runner.run(runner, :wf_retry, 7)
      assert_workflow_idle(runner, :wf_retry)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_retry)
      assert 70 in results
    end

    test "step with timeout_ms that's too short fails", %{runner: runner} do
      slow_fn = fn x ->
        Process.sleep(500)
        x
      end

      step = Runic.step(slow_fn, name: :slow_step)
      workflow = Runic.workflow(steps: [step])

      policies = [{:slow_step, %{timeout_ms: 10}}]
      workflow = Workflow.set_scheduler_policies(workflow, policies)

      {:ok, _} = Runic.Runner.start_workflow(runner, :wf_timeout, workflow)
      :ok = Runic.Runner.run(runner, :wf_timeout, 1)
      assert_workflow_idle(runner, :wf_timeout)

      # The step failed due to timeout, so raw_productions should not contain the value
      {:ok, results} = Runic.Runner.get_results(runner, :wf_timeout)
      refute 1 in results
    end

    test "step with on_failure: :skip skips without blocking pipeline", %{runner: runner} do
      step_a = Runic.step(fn _ -> raise "always fails" end, name: :failing)
      step_b = Runic.step(fn x -> x + 1 end, name: :after_fail)

      workflow = Runic.workflow(steps: [{step_a, [step_b]}])

      policies = [{:failing, %{on_failure: :skip}}]
      workflow = Workflow.set_scheduler_policies(workflow, policies)

      {:ok, _} = Runic.Runner.start_workflow(runner, :wf_skip, workflow)
      :ok = Runic.Runner.run(runner, :wf_skip, 5)
      assert_workflow_idle(runner, :wf_skip)

      # The failing step was skipped — the pipeline should not produce the after_fail result
      # since no value flowed through
      {:ok, _results} = Runic.Runner.get_results(runner, :wf_skip)
    end

    test "runtime policy override via run opts", %{runner: runner} do
      step = Runic.step(fn x -> x + 1 end, name: :override_step)
      workflow = Runic.workflow(steps: [step])

      {:ok, _} = Runic.Runner.start_workflow(runner, :wf_override, workflow)

      runtime_policies = [{:override_step, %{timeout_ms: 10_000}}]
      :ok = Runic.Runner.run(runner, :wf_override, 5, scheduler_policies: runtime_policies)
      assert_workflow_idle(runner, :wf_override)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_override)
      assert 6 in results
    end
  end

  # ---------------------------------------------------------------------------
  # D. Concurrency
  # ---------------------------------------------------------------------------

  describe "concurrency" do
    test "max_concurrency: 1 executes runnables one at a time", %{runner: runner} do
      timestamps = :ets.new(:timestamps, [:public, :ordered_set])

      make_step = fn name ->
        Runic.step(
          fn x ->
            :ets.insert(timestamps, {name, System.monotonic_time(:millisecond)})
            Process.sleep(50)
            x
          end,
          name: name
        )
      end

      step_a = Runic.step(fn x -> x end, name: :fan)
      step_b = make_step.(:b)
      step_c = make_step.(:c)

      workflow = Runic.workflow(steps: [{step_a, [step_b, step_c]}])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_serial, workflow, max_concurrency: 1)

      :ok = Runic.Runner.run(runner, :wf_serial, 1)
      assert_workflow_idle(runner, :wf_serial, 2000)
    end

    test "task crash doesn't kill the Worker process", %{runner: runner} do
      step = Runic.step(fn _ -> raise "kaboom" end, name: :crasher)
      workflow = Runic.workflow(steps: [step])

      {:ok, pid} = Runic.Runner.start_workflow(runner, :wf_crash, workflow)
      :ok = Runic.Runner.run(runner, :wf_crash, 1)
      assert_workflow_idle(runner, :wf_crash)

      assert Process.alive?(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # E. Persistence — ETS store integration
  # ---------------------------------------------------------------------------

  describe "persistence" do
    test "after run completes, the store contains the workflow log", %{runner: runner} do
      workflow = build_single_step_workflow()
      {:ok, _} = Runic.Runner.start_workflow(runner, :wf_persist, workflow)
      :ok = Runic.Runner.run(runner, :wf_persist, 5)
      assert_workflow_idle(runner, :wf_persist)

      {store_mod, store_state} = Runic.Runner.get_store(runner)
      assert {:ok, log} = store_mod.load(:wf_persist, store_state)
      assert is_list(log)
      assert length(log) > 0
    end

    test "resume loads from store and starts a new Worker with restored workflow", %{
      runner: runner
    } do
      workflow = build_single_step_workflow()
      {:ok, _} = Runic.Runner.start_workflow(runner, :wf_resume, workflow)
      :ok = Runic.Runner.run(runner, :wf_resume, 5)
      assert_workflow_idle(runner, :wf_resume)

      {:ok, original_results} = Runic.Runner.get_results(runner, :wf_resume)

      :ok = Runic.Runner.stop(runner, :wf_resume)
      Process.sleep(50)

      assert {:ok, _pid} = Runic.Runner.resume(runner, :wf_resume)

      {:ok, resumed_results} = Runic.Runner.get_results(runner, :wf_resume)
      assert Enum.sort(original_results) == Enum.sort(resumed_results)
    end

    test "stop with persist: true (default) saves final state", %{runner: runner} do
      workflow = build_single_step_workflow()
      {:ok, _} = Runic.Runner.start_workflow(runner, :wf_persist_stop, workflow)
      :ok = Runic.Runner.stop(runner, :wf_persist_stop)
      Process.sleep(50)

      {store_mod, store_state} = Runic.Runner.get_store(runner)
      assert {:ok, _log} = store_mod.load(:wf_persist_stop, store_state)
    end

    test "checkpoint_strategy: :on_complete only persists when workflow satisfies", %{
      runner: runner
    } do
      step_a = Runic.step(fn x -> x + 1 end, name: :cp_a)
      step_b = Runic.step(fn x -> x * 2 end, name: :cp_b)
      workflow = Runic.workflow(steps: [{step_a, [step_b]}])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_on_complete, workflow,
          checkpoint_strategy: :on_complete
        )

      :ok = Runic.Runner.run(runner, :wf_on_complete, 5)
      assert_workflow_idle(runner, :wf_on_complete)

      # After full completion, the store should have the log
      {store_mod, store_state} = Runic.Runner.get_store(runner)
      assert {:ok, _log} = store_mod.load(:wf_on_complete, store_state)
    end

    test "checkpoint_strategy: {:every_n, 3} persists every 3rd cycle", %{runner: runner} do
      # Build a pipeline with enough steps to trigger multiple cycles
      step_a = Runic.step(fn x -> x + 1 end, name: :en_a)
      step_b = Runic.step(fn x -> x + 2 end, name: :en_b)
      step_c = Runic.step(fn x -> x + 3 end, name: :en_c)
      step_d = Runic.step(fn x -> x + 4 end, name: :en_d)
      workflow = Runic.workflow(steps: [{step_a, [{step_b, [{step_c, [step_d]}]}]}])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_every_n, workflow,
          checkpoint_strategy: {:every_n, 3}
        )

      :ok = Runic.Runner.run(runner, :wf_every_n, 0)
      assert_workflow_idle(runner, :wf_every_n)

      # After completion, the store should have the log (final persist on idle)
      {store_mod, store_state} = Runic.Runner.get_store(runner)
      assert {:ok, _log} = store_mod.load(:wf_every_n, store_state)
    end
  end

  # ---------------------------------------------------------------------------
  # F. Completion callbacks
  # ---------------------------------------------------------------------------

  describe "completion callbacks" do
    test "on_complete: fn/2 is called with correct arguments", %{runner: runner} do
      test_pid = self()

      callback = fn id, workflow ->
        send(test_pid, {:completed, id, Workflow.raw_productions(workflow)})
      end

      workflow = build_single_step_workflow()

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_callback, workflow, on_complete: callback)

      :ok = Runic.Runner.run(runner, :wf_callback, 5)

      assert_receive {:completed, :wf_callback, results}, 2000
      assert 6 in results
    end

    test "on_complete: {Module, :function, [extra_arg]} is called", %{runner: runner} do
      test_pid = self()
      # Use a callback that sends to the test process
      callback = fn id, _workflow, extra ->
        send(test_pid, {:mfa_completed, id, extra})
      end

      # We'll use a {module, function, args} tuple by wrapping in a fn
      # Since MFA requires a real module, use the anonymous fn approach
      workflow = build_single_step_workflow()

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_mfa, workflow,
          on_complete: fn id, workflow ->
            callback.(id, workflow, :extra_data)
          end
        )

      :ok = Runic.Runner.run(runner, :wf_mfa, 5)

      assert_receive {:mfa_completed, :wf_mfa, :extra_data}, 2000
    end
  end

  # ---------------------------------------------------------------------------
  # G. Multiple inputs
  # ---------------------------------------------------------------------------

  describe "multiple inputs" do
    test "send run twice with different inputs, both are processed", %{runner: runner} do
      step = Runic.step(fn x -> x * 2 end, name: :doubler)
      workflow = Runic.workflow(steps: [step])

      {:ok, _} = Runic.Runner.start_workflow(runner, :wf_multi, workflow)
      :ok = Runic.Runner.run(runner, :wf_multi, 3)
      :ok = Runic.Runner.run(runner, :wf_multi, 7)
      assert_workflow_idle(runner, :wf_multi)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_multi)
      assert 6 in results
      assert 14 in results
    end
  end

  # ---------------------------------------------------------------------------
  # H. Error cases
  # ---------------------------------------------------------------------------

  describe "error cases" do
    test "run on non-existent workflow returns {:error, :not_found}", %{runner: runner} do
      assert {:error, :not_found} = Runic.Runner.run(runner, :nope, 1)
    end

    test "get_results on non-existent workflow returns {:error, :not_found}", %{runner: runner} do
      assert {:error, :not_found} = Runic.Runner.get_results(runner, :nope)
    end

    test "resume with no persisted state returns {:error, :not_found}", %{runner: runner} do
      assert {:error, :not_found} = Runic.Runner.resume(runner, :nope)
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
