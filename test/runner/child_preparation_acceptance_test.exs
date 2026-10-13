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

      assert_receive {:executor_result, ^worker, handle, {executed, events}}, 1_000

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
      assert_receive {:executor_released, ^handle}, 1_000
      {:ok, observed} = Runner.await_execution(runner, :wf, id)
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
end
