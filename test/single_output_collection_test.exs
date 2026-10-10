defmodule Runic.Workflow.SingleOutputCollectionTest do
  use ExUnit.Case, async: true

  require Runic
  alias Runic.TestSupport.OrdinaryComponent, as: Custom
  alias Runic.Workflow
  alias Runic.Workflow.{FanIn, FanOut}

  test "custom composite topology tracks ordinary outputs without a mapped-path convention" do
    node = Custom.new(:item, :add, 10)
    workflow = collection(node)
    assert workflow.mapped.mapped_paths == MapSet.new()
    completed = Workflow.react_until_satisfied(workflow, [1, 1, 2], async: true)
    assert Workflow.raw_productions(completed, :total) == [[11, 11, 12]]
    refute Workflow.is_runnable?(completed)
  end

  test "an intervening ordinary node does not lose collection lineage" do
    first = Custom.new(:first, :add, 1)
    last = Custom.new(:item, :add, 10)
    workflow = collection(last, first)
    completed = Workflow.react_until_satisfied(workflow, [1, 2], async: true)
    assert Workflow.raw_productions(completed, :total) == [[12, 13]]
  end

  test "fallback values participate in the same collection completion" do
    for node <- [
          Custom.new(:item, :failure, :unavailable),
          Runic.step(fn _ -> raise "unavailable" end, name: :item)
        ] do
      workflow = collection(node)

      completed =
        Workflow.react_until_satisfied(workflow, [1, 2],
          scheduler_policies: [{:item, %{fallback: fn _, _ -> {:value, 7} end}}]
        )

      assert Workflow.raw_productions(completed, :total) == [[7, 7]]
    end
  end

  test "plain mapped Steps retain native tracking" do
    workflow =
      Workflow.new()
      |> Workflow.add(Runic.map(fn value -> value * 2 end, name: :double))
      |> Workflow.add(Runic.reduce(0, fn value, total -> total + value end, name: :sum),
        to: :double
      )
      |> Workflow.react_until_satisfied([1, 1, 2])

    assert Workflow.raw_productions(workflow, :sum) == [8]
  end

  test "an uncollected branch does not retain unused tracking" do
    fan_out = fan_out()
    node = Custom.new(:uncollected, :data)
    workflow = Workflow.new() |> Workflow.add_step(fan_out) |> Workflow.add(node, to: fan_out)
    completed = Workflow.react_until_satisfied(workflow, [1, 2])

    refute Enum.any?(completed.mapped, fn
             {{_source, hash}, _} -> hash == node.hash
             _ -> false
           end)
  end

  test "collection preparation follows lightweight ancestor references without loading payloads" do
    first = Custom.new(:first, :add, 1)
    last = Custom.new(:item, :add, 10)

    workflow =
      collection(last, first)
      |> Workflow.react(Workflow.Fact.new(value: [1, 2]))
      |> Workflow.react()

    fan_out_hash = fan_out().hash

    ancestors =
      Workflow.facts(workflow)
      |> Enum.filter(fn fact ->
        match?({^fan_out_hash, _}, fact.ancestry)
      end)

    assert length(ancestors) == 2

    graph =
      Enum.reduce(ancestors, workflow.graph, fn fact, graph ->
        ref =
          struct(
            Workflow.FactRef,
            Map.take(Map.from_struct(fact), Map.keys(Map.from_struct(%Workflow.FactRef{})))
          )

        %{graph | vertices: Map.put(graph.vertices, fact.hash, ref)}
      end)

    completed = %{workflow | graph: graph} |> Workflow.react_until_satisfied()
    assert Workflow.raw_productions(completed, :total) == [[12, 13]]
  end

  defp collection(node, intermediate \\ nil) do
    fan_out = fan_out()

    collector = %FanIn{
      hash: Runic.Identity.digest(:component_definition, :ordinary_collector),
      name: :collector,
      init: fn -> [] end,
      reducer: fn value, acc -> acc ++ [value] end
    }

    workflow = Workflow.new() |> Workflow.add_step(fan_out)

    workflow =
      if intermediate do
        workflow
        |> Workflow.add(intermediate, to: fan_out)
        |> Workflow.add(node, to: intermediate)
      else
        Workflow.add(workflow, node, to: fan_out)
      end

    workflow
    |> Workflow.add_step(node, collector)
    |> Workflow.draw_connection(fan_out, collector, :fan_in)
    |> Workflow.add(Custom.new(:total, :data), to: collector)
  end

  defp fan_out do
    %FanOut{hash: Runic.Identity.digest(:component_definition, :ordinary_fan_out), name: :fan_out}
  end
end
