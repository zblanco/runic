defmodule Runic.Workflow.NamedConnectionTest do
  use ExUnit.Case, async: true

  require Runic

  alias Runic.Workflow

  alias Runic.Workflow.{
    ComponentAdded,
    CallContract,
    Connection,
    Fact,
    InputBinding,
    Invocation,
    Invokable,
    Join,
    Root
  }

  describe "named connection lowering" do
    test "selects a safe path from one named output into one named input" do
      producer =
        Runic.step(fn input -> %{score: input + 2} end,
          name: :producer,
          outputs: [payload: [type: :any]]
        )

      consumer =
        Runic.step(fn score -> score * 3 end,
          name: :consumer,
          inputs: [score: [type: :any]]
        )

      workflow =
        Workflow.new()
        |> Workflow.add(producer)
        |> Workflow.add(consumer,
          connections: [
            [
              id: "score-binding",
              from: {:producer, :payload},
              to: :score,
              selector: [:score]
            ]
          ]
        )

      executed = Workflow.react_until_satisfied(workflow, 5)

      assert Workflow.raw_productions(executed, :consumer) == [21]

      refute Enum.any?(Multigraph.vertices(workflow.graph), &match?(%Join{}, &1))

      assert [
               %{
                 properties: %{
                   kind: :port_binding,
                   connections: [%Connection{id: "score-binding"}]
                 }
               }
             ] =
               Multigraph.edges(workflow.graph, by: :connects_to)

      assert [%{v2: %InputBinding{} = binding, properties: %{kind: :input_binding}}] =
               Multigraph.out_edges(workflow.graph, consumer, by: :compiled_for)

      assert [%{v2: %Fact{} = bound_fact}] =
               Multigraph.out_edges(executed.graph, binding, by: :produced)

      assert {:ok, runnable} = Invokable.prepare(consumer, executed, bound_fact)

      invocation =
        Invocation.materialize(runnable.invocation, bound_fact.value, runnable.context)

      assert [
               %{
                 id: "score-binding",
                 source_port: :payload,
                 target_port: :score,
                 selector: [:score]
               }
             ] = invocation.bindings.sources
    end

    test "assembles multiple sources in target port order, independent of declaration order" do
      workflow = positional_sum_workflow()
      workflow = Workflow.put_run_context(workflow, %{_global: %{request_id: "request-1"}})

      assert Enum.count(Multigraph.vertices(workflow.graph), &match?(%Join{}, &1)) == 1

      assert workflow
             |> Workflow.react_until_satisfied(5)
             |> Workflow.raw_productions(:sum) == [16]
    end

    test "projects a named port from a multi-output domain value" do
      producer =
        Runic.step(fn input -> %{left: input + 1, right: input * 4} end,
          name: :producer,
          outputs: [left: [type: :integer], right: [type: :integer]]
        )

      consumer =
        Runic.step(fn value -> value + 3 end,
          name: :consumer,
          inputs: [value: [type: :integer]]
        )

      workflow =
        Workflow.new()
        |> Workflow.add(producer)
        |> Workflow.add(consumer,
          connections: [[from: {:producer, :right}, to: :value]]
        )

      assert workflow
             |> Workflow.react_until_satisfied(5)
             |> Workflow.raw_productions(:consumer) == [23]
    end

    test "routes multiple ports from one source without introducing a Join" do
      producer =
        Runic.step(fn input -> %{left: input + 1, right: input * 2} end,
          name: :producer,
          outputs: [left: [type: :integer], right: [type: :integer]]
        )

      consumer =
        Runic.step(fn left, right -> left + right end,
          name: :consumer,
          inputs: [left: [type: :integer], right: [type: :integer]]
        )

      workflow =
        Workflow.new()
        |> Workflow.add(producer)
        |> Workflow.add(consumer,
          connections: [
            [from: {:producer, :left}, to: :left],
            [from: {:producer, :right}, to: :right]
          ]
        )

      refute Enum.any?(Multigraph.vertices(workflow.graph), &match?(%Join{}, &1))

      assert [%{properties: %{connections: connections}}] =
               Multigraph.edges(workflow.graph, by: :connects_to)

      assert length(connections) == 2

      assert workflow
             |> Workflow.react_until_satisfied(5)
             |> Workflow.raw_productions(:consumer) == [16]
    end

    test "assembles distinct target paths without executable edge code" do
      customer =
        Runic.step(fn input -> input + 10 end,
          name: :customer,
          outputs: [id: [type: :integer]]
        )

      item =
        Runic.step(fn input -> "item-#{input}" end,
          name: :item,
          outputs: [name: [type: :string]]
        )

      consumer =
        Runic.step(fn payload -> payload end,
          name: :consumer,
          inputs: [payload: [type: :any]]
        )

      workflow =
        Workflow.new()
        |> Workflow.add(customer)
        |> Workflow.add(item)
        |> Workflow.add(consumer,
          connections: [
            [from: {:customer, :id}, to: :payload, target_path: [:customer, :id]],
            [from: {:item, :name}, to: :payload, target_path: [:items, 0, :name]]
          ]
        )

      assert workflow
             |> Workflow.react_until_satisfied(5)
             |> Workflow.raw_productions(:consumer) == [
               %{customer: %{id: 15}, items: [%{name: "item-5"}]}
             ]
    end
  end

  describe "durability and graph projections" do
    test "add_with_events emits replayable normalized connection data" do
      producer =
        Runic.step(fn input -> input + 1 end,
          name: :producer,
          outputs: [value: [type: :integer]]
        )

      consumer =
        Runic.step(fn input -> input * 2 end,
          name: :consumer,
          inputs: [value: [type: :integer]]
        )

      {workflow, producer_events} = Workflow.add_with_events(Workflow.new(), producer)

      {original, consumer_events} =
        Workflow.add_with_events(workflow, consumer,
          connections: [[from: {:producer, :value}, to: :value]]
        )

      assert [
               %ComponentAdded{
                 to: nil,
                 connections: [
                   %Connection{source: :producer, target: :consumer, target_port: :value}
                 ]
               }
             ] = consumer_events

      rebuilt = Workflow.apply_events(Workflow.new(), producer_events ++ consumer_events)

      for workflow <- [original, rebuilt] do
        assert workflow
               |> Workflow.react_until_satisfied(5)
               |> Workflow.raw_productions(:consumer) == [12]
      end
    end

    test "replay preserves port contracts applied after component construction" do
      producer =
        Runic.step(fn input -> input + 1 end, name: :producer)
        |> Map.put(:outputs, value: [type: :integer])

      consumer =
        Runic.step(fn input -> input * 2 end, name: :consumer)
        |> Map.put(:inputs, value: [type: :integer])

      original =
        Workflow.new()
        |> Workflow.add(producer)
        |> Workflow.add(consumer,
          connections: [[from: {:producer, :value}, to: :value]]
        )

      [producer_event, consumer_event] = Workflow.build_log(original)
      assert producer_event.output_ports == [value: [type: :integer]]
      assert consumer_event.input_ports == [value: [type: :integer]]

      rebuilt = original |> Workflow.build_log() |> Workflow.from_log()

      for workflow <- [original, rebuilt] do
        assert workflow
               |> Workflow.react_until_satisfied(5)
               |> Workflow.raw_productions(:consumer) == [12]
      end
    end

    test "round-trips deterministic connection data and equivalent lowering" do
      original = positional_sum_workflow()

      log =
        original |> Workflow.build_log() |> :erlang.term_to_binary() |> :erlang.binary_to_term()

      assert %ComponentAdded{connections: [%Connection{}, %Connection{}]} = List.last(log)

      rebuilt = Workflow.from_log(log)

      assert logical_inventory(original) == logical_inventory(rebuilt)
      assert flow_inventory(original) == flow_inventory(rebuilt)

      for workflow <- [original, rebuilt] do
        assert workflow
               |> Workflow.react_until_satisfied(5)
               |> Workflow.raw_productions(:sum) == [16]

        assert Workflow.raw_productions_by_component(workflow).sum == []
      end
    end

    test "component graph retains connection properties while flow graph retains lowering" do
      workflow = positional_sum_workflow()
      component_graph = Workflow.component_graph(workflow)
      flow_graph = Workflow.flow_graph(workflow)

      assert Enum.count(Multigraph.edges(component_graph, by: :connects_to)) == 2

      assert Enum.all?(Multigraph.edges(component_graph), fn edge ->
               match?(%{connections: [%Connection{}]}, edge.properties)
             end)

      assert Enum.empty?(Multigraph.edges(component_graph, by: :flow))
      assert Enum.empty?(Multigraph.edges(flow_graph, by: :connects_to))
      assert Enum.count(Multigraph.vertices(flow_graph), &match?(%InputBinding{}, &1)) == 1
      assert Enum.count(Multigraph.vertices(flow_graph), &match?(%Join{}, &1)) == 1
    end

    test "serializers expose the binding as compiled topology without making it a component" do
      workflow = positional_sum_workflow()

      assert Workflow.to_mermaid(workflow) =~ "InputBinding"
      assert Workflow.to_dot(workflow) =~ "InputBinding"

      assert Enum.any?(Workflow.to_cytoscape(workflow), fn
               %{data: %{kind: "inputbinding"}} -> true
               _ -> false
             end)

      refute Map.has_key?(Workflow.components(workflow), :input_binding)

      ran = Workflow.react_until_satisfied(workflow, 5)
      assert Workflow.raw_productions(ran, :sum) == [16]
      assert Workflow.raw_productions_by_component(ran).sum == [16]
    end
  end

  describe "group validation and invocation semantics" do
    test "validates each named source-target pair" do
      producer =
        Runic.step(fn input -> input end,
          name: :producer,
          outputs: [number: [type: :integer]]
        )

      consumer =
        Runic.step(fn input -> input end,
          name: :consumer,
          inputs: [text: [type: :string]]
        )

      workflow = Workflow.new() |> Workflow.add(producer)

      assert_raise Runic.IncompatiblePortError, fn ->
        Workflow.add(workflow, consumer, connections: [[from: {:producer, :number}, to: :text]])
      end
    end

    test "requires every required target port exactly once" do
      producer = Runic.step(fn input -> input end, name: :producer)

      consumer =
        Runic.step(fn left, right -> {left, right} end,
          name: :consumer,
          inputs: [left: [type: :any], right: [type: :any]]
        )

      workflow = Workflow.new() |> Workflow.add(producer)

      assert_raise ArgumentError, ~r/unassigned required input ports: \[:right\]/, fn ->
        Workflow.add(workflow, consumer, connections: [[from: {:producer, :out}, to: :left]])
      end
    end

    test "rejects overlapping target paths" do
      first = Runic.step(fn input -> input end, name: :first)
      second = Runic.step(fn input -> input end, name: :second)
      consumer = Runic.step(fn input -> input end, name: :consumer)

      workflow = Workflow.new() |> Workflow.add(first) |> Workflow.add(second)

      assert_raise ArgumentError, ~r/overlapping assignments/, fn ->
        Workflow.add(workflow, consumer,
          connections: [
            [from: {:first, :out}, to: :in, target_path: [:value]],
            [from: {:second, :out}, to: :in, target_path: [:value, :nested]]
          ]
        )
      end
    end

    test "compiles bound multi-input steps as positional without a user invocation option" do
      left = Runic.step(fn input -> input end, name: :left)
      right = Runic.step(fn input -> input end, name: :right)

      sum =
        Runic.step(fn left, right -> left + right end,
          name: :sum,
          inputs: [left: [type: :any], right: [type: :any]]
        )

      workflow =
        Workflow.new()
        |> Workflow.add(left)
        |> Workflow.add(right)
        |> Workflow.add(sum,
          connections: [
            [from: {:left, :out}, to: :left],
            [from: {:right, :out}, to: :right]
          ]
        )
        |> Workflow.put_run_context(%{_global: %{request_id: "request-1"}})

      refute Map.has_key?(sum, :invocation)
      assert %CallContract{style: :positional, input_order: [:left, :right]} = sum.call_contract

      assert workflow
             |> Workflow.react_until_satisfied(5)
             |> Workflow.raw_productions(:sum) == [10]
    end

    test "context/1 compiles input-and-context calling without a user invocation option" do
      producer = Runic.step(fn input -> input + 1 end, name: :producer)

      consumer =
        Runic.step(fn input -> input + context(:offset) end, name: :consumer)

      assert %CallContract{style: :input_and_context, input_order: [:in]} =
               consumer.call_contract

      workflow =
        Workflow.new()
        |> Workflow.add(producer)
        |> Workflow.add(consumer,
          connections: [[from: {:producer, :out}, to: :in]]
        )
        |> Workflow.put_run_context(%{consumer: %{offset: 10}})

      rebuilt =
        workflow
        |> Workflow.build_log()
        |> Workflow.from_log()
        |> Workflow.put_run_context(%{consumer: %{offset: 10}})

      for candidate <- [workflow, rebuilt] do
        assert candidate
               |> Workflow.react_until_satisfied(5)
               |> Workflow.raw_productions(:consumer) == [16]
      end
    end

    test "selector failures retain precise connection evidence on the runnable" do
      producer = Runic.step(fn input -> %{value: input} end, name: :producer)
      consumer = Runic.step(fn input -> input end, name: :consumer)

      workflow =
        Workflow.new()
        |> Workflow.add(producer)
        |> Workflow.add(consumer,
          connections: [
            [from: {:producer, :out}, to: :in, selector: [:missing]]
          ]
        )

      binding = Enum.find(Multigraph.vertices(workflow.graph), &match?(%InputBinding{}, &1))
      fact = Fact.new(value: %{value: 5})
      {:ok, runnable} = Invokable.prepare(binding, workflow, fact)
      executed = Invokable.execute(binding, runnable)

      assert %{status: :failed, error: %Runic.InputBindingError{message: message}} = executed
      assert message =~ ":missing"
    end
  end

  describe "composite component boundaries" do
    test "binds into a Rule condition entry" do
      producer = Runic.step(fn input -> input + 1 end, name: :producer)
      rule = Runic.rule(fn value when value > 5 -> {:large, value} end, name: :gate)

      workflow =
        Workflow.new()
        |> Workflow.add(producer)
        |> Workflow.add(rule,
          connections: [[from: {:producer, :out}, to: :in]]
        )

      for candidate <- [workflow, workflow |> Workflow.build_log() |> Workflow.from_log()] do
        assert candidate
               |> Workflow.react_until_satisfied(5)
               |> Workflow.raw_productions(:gate) == [{:large, 6}]
      end
    end

    test "binds into a Map fan-out entry" do
      producer = Runic.step(fn _input -> [1, 2, 3] end, name: :producer)
      map = Runic.map(fn value -> value * 2 end, name: :mapped)

      workflow =
        Workflow.new()
        |> Workflow.add(producer)
        |> Workflow.add(map,
          connections: [[from: {:producer, :out}, to: :items]]
        )

      for candidate <- [workflow, workflow |> Workflow.build_log() |> Workflow.from_log()] do
        assert candidate
               |> Workflow.react_until_satisfied(:start)
               |> Workflow.raw_productions(:mapped)
               |> Enum.sort() == [2, 4, 6]
      end
    end

    test "binds from a Rule reaction exit" do
      rule = Runic.rule(fn value when value > 5 -> {:large, value} end, name: :gate)
      consumer = Runic.step(fn {:large, value} -> value * 10 end, name: :consumer)

      workflow =
        Workflow.new()
        |> Workflow.add(rule)
        |> Workflow.add(consumer,
          connections: [[from: {:gate, :out}, to: :in]]
        )

      assert workflow
             |> Workflow.react_until_satisfied(6)
             |> Workflow.raw_productions(:consumer) == [60]
    end

    test "binds from a Map leaf exit" do
      map = Runic.map(fn value -> value * 2 end, name: :mapped)
      consumer = Runic.step(fn value -> value + 1 end, name: :consumer)

      workflow =
        Workflow.new()
        |> Workflow.add(map)
        |> Workflow.add(consumer,
          connections: [[from: {:mapped, :out}, to: :in]]
        )

      assert workflow
             |> Workflow.react_until_satisfied([1, 2])
             |> Workflow.raw_productions(:consumer)
             |> Enum.sort() == [3, 5]
    end

    test "binds through Reduce fan-in entry and exit nodes" do
      producer = Runic.step(fn _input -> [1, 2, 3] end, name: :producer)
      reduce = Runic.reduce(0, fn value, acc -> value + acc end, name: :sum)
      consumer = Runic.step(fn value -> value * 10 end, name: :consumer)

      workflow =
        Workflow.new()
        |> Workflow.add(producer)
        |> Workflow.add(reduce,
          connections: [[from: {:producer, :out}, to: :items]]
        )
        |> Workflow.add(consumer,
          connections: [[from: {:sum, :result}, to: :in]]
        )

      for candidate <- [workflow, workflow |> Workflow.build_log() |> Workflow.from_log()] do
        assert candidate
               |> Workflow.react_until_satisfied(:start)
               |> Workflow.raw_productions(:consumer) == [60]
      end
    end
  end

  defp positional_sum_workflow do
    left =
      Runic.step(fn input -> input + 1 end,
        name: :left,
        outputs: [value: [type: :integer]]
      )

    right =
      Runic.step(fn input -> input * 2 end,
        name: :right,
        outputs: [value: [type: :integer]]
      )

    sum =
      Runic.step(fn left_value, right_value -> left_value + right_value end,
        name: :sum,
        inputs: [left: [type: :integer], right: [type: :integer]]
      )

    Workflow.new()
    |> Workflow.add(left)
    |> Workflow.add(right)
    |> Workflow.add(sum,
      connections: [
        [from: {:right, :value}, to: :right],
        [from: {:left, :value}, to: :left]
      ]
    )
  end

  defp logical_inventory(workflow) do
    workflow
    |> Workflow.component_graph()
    |> Multigraph.edges()
    |> Enum.map(fn edge ->
      {edge.v1.name, edge.v2.name, Enum.map(edge.properties.connections, &Map.from_struct/1)}
    end)
    |> Enum.sort()
  end

  defp flow_inventory(workflow) do
    workflow
    |> Workflow.flow_graph()
    |> Multigraph.edges()
    |> Enum.map(fn edge -> {node_identity(edge.v1), node_identity(edge.v2), edge.label} end)
    |> Enum.sort()
  end

  defp node_identity(%Join{joins: joins}), do: {:join, joins}
  defp node_identity(%InputBinding{bindings: bindings}), do: {:binding, bindings}
  defp node_identity(%Root{}), do: :root
  defp node_identity(%{name: name}) when not is_nil(name), do: {:component, name}
  defp node_identity(%{hash: hash}), do: {:node, hash}
end
