defmodule Runic.Runner.BatchChildIntegrationTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  require Runic
  alias Runic.{Runner, Workflow}
  alias Runic.TestSupport.SnapshotTailStore
  alias Runic.Workflow.{Batch, Call, ChildInvocation}
  alias Runic.Workflow.ChildInvocation.Occurrence

  for wiring <- [:whole, :ports] do
    test "Batch terminal outcomes feed a child through #{wiring} wiring and replay" do
      definition = workflow(unquote(wiring))
      {completed, execution} = Workflow.execute(definition, input())

      assert execution.admission == :open
      assert_result(completed)
      assert_receive :child_sum_ran

      replayed =
        Workflow.from_events(
          Workflow.build_log(definition) ++ Enum.reverse(completed.uncommitted_events)
        )

      assert_result(replayed)
      refute_received :child_sum_ran
    end
  end

  test "snapshot-tail recovery preserves Batch outcomes and installs a later child attachment" do
    runner = runner()

    {:ok, _} =
      Runner.start_workflow(runner, :batch_child, workflow(),
        executor: :inline,
        dispatch_mode: :manual
      )

    {:ok, _} = Runner.start_execution(runner, :batch_child, input())

    snapshot =
      step_until(runner, fn workflow ->
        Enum.any?(Workflow.next_runnables(workflow), fn {node, _} -> is_struct(node, Call) end)
      end)

    assert Batch.present?(snapshot)
    assert occurrences(snapshot) == []
    assert_items_ran()
    assert :ok = Runner.checkpoint(runner, :batch_child)
    {store, state} = Runner.get_store(runner)
    {:ok, prefix} = store.stream(:batch_child, state)
    cursor = Enum.count(prefix)

    assert :ok =
             store.save_snapshot(:batch_child, cursor, Runner.encode_snapshot(snapshot), state)

    assert :ok = Runner.step(runner, :batch_child)
    assert :ok = Runner.checkpoint(runner, :batch_child)
    {:ok, attached} = Runner.get_workflow(runner, :batch_child)
    assert length(occurrences(attached)) == 1
    refute_received :child_sum_ran

    {:ok, tail} = store.stream(:batch_child, state, after_cursor: cursor)
    assert Enum.any?(tail, &is_struct(&1, Workflow.ComponentAdded))
    assert :ok = Runner.stop(runner, :batch_child)

    {:ok, _} =
      Runner.resume(runner, :batch_child,
        executor: :inline,
        rehydration: :full,
        run_context: runtime_context(),
        scheduler_policies: policies()
      )

    {:ok, restored} = Runner.get_workflow(runner, :batch_child)
    assert_result(restored)
    assert_receive :child_sum_ran
    refute_received :child_sum_ran
    refute_received {:batch_item_ran, _}
  end

  test "a child Promise retains its accepted prefix after Task loss and full Store recovery" do
    runner = runner()
    observer = self()

    {:ok, worker} =
      Runner.start_workflow(runner, :batch_child, workflow(),
        promise_opts: [min_chain_length: 2],
        hooks: [
          on_complete: fn runnable, _, _ ->
            send(observer, {:accepted, Map.get(runnable.node, :name)})
          end
        ]
      )

    {:ok, id} =
      Runner.start_execution(runner, :batch_child, input(), run_context: runtime_context(true))

    assert_receive {:child_tail_blocked, task}, 5_000
    assert_receive {:accepted, :child_sum}, 5_000
    assert_receive :child_sum_ran
    assert_items_ran()

    state = :sys.get_state(worker)
    [progress] = Map.values(state.promise_progress)
    assert [%{node: %{name: :child_double}}] = progress.frontier
    assert :ok = Runner.checkpoint(runner, :batch_child)

    assert {:ok, %{status: :saved, pending_events: 0}} =
             Runner.persistence_status(runner, :batch_child)

    Process.exit(task, :kill)
    assert {:ok, execution} = Runner.await_execution(runner, :batch_child, id, 10_000)
    assert execution.admission == :stopped
    assert Enum.any?(execution.outcomes, &match?(%{kind: :completed, node_name: :child_sum}, &1))

    assert Enum.any?(
             execution.outcomes,
             &match?(%{kind: :uncertain, node_name: :child_double}, &1)
           )

    {:ok, interrupted} = Runner.get_workflow(runner, :batch_child)
    assert Workflow.raw_productions(interrupted, :call) == []
    assert :ok = Runner.stop(runner, :batch_child)

    {:ok, _} =
      Runner.resume(runner, :batch_child,
        executor: :inline,
        rehydration: :full,
        run_context: runtime_context(),
        scheduler_policies: policies()
      )

    {:ok, restored} = Runner.get_workflow(runner, :batch_child)
    assert_result(restored)
    refute_received :child_sum_ran
    refute_received {:batch_item_ran, _}
  end

  defp workflow(wiring \\ :ports) do
    member =
      Runic.step(
        fn value ->
          send(context(:observer), {:batch_item_ran, value})
          if value == :bad, do: raise("bad item")
          value + context(:batch).parent.offset
        end,
        name: :item
      )

    request =
      Runic.step(
        fn %Runic.Workflow.Batch.Result{outcomes: outcomes} ->
          sum =
            Runic.step(
              fn values ->
                send(context(:observer), :child_sum_ran)
                Enum.sum(values)
              end,
              name: :child_sum
            )

          double =
            Runic.step(
              fn value ->
                if context(:block) do
                  send(context(:observer), {:child_tail_blocked, self()})
                  receive do: (:release -> :ok)
                end

                value * 2
              end,
              name: :child_double
            )

          target =
            Workflow.new(
              name: :child,
              input_ports: [in: []],
              output_ports: [out: [from: :child_double]]
            )
            |> Workflow.add(sum)
            |> Workflow.add(double, to: :child_sum)

          values = for %{status: :completed, value: value} <- outcomes, do: value
          ChildInvocation.new(target: target, input: values)
        end,
        name: :request
      )

    connections =
      case wiring do
        :whole -> [to: :batch]
        :ports -> [connections: [[from: {:batch, :out}, to: :in]]]
      end

    Workflow.new()
    |> Workflow.add(Runic.batch(member, name: :batch))
    |> Workflow.add(Call.new(request, name: :call), connections)
    |> Workflow.add(Runic.step(fn value -> value end, name: :receipt), to: :call)
    |> Workflow.put_run_context(runtime_context())
    |> Workflow.set_scheduler_policies(policies())
    |> Workflow.enable_event_emission()
  end

  defp input, do: Batch.input([1, :bad, 3], %{offset: 10})
  defp runtime_context(block \\ false), do: %{_global: %{observer: self(), block: block}}

  defp policies do
    [
      {:item, %{execution_mode: :durable, on_failure: :skip}},
      {:default, %{execution_mode: :durable}}
    ]
  end

  defp assert_result(workflow) do
    assert [%Batch.Result{parent: %{offset: 10}, outcomes: outcomes}] =
             Workflow.raw_productions(workflow, :batch)

    assert Enum.map(outcomes, & &1.status) == [:completed, :skipped, :completed]
    assert Enum.map(outcomes, & &1.value) == [11, nil, 13]
    assert Workflow.raw_productions(workflow, :call) == [48]
    assert Workflow.raw_productions(workflow, :receipt) == [48]
    assert length(occurrences(workflow)) == 1
    refute Workflow.is_runnable?(workflow)
  end

  defp assert_items_ran do
    for value <- [1, :bad, 3], do: assert_receive({:batch_item_ran, ^value}, 5_000)
  end

  defp occurrences(workflow),
    do: Enum.filter(Multigraph.vertices(workflow.graph), &is_struct(&1, Occurrence))

  defp runner do
    name = :"batch_child_integration_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: name, store: SnapshotTailStore})
    Runner.get_store(name)
    name
  end

  defp step_until(runner, predicate, remaining \\ 20) do
    {:ok, workflow} = Runner.get_workflow(runner, :batch_child)

    if predicate.(workflow) do
      workflow
    else
      assert remaining > 0
      assert :ok = Runner.step(runner, :batch_child)
      step_until(runner, predicate, remaining - 1)
    end
  end
end
