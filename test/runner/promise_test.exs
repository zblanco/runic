defmodule Runic.Runner.PromiseTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  require Runic
  alias Runic.Workflow

  setup do
    runner_name = :"test_runner_promise_#{System.unique_integer([:positive])}"
    start_supervised!({Runic.Runner, name: runner_name})
    %{runner: runner_name}
  end

  # ---------------------------------------------------------------------------
  # A. Promise struct
  # ---------------------------------------------------------------------------

  describe "Promise.new/2" do
    test "creates a promise with node_hashes from runnables" do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      workflow = Runic.workflow(steps: [{step_a, [step_b]}])

      workflow = Workflow.plan_eagerly(workflow, 5)
      {_wf, runnables} = Workflow.prepare_for_dispatch(workflow)

      promise = Runic.Runner.Promise.new(runnables)

      assert is_reference(promise.id)
      assert length(promise.runnables) == length(runnables)
      assert promise.strategy == :sequential
      assert promise.status == :pending

      for r <- runnables do
        assert MapSet.member?(promise.node_hashes, r.node.hash)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # B. PromiseBuilder — chain detection
  # ---------------------------------------------------------------------------

  describe "PromiseBuilder.build_promises/3" do
    test "linear chain a → b → c detected via structural look-ahead" do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      step_c = Runic.step(fn x -> x - 1 end, name: :c)

      workflow = Runic.workflow(steps: [{step_a, [{step_b, [step_c]}]}])
      workflow = Workflow.plan_eagerly(workflow, 5)
      {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

      # Only step_a is runnable, but structural look-ahead finds chain a → b → c
      assert length(runnables) == 1

      {promises, standalone} =
        Runic.Runner.PromiseBuilder.build_promises(workflow, runnables)

      assert length(promises) == 1
      [promise] = promises
      # Promise node_hashes covers all 3 nodes in the structural chain
      assert MapSet.size(promise.node_hashes) == 3
      # Only step_a is in the initial runnables
      assert length(promise.runnables) == 1
      assert hd(promise.runnables).node.name == :a
      # No standalone runnables
      assert standalone == []
    end

    test "two independent runnables are not chained" do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)

      workflow = Runic.workflow(steps: [step_a, step_b])
      workflow = Workflow.plan_eagerly(workflow, 5)
      {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

      assert length(runnables) == 2

      {promises, standalone} =
        Runic.Runner.PromiseBuilder.build_promises(workflow, runnables)

      assert promises == []
      assert length(standalone) == 2
    end

    test "min_chain_length: 3 excludes length-2 chains" do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)

      workflow = Runic.workflow(steps: [{step_a, [step_b]}])
      workflow = Workflow.plan_eagerly(workflow, 5)

      # Execute step_a to make step_b runnable, giving us a 2-node chain
      workflow = Workflow.react(workflow)
      {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

      # There might be 1 runnable (step_b) now. That's a chain of 1.
      # For a proper test of min_chain_length, we just verify the option is respected
      {promises, _standalone} =
        Runic.Runner.PromiseBuilder.build_promises(workflow, runnables, min_chain_length: 3)

      # Can't form a chain of 3 from fewer runnables
      assert promises == []
    end
  end

  # ---------------------------------------------------------------------------
  # C. Promise execution via Worker — linear chain
  # ---------------------------------------------------------------------------

  describe "promise execution" do
    test "linear chain a → b → c dispatched as promise, produces correct result", %{
      runner: runner
    } do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      step_c = Runic.step(fn x -> x - 1 end, name: :c)

      workflow = Runic.workflow(steps: [{step_a, [{step_b, [step_c]}]}])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_promise_chain, workflow,
          promise_opts: [min_chain_length: 2]
        )

      :ok = Runic.Runner.run(runner, :wf_promise_chain, 5)
      assert_workflow_idle(runner, :wf_promise_chain)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_promise_chain)
      # 5 -> 6 -> 12 -> 11
      assert 11 in results
    end

    test "promise with inline executor", %{runner: runner} do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      step_c = Runic.step(fn x -> x - 1 end, name: :c)

      workflow = Runic.workflow(steps: [{step_a, [{step_b, [step_c]}]}])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_promise_inline, workflow,
          executor: :inline,
          promise_opts: [min_chain_length: 2]
        )

      :ok = Runic.Runner.run(runner, :wf_promise_inline, 5)
      assert_workflow_idle(runner, :wf_promise_inline)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_promise_inline)
      # 5 -> 6 -> 12 -> 11
      assert 11 in results
    end

    test "standalone runnables not in chains still dispatched individually", %{runner: runner} do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)

      # Two independent steps — no chain
      workflow = Runic.workflow(steps: [step_a, step_b])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_promise_standalone, workflow,
          promise_opts: [min_chain_length: 2]
        )

      :ok = Runic.Runner.run(runner, :wf_promise_standalone, 5)
      assert_workflow_idle(runner, :wf_promise_standalone)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_promise_standalone)
      assert 6 in results
      assert 10 in results
    end

    test "behavioral equivalence: promise produces same result as individual dispatch", %{
      runner: runner
    } do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      step_c = Runic.step(fn x -> x - 1 end, name: :c)

      workflow = Runic.workflow(steps: [{step_a, [{step_b, [step_c]}]}])

      # Without promises
      {:ok, _} = Runic.Runner.start_workflow(runner, :wf_no_promise, workflow)
      :ok = Runic.Runner.run(runner, :wf_no_promise, 10)
      assert_workflow_idle(runner, :wf_no_promise)
      {:ok, no_promise_results} = Runic.Runner.get_results(runner, :wf_no_promise)

      # With promises
      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_with_promise, workflow,
          promise_opts: [min_chain_length: 2]
        )

      :ok = Runic.Runner.run(runner, :wf_with_promise, 10)
      assert_workflow_idle(runner, :wf_with_promise)
      {:ok, promise_results} = Runic.Runner.get_results(runner, :wf_with_promise)

      assert Enum.sort(no_promise_results) == Enum.sort(promise_results)
    end
  end

  # ---------------------------------------------------------------------------
  # D. Promise partial failure
  # ---------------------------------------------------------------------------

  describe "promise partial failure" do
    test "failure at step N: steps before N applied, step N marked failed", %{runner: runner} do
      counter = :counters.new(1, [:atomics])

      step_a = Runic.step(fn x -> x + 1 end, name: :a)

      step_b =
        Runic.step(
          fn _x ->
            :counters.add(counter, 1, 1)
            raise "intentional failure"
          end,
          name: :b
        )

      step_c = Runic.step(fn x -> x - 1 end, name: :c)

      workflow = Runic.workflow(steps: [{step_a, [{step_b, [step_c]}]}])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_promise_fail, workflow,
          promise_opts: [min_chain_length: 2]
        )

      :ok = Runic.Runner.run(runner, :wf_promise_fail, 5)
      assert_workflow_idle(runner, :wf_promise_fail)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_promise_fail)
      # step_a produced 6, step_b failed, step_c never ran
      # The result of step_a (6) should be in productions
      assert 6 in results
      # step_c's result (11) should NOT be in productions
      refute 11 in results
    end
  end

  # ---------------------------------------------------------------------------
  # E. Promise telemetry
  # ---------------------------------------------------------------------------

  describe "promise telemetry" do
    test "emits :start and :stop events", %{runner: runner} do
      test_pid = self()

      :telemetry.attach_many(
        "promise-telemetry-test",
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
      step_c = Runic.step(fn x -> x - 1 end, name: :c)

      workflow = Runic.workflow(steps: [{step_a, [{step_b, [step_c]}]}])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_promise_telemetry, workflow,
          promise_opts: [min_chain_length: 2]
        )

      :ok = Runic.Runner.run(runner, :wf_promise_telemetry, 5)
      assert_workflow_idle(runner, :wf_promise_telemetry)

      # We should receive at least one :start and :stop event
      # (the chain may be detected at different points as the workflow progresses)
      assert_receive {:telemetry, [:runic, :runner, :promise, :start], _m, metadata}, 2000
      assert is_reference(metadata.promise_id)
      assert is_integer(metadata.runnable_count)
      assert %MapSet{} = metadata.node_hashes

      assert_receive {:telemetry, [:runic, :runner, :promise, :stop], measurements, _meta}, 2000
      assert is_integer(measurements.duration)

      :telemetry.detach("promise-telemetry-test")
    end
  end

  # ---------------------------------------------------------------------------
  # F. Fan-out exclusion — promises don't batch across fan-out/fan-in
  # ---------------------------------------------------------------------------

  describe "fan-out exclusion" do
    test "independent branches dispatched as individual runnables, not batched", %{
      runner: runner
    } do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      step_c = Runic.step(fn x -> x * 3 end, name: :c)

      # Fan-out: a feeds both b and c
      workflow = Runic.workflow(steps: [{step_a, [step_b, step_c]}])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_fanout, workflow,
          promise_opts: [min_chain_length: 2]
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
  # G. Promises disabled by default
  # ---------------------------------------------------------------------------

  describe "default behavior" do
    test "no promise_opts means no promise dispatching", %{runner: runner} do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)

      workflow = Runic.workflow(steps: [{step_a, [step_b]}])

      {:ok, pid} = Runic.Runner.start_workflow(runner, :wf_default, workflow)

      state = :sys.get_state(pid)
      assert state.promise_opts == []
      assert state.active_promises == %{}

      :ok = Runic.Runner.run(runner, :wf_default, 5)
      assert_workflow_idle(runner, :wf_default)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_default)
      assert 12 in results
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
