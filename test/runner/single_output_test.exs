defmodule Runic.Runner.SingleOutputTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  alias Runic.Runner
  alias Runic.TestSupport.OrdinaryComponent, as: Custom
  alias Runic.Workflow

  setup do
    runner = :"single_output_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner})
    %{runner: runner}
  end

  test "immediate and managed execution share data, metadata, and retry semantics", %{
    runner: runner
  } do
    owner = self()

    workflow =
      Workflow.new()
      |> Workflow.add(Custom.new(:retry, :retry, 1))
      |> Workflow.add(Custom.new(:output, :metadata, :accepted), to: :retry)
      |> Workflow.set_scheduler_policies([{:retry, %{max_retries: 1, backoff: :none}}])

    direct = Workflow.react_until_satisfied(workflow, 4)

    {:ok, _} =
      Runner.start_workflow(runner, :managed, workflow,
        on_complete: fn id, completed -> send(owner, {:completed, id, completed}) end
      )

    assert :ok = Runner.run(runner, :managed, 4)
    assert_receive {:completed, :managed, completed}, 5_000
    assert Workflow.productions(completed, :output) == Workflow.productions(direct, :output)
    assert [%{value: 4, meta: %{custom: :accepted}}] = Workflow.productions(completed, :output)
    assert :ok = Runner.checkpoint(runner, :managed)
    assert :ok = Runner.stop(runner, :managed)
    assert {:ok, _} = Runner.resume(runner, :managed)
    assert {:ok, restored} = Runner.get_workflow(runner, :managed)
    assert Workflow.productions(restored, :output) == Workflow.productions(direct, :output)
  end

  test "manual checkpoint and resume execute pending custom work with fresh context", %{
    runner: runner
  } do
    owner = self()

    workflow =
      Workflow.new()
      |> Workflow.add(Custom.new(:first, :add, 1))
      |> Workflow.add(Custom.new(:second, :add, 2), to: :first)
      |> Workflow.put_run_context(%{_global: %{observer: owner}, second: %{offset: 100}})

    {:ok, worker} =
      Runner.start_workflow(runner, :resume, workflow,
        dispatch_mode: :manual,
        checkpoint_strategy: :manual,
        hooks: [
          on_complete: fn runnable, _, _ -> send(owner, {:accepted, runnable.node.name}) end
        ]
      )

    assert :ok = Runner.run(runner, :resume, 3)
    assert :ok = Runner.step(runner, :resume)
    assert_receive {:accepted, :first}, 5_000
    assert :ok = Runner.checkpoint(runner, :resume)
    assert_received {:work, :first, _}
    refute_received {:work, :second, _}
    monitor = Process.monitor(worker)
    assert :ok = Runner.stop(runner, :resume)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 5_000

    assert {:ok, _} =
             Runner.resume(runner, :resume,
               run_context: %{_global: %{observer: owner}, second: %{offset: 7}},
               on_complete: fn id, completed -> send(owner, {:completed, id, completed}) end
             )

    assert_receive {:completed, :resume, completed}, 5_000
    assert Workflow.raw_productions(completed, :second) == [13]
    assert_received {:work, :second, %{runtime: %{offset: 7}}}
    refute_received {:work, :first, _}
  end

  test "failure conversion reaches managed policy without producing success data", %{
    runner: runner
  } do
    owner = self()
    workflow = Workflow.new() |> Workflow.add(Custom.new(:failure, :failure, :domain_error))

    {:ok, _} =
      Runner.start_workflow(runner, :failed, workflow,
        hooks: [on_failed: fn runnable, _, _ -> send(owner, {:failed, runnable.error}) end],
        on_complete: fn id, completed -> send(owner, {:completed, id, completed}) end
      )

    assert :ok = Runner.run(runner, :failed, :input)
    assert_receive {:completed, :failed, completed}, 5_000
    assert Workflow.raw_productions(completed, :failure) == []

    assert_received {:failed, :domain_error}
  end

  test "custom nodes can execute through a batched scheduler", %{runner: runner} do
    owner = self()

    workflow =
      Workflow.new()
      |> Workflow.add(Custom.new(:first, :add, 1))
      |> Workflow.add(Custom.new(:second, :add, 2), to: :first)

    {:ok, _} =
      Runner.start_workflow(runner, :batch, workflow,
        scheduler: Runic.Runner.Scheduler.ChainBatching,
        on_complete: fn id, completed -> send(owner, {:completed, id, completed}) end
      )

    assert :ok = Runner.run(runner, :batch, 3)
    assert_receive {:completed, :batch, completed}, 5_000
    assert Workflow.raw_productions(completed, :second) == [6]
  end
end
