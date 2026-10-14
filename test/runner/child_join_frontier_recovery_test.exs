defmodule Runic.Runner.ChildJoinFrontierRecoveryTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  require Runic
  alias Runic.{Runner, Workflow}
  alias Runic.Workflow.{Call, ChildInvocation, Join}
  alias Runic.TestSupport.{OrdinaryComponent, SnapshotTailStore}

  for mode <- [:stream, :snapshot_tail] do
    test "#{mode} recovery delivers a pending completed Join consumer once" do
      runner = :"join_frontier_#{System.unique_integer([:positive])}"
      start_supervised!({Runner, name: runner, store: SnapshotTailStore})
      Runner.get_store(runner)

      request =
        Runic.step(
          fn n ->
            ChildInvocation.new(target: OrdinaryComponent.new(:target, :add, 100), input: n)
          end,
          name: :request
        )

      original =
        Workflow.new()
        |> Workflow.add(Call.new(request, name: :call))
        |> Workflow.add(Runic.step(fn n -> n end, name: :other))
        |> Workflow.add(
          Runic.step(
            fn [left, right] ->
              send(context(:observer), {:joined_once, {left, right}})
              {left, right}
            end,
            name: :joined
          ),
          to: [:call, :other]
        )

      {:ok, _} =
        Runner.start_workflow(runner, :wf, original,
          executor: :inline,
          dispatch_mode: :manual,
          run_context: %{_global: %{observer: self()}}
        )

      {:ok, id} = Runner.start_execution(runner, :wf, 6)
      step_until(runner, fn wf -> Multigraph.edges(wf.graph, by: :joined) != [] end)
      :ok = Runner.checkpoint(runner, :wf)
      {store, state} = Runner.get_store(runner)

      if unquote(mode) == :snapshot_tail do
        {:ok, snapshot} = Runner.get_workflow(runner, :wf)
        {:ok, events} = store.stream(:wf, state)
        cursor = events |> Enum.to_list() |> length()
        :ok = store.save_snapshot(:wf, cursor, Runner.encode_snapshot(snapshot), state)
      end

      pending =
        step_until(runner, fn wf ->
          Enum.any?(Workflow.next_runnables(wf), fn {node, _} ->
            Map.get(node, :name) == :joined
          end)
        end)

      join = Enum.find(Multigraph.vertices(pending.graph), &is_struct(&1, Join))

      [edge] =
        Multigraph.in_edges(pending.graph, Workflow.get_component!(pending, :joined),
          by: :runnable
        )

      assert {:known, [_, _]} = Workflow.join_contributions(pending, edge.v1)
      assert join
      refute_received {:joined_once, _}
      :ok = Runner.checkpoint(runner, :wf)
      :ok = Runner.stop(runner, :wf)

      {:ok, _} =
        Runner.resume(runner, :wf,
          executor: :inline,
          dispatch_mode: :manual,
          run_context: %{_global: %{observer: self()}}
        )

      {:ok, recovered} = Runner.get_workflow(runner, :wf)

      assert Enum.any?(Workflow.next_runnables(recovered), fn {node, _} ->
               Map.get(node, :name) == :joined
             end)

      :ok = Runner.step(runner, :wf)
      assert_receive {:joined_once, {106, 6}}
      assert {:error, :not_runnable} = Runner.step(runner, :wf)
      refute_received {:joined_once, _}
      :ok = Runner.stop(runner, :wf)
      {:ok, _} = Runner.resume(runner, :wf, executor: :inline)
      {:ok, final} = Runner.get_workflow(runner, :wf)
      assert Workflow.raw_productions(final, :joined) == [{106, 6}]
      refute_received {:joined_once, _}
      assert id
    end
  end

  defp step_until(runner, predicate, remaining \\ 20) do
    {:ok, workflow} = Runner.get_workflow(runner, :wf)

    if predicate.(workflow) do
      workflow
    else
      assert remaining > 0
      assert :ok = Runner.step(runner, :wf)
      step_until(runner, predicate, remaining - 1)
    end
  end
end
