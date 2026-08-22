defmodule Runic.Workflow.CompositeConnectionBoundaryTest do
  use ExUnit.Case, async: true

  require Runic

  alias Runic.Workflow

  alias Runic.Workflow.{
    ComponentAdded,
    Connection,
    Definition,
    InputBinding,
    Join,
    Root
  }

  describe "durable nested workflow boundaries" do
    test "round-trips a named input binding without flattening the child build log" do
      source = Runic.step(fn input -> input + 1 end, name: :source)
      inner = Runic.step(fn value -> value * 10 end, name: :inner)

      child =
        Workflow.new(
          name: :child,
          input_ports: [in: [type: :integer]],
          output_ports: [out: [type: :integer, from: :inner]]
        )
        |> Workflow.add(inner)

      {parent, source_events} =
        Workflow.add_with_events(Workflow.new(name: :parent), source)

      {original, child_events} =
        Workflow.add_with_events(parent, child,
          connections: [[id: :child_input, from: {:source, :out}, to: :in]]
        )

      assert Workflow.build_log(original) == source_events ++ child_events

      serialized_log =
        original
        |> Workflow.build_log()
        |> :erlang.term_to_binary()
        |> :erlang.binary_to_term()

      assert [
               %ComponentAdded{name: :source},
               %ComponentAdded{
                 name: :child,
                 source: nil,
                 connections: [
                   %Connection{id: :child_input, target: :child, target_port: :in}
                 ],
                 workflow_definition: %Definition{
                   version: 1,
                   name: :child,
                   input_ports: [in: [type: :integer]],
                   output_ports: [out: [type: :integer, from: :inner]],
                   build_log: [%ComponentAdded{name: :inner}]
                 }
               }
             ] = serialized_log

      rebuilt = Workflow.from_log(serialized_log)

      assert component_inventory(original) == component_inventory(rebuilt)
      assert flow_inventory(original) == flow_inventory(rebuilt)

      for candidate <- [original, rebuilt] do
        assert %Workflow{
                 name: :child,
                 input_ports: [in: [type: :integer]],
                 output_ports: [out: [type: :integer, from: :inner]]
               } = Workflow.get_component(candidate, :child)

        assert candidate
               |> Workflow.react_until_satisfied(5)
               |> Workflow.results([:child, :inner]) == %{child: 60, inner: 60}

        assert Enum.count(
                 Multigraph.vertices(Workflow.flow_graph(candidate)),
                 &match?(%InputBinding{}, &1)
               ) == 1
      end
    end

    test "retains whole-value child workflow connections across replay" do
      source = Runic.step(fn input -> input + 1 end, name: :source)
      inner = Runic.step(fn value -> value * 10 end, name: :inner)

      child =
        Workflow.new(
          name: :child,
          input_ports: [in: [type: :any]],
          output_ports: [out: [type: :any, from: :inner]]
        )
        |> Workflow.add(inner)

      original =
        Workflow.new(name: :parent)
        |> Workflow.add(source)
        |> Workflow.add(child, to: :source)

      rebuilt = original |> Workflow.build_log() |> Workflow.from_log()

      assert component_inventory(original) == component_inventory(rebuilt)
      assert flow_inventory(original) == flow_inventory(rebuilt)

      for candidate <- [original, rebuilt] do
        assert %Workflow{name: :child} = Workflow.get_component(candidate, :child)

        assert candidate
               |> Workflow.react_until_satisfied(5)
               |> Workflow.raw_productions(:inner) == [60]
      end
    end

    test "routes a declared child output without exposing the downstream binder as child output" do
      inner =
        Runic.step(
          fn value -> %{out: value * 10, mirrored: value * 10} end,
          name: :inner
        )

      consumer = Runic.step(fn value -> value + 1 end, name: :consumer)

      child =
        Workflow.new(
          name: :child,
          input_ports: [in: [type: :integer]],
          output_ports: [
            out: [type: :integer, from: :inner],
            mirrored: [type: :integer, from: :inner]
          ]
        )
        |> Workflow.add(inner)

      original =
        Workflow.new(name: :parent)
        |> Workflow.add(child)
        |> Workflow.add(consumer, connections: [[from: {:child, :out}, to: :in]])

      rebuilt = original |> Workflow.build_log() |> Workflow.from_log()

      assert component_inventory(original) == component_inventory(rebuilt)
      assert flow_inventory(original) == flow_inventory(rebuilt)

      for candidate <- [original, rebuilt] do
        executed = Workflow.react_until_satisfied(candidate, 5)

        assert Workflow.results(executed, [:child, :inner, :consumer]) == %{
                 child: %{out: 50, mirrored: 50},
                 inner: %{out: 50, mirrored: 50},
                 consumer: 51
               }

        assert Workflow.raw_productions(executed, :child) == [%{out: 50, mirrored: 50}]

        assert [
                 %{
                   properties: %{
                     kind: :output,
                     ports: [:out, :mirrored],
                     sources: [:inner, :inner]
                   }
                 }
               ] =
                 Multigraph.out_edges(candidate.graph, Workflow.get_component(candidate, :child),
                   by: :component_of
                 )

        assert Enum.count(
                 Multigraph.vertices(Workflow.flow_graph(candidate)),
                 &match?(%InputBinding{}, &1)
               ) == 1
      end
    end

    test "rejects unsupported nested definition versions" do
      inner = Runic.step(fn value -> value end, name: :inner)
      child = Workflow.new(name: :child) |> Workflow.add(inner)
      definition = Definition.from_workflow(child)

      assert_raise ArgumentError, "unsupported nested workflow definition version: 2", fn ->
        Definition.rebuild(%{definition | version: 2})
      end
    end
  end

  describe "stateful and coordinated composite boundaries" do
    test "binds into an Accumulator and preserves replayed state production" do
      source = Runic.step(fn input -> input + 1 end, name: :source)

      accumulator =
        Runic.accumulator(0, fn value, state -> value + state end,
          name: :counter,
          inputs: [in: [type: :integer]],
          outputs: [state: [type: :integer]]
        )

      assert_replayed_output(
        Workflow.new(name: :accumulator_parent)
        |> Workflow.add(source)
        |> Workflow.add(accumulator, connections: [[from: {:source, :out}, to: :in]]),
        5,
        :counter,
        [0, 6]
      )
    end

    test "binds into a StateMachine and preserves replayed state transitions" do
      source = Runic.step(fn input -> input + 1 end, name: :source)

      state_machine =
        Runic.state_machine(
          name: :counter,
          init: 0,
          reducer: fn value, state -> value + state end,
          inputs: [event: [type: :integer]],
          outputs: [state: [type: :integer]]
        )

      assert_replayed_output(
        Workflow.new(name: :state_machine_parent)
        |> Workflow.add(source)
        |> Workflow.add(state_machine,
          connections: [[from: {:source, :out}, to: :event]]
        ),
        5,
        :counter,
        [0, 6]
      )
    end

    test "binds into a map-linked Reduce and preserves fan-in coordination" do
      source = Runic.step(fn _input -> [1, 2, 3] end, name: :source)
      map = Runic.map(fn value -> value * 2 end, name: :double)
      reduce = Runic.reduce(0, fn value, acc -> value + acc end, name: :sum, map: :double)

      original =
        Workflow.new(name: :map_reduce_parent)
        |> Workflow.add(source)
        |> Workflow.add(map, connections: [[from: {:source, :out}, to: :items]])
        |> Workflow.add(reduce, to: :double)

      rebuilt = original |> Workflow.build_log() |> Workflow.from_log()

      assert component_inventory(original) == component_inventory(rebuilt)
      assert flow_inventory(original) == flow_inventory(rebuilt)

      for candidate <- [original, rebuilt] do
        assert candidate
               |> Workflow.react_until_satisfied(:start)
               |> Workflow.raw_productions(:sum) == [12]

        assert Enum.count(Multigraph.edges(candidate.graph, by: :fan_in)) == 1
      end
    end
  end

  defp assert_replayed_output(original, input, component_name, expected) do
    rebuilt = original |> Workflow.build_log() |> Workflow.from_log()

    assert component_inventory(original) == component_inventory(rebuilt)
    assert flow_inventory(original) == flow_inventory(rebuilt)

    for candidate <- [original, rebuilt] do
      actual =
        candidate
        |> Workflow.react_until_satisfied(input)
        |> Workflow.raw_productions(component_name)
        |> Enum.sort()

      assert actual == expected
    end
  end

  defp component_inventory(workflow) do
    workflow
    |> Workflow.component_graph()
    |> Multigraph.edges()
    |> Enum.map(fn edge ->
      connections =
        edge.properties
        |> Map.get(:connections, [])
        |> Enum.map(&Map.from_struct/1)

      {
        node_identity(workflow, edge.v1),
        node_identity(workflow, edge.v2),
        edge.label,
        connections
      }
    end)
    |> Enum.sort()
  end

  defp flow_inventory(workflow) do
    workflow
    |> Workflow.flow_graph()
    |> Multigraph.edges()
    |> Enum.map(fn edge ->
      {node_identity(workflow, edge.v1), node_identity(workflow, edge.v2), edge.label}
    end)
    |> Enum.sort()
  end

  defp node_identity(_workflow, %Root{}), do: :root
  defp node_identity(_workflow, %Join{joins: joins}), do: {:join, joins}

  defp node_identity(_workflow, %InputBinding{} = binding) do
    {:input_binding, binding.target_component_hash, binding.source_order, binding.bindings}
  end

  defp node_identity(workflow, node) do
    owner =
      workflow.graph
      |> Multigraph.in_edges(node, by: :component_of)
      |> Enum.find(fn edge -> edge.v1 != node end)

    case owner do
      %{v1: %{name: owner_name}, properties: %{kind: kind}} ->
        {:owned, owner_name, kind}

      _ ->
        intrinsic_node_identity(node)
    end
  end

  defp intrinsic_node_identity(%{__struct__: module, name: name}) when not is_nil(name),
    do: {module, name}

  defp intrinsic_node_identity(%{__struct__: module, hash: hash}), do: {module, hash}
end
