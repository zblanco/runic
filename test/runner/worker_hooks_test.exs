defmodule Runic.Runner.WorkerHooksTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  require Runic

  setup do
    runner_name = :"test_runner_hooks_#{System.unique_integer([:positive])}"
    start_supervised!({Runic.Runner, name: runner_name})
    %{runner: runner_name}
  end

  # ---------------------------------------------------------------------------
  # A. on_dispatch hook
  # ---------------------------------------------------------------------------

  describe "on_dispatch" do
    test "called before each runnable is dispatched", %{runner: runner} do
      test_pid = self()

      hook = fn runnable, _state ->
        send(test_pid, {:dispatched, runnable.node.name})
        :ok
      end

      step_a = Runic.step(fn x -> x + 1 end, name: :hook_a)
      step_b = Runic.step(fn x -> x * 2 end, name: :hook_b)
      workflow = Runic.workflow(steps: [{step_a, [step_b]}])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_on_dispatch, workflow, hooks: [on_dispatch: hook])

      :ok = Runic.Runner.run(runner, :wf_on_dispatch, 5)
      assert_workflow_idle(runner, :wf_on_dispatch)

      assert_received {:dispatched, :hook_a}
      assert_received {:dispatched, :hook_b}
    end
  end

  # ---------------------------------------------------------------------------
  # B. on_complete hook
  # ---------------------------------------------------------------------------

  describe "on_complete" do
    test "called with runnable, duration, and state after successful completion", %{
      runner: runner
    } do
      test_pid = self()

      hook = fn runnable, duration_ms, _state ->
        send(test_pid, {:completed, runnable.node.name, duration_ms})
        :ok
      end

      step = Runic.step(fn x -> x + 1 end, name: :complete_step)
      workflow = Runic.workflow(steps: [step])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_on_complete, workflow, hooks: [on_complete: hook])

      :ok = Runic.Runner.run(runner, :wf_on_complete, 5)
      assert_workflow_idle(runner, :wf_on_complete)

      assert_receive {:completed, :complete_step, duration_ms}
      assert is_integer(duration_ms)
      assert duration_ms >= 0
    end
  end

  # ---------------------------------------------------------------------------
  # C. on_failed hook
  # ---------------------------------------------------------------------------

  describe "on_failed" do
    test "called when a task crashes", %{runner: runner} do
      test_pid = self()

      hook = fn _runnable, reason, _state ->
        send(test_pid, {:failed, reason})
        :ok
      end

      step = Runic.step(fn _ -> raise "kaboom" end, name: :crasher)
      workflow = Runic.workflow(steps: [step])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_on_failed, workflow, hooks: [on_failed: hook])

      :ok = Runic.Runner.run(runner, :wf_on_failed, 1)
      assert_workflow_idle(runner, :wf_on_failed)

      assert_receive {:failed, _reason}
    end
  end

  # ---------------------------------------------------------------------------
  # D. on_idle hook
  # ---------------------------------------------------------------------------

  describe "on_idle" do
    test "called when workflow transitions to idle", %{runner: runner} do
      test_pid = self()

      hook = fn _state ->
        send(test_pid, :idle_reached)
        :ok
      end

      step = Runic.step(fn x -> x + 1 end, name: :idle_step)
      workflow = Runic.workflow(steps: [step])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_on_idle, workflow, hooks: [on_idle: hook])

      :ok = Runic.Runner.run(runner, :wf_on_idle, 5)
      assert_workflow_idle(runner, :wf_on_idle)

      assert_received :idle_reached
    end
  end

  # ---------------------------------------------------------------------------
  # E. transform_runnables hook
  # ---------------------------------------------------------------------------

  describe "transform_runnables" do
    test "is called with runnables and can observe them", %{runner: runner} do
      test_pid = self()

      transform = fn runnables, _workflow ->
        names = Enum.map(runnables, & &1.node.name)
        send(test_pid, {:transform_called, names})
        runnables
      end

      step_a = Runic.step(fn x -> x end, name: :root)
      step_b = Runic.step(fn x -> x + 1 end, name: :keep_me)
      step_c = Runic.step(fn x -> x + 2 end, name: :also_me)
      workflow = Runic.workflow(steps: [{step_a, [step_b, step_c]}])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_transform, workflow,
          hooks: [transform_runnables: transform]
        )

      :ok = Runic.Runner.run(runner, :wf_transform, 5)
      assert_workflow_idle(runner, :wf_transform)

      # The transform was called at least for the fan-out batch
      assert_receive {:transform_called, names}
      assert :keep_me in names or :also_me in names or :root in names

      {:ok, results} = Runic.Runner.get_results(runner, :wf_transform)
      assert 6 in results
      assert 7 in results
    end

    test "can reorder runnables", %{runner: runner} do
      dispatch_order = :ets.new(:dispatch_order, [:public, :ordered_set])

      transform = fn runnables, _workflow ->
        Enum.sort_by(runnables, fn r -> r.node.name end)
      end

      on_dispatch = fn runnable, _state ->
        :ets.insert(dispatch_order, {System.monotonic_time(:nanosecond), runnable.node.name})
        :ok
      end

      step_a = Runic.step(fn x -> x end, name: :root)
      step_z = Runic.step(fn x -> x + 1 end, name: :z_step)
      step_m = Runic.step(fn x -> x + 2 end, name: :m_step)
      step_a2 = Runic.step(fn x -> x + 3 end, name: :a_step)

      workflow = Runic.workflow(steps: [{step_a, [step_z, step_m, step_a2]}])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_reorder, workflow,
          hooks: [transform_runnables: transform, on_dispatch: on_dispatch]
        )

      :ok = Runic.Runner.run(runner, :wf_reorder, 0)
      assert_workflow_idle(runner, :wf_reorder)

      # Verify dispatch order was alphabetical (excluding :root which dispatches first)
      dispatched =
        :ets.tab2list(dispatch_order)
        |> Enum.map(fn {_, name} -> name end)
        |> Enum.reject(&(&1 == :root))

      assert dispatched == [:a_step, :m_step, :z_step]
    end
  end

  # ---------------------------------------------------------------------------
  # F. Hook resilience
  # ---------------------------------------------------------------------------

  describe "hook resilience" do
    test "hook exception does not crash the Worker", %{runner: runner} do
      crashing_hook = fn _runnable, _state ->
        raise "hook explosion"
      end

      step = Runic.step(fn x -> x + 1 end, name: :resilient_step)
      workflow = Runic.workflow(steps: [step])

      {:ok, pid} =
        Runic.Runner.start_workflow(runner, :wf_hook_crash, workflow,
          hooks: [on_dispatch: crashing_hook]
        )

      :ok = Runic.Runner.run(runner, :wf_hook_crash, 5)
      assert_workflow_idle(runner, :wf_hook_crash)

      assert Process.alive?(pid)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_hook_crash)
      assert 6 in results
    end

    test "no hooks configured (default) produces zero overhead", %{runner: runner} do
      step = Runic.step(fn x -> x + 1 end, name: :no_hooks)
      workflow = Runic.workflow(steps: [step])

      {:ok, pid} = Runic.Runner.start_workflow(runner, :wf_no_hooks, workflow)

      state = :sys.get_state(pid)
      # All hook slots are nil when no hooks configured
      assert state.hooks.on_dispatch == nil
      assert state.hooks.on_complete == nil
      assert state.hooks.on_failed == nil
      assert state.hooks.on_idle == nil
      assert state.hooks.transform_runnables == nil

      :ok = Runic.Runner.run(runner, :wf_no_hooks, 5)
      assert_workflow_idle(runner, :wf_no_hooks)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_no_hooks)
      assert 6 in results
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
