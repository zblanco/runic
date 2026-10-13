defmodule Runic.Runner.PromiseProgressOrderingTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  require Runic
  alias Runic.{Runner, Workflow}
  alias Runic.TestSupport.{PromiseDeferredNode, PromiseProgressScheduler}

  for first <- [:final, :loss] do
    @tag first: first
    test "late progress and final replies are ignored after #{first}", ctx do
      {runner, worker, id, task, promise, handle} = blocked_chain()
      original = hd(promise.runnables)
      a = Workflow.SingleOutput.complete_value(original, 1)
      state = :sys.get_state(worker)

      {:ok, prepared_b} =
        Workflow.Invokable.prepare(
          Workflow.get_component!(state.workflow, :b),
          state.workflow,
          a.result
        )

      b = Workflow.SingleOutput.complete_value(prepared_b, 2)
      final = {handle, {:promise_result, promise.id, [a, b]}}

      if ctx.first == :final,
        do: send(worker, final),
        else: send(worker, {:DOWN, handle, :process, task, :killed})

      :sys.get_state(worker)
      monitor = Process.monitor(task)
      Process.exit(task, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^task, :killed}, 2000
      before_late = :sys.get_state(worker)
      send(worker, {:promise_progress, promise.id, a, [prepared_b]})
      send(worker, final)
      send(worker, {:DOWN, handle, :process, task, :late})
      assert :sys.get_state(worker) == before_late
      {:ok, execution} = Runner.execution(runner, :ordering, id)

      if ctx.first == :final do
        assert Enum.map(execution.outcomes, & &1.kind) == [:completed, :completed]
        assert Workflow.raw_productions(before_late.workflow, :b) == [2]
      else
        assert [%{kind: :uncertain, node_name: :a}] = execution.outcomes
        assert Workflow.raw_productions(before_late.workflow) == []
        assert execution.admission == :stopped
      end
    end
  end

  test "a rejected non-ready frontier still accepts the final computed prefix" do
    runner = runner()

    a =
      Runic.step(
        fn value ->
          send(context(:observer), {:blocked, self()})
          receive do: (:release -> value + 1)
        end,
        name: :a
      )

    deferred = %PromiseDeferredNode{
      name: :deferred,
      hash: Runic.Identity.derive(:component_definition, [:deferred])
    }

    workflow =
      Workflow.new()
      |> Workflow.add(a)
      |> Workflow.add_step(a, deferred)
      |> Workflow.put_run_context(%{_global: %{observer: self()}})

    observer = self()

    {:ok, worker} =
      Runner.start_workflow(runner, :fallback, workflow,
        promise_opts: [min_chain_length: 2],
        hooks: [on_complete: fn r, _, _ -> send(observer, {:accepted, r.node.name}) end]
      )

    :ok = Runner.run(runner, :fallback, 0)
    assert_receive {:blocked, task}, 2000
    state = :sys.get_state(worker)
    [{handle, _}] = Map.to_list(state.active_tasks)
    scope = state.task_scope
    :sys.suspend(scope)
    on_exit(fn -> if Process.alive?(scope), do: :sys.resume(scope) end)
    :erlang.trace(worker, true, [:receive, {:tracer, self()}])
    on_exit(fn -> if Process.alive?(worker), do: :erlang.trace(worker, false, [:receive]) end)
    send(task, :release)

    assert_receive {:trace, ^worker, :receive,
                    {:promise_progress, _id, %Workflow.Runnable{}, []}},
                   2000

    :erlang.trace(worker, false, [:receive])
    wait_control(scope, handle)
    rejected = :sys.get_state(worker)
    assert rejected.promise_progress == %{}
    assert Workflow.raw_productions(rejected.workflow, :a) == []
    :sys.resume(scope)
    assert_receive {:accepted, :a}, 2000
    accepted = :sys.get_state(worker)
    assert Workflow.raw_productions(accepted.workflow, :a) == [1]
    assert accepted.active_promises == %{}
    assert accepted.promise_progress == %{}
    refute_received {:accepted, :a}
    assert :ok = Runner.cancel(runner, :fallback)
  end

  test "a Condition deliberately ends a Promise and the Rule tail runs in a second unit" do
    runner = runner()
    a = Runic.step(fn value -> value + 1 end, name: :a)
    rule = Runic.rule(fn value when value > 0 -> value * 2 end, name: :rule)
    z = Runic.step(fn value -> value + 13 end, name: :z)

    workflow =
      Workflow.new()
      |> Workflow.add(a)
      |> Workflow.add(rule, to: :a)
      |> Workflow.add(z, to: :rule)

    {:ok, worker} =
      Runner.start_workflow(runner, :condition, workflow,
        scheduler: PromiseProgressScheduler,
        scheduler_opts: [observer: self()]
      )

    {:ok, id} = Runner.start_execution(runner, :condition, 5)
    assert {:ok, _} = Runner.await_execution(runner, :condition, id)
    assert_receive {:scheduler_dispatch, first}
    assert_receive {:scheduler_dispatch, second}
    assert MapSet.size(first.node_hashes) == 4
    assert MapSet.size(second.node_hashes) == 2
    refute_receive {:scheduler_dispatch, _}, 20
    assert Workflow.raw_productions(:sys.get_state(worker).workflow, :z) == [25]
    assert :sys.get_state(worker).scheduler_state.active == MapSet.new()
  end

  defp blocked_chain do
    runner = runner()

    a =
      Runic.step(
        fn value ->
          send(context(:observer), {:blocked, self()})
          receive do: (:release -> value + 1)
        end,
        name: :a
      )

    b = Runic.step(fn value -> value + 1 end, name: :b)

    workflow =
      Runic.workflow(steps: [{a, [b]}])
      |> Workflow.put_run_context(%{_global: %{observer: self()}})

    {:ok, worker} =
      Runner.start_workflow(runner, :ordering, workflow, promise_opts: [min_chain_length: 2])

    {:ok, id} = Runner.start_execution(runner, :ordering, 0)
    assert_receive {:blocked, task}, 2000
    state = :sys.get_state(worker)
    [promise] = Map.values(state.active_promises)
    [{handle, _}] = Map.to_list(state.active_tasks)
    {runner, worker, id, task, promise, handle}
  end

  defp runner do
    name = :"promise_ordering_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: name})
    name
  end

  defp wait_control(scope, handle, tries \\ 200)
  defp wait_control(_scope, _handle, 0), do: flunk("final reply was not queued")

  defp wait_control(scope, handle, tries) do
    {:messages, messages} = Process.info(scope, :messages)

    if Enum.any?(messages, &match?({:result, ^handle, _}, &1)),
      do: :ok,
      else:
        (
          Process.sleep(5)
          wait_control(scope, handle, tries - 1)
        )
  end
end
