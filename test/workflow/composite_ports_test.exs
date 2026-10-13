defmodule Runic.Workflow.CompositePortsTest do
  use ExUnit.Case, async: true
  require Runic
  alias Runic.Workflow
  alias Runic.TestSupport.PortPair

  test "custom output endpoints connect to a grouped nested workflow and replay" do
    child =
      Workflow.new(
        name: :child,
        input_ports: [in: [type: :any]],
        output_ports: [out: [from: :sum]]
      )
      |> Workflow.add(Runic.step(fn [left, right] -> left + right end, name: :sum))

    workflow =
      Workflow.new()
      |> Workflow.add(PortPair.new(:pair))
      |> Workflow.add(child,
        connections: [
          [from: {:pair, :left}, to: :in, target_path: [0]],
          [from: {:pair, :right}, to: :in, target_path: [1]]
        ]
      )

    for candidate <- [workflow, Workflow.from_log(Workflow.build_log(workflow))] do
      result = Workflow.react_until_satisfied(candidate, 3)
      assert Workflow.raw_productions(result, :child) == [10]
      assert Enum.sort(Workflow.raw_productions(result, :pair)) == [4, 6]
      assert Map.keys(Workflow.results(result)) |> Enum.all?(&(is_atom(&1) or is_binary(&1)))
    end
  end

  test "distinct nested output endpoints produce whole port values" do
    child =
      Workflow.new(
        name: :pair,
        input_ports: [in: []],
        output_ports: [left: [from: :left], right: [from: :right]]
      )
      |> Workflow.add(Runic.step(fn n -> n + 1 end, name: :left))
      |> Workflow.add(Runic.step(fn n -> n * 2 end, name: :right))

    workflow = Workflow.new() |> Workflow.add(child)
    sum = Runic.step(fn a, b -> a + b end, name: :sum, inputs: [a: [], b: []])

    workflow =
      Workflow.add(workflow, sum,
        connections: [[from: {:pair, :left}, to: :a], [from: {:pair, :right}, to: :b]]
      )

    assert Workflow.react_until_satisfied(workflow, 3) |> Workflow.raw_productions(:sum) == [10]
  end

  test "any-input is explicit and retains separate activations through replay" do
    workflow = Workflow.new() |> Workflow.add(PortPair.new(:pair))
    sink = Runic.step(fn x -> x + 10 end, name: :sink)
    connections = [[from: {:pair, :left}, to: :in], [from: {:pair, :right}, to: :in]]

    assert_raise ArgumentError, ~r/overlapping assignments/, fn ->
      Workflow.add(workflow, sink, connections: connections)
    end

    workflow = Workflow.add(workflow, sink, connections: connections, input_mode: :any)

    for candidate <- [workflow, Workflow.from_log(Workflow.build_log(workflow))] do
      [edge] =
        Multigraph.out_edges(
          Workflow.component_graph(candidate),
          Workflow.get_component!(candidate, :pair),
          by: :connects_to
        )

      assert Enum.map(edge.properties.connections, & &1.source_port) == [:left, :right]

      assert Enum.map(edge.properties.connections, &{&1.source, &1.target}) == [
               {:pair, :sink},
               {:pair, :sink}
             ]

      assert candidate
             |> Workflow.react_until_satisfied(3)
             |> Workflow.raw_productions(:sink)
             |> Enum.sort() == [14, 16]
    end
  end

  test "multi-port nested input is a map with declared keys" do
    child =
      Workflow.new(
        name: :child,
        input_ports: [left: [], right: []],
        output_ports: [out: [from: :sum]]
      )
      |> Workflow.add(Runic.step(fn %{left: a, right: b} -> a + b end, name: :sum))

    workflow = Workflow.new() |> Workflow.add(PortPair.new(:pair))

    workflow =
      Workflow.add(workflow, child,
        connections: [[from: {:pair, :left}, to: :left], [from: {:pair, :right}, to: :right]]
      )

    assert workflow |> Workflow.react_until_satisfied(3) |> Workflow.raw_productions(:child) == [
             10
           ]
  end

  test "missing endpoints, ports, and incompatible types fail during construction" do
    pair = PortPair.new(:pair)

    assert_raise KeyError, fn ->
      Workflow.add(Workflow.new(), %{pair | outputs: [out: [from: :missing]]})
    end

    workflow = Workflow.add(Workflow.new(), pair)
    sink = Runic.step(fn x -> x end, name: :sink, inputs: [in: [type: :string]])

    assert_raise ArgumentError, ~r/no output port/, fn ->
      Workflow.add(workflow, sink, connections: [[from: {:pair, :missing}, to: :in]])
    end

    assert_raise ArgumentError, ~r/no input port/, fn ->
      Workflow.add(workflow, sink, connections: [[from: {:pair, :left}, to: :missing]])
    end

    assert_raise Runic.IncompatiblePortError, fn ->
      Workflow.add(workflow, sink, connections: [[from: {:pair, :left}, to: :in]])
    end

    assert_raise ArgumentError, ~r/input_mode/, fn ->
      Workflow.add(workflow, sink,
        connections: [[from: {:pair, :left}, to: :in]],
        input_mode: :unknown
      )
    end
  end

  test "binding metadata keeps application values and replaces native binding annotations" do
    source = Runic.TestSupport.OrdinaryComponent.new(:source, :metadata, :kept)
    sink = Runic.step(fn n -> n end, name: :sink)

    workflow =
      Workflow.new()
      |> Workflow.add(source)
      |> Workflow.add(sink, connections: [[from: {:source, :out}, to: :in]])

    planned = workflow |> Workflow.react(3) |> Workflow.react()

    binding =
      Enum.find(Multigraph.vertices(planned.graph), &is_struct(&1, Runic.Workflow.InputBinding))

    assert [%{v2: %{meta: %{custom: :kept, runic: %{input_bindings: [_]}}}}] =
             Multigraph.out_edges(planned.graph, binding, by: :produced)
  end

  test "an old binding snapshot has the positional input shape" do
    binding =
      Runic.Workflow.InputBinding.new(
        target_component_hash: :target,
        source_order: [:source],
        input_ports: [in: []],
        bindings: [
          %{
            id: :binding,
            source_hash: :source,
            source_port: :out,
            source_port_count: 1,
            source_port_index: 0,
            target_port: :in,
            selector: [],
            target_path: []
          }
        ]
      )

    legacy = :erlang.binary_to_term(:erlang.term_to_binary(Map.delete(binding, :input_shape)))
    assert Runic.Workflow.InputBinding.bind(legacy, 3) == 3
  end

  test "bound arity-two Rules receive declared positional inputs live and after replay" do
    producer =
      Runic.step(fn n -> %{left: n, right: n + 1} end,
        name: :producer,
        outputs: [left: [], right: []]
      )

    rule =
      Runic.rule(fn a, b when is_integer(a) and is_integer(b) -> a + b end,
        name: :sum,
        inputs: [a: [], b: []]
      )

    assert Runic.Workflow.Rule.run(rule, [3, 4]) == 7

    workflow =
      Workflow.new()
      |> Workflow.add(producer)
      |> Workflow.add(rule,
        connections: [[from: {:producer, :right}, to: :b], [from: {:producer, :left}, to: :a]]
      )

    for candidate <- [workflow, Workflow.from_log(Workflow.build_log(workflow))] do
      assert candidate |> Workflow.react_until_satisfied(3) |> Workflow.raw_productions(:sum) == [
               7
             ]
    end

    invalid = %{rule | inputs: [in: []]}

    assert_raise ArgumentError, ~r/2 positional input ports/, fn ->
      Workflow.add(Workflow.new() |> Workflow.add(producer), invalid,
        connections: [[from: {:producer, :left}, to: :in]]
      )
    end
  end
end
