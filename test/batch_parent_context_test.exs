defmodule Runic.Workflow.BatchParentContextTest do
  use ExUnit.Case, async: true

  alias Runic.Workflow
  alias Runic.Workflow.Batch
  alias Runic.TestSupport.{CoordinateComponent, OrdinaryComponent}

  test "the parent option requires a boolean" do
    assert_raise ArgumentError, ":batch_parent must be a boolean", fn ->
      Code.compile_quoted(
        quote do
          defmodule Runic.TestSupport.InvalidBatchParent do
            use Runic.Workflow.SingleOutput, batch_parent: :all
          end
        end
      )
    end
  end

  test "a component can keep coordinates without copying the shared parent" do
    small = prepare(%{padding: []})
    large = prepare(%{padding: Enum.to_list(1..10_000)})

    for runnable <- small ++ large do
      batch = runnable.context.batch
      refute Map.has_key?(batch, :parent)
      assert batch.index in [0, 1]
      assert batch.item_id == runnable.input_fact.hash
      assert runnable.context.fan_out_context.fan_out_fact_hash == batch.item_id
    end

    assert :erlang.external_size(small) == :erlang.external_size(large)
    assert :erts_debug.flat_size(small) == :erts_debug.flat_size(large)
  end

  test "omitting the callback parent preserves ordered results, parent data, and replay" do
    batch = Runic.batch(CoordinateComponent.new(:item), name: :batch)

    definition =
      Workflow.new()
      |> Workflow.add(batch)
      |> Workflow.add(OrdinaryComponent.new(:output, :data), to: :batch)

    rebuilt = definition |> Workflow.build_log() |> Workflow.from_log()
    parent = %{padding: Enum.to_list(1..100)}

    for items <- [[], [4], [4, 4, 2]] do
      workflow = Workflow.enable_event_emission(rebuilt)
      {completed, observation} = Workflow.execute(workflow, Batch.input(items, parent))
      assert observation.quiescent?

      assert [%Batch.Result{parent: ^parent, outcomes: outcomes} = result] =
               Workflow.raw_productions(completed, :output)

      assert Enum.map(outcomes, & &1.value) ==
               Enum.with_index(items, fn value, index -> %{value: value, index: index} end)

      replayed =
        Workflow.from_events(
          Workflow.build_log(completed) ++ Enum.reverse(completed.uncommitted_events)
        )

      assert Workflow.raw_productions(replayed, :output) == [result]
      refute Workflow.is_runnable?(replayed)
    end
  end

  defp prepare(parent) do
    workflow =
      Workflow.new()
      |> Workflow.add(Runic.batch(CoordinateComponent.new(:item), name: :batch))
      |> Workflow.plan_eagerly(Batch.input([1, 2], parent))
      |> Workflow.react()

    {_, runnables} = Workflow.prepare_for_dispatch(workflow)
    Enum.sort_by(runnables, & &1.context.batch.index)
  end
end
