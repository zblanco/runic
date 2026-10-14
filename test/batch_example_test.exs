defmodule Runic.BatchExampleTest do
  use ExUnit.Case, async: true
  require Runic
  alias Runic.{Runner, Workflow}
  alias Runic.Workflow.Batch
  alias Runic.Examples.Batch.Adjustment
  alias Runic.TestSupport.OrdinaryComponent, as: Custom

  test "a non-Jido component uses parent context and explicit failure conversion" do
    batch = Runic.batch(Adjustment.new(:price), name: :prices)

    template =
      Workflow.new()
      |> Workflow.add(batch)
      |> Workflow.add(Custom.new(:result, :data), to: :prices)

    template = Workflow.from_log(Workflow.build_log(template))

    {completed, _} =
      Workflow.execute(template, Batch.input([10, :invalid, 20], %{adjustment: 3}),
        scheduler_policies: [{:price, %{on_failure: :skip}}]
      )

    assert [%{parent: %{adjustment: 3}, outcomes: outcomes}] =
             Workflow.raw_productions(completed, :result)

    assert Enum.map(outcomes, & &1.status) == [:completed, :skipped, :completed]
    assert Enum.map(outcomes, & &1.value) == [13, nil, 23]
    assert Enum.at(outcomes, 1).error == :invalid_price
  end

  test "a captured Step batch preserves internal identities through build and event replay" do
    offset = 7
    item = Runic.step(fn value -> value + ^offset end, name: :item)
    batch = Runic.batch(item, name: :batch)

    template =
      Workflow.new()
      |> Workflow.add(batch)
      |> Workflow.add(Custom.new(:result, :data), to: :batch)

    rebuilt = Workflow.from_log(Workflow.build_log(template))
    rebuilt_batch = Workflow.get_component!(rebuilt, :batch)
    assert rebuilt_batch.fan_out.hash == batch.fan_out.hash
    assert rebuilt_batch.fan_in.hash == batch.fan_in.hash
    assert rebuilt_batch.component.hash == batch.component.hash

    {completed, _} =
      Workflow.execute(Workflow.enable_event_emission(rebuilt), Batch.input([1, 2], :parent))

    replayed =
      Workflow.from_events(
        Workflow.build_log(completed) ++ Enum.reverse(completed.uncommitted_events)
      )

    assert Workflow.raw_productions(replayed, :result) ==
             Workflow.raw_productions(completed, :result)

    assert [%{outcomes: [%{value: 8}, %{value: 9}]}] = Workflow.raw_productions(replayed, :result)
  end

  test "nested batch definitions and completed downstream activations replay" do
    inner = Runic.batch(Custom.new(:item, :add, 1), name: :inner)
    outer = Runic.batch(inner, name: :outer)

    template =
      Workflow.new()
      |> Workflow.add(outer)
      |> Workflow.add(Custom.new(:result, :data), to: :outer)
      |> Workflow.enable_event_emission()

    {completed, _} = Workflow.execute(template, Batch.input([[1, 2], []], :parent))

    replayed =
      Workflow.from_events(
        Workflow.build_log(completed) ++ Enum.reverse(completed.uncommitted_events)
      )

    assert Workflow.raw_productions(replayed, :result) ==
             Workflow.raw_productions(completed, :result)

    refute Workflow.is_runnable?(replayed)
  end

  test "a native snapshot and Store tail retain accepted item progress" do
    runner = :"batch_snapshot_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner, store: Runic.TestSupport.SnapshotTailStore})
    _ = Runner.get_store(runner)
    batch = Runic.batch(Custom.new(:item, :add, 2), name: :batch)

    template =
      Workflow.new()
      |> Workflow.add(batch)
      |> Workflow.add(Custom.new(:result, :data), to: :batch)
      |> Workflow.put_run_context(%{_global: %{observer: self()}})

    {:ok, worker} =
      Runner.start_workflow(runner, :snapshot, template,
        dispatch_mode: :manual,
        executor: :inline
      )

    :ok = Runner.run(runner, :snapshot, Batch.input([1, 2], :parent))
    :sys.get_state(worker)
    :ok = Runner.step(runner, :snapshot)
    :ok = Runner.step(runner, :snapshot)
    assert_receive {:work, :item, accepted}
    :ok = Runner.checkpoint(runner, :snapshot)
    {:ok, %{event_cursor: cursor}} = Runner.persistence_status(runner, :snapshot)
    {:ok, workflow} = Runner.get_workflow(runner, :snapshot)
    {store, state} = Runner.get_store(runner)
    :ok = store.save_snapshot(:snapshot, cursor, Runner.encode_snapshot(workflow), state)
    :ok = Runner.stop(runner, :snapshot)

    {:ok, recovered} =
      Runner.resume(runner, :snapshot,
        executor: :inline,
        run_context: %{_global: %{observer: self()}}
      )

    assert_receive {:work, :item, second}, 2000
    refute accepted.activation_id == second.activation_id
    wait_idle(recovered)
    {:ok, workflow} = Runner.get_workflow(runner, :snapshot)
    assert [%{parent: :parent, outcomes: outcomes}] = Workflow.raw_productions(workflow, :result)
    assert Enum.map(outcomes, & &1.value) == [3, 4]
    refute_receive {:work, :item, _}, 20

    assert Runic.TestSupport.SnapshotTailStore.call_count(
             state,
             {:stream, :snapshot, :after_cursor}
           ) == 1
  end

  defp wait_idle(worker, attempts \\ 200)
  defp wait_idle(_worker, 0), do: flunk("worker did not become idle")

  defp wait_idle(worker, attempts) do
    if :sys.get_state(worker).status == :idle do
      :ok
    else
      Process.sleep(10)
      wait_idle(worker, attempts - 1)
    end
  end
end
