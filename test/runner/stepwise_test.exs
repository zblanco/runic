defmodule Runic.Runner.StepwiseTest do
  use ExUnit.Case, async: true

  require Runic

  alias Runic.Runner

  setup do
    runner = :"stepwise_runner_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner})
    %{runner: runner}
  end

  test "manual dispatch runs one ready unit per step", %{runner: runner} do
    owner = self()

    first =
      Runic.step(
        fn value ->
          send(owner, {:ran, :first})
          value + 1
        end,
        name: :first
      )

    second =
      Runic.step(
        fn value ->
          send(owner, {:ran, :second})
          value * 2
        end,
        name: :second
      )

    workflow = Runic.workflow(steps: [{first, [second]}])

    {:ok, pid} =
      Runner.start_workflow(runner, :manual_steps, workflow, dispatch_mode: :manual)

    :ok = Runner.run(runner, :manual_steps, 3)
    refute_receive {:ran, _}, 50

    assert :ok = Runner.step(runner, :manual_steps)
    assert_receive {:ran, :first}
    wait_until_quiet(pid)
    refute_receive {:ran, :second}, 50

    assert :ok = Runner.step(runner, :manual_steps)
    assert_receive {:ran, :second}
    wait_until_idle(pid)

    assert {:ok, %{second: 8}} =
             Runner.get_results(runner, :manual_steps, components: [:second])

    assert {:error, :not_runnable} = Runner.step(runner, :manual_steps)
  end

  test "step rejects automatic dispatch and active work", %{runner: runner} do
    owner = self()

    blocking =
      Runic.step(
        fn value ->
          send(owner, {:started, self()})

          receive do
            :release -> value
          end
        end,
        name: :blocking
      )

    workflow = Runic.workflow(steps: [blocking])

    {:ok, _pid} = Runner.start_workflow(runner, :automatic, workflow)
    assert {:error, :automatic_dispatch} = Runner.step(runner, :automatic)

    {:ok, _pid} =
      Runner.start_workflow(runner, :manual_busy, workflow, dispatch_mode: :manual)

    :ok = Runner.run(runner, :manual_busy, :value)
    :ok = Runner.step(runner, :manual_busy)
    assert_receive {:started, task}
    assert {:error, :busy} = Runner.step(runner, :manual_busy)
    send(task, :release)
  end

  test "continue returns a manual workflow to automatic dispatch", %{runner: runner} do
    first = Runic.step(fn value -> value + 1 end, name: :first)
    second = Runic.step(fn value -> value * 2 end, name: :second)
    third = Runic.step(fn value -> value - 3 end, name: :third)
    workflow = Runic.workflow(steps: [{first, [{second, [third]}]}])

    {:ok, pid} = Runner.start_workflow(runner, :continue, workflow, dispatch_mode: :manual)
    :ok = Runner.run(runner, :continue, 5)
    :ok = Runner.step(runner, :continue)
    wait_until_quiet(pid)

    assert :ok = Runner.continue(runner, :continue)
    wait_until_idle(pid)

    assert {:ok, %{third: 9}} =
             Runner.get_results(runner, :continue, components: [:third])
  end

  test "a batching scheduler steps one scheduler unit", %{runner: runner} do
    first = Runic.step(fn value -> value + 1 end, name: :first)
    second = Runic.step(fn value -> value * 2 end, name: :second)
    third = Runic.step(fn value -> value - 3 end, name: :third)
    workflow = Runic.workflow(steps: [{first, [{second, [third]}]}])

    {:ok, pid} =
      Runner.start_workflow(runner, :batch_step, workflow,
        dispatch_mode: :manual,
        scheduler: Runic.Runner.Scheduler.ChainBatching
      )

    :ok = Runner.run(runner, :batch_step, 5)
    :ok = Runner.step(runner, :batch_step)
    wait_until_idle(pid)

    assert {:ok, %{third: 9}} =
             Runner.get_results(runner, :batch_step, components: [:third])
  end

  defp wait_until_quiet(pid), do: wait_until(pid, &(&1.active_tasks == %{}))

  defp wait_until_idle(pid) do
    wait_until(pid, &(&1.status == :idle and &1.active_tasks == %{}))
  end

  defp wait_until(pid, condition, attempts \\ 200)

  defp wait_until(_pid, _condition, 0), do: flunk("workflow did not reach the expected state")

  defp wait_until(pid, condition, attempts) do
    if condition.(:sys.get_state(pid)) do
      :ok
    else
      Process.sleep(10)
      wait_until(pid, condition, attempts - 1)
    end
  end
end
