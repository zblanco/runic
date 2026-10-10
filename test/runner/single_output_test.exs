defmodule Runic.Runner.SingleOutputTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  require Runic

  alias Runic.Runner
  alias Runic.TestSupport.OrdinaryComponent, as: Custom
  alias Runic.Workflow

  setup do
    runner = :"single_output_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner})
    %{runner: runner}
  end

  for node_type <- [:step, :custom] do
    test "managed #{node_type} hooks receive the input and produced Facts", %{runner: runner} do
      owner = self()

      node =
        case unquote(node_type) do
          :step -> Runic.step(fn value -> value + 1 end, name: :increment)
          :custom -> Custom.new(:increment, :add, 1)
        end

      input = Runic.Workflow.Fact.new(value: 1, meta: %{domain: :input})

      workflow =
        Workflow.new()
        |> Workflow.add(node)
        |> Workflow.attach_before_hook(:increment, fn node, workflow, fact ->
          send(owner, {:before, node, fact})
          workflow
        end)
        |> Workflow.attach_after_hook(:increment, fn node, workflow, fact ->
          send(owner, {:after, node, fact})
          workflow
        end)

      {:ok, _} =
        Runner.start_workflow(runner, :hooks, workflow,
          on_complete: fn id, completed -> send(owner, {:completed, id, completed}) end
        )

      assert :ok = Runner.run(runner, :hooks, input)
      assert_receive {:completed, :hooks, completed}, 5_000
      [output] = Workflow.productions(completed, :increment)
      assert output.value == 2
      assert output.ancestry == {node.hash, input.hash}
      assert_received {:before, ^node, ^input}
      assert_received {:after, ^node, ^output}
      refute_received {:before, _, _}
      refute_received {:after, _, _}
    end
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
