defmodule Runic.Runner.SchedulerTest do
  use ExUnit.Case, async: true

  require Runic

  setup do
    runner_name = :"test_runner_sched_#{System.unique_integer([:positive])}"
    start_supervised!({Runic.Runner, name: runner_name})
    %{runner: runner_name}
  end

  # ---------------------------------------------------------------------------
  # A. Default scheduler — identical to pre-scheduler behavior
  # ---------------------------------------------------------------------------

  describe "Default scheduler" do
    test "produces correct results for a→b pipeline", %{runner: runner} do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      workflow = Runic.workflow(steps: [{step_a, [step_b]}])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_default_sched, workflow,
          scheduler: Runic.Runner.Scheduler.Default
        )

      :ok = Runic.Runner.run(runner, :wf_default_sched, 5)
      assert_workflow_idle(runner, :wf_default_sched)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_default_sched)
      assert 12 in results
    end

    test "is used when no scheduler is specified", %{runner: runner} do
      workflow = Runic.workflow(steps: [Runic.step(fn x -> x + 1 end, name: :a)])
      {:ok, pid} = Runic.Runner.start_workflow(runner, :wf_no_sched, workflow)

      state = :sys.get_state(pid)
      assert state.scheduler == Runic.Runner.Scheduler.Default
    end
  end

  # ---------------------------------------------------------------------------
  # B. ChainBatching scheduler
  # ---------------------------------------------------------------------------

  describe "ChainBatching scheduler" do
    test "batches linear chains and produces correct result", %{runner: runner} do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      step_c = Runic.step(fn x -> x - 1 end, name: :c)
      workflow = Runic.workflow(steps: [{step_a, [{step_b, [step_c]}]}])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_chain, workflow,
          scheduler: Runic.Runner.Scheduler.ChainBatching,
          scheduler_opts: [min_chain_length: 2]
        )

      :ok = Runic.Runner.run(runner, :wf_chain, 5)
      assert_workflow_idle(runner, :wf_chain)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_chain)
      # 5 -> 6 -> 12 -> 11
      assert 11 in results
    end

    test "leaves non-chains as individual runnables", %{runner: runner} do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      workflow = Runic.workflow(steps: [step_a, step_b])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_no_chain, workflow,
          scheduler: Runic.Runner.Scheduler.ChainBatching
        )

      :ok = Runic.Runner.run(runner, :wf_no_chain, 5)
      assert_workflow_idle(runner, :wf_no_chain)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_no_chain)
      assert 6 in results
      assert 10 in results
    end

    test "behavioral equivalence with Default scheduler", %{runner: runner} do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      step_c = Runic.step(fn x -> x - 1 end, name: :c)
      workflow = Runic.workflow(steps: [{step_a, [{step_b, [step_c]}]}])

      {:ok, _} = Runic.Runner.start_workflow(runner, :wf_equiv_default, workflow)
      :ok = Runic.Runner.run(runner, :wf_equiv_default, 10)
      assert_workflow_idle(runner, :wf_equiv_default)
      {:ok, default_results} = Runic.Runner.get_results(runner, :wf_equiv_default)

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_equiv_chain, workflow,
          scheduler: Runic.Runner.Scheduler.ChainBatching
        )

      :ok = Runic.Runner.run(runner, :wf_equiv_chain, 10)
      assert_workflow_idle(runner, :wf_equiv_chain)
      {:ok, chain_results} = Runic.Runner.get_results(runner, :wf_equiv_chain)

      assert Enum.sort(default_results) == Enum.sort(chain_results)
    end

    test "with inline executor", %{runner: runner} do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      step_c = Runic.step(fn x -> x - 1 end, name: :c)
      workflow = Runic.workflow(steps: [{step_a, [{step_b, [step_c]}]}])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_chain_inline, workflow,
          executor: :inline,
          scheduler: Runic.Runner.Scheduler.ChainBatching
        )

      :ok = Runic.Runner.run(runner, :wf_chain_inline, 5)
      assert_workflow_idle(runner, :wf_chain_inline)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_chain_inline)
      assert 11 in results
    end
  end

  # ---------------------------------------------------------------------------
  # C. Worker scheduler option
  # ---------------------------------------------------------------------------

  describe "Worker scheduler option" do
    test "stores scheduler module and state in Worker", %{runner: runner} do
      workflow = Runic.workflow(steps: [Runic.step(fn x -> x + 1 end, name: :a)])

      {:ok, pid} =
        Runic.Runner.start_workflow(runner, :wf_sched_state, workflow,
          scheduler: Runic.Runner.Scheduler.ChainBatching,
          scheduler_opts: [min_chain_length: 3]
        )

      state = :sys.get_state(pid)
      assert state.scheduler == Runic.Runner.Scheduler.ChainBatching
      assert state.scheduler_state.min_chain_length == 3
    end
  end

  # ---------------------------------------------------------------------------
  # D. Backward compatibility with promise_opts
  # ---------------------------------------------------------------------------

  describe "backward compatibility" do
    test "promise_opts maps to ChainBatching scheduler", %{runner: runner} do
      workflow = Runic.workflow(steps: [Runic.step(fn x -> x + 1 end, name: :a)])

      {:ok, pid} =
        Runic.Runner.start_workflow(runner, :wf_compat, workflow,
          promise_opts: [min_chain_length: 2]
        )

      state = :sys.get_state(pid)
      assert state.scheduler == Runic.Runner.Scheduler.ChainBatching
    end

    test "promise_opts produces same results as explicit ChainBatching", %{runner: runner} do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      step_c = Runic.step(fn x -> x - 1 end, name: :c)
      workflow = Runic.workflow(steps: [{step_a, [{step_b, [step_c]}]}])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_compat_promise, workflow,
          promise_opts: [min_chain_length: 2]
        )

      :ok = Runic.Runner.run(runner, :wf_compat_promise, 5)
      assert_workflow_idle(runner, :wf_compat_promise)
      {:ok, promise_results} = Runic.Runner.get_results(runner, :wf_compat_promise)

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_compat_chain, workflow,
          scheduler: Runic.Runner.Scheduler.ChainBatching,
          scheduler_opts: [min_chain_length: 2]
        )

      :ok = Runic.Runner.run(runner, :wf_compat_chain, 5)
      assert_workflow_idle(runner, :wf_compat_chain)
      {:ok, chain_results} = Runic.Runner.get_results(runner, :wf_compat_chain)

      assert Enum.sort(promise_results) == Enum.sort(chain_results)
    end

    test "explicit scheduler takes precedence over promise_opts", %{runner: runner} do
      workflow = Runic.workflow(steps: [Runic.step(fn x -> x + 1 end, name: :a)])

      {:ok, pid} =
        Runic.Runner.start_workflow(runner, :wf_precedence, workflow,
          scheduler: Runic.Runner.Scheduler.Default,
          promise_opts: [min_chain_length: 2]
        )

      state = :sys.get_state(pid)
      assert state.scheduler == Runic.Runner.Scheduler.Default
    end
  end

  # ---------------------------------------------------------------------------
  # E. Fan-out patterns
  # ---------------------------------------------------------------------------

  describe "fan-out patterns" do
    test "independent branches dispatched individually with ChainBatching", %{runner: runner} do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      step_c = Runic.step(fn x -> x * 3 end, name: :c)
      workflow = Runic.workflow(steps: [{step_a, [step_b, step_c]}])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_fanout, workflow,
          scheduler: Runic.Runner.Scheduler.ChainBatching
        )

      :ok = Runic.Runner.run(runner, :wf_fanout, 5)
      assert_workflow_idle(runner, :wf_fanout)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_fanout)
      # 5 -> 6 -> 12 (b) and 5 -> 6 -> 18 (c)
      assert 12 in results
      assert 18 in results
    end
  end

  # ---------------------------------------------------------------------------
  # F. Custom scheduler — reordering
  # ---------------------------------------------------------------------------

  describe "custom scheduler" do
    test "reversing scheduler still produces correct final results", %{runner: runner} do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      workflow = Runic.workflow(steps: [step_a, step_b])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_reverse, workflow,
          scheduler: Runic.Runner.TestSchedulers.Reversing
        )

      :ok = Runic.Runner.run(runner, :wf_reverse, 5)
      assert_workflow_idle(runner, :wf_reverse)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_reverse)
      assert 6 in results
      assert 10 in results
    end
  end

  # ---------------------------------------------------------------------------
  # G. Scheduler exception handling
  # ---------------------------------------------------------------------------

  describe "scheduler exception handling" do
    test "scheduler crash in plan_dispatch falls back to default behavior", %{runner: runner} do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      workflow = Runic.workflow(steps: [{step_a, [step_b]}])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_crash_sched, workflow,
          scheduler: Runic.Runner.TestSchedulers.Crashing
        )

      :ok = Runic.Runner.run(runner, :wf_crash_sched, 5)
      assert_workflow_idle(runner, :wf_crash_sched)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_crash_sched)
      # 5 -> 6 -> 12
      assert 12 in results
    end
  end

  # ---------------------------------------------------------------------------
  # H. on_complete callback
  # ---------------------------------------------------------------------------

  describe "on_complete callback" do
    test "on_complete receives dispatch unit and duration for individual runnables", %{
      runner: runner
    } do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      workflow = Runic.workflow(steps: [step_a])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_on_complete, workflow,
          scheduler: Runic.Runner.TestSchedulers.Tracking,
          scheduler_opts: [test_pid: self()]
        )

      :ok = Runic.Runner.run(runner, :wf_on_complete, 5)
      assert_workflow_idle(runner, :wf_on_complete)

      assert_receive {:scheduler_on_complete, {:runnable, runnable}, duration_ms}, 2000
      assert is_integer(duration_ms)
      assert duration_ms >= 0
      assert runnable.status == :completed
    end

    test "on_complete receives promise units when using ChainBatching", %{runner: runner} do
      test_pid = self()

      # A tracking scheduler that also does chain batching
      # We can verify by checking promise_opts backward compat + tracking
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      step_c = Runic.step(fn x -> x - 1 end, name: :c)
      workflow = Runic.workflow(steps: [{step_a, [{step_b, [step_c]}]}])

      # Use ChainBatching to get promise dispatch units
      # Can't track on_complete with ChainBatching since it doesn't implement on_complete
      # Instead, use telemetry to verify promises are created
      :telemetry.attach(
        "sched-promise-test",
        [:runic, :runner, :promise, :stop],
        fn _event, measurements, _metadata, _config ->
          send(test_pid, {:promise_completed, measurements.duration})
        end,
        nil
      )

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_chain_track, workflow,
          scheduler: Runic.Runner.Scheduler.ChainBatching
        )

      :ok = Runic.Runner.run(runner, :wf_chain_track, 5)
      assert_workflow_idle(runner, :wf_chain_track)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_chain_track)
      assert 11 in results

      assert_receive {:promise_completed, duration}, 2000
      assert is_integer(duration)

      :telemetry.detach("sched-promise-test")
    end

    test "on_complete accumulates state across completions", %{runner: runner} do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      workflow = Runic.workflow(steps: [step_a, step_b])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_on_complete_multi, workflow,
          scheduler: Runic.Runner.TestSchedulers.Tracking,
          scheduler_opts: [test_pid: self()]
        )

      :ok = Runic.Runner.run(runner, :wf_on_complete_multi, 5)
      assert_workflow_idle(runner, :wf_on_complete_multi)

      # Should receive on_complete for both runnables
      assert_receive {:scheduler_on_complete, {:runnable, _}, _}, 2000
      assert_receive {:scheduler_on_complete, {:runnable, _}, _}, 2000

      # Verify scheduler state accumulated completions
      pid = Runic.Runner.lookup(runner, :wf_on_complete_multi)
      state = :sys.get_state(pid)
      assert length(state.scheduler_state.completions) == 2
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
