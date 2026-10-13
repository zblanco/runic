defmodule Runic.Workflow.ChildCallReviewTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  require Runic
  alias Runic.Workflow
  alias Runic.Workflow.{Call, ChildInvocation, ComponentAdded, Invokable}
  alias Runic.TestSupport.{ChildTargets, OrdinaryChildComposite, PortPair}

  defp call do
    request =
      Runic.step(
        fn n ->
          ChildInvocation.new(target: Runic.step(fn x -> x * 2 end, name: :target), input: n)
        end,
        name: :request
      )

    Call.new(request, name: :call)
  end

  defp after_step, do: Runic.step(fn n -> n + 1 end, name: :after)

  test "to and pipeline composition use the public producer while retaining authored parents" do
    candidates = [
      Workflow.new() |> Workflow.add(call()) |> Workflow.add(after_step(), to: :call),
      Runic.workflow(steps: [{call(), [after_step()]}])
    ]

    for original <- candidates do
      assert %ComponentAdded{to: :call} = List.last(Workflow.build_log(original))

      for base <- [original, Workflow.from_log(Workflow.build_log(original))] do
        result = Workflow.react_until_satisfied(base, 4)
        assert Workflow.raw_productions(result, :call) == [8]
        assert Workflow.raw_productions(result, :after) == [9]
      end
    end
  end

  test "ported nested whole-component connection uses its producer; ambiguous and contract-only sources reject" do
    nested =
      Workflow.new(name: :nested, input_ports: [in: []], output_ports: [out: [from: :call]])
      |> Workflow.add(call())

    workflow = Workflow.new() |> Workflow.add(nested) |> Workflow.add(after_step(), to: :nested)

    for base <- [workflow, Workflow.from_log(Workflow.build_log(workflow))] do
      assert base |> Workflow.react_until_satisfied(4) |> Workflow.raw_productions(:after) == [9]
    end

    contract = %{nested | name: :contract, output_ports: [out: []]}

    assert_raise ArgumentError, ~r/no public output producer/, fn ->
      Workflow.new() |> Workflow.add(contract) |> Workflow.add(after_step(), to: :contract)
    end

    pair = Workflow.new() |> Workflow.add(PortPair.new(:pair))

    assert_raise ArgumentError, ~r/multiple public producers/, fn ->
      Workflow.add(pair, after_step(), to: :pair)
    end
  end

  test "Map pipelines containing Call reject before runnable wiring is accepted, also through source" do
    call = call()
    after_step = after_step()

    for map <- [
          Runic.map({Runic.step(fn n -> n end, name: :id), [call]}, name: :map_leaf),
          Runic.map({Runic.step(fn n -> n end, name: :id), [{call, [after_step]}]},
            name: :map_after
          )
        ] do
      assert_raise ArgumentError,
                   ~r/Call inside Map requires a collection instance contract/,
                   fn -> Workflow.add(Workflow.new(), map) end

      {rebuilt, _} =
        Code.eval_quoted(
          Runic.Component.source(map),
          [call: call, after_step: after_step],
          __ENV__
        )

      assert_raise ArgumentError, ~r/Call inside Map/, fn ->
        Workflow.add(Workflow.new(), rebuilt)
      end
    end
  end

  test "partial declared exports and partial ownership edges reject instead of binding the wrong value" do
    composite = OrdinaryChildComposite.new()
    partial = %{composite | outputs: [raw: [], doubled: [from: composite.leaf.name]]}

    assert_raise ArgumentError, ~r/output port :raw.*no declared producer/, fn ->
      Workflow.add(Workflow.new(), partial)
    end

    pair = %{PortPair.new(:pair) | outputs: [left: [from: "pair/left"], right: []]}

    assert_raise ArgumentError, ~r/output port :right.*no declared producer/, fn ->
      Workflow.add(Workflow.new(), pair)
    end
  end

  test "raw and Fact production APIs use the same declared producers and deduplicate" do
    pair = PortPair.new(:pair)
    pair = %{pair | outputs: [right: [from: pair.right.name]]}
    base = Workflow.new() |> Workflow.add(pair)
    result = Workflow.react_until_satisfied(base, 5)
    assert Workflow.raw_productions(result, :pair) == [10]
    assert Enum.map(Workflow.productions(result, :pair), & &1.value) == [10]
    assert Workflow.results(result, [:pair], all: true) == %{pair: [10]}

    assert Enum.map(Workflow.results(result, [:pair], facts: true, all: true).pair, & &1.value) ==
             [10]
  end

  test "private occurrence audit events do not change the public logical graph" do
    base =
      Workflow.new()
      |> Workflow.add(call())
      |> Workflow.add(after_step(), to: :call)
      |> Workflow.enable_event_emission()

    result = base |> Workflow.react_until_satisfied(3) |> Workflow.react_until_satisfied(4)

    replayed =
      Workflow.from_events(Workflow.build_log(base) ++ Enum.reverse(result.uncommitted_events))

    for candidate <- [result, replayed] do
      assert logical(candidate) == logical(base)

      assert Enum.count(
               Workflow.build_log(candidate),
               &String.starts_with?(to_string(&1.name), "__runic_child__/")
             ) == 2
    end
  end

  test "ordinary SingleOutput composite and nested ported targets execute and replay" do
    composite_request =
      Runic.step(fn n -> ChildInvocation.new(target: OrdinaryChildComposite.new(), input: n) end,
        name: :composite_request
      )

    nested_request =
      Runic.step(
        fn n ->
          inner =
            Workflow.new(
              name: :inner,
              input_ports: [in: []],
              output_ports: [out: [from: :double]]
            )
            |> Workflow.add(Runic.step(fn x -> x * 2 end, name: :double))

          outer =
            Workflow.new(name: :outer, input_ports: [in: []], output_ports: [out: [from: :inner]])
            |> Workflow.add(inner)

          ChildInvocation.new(target: outer, input: n)
        end,
        name: :nested_request
      )

    for {request, value} <- [{composite_request, 8}, {nested_request, 6}] do
      base =
        Workflow.new()
        |> Workflow.add(Call.new(request, name: :call))
        |> Workflow.enable_event_emission()

      result = Workflow.react_until_satisfied(base, 3)

      replayed =
        Workflow.from_events(Workflow.build_log(base) ++ Enum.reverse(result.uncommitted_events))

      assert Workflow.raw_productions(result, :call) == [value]
      assert Workflow.raw_productions(replayed, :call) == [value]
    end
  end

  test "many cardinality is inherited through an unambiguous boundary or explicitly selected as one" do
    request =
      Runic.step(fn n -> ChildInvocation.new(target: ChildTargets.many_returns(), input: n) end,
        name: :request
      )

    for {options, expected} <- [
          {[from: :call], [4, 5]},
          {[from: :call, cardinality: :many], [4, 5]},
          {[from: :call, cardinality: :one], :last}
        ] do
      base =
        Workflow.new(name: :parent, output_ports: [result: options])
        |> Workflow.add(Call.new(request, name: :call))

      result = Workflow.react_until_satisfied(base, 3)
      values = Workflow.raw_productions(result, :call)
      actual = Workflow.results(result).result

      if expected == :last,
        do: assert(actual == List.last(values)),
        else: assert(Enum.sort(actual) == expected)
    end
  end

  test "target graph is prepared in work, with no owner-time reconstruction or durable compiled graph" do
    Process.put(:runic_test_constructor_observer, self())

    on_exit(fn ->
      Process.delete(:runic_test_constructor_observer)
      Process.delete(:runic_test_constructor_error)
    end)

    request =
      Runic.step(fn n -> ChildInvocation.new(target: OrdinaryChildComposite.new(), input: n) end,
        name: :request
      )

    base =
      Workflow.new() |> Workflow.add(Call.new(request, name: :call)) |> Workflow.plan_eagerly(3)

    {prepared, [runnable]} = Workflow.prepare_for_dispatch(base)
    executed = Invokable.execute(runnable.node, runnable)
    assert executed.status == :completed
    assert_receive :target_constructed
    assert_receive :target_constructed
    refute_received :target_constructed
    assert is_map(executed.execution_data)
    Process.put(:runic_test_constructor_error, true)
    attached = Workflow.apply_runnable(prepared, executed)
    Process.delete(:runic_test_constructor_error)
    result = Workflow.react_until_satisfied(attached)
    assert Workflow.raw_productions(result, :call) == [8]
    refute_received :target_constructed

    occurrence =
      Enum.find(
        Multigraph.vertices(result.graph),
        &is_struct(&1, Runic.Workflow.ChildInvocation.Occurrence)
      )

    refute Map.has_key?(occurrence, :request)
    refute Map.has_key?(occurrence, :execution_data)
  end

  defp logical(workflow),
    do:
      Workflow.component_graph(workflow)
      |> Multigraph.edges()
      |> Enum.map(&{&1.v1.hash, &1.v2.hash, &1.label, &1.properties})
      |> Enum.sort()

  test "live custom target wiring is validated without another source reconstruction" do
    composite = OrdinaryChildComposite.new()

    invalid = %{
      composite
      | leaf: Runic.accumulator(0, fn n, state -> n + state end, name: :state),
        outputs: [out: [from: :state]]
    }

    assert_raise ArgumentError, ~r/unsupported child node/, fn ->
      ChildInvocation.new(target: invalid, input: 3)
    end
  end
end
