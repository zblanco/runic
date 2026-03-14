defmodule Runic.Runner.ParallelPromiseTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  require Runic
  alias Runic.Workflow
  alias Runic.Runner.Promise

  setup do
    runner_name = :"test_runner_par_promise_#{System.unique_integer([:positive])}"
    start_supervised!({Runic.Runner, name: runner_name})
    %{runner: runner_name}
  end

  # ---------------------------------------------------------------------------
  # A. Promise struct — parallel strategy
  # ---------------------------------------------------------------------------

  describe "Promise.new/2 with parallel strategy" do
    test "creates a parallel promise" do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      workflow = Runic.workflow(steps: [step_a, step_b])

      workflow = Workflow.plan_eagerly(workflow, 5)
      {_wf, runnables} = Workflow.prepare_for_dispatch(workflow)

      promise = Promise.new(runnables, strategy: :parallel)

      assert promise.strategy == :parallel
      assert promise.flow_opts == []
      assert length(promise.runnables) == 2
    end

    test "accepts flow_opts" do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      workflow = Runic.workflow(steps: [step_a])

      workflow = Workflow.plan_eagerly(workflow, 5)
      {_wf, runnables} = Workflow.prepare_for_dispatch(workflow)

      promise = Promise.new(runnables, strategy: :parallel, flow_opts: [stages: 4, max_demand: 2])

      assert promise.strategy == :parallel
      assert promise.flow_opts == [stages: 4, max_demand: 2]
    end
  end

  # ---------------------------------------------------------------------------
  # B. Parallel promise execution — independent runnables
  # ---------------------------------------------------------------------------

  describe "parallel promise execution" do
    test "independent runnables execute concurrently and produce correct results", %{
      runner: runner
    } do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      step_c = Runic.step(fn x -> x * 3 end, name: :c)

      # Three independent steps — all can run in parallel
      workflow = Runic.workflow(steps: [step_a, step_b, step_c])

      # Manually create a parallel promise via inline executor
      {:ok, _pid} =
        Runic.Runner.start_workflow(runner, :wf_par_basic, workflow,
          executor: :inline,
          scheduler: TestParallelScheduler
        )

      :ok = Runic.Runner.run(runner, :wf_par_basic, 5)
      assert_workflow_idle(runner, :wf_par_basic)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_par_basic)
      # 5 + 1
      assert 6 in results
      # 5 * 2
      assert 10 in results
      # 5 * 3
      assert 15 in results
    end

    test "behavioral equivalence: parallel promise produces same results as individual dispatch",
         %{runner: runner} do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      step_c = Runic.step(fn x -> x * 3 end, name: :c)

      workflow = Runic.workflow(steps: [step_a, step_b, step_c])

      # Without parallel promises (default scheduler)
      {:ok, _} = Runic.Runner.start_workflow(runner, :wf_par_equiv_default, workflow)
      :ok = Runic.Runner.run(runner, :wf_par_equiv_default, 10)
      assert_workflow_idle(runner, :wf_par_equiv_default)
      {:ok, default_results} = Runic.Runner.get_results(runner, :wf_par_equiv_default)

      # With parallel promises
      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_par_equiv_parallel, workflow,
          scheduler: TestParallelScheduler
        )

      :ok = Runic.Runner.run(runner, :wf_par_equiv_parallel, 10)
      assert_workflow_idle(runner, :wf_par_equiv_parallel)
      {:ok, parallel_results} = Runic.Runner.get_results(runner, :wf_par_equiv_parallel)

      assert Enum.sort(default_results) == Enum.sort(parallel_results)
    end

    test "parallel promise with Task executor (async dispatch)", %{runner: runner} do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)

      workflow = Runic.workflow(steps: [step_a, step_b])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_par_async, workflow,
          scheduler: TestParallelScheduler
        )

      :ok = Runic.Runner.run(runner, :wf_par_async, 7)
      assert_workflow_idle(runner, :wf_par_async)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_par_async)
      # 7 + 1
      assert 8 in results
      # 7 * 2
      assert 14 in results
    end

    test "parallel promise verifies concurrent execution", %{runner: runner} do
      # Each step sleeps and records its start/end time to prove concurrency
      parent = self()

      step_a =
        Runic.step(
          fn x ->
            send(parent, {:started, :a, System.monotonic_time(:millisecond)})
            Process.sleep(50)
            send(parent, {:finished, :a, System.monotonic_time(:millisecond)})
            x + 1
          end,
          name: :a
        )

      step_b =
        Runic.step(
          fn x ->
            send(parent, {:started, :b, System.monotonic_time(:millisecond)})
            Process.sleep(50)
            send(parent, {:finished, :b, System.monotonic_time(:millisecond)})
            x * 2
          end,
          name: :b
        )

      workflow = Runic.workflow(steps: [step_a, step_b])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_par_concurrent, workflow,
          scheduler: TestParallelScheduler
        )

      :ok = Runic.Runner.run(runner, :wf_par_concurrent, 5)
      assert_workflow_idle(runner, :wf_par_concurrent)

      # Collect timing messages
      assert_receive {:started, :a, a_start}, 2000
      assert_receive {:started, :b, b_start}, 2000
      assert_receive {:finished, :a, _a_end}, 2000
      assert_receive {:finished, :b, _b_end}, 2000

      # Both should start within a small window (< 40ms apart),
      # proving they run concurrently, not sequentially
      assert abs(a_start - b_start) < 40

      {:ok, results} = Runic.Runner.get_results(runner, :wf_par_concurrent)
      assert 6 in results
      assert 10 in results
    end
  end

  # ---------------------------------------------------------------------------
  # C. Parallel promise failure handling
  # ---------------------------------------------------------------------------

  describe "parallel promise failure handling" do
    test "failure in one runnable does not prevent others from completing", %{runner: runner} do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)

      step_b =
        Runic.step(
          fn _x -> raise "intentional failure" end,
          name: :b
        )

      step_c = Runic.step(fn x -> x * 3 end, name: :c)

      workflow = Runic.workflow(steps: [step_a, step_b, step_c])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_par_fail, workflow,
          executor: :inline,
          scheduler: TestParallelScheduler
        )

      :ok = Runic.Runner.run(runner, :wf_par_fail, 5)
      assert_workflow_idle(runner, :wf_par_fail)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_par_fail)
      # step_a and step_c should succeed
      # 5 + 1
      assert 6 in results
      # 5 * 3
      assert 15 in results
    end

    test "multiple failures are each handled independently", %{runner: runner} do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)

      step_b =
        Runic.step(fn _x -> raise "fail b" end, name: :b)

      step_c =
        Runic.step(fn _x -> raise "fail c" end, name: :c)

      workflow = Runic.workflow(steps: [step_a, step_b, step_c])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_par_multi_fail, workflow,
          executor: :inline,
          scheduler: TestParallelScheduler
        )

      :ok = Runic.Runner.run(runner, :wf_par_multi_fail, 5)
      assert_workflow_idle(runner, :wf_par_multi_fail)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_par_multi_fail)
      # Only step_a should succeed
      assert 6 in results
      assert length(results) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # D. Parallel promise telemetry
  # ---------------------------------------------------------------------------

  describe "parallel promise telemetry" do
    test "emits :start and :stop events", %{runner: runner} do
      test_pid = self()

      :telemetry.attach_many(
        "par-promise-telemetry-test",
        [
          [:runic, :runner, :promise, :start],
          [:runic, :runner, :promise, :stop]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)

      workflow = Runic.workflow(steps: [step_a, step_b])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_par_telemetry, workflow,
          scheduler: TestParallelScheduler
        )

      :ok = Runic.Runner.run(runner, :wf_par_telemetry, 5)
      assert_workflow_idle(runner, :wf_par_telemetry)

      assert_receive {:telemetry, [:runic, :runner, :promise, :start], _m, metadata}, 2000
      assert is_reference(metadata.promise_id)
      assert metadata.runnable_count >= 2

      assert_receive {:telemetry, [:runic, :runner, :promise, :stop], measurements, _meta}, 2000
      assert is_integer(measurements.duration)

      :telemetry.detach("par-promise-telemetry-test")
    end
  end

  # ---------------------------------------------------------------------------
  # E. Flow opts configuration
  # ---------------------------------------------------------------------------

  describe "flow_opts" do
    test "stages option is respected and results are correct", %{runner: runner} do
      # Each step must have a unique function body to get a unique hash
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      step_c = Runic.step(fn x -> x + 10 end, name: :c)
      step_d = Runic.step(fn x -> x * 3 end, name: :d)

      workflow = Runic.workflow(steps: [step_a, step_b, step_c, step_d])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_par_flow_opts, workflow,
          scheduler: TestParallelScheduler,
          scheduler_opts: [flow_opts: [stages: 2, max_demand: 1]]
        )

      :ok = Runic.Runner.run(runner, :wf_par_flow_opts, 5)
      assert_workflow_idle(runner, :wf_par_flow_opts)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_par_flow_opts)
      # 5 + 1
      assert 6 in results
      # 5 * 2
      assert 10 in results
      # 5 + 10
      assert 15 in results
      # 5 * 3
      assert 15 in results
      assert length(results) == 4
    end
  end

  # ---------------------------------------------------------------------------
  # F. Fallback to Task.async_stream
  # ---------------------------------------------------------------------------

  describe "resolve_with_async_stream fallback" do
    test "parallel promise works when using async_stream directly" do
      # Test the async_stream fallback path by calling it directly
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)

      workflow = Runic.workflow(steps: [step_a, step_b])
      workflow = Workflow.plan_eagerly(workflow, 5)
      {_wf, runnables} = Workflow.prepare_for_dispatch(workflow)

      promise = Promise.new(runnables, strategy: :parallel)
      policies = workflow.scheduler_policies

      # Execute each runnable via PolicyDriver (simulating the parallel path)
      results =
        promise.runnables
        |> Task.async_stream(
          fn runnable ->
            policy = Runic.Workflow.SchedulerPolicy.resolve(runnable, policies)
            Runic.Workflow.PolicyDriver.execute(runnable, policy)
          end,
          max_concurrency: 2,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert length(results) == 2

      statuses = Enum.map(results, fn r -> r.status end)
      assert Enum.all?(statuses, &(&1 == :completed))
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
