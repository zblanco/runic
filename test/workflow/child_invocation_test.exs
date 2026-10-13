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

  test "a static nested boundary exports the Call completion producer live and through replay" do
    nested =
      Workflow.new(name: :nested, input_ports: [in: []], output_ports: [out: [from: :call]])
      |> Workflow.add(call())

    parent =
      Workflow.new()
      |> Workflow.add(nested)
      |> Workflow.add(Runic.step(fn n -> n + 1 end, name: :after_nested),
        connections: [[from: {:nested, :out}, to: :in]]
      )

    for candidate <- [parent, Workflow.from_log(Workflow.build_log(parent))] do
      completed =
        candidate |> Workflow.enable_event_emission() |> Workflow.react_until_satisfied(4)

      replayed =
        Workflow.from_events(
          Workflow.build_log(candidate) ++ Enum.reverse(completed.uncommitted_events)
        )

      for result <- [completed, replayed] do
        assert Workflow.raw_productions(result, :nested) == [8]
        assert Workflow.raw_productions(result, :after_nested) == [9]

        refute Enum.any?(
                 Workflow.raw_productions(result, :nested),
                 &is_struct(&1, ChildInvocation)
               )
      end
    end
  end

  test "grouped public constructors preserve their Join in child definitions" do
    child = Runic.TestSupport.ChildTargets.grouped()

    rebuilt =
      Workflow.new(
        name: child.name,
        input_ports: child.input_ports,
        output_ports: child.output_ports
      )
      |> Workflow.apply_events(Workflow.build_log(child))

    assert Enum.map(
             Multigraph.edges(child.graph, by: :flow),
             &{Runic.Workflow.Components.vertex_id_of(&1.v1),
              Runic.Workflow.Components.vertex_id_of(&1.v2)}
           )
           |> Enum.sort() ==
             Enum.map(
               Multigraph.edges(rebuilt.graph, by: :flow),
               &{Runic.Workflow.Components.vertex_id_of(&1.v1),
                Runic.Workflow.Components.vertex_id_of(&1.v2)}
             )
             |> Enum.sort()

    for target <- [child, rebuilt] do
      assert target |> Workflow.react_until_satisfied(3) |> Workflow.raw_productions(:sum) == [10]
      ChildInvocation.new(target: target, input: 3)
    end

    request =
      Runic.step(
        fn n ->
          ChildInvocation.new(target: Runic.TestSupport.ChildTargets.grouped(), input: n)
        end,
        name: :request
      )

    workflow = Workflow.new() |> Workflow.add(Call.new(request, name: :call))

    for candidate <- [workflow, Workflow.from_log(Workflow.build_log(workflow))] do
      assert candidate |> Workflow.react_until_satisfied(3) |> Workflow.raw_productions(:call) ==
               [10]
    end
  end

  test "custom activation and coordination are rejected before child attachment" do
    alias Runic.TestSupport.{CustomChildActivation, CustomChildCoordination}
    wrapper = CustomChildActivation.new()

    assert Workflow.new()
           |> Workflow.add(wrapper)
           |> Workflow.react_until_satisfied(3)
           |> Workflow.raw_productions(:wrapper) == [6]

    assert Workflow.new()
           |> Workflow.add(CustomChildCoordination.new())
           |> Workflow.react_until_satisfied(3)
           |> Workflow.raw_productions(:custom) == [3]

    for node <- [wrapper, CustomChildCoordination.new()] do
      assert_raise ArgumentError, ~r/custom child activation or coordination/, fn ->
        ChildInvocation.new(target: node, input: 3)
      end

      target =
        Workflow.new(name: :target, input_ports: [in: []], output_ports: [out: [from: node.name]])
        |> Workflow.add(node)

      assert_raise ArgumentError, ~r/custom child activation or coordination/, fn ->
        ChildInvocation.new(target: target, input: 3)
      end
    end
  end

  test "one child occurrence forwards all accepted values of the selected producer" do
    request =
      Runic.step(
        fn n ->
          ChildInvocation.new(target: Runic.TestSupport.ChildTargets.many_returns(), input: n)
        end,
        name: :request
      )

    base =
      Workflow.new()
      |> Workflow.add(Call.new(request, name: :call))
      |> Workflow.enable_event_emission()

    result = Workflow.react_until_satisfied(base, 3)

    replayed =
      Workflow.from_events(Workflow.build_log(base) ++ Enum.reverse(result.uncommitted_events))

    for candidate <- [result, replayed] do
      assert candidate |> Workflow.raw_productions(:call) |> Enum.sort() == [4, 5]

      assert candidate
             |> Workflow.results([:call], all: true)
             |> Map.fetch!(:call)
             |> Enum.sort() == [4, 5]

      assert Enum.count(Multigraph.vertices(candidate.graph), &is_struct(&1, Occurrence)) == 1
    end

    assert Runic.Component.outputs(Workflow.get_component!(result, :call))[:out][:cardinality] ==
             :many
  end

  test "selected output can succeed while an independent child branch fails under skip policy" do
    request =
      Runic.step(
        fn n ->
          ChildInvocation.new(target: Runic.TestSupport.ChildTargets.sibling_failure(), input: n)
        end,
        name: :request
      )

    base =
      Workflow.new()
      |> Workflow.add(Call.new(request, name: :call))
      |> Workflow.enable_event_emission()

    {result, execution} =
      Workflow.execute(base, 3, scheduler_policies: [{:failure, %{on_failure: :skip}}])

    assert execution.quiescent?
    assert [%{error: :bad, kind: :skipped}] = execution.failures
    assert Workflow.raw_productions(result, :call) == [4]

    replayed =
      Workflow.from_events(Workflow.build_log(base) ++ Enum.reverse(result.uncommitted_events))

    assert Workflow.raw_productions(replayed, :call) == [4]
    assert not Workflow.is_runnable?(replayed)
  end

  test "unrecorded child graph wiring is rejected instead of silently dropped" do
    child = Runic.TestSupport.ChildTargets.grouped()
    extra = Runic.step(fn n -> n + 10 end, name: :unrecorded)
    child = Workflow.add_step(child, Workflow.get_component!(child, :sum), extra)

    assert_raise ArgumentError, ~r/build log does not preserve its graph/, fn ->
      ChildInvocation.new(target: child, input: 3)
    end
  end
end
