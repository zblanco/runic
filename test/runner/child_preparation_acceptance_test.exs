defmodule Runic.Runner.ChildPreparationAcceptanceTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  require Runic
  alias Runic.{Runner, Workflow}
  alias Runic.Workflow.{Call, ChildInvocation, Invokable, RunnableCompleted, RunnableFailed}
  alias Runic.TestSupport.ReleasingExecutor

  defp definition do
    request =
      Runic.step(
        fn n ->
          ChildInvocation.new(target: Runic.step(fn x -> x + 1 end, name: :target), input: n)
        end,
        name: :request
      )

    Workflow.new() |> Workflow.add(Call.new(request, name: :call))
  end

  for mode <- [nil, :stale, :missing] do
    test "owner rejects #{mode} prepared data before completion and deferred hooks", _ctx do
      owner = self()

      base =
        definition()
        |> Workflow.attach_after_hook(:call, fn _, wf, _ ->
          send(owner, :deferred_hook)
          wf
        end)

      runner = :"prepared_accept_#{System.unique_integer([:positive])}"
      start_supervised!({Runner, name: runner})

      {:ok, worker} =
        Runner.start_workflow(runner, :wf, base,
          executor: ReleasingExecutor,
          executor_opts: [test_pid: self(), outcome: :deferred],
          on_complete: fn _, _ -> send(owner, :scope_complete) end
        )

      {:ok, id} =
        Runner.start_execution(runner, :wf, 3,
          scheduler_policies: [{:call, %{execution_mode: :durable}}]
        )

      assert_receive {:executor_result, ^worker, handle, {executed, events}}, 5_000

      invalid =
        case unquote(mode) do
          nil ->
            %{executed | execution_data: nil}

          :missing ->
            Map.delete(executed, :execution_data)

          :stale ->
            %{
              executed
              | execution_data: %{
                  executed.execution_data
                  | occurrence_hash: Runic.Identity.derive(:node_occurrence, [:another])
                }
            }
        end

      send(worker, {handle, {invalid, events}})
      assert_receive {:executor_released, ^handle}, 5_000
      {:ok, observed} = Runner.await_execution(runner, :wf, id, 10_000)
      assert observed.admission == :stopped

      assert [%{kind: :failed, error: {:child_preparation_missing, _}, result: nil}] =
               observed.failures

      assert Process.alive?(worker)
      refute_received :deferred_hook
      {:ok, result} = Runner.get_workflow(runner, :wf)
      assert Workflow.raw_productions(result, :call) == []
      refute Enum.any?(result.runnable_events, &is_struct(&1, RunnableCompleted))
      assert Enum.any?(result.runnable_events, &is_struct(&1, RunnableFailed))

      refute Enum.any?(
               Multigraph.vertices(result.graph),
               &is_struct(&1, Runic.Workflow.ChildInvocation.Occurrence)
             )
    end
  end

  test "direct application rejects a graph from another activation before it produces a request Fact" do
    base = definition()
    first = Workflow.plan_eagerly(base, 3)
    {first, [work]} = Workflow.prepare_for_dispatch(first)
    good = Invokable.execute(work.node, work)
    second = Workflow.plan_eagerly(base, 4)
    {_, [other]} = Workflow.prepare_for_dispatch(second)
    stale = Invokable.execute(other.node, other)
    invalid = %{good | execution_data: stale.execution_data}
    checked = Workflow.validate_runnable(invalid)
    assert checked.status == :failed
    assert checked.result == nil
    result = Workflow.apply_runnable(first, invalid)
    assert Workflow.raw_productions(result, :call) == []
    refute Map.has_key?(result.graph.vertices, good.result.hash)
  end

  test "parallel Promise results normalize invalid preparation before owner acceptance" do
    request =
      Runic.step(
        fn n ->
          ChildInvocation.new(target: Runic.step(fn x -> x + 1 end, name: :target), input: n)
        end,
        name: :request
      )

    base =
      Workflow.new()
      |> Workflow.add(Call.new(request, name: :first))
      |> Workflow.add(Call.new(request, name: :second))

    runner = :"promise_preparation_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner, store: Runic.TestSupport.SnapshotTailStore})
    Runner.get_store(runner)

    {:ok, worker} =
      Runner.start_workflow(runner, :wf, base,
        scheduler: TestParallelScheduler,
        executor: ReleasingExecutor,
        executor_opts: [test_pid: self(), outcome: :deferred]
      )

    {:ok, id} =
      Runner.start_execution(runner, :wf, 3,
        scheduler_policies: [{:default, %{execution_mode: :durable}}]
      )

    assert_receive {:executor_result, ^worker, handle,
                    {:promise_result, promise_id, [first, second]}},
                   5_000

    rejected =
      case first do
        {work, _} -> work
        work -> work
      end

    accepted =
      case second do
        {work, _} -> work
        work -> work
      end

    invalid =
      case first do
        {%Runic.Workflow.Runnable{} = result, events} -> {%{result | execution_data: nil}, events}
        %Runic.Workflow.Runnable{} = result -> %{result | execution_data: nil}
      end

    send(worker, {handle, {:promise_result, promise_id, [invalid, second]}})
    assert_receive {:executor_released, ^handle}, 5_000
    {:ok, observed} = Runner.await_execution(runner, :wf, id, 10_000)
    assert Process.alive?(worker)
    assert observed.admission == :stopped
    assert [%{kind: :failed, error: {:child_preparation_missing, _}}] = observed.failures
    assert Enum.count(observed.outcomes, &(&1.kind == :completed)) == 1
    {:ok, result} = Runner.get_workflow(runner, :wf)

    assert Enum.count(
             Multigraph.vertices(result.graph),
             &is_struct(&1, Runic.Workflow.ChildInvocation.Occurrence)
           ) == 1

    :ok = Runner.checkpoint(runner, :wf)
    {store, state} = Runner.get_store(runner)
    {:ok, persisted} = store.stream(:wf, state)
    persisted = Enum.to_list(persisted)

    assert Enum.any?(
             persisted,
             &match?(%RunnableFailed{node_hash: hash} when hash == rejected.node.hash, &1)
           )

    refute Enum.any?(
             persisted,
             &match?(%RunnableCompleted{node_hash: hash} when hash == rejected.node.hash, &1)
           )

    :ok = Runner.stop(runner, :wf)
    {:ok, _} = Runner.resume(runner, :wf, executor: :inline)
    {:ok, restored} = Runner.get_workflow(runner, :wf)
    assert Workflow.raw_productions(restored, rejected.node.name) == []
    assert Workflow.raw_productions(restored, accepted.node.name) == [4]

    assert Enum.count(
             Multigraph.vertices(restored.graph),
             &is_struct(&1, Runic.Workflow.ChildInvocation.Occurrence)
           ) == 1
  end
end
