defmodule Runic.Workflow.GroupedReplayTest do
  use ExUnit.Case, async: true

  require Runic

  alias Runic.Workflow
  alias Runic.Workflow.{ComponentAdded, Join, Root}

  describe "grouped component replay" do
    test "preserves one multi-parent construction decision and its logical and compiled graphs" do
      original = grouped_workflow()
      build_log = Workflow.build_log(original)
      serialized_log = build_log |> :erlang.term_to_binary() |> :erlang.binary_to_term()

      assert %ComponentAdded{name: :sum, to: [:a, :b]} = List.last(serialized_log)

      rebuilt = Workflow.from_log(serialized_log)

      assert edge_inventory(original, :connects_to) == edge_inventory(rebuilt, :connects_to)
      assert edge_inventory(original, :flow) == edge_inventory(rebuilt, :flow)

      for workflow <- [original, rebuilt] do
        assert Enum.count(Multigraph.vertices(workflow.graph), &match?(%Join{}, &1)) == 1

        assert workflow
               |> Workflow.react_until_satisfied(5)
               |> Workflow.raw_productions(:sum) == [16]
      end
    end

    test "add_with_events emits one grouped event and rebuilds through the Join path" do
      a = Runic.step(fn value -> value + 1 end, name: :a)
      b = Runic.step(fn value -> value * 2 end, name: :b)
      sum = Runic.step(fn left, right -> left + right end, name: :sum)

      {workflow, events_a} = Workflow.add_with_events(Workflow.new(), a)
      {workflow, events_b} = Workflow.add_with_events(workflow, b)
      {original, events_sum} = Workflow.add_with_events(workflow, sum, to: [:a, :b])

      assert [%ComponentAdded{name: :sum, to: [:a, :b]}] = events_sum

      rebuilt = Workflow.apply_events(Workflow.new(), events_a ++ events_b ++ events_sum)

      assert edge_inventory(original, :connects_to) == edge_inventory(rebuilt, :connects_to)
      assert edge_inventory(original, :flow) == edge_inventory(rebuilt, :flow)

      assert rebuilt
             |> Workflow.react_until_satisfied(5)
             |> Workflow.raw_productions(:sum) == [16]
    end

    test "coalesces consecutive legacy events for the same component identity" do
      workflow = grouped_workflow()
      [a_event, b_event, %ComponentAdded{} = grouped_sum] = Workflow.build_log(workflow)

      legacy_events = [
        a_event,
        b_event,
        %ComponentAdded{grouped_sum | to: :a},
        %ComponentAdded{grouped_sum | to: :b}
      ]

      rebuilt = Workflow.from_log(legacy_events)

      assert Enum.count(Multigraph.vertices(rebuilt.graph), &match?(%Join{}, &1)) == 1

      assert rebuilt
             |> Workflow.react_until_satisfied(5)
             |> Workflow.raw_productions(:sum) == [16]
    end

    test "keeps a legacy single-parent event compatible" do
      parent = Runic.step(fn value -> value + 1 end, name: :parent)
      child = Runic.step(fn value -> value * 2 end, name: :child)

      workflow = Workflow.new() |> Workflow.add(parent) |> Workflow.add(child, to: :parent)
      [parent_event, %ComponentAdded{} = child_event] = Workflow.build_log(workflow)

      assert child_event.to == :parent

      rebuilt = Workflow.from_log([parent_event, child_event])

      assert rebuilt
             |> Workflow.react_until_satisfied(5)
             |> Workflow.raw_productions(:child) == [12]
    end
  end

  defp grouped_workflow do
    a = Runic.step(fn value -> value + 1 end, name: :a)
    b = Runic.step(fn value -> value * 2 end, name: :b)
    sum = Runic.step(fn left, right -> left + right end, name: :sum)

    Workflow.new()
    |> Workflow.add(a)
    |> Workflow.add(b)
    |> Workflow.add(sum, to: [:a, :b])
  end

  defp edge_inventory(workflow, label) do
    workflow.graph
    |> Multigraph.edges(by: label)
    |> Enum.map(fn edge -> {node_identity(edge.v1), node_identity(edge.v2), edge.label} end)
    |> Enum.sort()
  end

  defp node_identity(%Root{}), do: :root
  defp node_identity(%Join{joins: joins}), do: {:join, joins}
  defp node_identity(%{name: name}) when not is_nil(name), do: {:component, name}
  defp node_identity(%{hash: hash}), do: {:node, hash}
end
