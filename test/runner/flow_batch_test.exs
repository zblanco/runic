defmodule Runic.Runner.Scheduler.FlowBatchTest do
  use ExUnit.Case, async: true

  require Runic
  alias Runic.Workflow
  alias Runic.Runner.Scheduler.FlowBatch
  alias Runic.Runner.Promise

  # ---------------------------------------------------------------------------
  # A. Unit tests — plan_dispatch detection
  # ---------------------------------------------------------------------------

  describe "plan_dispatch/3 parallel batch detection" do
    test "groups independent runnables into a :parallel promise" do
      step_a = Runic.step(fn x -> x + 1 end, name: :fb_a)
      step_b = Runic.step(fn x -> x * 2 end, name: :fb_b)
      step_c = Runic.step(fn x -> x + 10 end, name: :fb_c)
      step_d = Runic.step(fn x -> x * 3 end, name: :fb_d)

      workflow = Runic.workflow(steps: [step_a, step_b, step_c, step_d])
      workflow = Workflow.plan_eagerly(workflow, 5)
      {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

      {:ok, state} = FlowBatch.init(min_batch_size: 4)
      {units, _state} = FlowBatch.plan_dispatch(workflow, runnables, state)

      parallel_promises =
        Enum.filter(units, fn
          {:promise, %Promise{strategy: :parallel}} -> true
          _ -> false
        end)

      assert length(parallel_promises) == 1
      [{:promise, promise}] = parallel_promises
      assert length(promise.runnables) == 4
      assert promise.strategy == :parallel
    end

    test "does not batch when below min_batch_size" do
      step_a = Runic.step(fn x -> x + 1 end, name: :fb_a)
      step_b = Runic.step(fn x -> x * 2 end, name: :fb_b)

      workflow = Runic.workflow(steps: [step_a, step_b])
      workflow = Workflow.plan_eagerly(workflow, 5)
      {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

      # min_batch_size: 4 means 2 runnables won't batch
      {:ok, state} = FlowBatch.init(min_batch_size: 4)
      {units, _state} = FlowBatch.plan_dispatch(workflow, runnables, state)

      parallel_promises =
        Enum.filter(units, fn
          {:promise, %Promise{strategy: :parallel}} -> true
          _ -> false
        end)

      assert parallel_promises == []
      assert length(units) == 2
      assert Enum.all?(units, &match?({:runnable, _}, &1))
    end

    test "still detects sequential chains (inherits ChainBatching)" do
      step_a = Runic.step(fn x -> x + 1 end, name: :fb_chain_a)
      step_b = Runic.step(fn x -> x * 2 end, name: :fb_chain_b)
      step_c = Runic.step(fn x -> x - 1 end, name: :fb_chain_c)

      workflow = Runic.workflow(steps: [{step_a, [{step_b, [step_c]}]}])
      workflow = Workflow.plan_eagerly(workflow, 5)
      {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

      {:ok, state} = FlowBatch.init(min_chain_length: 2, min_batch_size: 4)
      {units, _state} = FlowBatch.plan_dispatch(workflow, runnables, state)

      seq_promises =
        Enum.filter(units, fn
          {:promise, %Promise{strategy: :sequential}} -> true
          _ -> false
        end)

      assert length(seq_promises) >= 1
    end

    test "fan-out branches become a parallel batch" do
      root = Runic.step(fn x -> x + 1 end, name: :fb_root)
      branch_a = Runic.step(fn x -> x * 2 end, name: :fb_br_a)
      branch_b = Runic.step(fn x -> x * 3 end, name: :fb_br_b)
      branch_c = Runic.step(fn x -> x * 4 end, name: :fb_br_c)
      branch_d = Runic.step(fn x -> x * 5 end, name: :fb_br_d)

      workflow =
        Runic.workflow(steps: [{root, [branch_a, branch_b, branch_c, branch_d]}])

      # Run root first to produce fan-out runnables
      workflow = Workflow.plan_eagerly(workflow, 5)
      {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

      # root is the only runnable at first — execute it
      assert length(runnables) == 1

      [root_runnable] = runnables

      executed =
        Runic.Workflow.PolicyDriver.execute(root_runnable, %Runic.Workflow.SchedulerPolicy{})

      workflow = Workflow.apply_runnable(workflow, executed)
      {workflow, fan_runnables} = Workflow.prepare_for_dispatch(workflow)

      # Now 4 independent branches should be ready
      assert length(fan_runnables) == 4

      {:ok, state} = FlowBatch.init(min_batch_size: 4)
      {units, _state} = FlowBatch.plan_dispatch(workflow, fan_runnables, state)

      parallel_promises =
        Enum.filter(units, fn
          {:promise, %Promise{strategy: :parallel}} -> true
          _ -> false
        end)

      assert length(parallel_promises) == 1
      [{:promise, promise}] = parallel_promises
      assert length(promise.runnables) == 4
    end

    test "connected runnables are not batched together as parallel" do
      # a → b is a chain — they should not be put in a parallel batch
      step_a = Runic.step(fn x -> x + 1 end, name: :fb_conn_a)
      step_b = Runic.step(fn x -> x * 2 end, name: :fb_conn_b)

      workflow = Runic.workflow(steps: [{step_a, [step_b]}])
      workflow = Workflow.plan_eagerly(workflow, 5)
      {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

      # Only step_a should be ready (step_b waits for step_a)
      assert length(runnables) == 1

      {:ok, state} = FlowBatch.init(min_batch_size: 2)
      {units, _state} = FlowBatch.plan_dispatch(workflow, runnables, state)

      # No parallel promises since there's only 1 runnable
      parallel_promises =
        Enum.filter(units, fn
          {:promise, %Promise{strategy: :parallel}} -> true
          _ -> false
        end)

      assert parallel_promises == []
    end

    test "empty runnables produces empty units" do
      step_a = Runic.step(fn x -> x + 1 end, name: :fb_empty)
      workflow = Runic.workflow(steps: [step_a])
      workflow = Workflow.plan_eagerly(workflow, 5)
      {workflow, _runnables} = Workflow.prepare_for_dispatch(workflow)

      {:ok, state} = FlowBatch.init([])
      {units, _state} = FlowBatch.plan_dispatch(workflow, [], state)

      assert units == []
    end

    test "flow_opts are set on parallel promises" do
      step_a = Runic.step(fn x -> x + 1 end, name: :fb_opts_a)
      step_b = Runic.step(fn x -> x * 2 end, name: :fb_opts_b)
      step_c = Runic.step(fn x -> x + 10 end, name: :fb_opts_c)
      step_d = Runic.step(fn x -> x * 3 end, name: :fb_opts_d)

      workflow = Runic.workflow(steps: [step_a, step_b, step_c, step_d])
      workflow = Workflow.plan_eagerly(workflow, 5)
      {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

      {:ok, state} = FlowBatch.init(min_batch_size: 4, flow_stages: 2, flow_max_demand: 3)
      {units, _state} = FlowBatch.plan_dispatch(workflow, runnables, state)

      [{:promise, promise}] =
        Enum.filter(units, fn
          {:promise, %Promise{strategy: :parallel}} -> true
          _ -> false
        end)

      assert Keyword.get(promise.flow_opts, :stages) == 2
      assert Keyword.get(promise.flow_opts, :max_demand) == 3
    end
  end

  # ---------------------------------------------------------------------------
  # B. Integration tests — full Worker execution with FlowBatch
  # ---------------------------------------------------------------------------

  describe "FlowBatch integration with Worker" do
    setup do
      runner_name = :"test_runner_flowbatch_#{System.unique_integer([:positive])}"
      start_supervised!({Runic.Runner, name: runner_name})
      %{runner: runner_name}
    end

    test "independent runnables produce correct results", %{runner: runner} do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      step_c = Runic.step(fn x -> x + 10 end, name: :c)
      step_d = Runic.step(fn x -> x * 3 end, name: :d)

      workflow = Runic.workflow(steps: [step_a, step_b, step_c, step_d])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_fb_basic, workflow,
          executor: :inline,
          scheduler: FlowBatch,
          scheduler_opts: [min_batch_size: 4]
        )

      :ok = Runic.Runner.run(runner, :wf_fb_basic, 5)
      assert_workflow_idle(runner, :wf_fb_basic)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_fb_basic)
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

    test "behavioral equivalence with Default scheduler", %{runner: runner} do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      step_c = Runic.step(fn x -> x + 10 end, name: :c)
      step_d = Runic.step(fn x -> x * 3 end, name: :d)

      workflow = Runic.workflow(steps: [step_a, step_b, step_c, step_d])

      {:ok, _} = Runic.Runner.start_workflow(runner, :wf_fb_equiv_default, workflow)
      :ok = Runic.Runner.run(runner, :wf_fb_equiv_default, 10)
      assert_workflow_idle(runner, :wf_fb_equiv_default)
      {:ok, default_results} = Runic.Runner.get_results(runner, :wf_fb_equiv_default)

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_fb_equiv_flow, workflow,
          scheduler: FlowBatch,
          scheduler_opts: [min_batch_size: 4]
        )

      :ok = Runic.Runner.run(runner, :wf_fb_equiv_flow, 10)
      assert_workflow_idle(runner, :wf_fb_equiv_flow)
      {:ok, flow_results} = Runic.Runner.get_results(runner, :wf_fb_equiv_flow)

      assert Enum.sort(default_results) == Enum.sort(flow_results)
    end

    test "fan-out workflow with FlowBatch", %{runner: runner} do
      root = Runic.step(fn x -> x + 1 end, name: :root)
      branch_a = Runic.step(fn x -> x * 2 end, name: :br_a)
      branch_b = Runic.step(fn x -> x * 3 end, name: :br_b)
      branch_c = Runic.step(fn x -> x * 4 end, name: :br_c)
      branch_d = Runic.step(fn x -> x * 5 end, name: :br_d)

      workflow =
        Runic.workflow(steps: [{root, [branch_a, branch_b, branch_c, branch_d]}])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_fb_fanout, workflow,
          scheduler: FlowBatch,
          scheduler_opts: [min_batch_size: 4]
        )

      :ok = Runic.Runner.run(runner, :wf_fb_fanout, 5)
      assert_workflow_idle(runner, :wf_fb_fanout)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_fb_fanout)
      # root: 5+1=6, branches: 12, 18, 24, 30
      assert 12 in results
      assert 18 in results
      assert 24 in results
      assert 30 in results
    end

    test "sequential chain + parallel batch mixed workflow", %{runner: runner} do
      # a → b → c (chain), plus d, e, f, g (independent)
      step_a = Runic.step(fn x -> x + 1 end, name: :chain_a)
      step_b = Runic.step(fn x -> x * 2 end, name: :chain_b)
      step_c = Runic.step(fn x -> x - 1 end, name: :chain_c)

      step_d = Runic.step(fn x -> x + 10 end, name: :par_d)
      step_e = Runic.step(fn x -> x * 3 end, name: :par_e)
      step_f = Runic.step(fn x -> x + 100 end, name: :par_f)
      step_g = Runic.step(fn x -> x * 5 end, name: :par_g)

      workflow =
        Runic.workflow(steps: [{step_a, [{step_b, [step_c]}]}, step_d, step_e, step_f, step_g])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_fb_mixed, workflow,
          scheduler: FlowBatch,
          scheduler_opts: [min_chain_length: 2, min_batch_size: 4]
        )

      :ok = Runic.Runner.run(runner, :wf_fb_mixed, 5)
      assert_workflow_idle(runner, :wf_fb_mixed)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_fb_mixed)
      # Chain: 5 → 6 → 12 → 11
      assert 11 in results
      # Parallel: 15, 15, 105, 25
      assert 15 in results
      assert 105 in results
      assert 25 in results
    end

    test "worker passes full runnable list to scheduler (not pre-capped)", %{runner: runner} do
      # Create many independent steps. With max_concurrency: 2, old behavior
      # would only pass 2 to the scheduler. Now it should pass all.
      step_a = Runic.step(fn x -> x + 1 end, name: :full_a)
      step_b = Runic.step(fn x -> x * 2 end, name: :full_b)
      step_c = Runic.step(fn x -> x + 10 end, name: :full_c)
      step_d = Runic.step(fn x -> x * 3 end, name: :full_d)

      workflow = Runic.workflow(steps: [step_a, step_b, step_c, step_d])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_fb_full_list, workflow,
          executor: :inline,
          max_concurrency: 2,
          scheduler: FlowBatch,
          scheduler_opts: [min_batch_size: 4]
        )

      :ok = Runic.Runner.run(runner, :wf_fb_full_list, 5)
      assert_workflow_idle(runner, :wf_fb_full_list)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_fb_full_list)
      # All 4 should complete — parallel promise counts as 1 slot
      assert length(results) == 4
    end

    test "parallel promise counts as 1 slot for concurrency", %{runner: runner} do
      parent = self()

      step_a =
        Runic.step(
          fn x ->
            send(parent, {:executing, :a})
            Process.sleep(30)
            x + 1
          end,
          name: :slot_a
        )

      step_b =
        Runic.step(
          fn x ->
            send(parent, {:executing, :b})
            Process.sleep(30)
            x * 2
          end,
          name: :slot_b
        )

      step_c =
        Runic.step(
          fn x ->
            send(parent, {:executing, :c})
            Process.sleep(30)
            x + 10
          end,
          name: :slot_c
        )

      step_d =
        Runic.step(
          fn x ->
            send(parent, {:executing, :d})
            Process.sleep(30)
            x * 3
          end,
          name: :slot_d
        )

      workflow = Runic.workflow(steps: [step_a, step_b, step_c, step_d])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_fb_slots, workflow,
          max_concurrency: 1,
          scheduler: FlowBatch,
          scheduler_opts: [min_batch_size: 4]
        )

      :ok = Runic.Runner.run(runner, :wf_fb_slots, 5)
      assert_workflow_idle(runner, :wf_fb_slots)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_fb_slots)
      # All should complete even with max_concurrency: 1
      # because the parallel promise uses 1 slot
      assert length(results) == 4
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
