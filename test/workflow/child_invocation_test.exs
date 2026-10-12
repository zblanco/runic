defmodule Runic.Workflow.ChildInvocationTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  require Runic
  alias Runic.Workflow
  alias Runic.Workflow.{Call, ChildInvocation, ComponentAdded, Fact}
  alias Runic.Workflow.ChildInvocation.Occurrence
  alias Runic.TestSupport.OrdinaryComponent

  defp call() do
    request =
      Runic.step(
        fn x ->
          ChildInvocation.new(target: Runic.step(fn y -> y * 2 end, name: :double), input: x)
        end,
        name: :request
      )

    Call.new(request, name: :call)
  end

  defp workflow() do
    Workflow.new()
    |> Workflow.add(call())
    |> Workflow.add(Runic.step(fn x -> x + 1 end, name: :after),
      connections: [[from: {:call, :out}, to: :in]]
    )
  end

  test "a child emits only completed public output and construction replays" do
    workflow = workflow()

    for candidate <- [workflow, Workflow.from_log(Workflow.build_log(workflow))] do
      result = Workflow.react_until_satisfied(candidate, 3)
      assert Workflow.raw_productions(result, :call) == [6]
      assert Workflow.raw_productions(result, :after) == [7]

      assert Enum.count(
               Workflow.build_log(result),
               &String.starts_with?(to_string(&1.name), "__runic_child__/")
             ) == 1
    end
  end

  test "separate input occurrences call the same target separately on a reusable graph" do
    original = workflow()

    first =
      Workflow.react_until_satisfied(
        original,
        Fact.new(value: 3, id: Runic.Identity.derive(:fact_occurrence, [:first]))
      )

    second =
      Workflow.react_until_satisfied(
        first,
        Fact.new(value: 3, id: Runic.Identity.derive(:fact_occurrence, [:second]))
      )

    children = Multigraph.vertices(second.graph) |> Enum.filter(&is_struct(&1, Occurrence))
    assert length(children) == 2
    assert length(Enum.uniq_by(children, & &1.hash)) == 2
    assert Enum.sort(Workflow.raw_productions(second, :call)) == [6, 6]
    assert Workflow.get_component(original, :double) == nil
  end

  test "checkpoint before attachment, during child work, and after completion" do
    base = workflow() |> Workflow.enable_event_emission()
    build = Workflow.build_log(base)
    planned = Workflow.plan_eagerly(base, 3)
    # Before request acceptance, the durable activation still belongs to Call.
    before = Workflow.from_events(build ++ Enum.reverse(planned.uncommitted_events))
    assert Workflow.get_component(before, :call)
    assert Workflow.react_until_satisfied(before) |> Workflow.raw_productions(:call) == [6]
    attached = Workflow.react(planned)
    tail = Enum.reverse(attached.uncommitted_events)
    assert Enum.any?(tail, &match?(%ComponentAdded{source: _}, &1))
    restored = Workflow.from_events(build ++ tail) |> Workflow.enable_event_emission()
    assert Workflow.raw_productions(restored, :call) == []
    during = Workflow.react(restored)

    recovered =
      Workflow.from_events(
        Workflow.build_log(during) ++ tail ++ Enum.reverse(during.uncommitted_events)
      )

    completed = Workflow.react_until_satisfied(recovered)
    assert Workflow.raw_productions(completed, :call) == [6]
    events = build ++ tail

    completed =
      Workflow.from_events(events)
      |> Workflow.enable_event_emission()
      |> Workflow.react_until_satisfied()

    replayed =
      Workflow.from_events(
        Workflow.build_log(completed) ++ tail ++ Enum.reverse(completed.uncommitted_events)
      )

    assert Workflow.raw_productions(replayed, :call) == [6]
    assert not Workflow.is_runnable?(replayed)
  end

  test "ordinary custom Result failure is a child failure and has no public return" do
    request =
      Runic.step(
        fn x ->
          ChildInvocation.new(target: OrdinaryComponent.new(:target, :failure, :bad), input: x)
        end,
        name: :request
      )

    base =
      Workflow.new()
      |> Workflow.add(Call.new(request, name: :call))
      |> Workflow.enable_event_emission()

    failed = Workflow.react_until_satisfied(base, 3)
    assert Workflow.raw_productions(failed, :call) == []
    assert not Workflow.is_runnable?(failed)
  end

  test "a stateless workflow child preserves grouped ports and scoped joins" do
    request =
      Runic.step(
        fn x ->
          child =
            Workflow.new(name: :target, input_ports: [in: []], output_ports: [out: [from: :sum]])
            |> Workflow.add(Runic.step(fn y -> y + 1 end, name: :left))
            |> Workflow.add(Runic.step(fn y -> y * 2 end, name: :right))
            |> Workflow.add(Runic.step(fn a, b -> a + b end, name: :sum, inputs: [a: [], b: []]),
              connections: [[from: {:left, :out}, to: :a], [from: {:right, :out}, to: :b]]
            )

          ChildInvocation.new(target: child, input: x)
        end,
        name: :request
      )

    base = Workflow.new() |> Workflow.add(Call.new(request, name: :call))
    result = Workflow.react_until_satisfied(base, 3)
    assert Workflow.raw_productions(result, :call) == [10]
    replayed = Workflow.from_log(Workflow.build_log(base)) |> Workflow.react_until_satisfied(3)
    assert Workflow.raw_productions(replayed, :call) == [10]
  end

  test "invalid requests and unsupported child state fail without attachment" do
    base =
      Workflow.new()
      |> Workflow.add(Call.new(Runic.step(fn _ -> {:ok, :data} end, name: :request), name: :call))

    result = Workflow.react_until_satisfied(base, 3)
    assert Workflow.raw_productions(result, :call) == []
    assert Enum.all?(Multigraph.vertices(result.graph), &(not is_struct(&1, Occurrence)))

    assert_raise ArgumentError, ~r/unsupported child node/, fn ->
      ChildInvocation.new(
        target: Runic.accumulator(0, fn n, acc -> n + acc end, name: :state),
        input: 1
      )
    end

    assert_raise ArgumentError, ~r/no output port/, fn ->
      ChildInvocation.new(
        target: Runic.step(fn n -> n end, name: :target),
        input: 1,
        output: :missing
      )
    end
  end

  test "a child selects a declared output port without internal endpoint lookup" do
    request =
      Runic.step(
        fn x ->
          target =
            Runic.step(fn n -> %{left: n + 1, right: n * 2} end,
              name: :target,
              outputs: [left: [], right: []]
            )

          ChildInvocation.new(target: target, input: x, output: :right)
        end,
        name: :request
      )

    completed =
      Workflow.new()
      |> Workflow.add(Call.new(request, name: :call))
      |> Workflow.react_until_satisfied(3)

    assert Workflow.raw_productions(completed, :call) == [6]

    assert_raise ArgumentError, ~r/select an output port/, fn ->
      ChildInvocation.new(
        target: Runic.step(fn n -> n end, name: :target, outputs: [left: [], right: []]),
        input: 3
      )
    end
  end
end
