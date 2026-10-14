defmodule Runic.Workflow.BatchParentSnapshotTest do
  use ExUnit.Case, async: false

  alias Runic.Runner
  alias Runic.TestSupport.CoordinateComponent
  alias Runic.Workflow
  alias Runic.Workflow.Batch

  test "snapshot recovery loads the component before checking its parent option" do
    parent = %{padding: Enum.to_list(1..10_000)}

    snapshot =
      Workflow.new()
      |> Workflow.add(Runic.batch(CoordinateComponent.new(:item), name: :batch))
      |> Workflow.plan_eagerly(Batch.input([4, 4, 2], parent))
      |> Workflow.react()
      |> Runner.encode_snapshot()

    on_exit(fn -> Code.ensure_loaded!(CoordinateComponent) end)
    :code.purge(CoordinateComponent)
    assert :code.delete(CoordinateComponent)
    assert :code.is_loaded(CoordinateComponent) == false

    assert {:ok, restored} = Runner.decode_snapshot(snapshot)
    assert :code.is_loaded(CoordinateComponent) == false

    {prepared, runnables} = Workflow.prepare_for_dispatch(restored)
    assert length(runnables) == 3

    for runnable <- runnables do
      refute Map.has_key?(runnable.context.batch, :parent)
      assert runnable.context.batch.item_id == runnable.input_fact.hash
    end

    assert {:file, _} = :code.is_loaded(CoordinateComponent)
    completed = Workflow.react_until_satisfied(prepared)
    refute Workflow.is_runnable?(completed)

    assert [%Batch.Result{parent: ^parent, outcomes: outcomes}] =
             Workflow.raw_productions(completed, :batch)

    assert Enum.map(outcomes, & &1.value) ==
             [%{value: 4, index: 0}, %{value: 4, index: 1}, %{value: 2, index: 2}]
  end
end
