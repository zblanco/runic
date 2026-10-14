defmodule Runic.Workflow.ChildResultCompatibilityTest do
  use ExUnit.Case, async: true
  require Runic
  alias Runic.{Runner, Workflow}

  test "missing and contract-only output references retain empty and nil results" do
    for ports <- [[summary: [type: :any]], [summary: [from: :missing]]] do
      base =
        Workflow.new(output_ports: ports)
        |> Workflow.add(Runic.step(fn n -> n + 1 end, name: :step))

      complete = Workflow.react_until_satisfied(base, 3)
      assert Workflow.results(complete) == %{summary: nil}
      assert Workflow.results(complete, nil, all: true) == %{summary: []}
      assert Workflow.results(complete, nil, facts: true) == %{summary: nil}
      runner = :"result_soft_#{System.unique_integer([:positive])}"
      start_supervised!({Runner, name: runner}, id: runner)
      {:ok, worker} = Runner.start_workflow(runner, :wf, base, executor: :inline)
      {:ok, id} = Runner.start_execution(runner, :wf, 3)
      {:ok, _} = Runner.await_execution(runner, :wf, id)
      assert {:ok, %{summary: nil}} = Runner.get_results(runner, :wf, format: :structured)

      assert {:ok, %{summary: []}} =
               Runner.get_results(runner, :wf, format: :structured, all: true)

      assert Process.alive?(worker)
    end
  end

  test "ordinary Map exports keep last-value selection unless explicitly many" do
    map = Runic.map(fn n -> n * 10 end, name: :mapped)

    for schema <- [[from: :mapped], [from: :mapped, cardinality: :many]] do
      base = Workflow.new(output_ports: [items: schema]) |> Workflow.add(map)
      result = Workflow.react_until_satisfied(base, [1, 2, 3])
      values = Workflow.raw_productions(result, :mapped)

      if schema[:cardinality] == :many do
        assert Workflow.results(result).items == values
      else
        assert Workflow.results(result).items == List.last(values)
      end

      assert Workflow.results(result, nil, all: true).items == values
    end
  end

  test "nested mixed export and contract ports connect and survive durable replay" do
    child =
      Workflow.new(
        name: :nested,
        input_ports: [in: []],
        output_ports: [out: [from: :inner], audit: [type: :any]]
      )
      |> Workflow.add(Runic.step(fn n -> n * 2 end, name: :inner))

    base =
      Workflow.new()
      |> Workflow.add(child)
      |> Workflow.add(Runic.step(fn n -> n + 1 end, name: :after),
        connections: [[from: {:nested, :out}, to: :in]]
      )

    for candidate <- [base, Workflow.from_log(Workflow.build_log(base))] do
      assert candidate |> Workflow.react_until_satisfied(3) |> Workflow.raw_productions(:after) ==
               [7]

      assert_raise ArgumentError, ~r/no compiled output node.*audit/, fn ->
        Workflow.add(candidate, Runic.step(fn n -> n end, name: :audit_sink),
          connections: [[from: {:nested, :audit}, to: :in]]
        )
      end
    end
  end

  test "Call many inheritance selects the compiled nested export and ignores contract-only ports" do
    request =
      Runic.step(
        fn n ->
          Runic.Workflow.ChildInvocation.new(
            target: Runic.TestSupport.ChildTargets.many_returns(),
            input: n
          )
        end,
        name: :request
      )

    for ports <- [
          [out: [from: :call]],
          [out: [from: :call], audit: [type: :any]],
          [out: [from: :call], copy: [from: :call]],
          [out: [from: :call], copy: [from: :call], audit: [type: :any]]
        ] do
      nested =
        Workflow.new(name: :nested, input_ports: [in: []], output_ports: ports)
        |> Workflow.add(Runic.Workflow.Call.new(request, name: :call))

      original = Workflow.new(output_ports: [result: [from: :nested]]) |> Workflow.add(nested)

      for base <- [
            original,
            Workflow.new(output_ports: original.output_ports)
            |> Workflow.apply_events(Workflow.build_log(original))
          ] do
        result = Workflow.react_until_satisfied(base, 3)
        assert Enum.sort(Workflow.results(result).result) == [4, 5]
      end

      runner = :"nested_many_#{System.unique_integer([:positive])}"
      start_supervised!({Runner, name: runner}, id: runner)
      {:ok, _} = Runner.start_workflow(runner, :wf, original, executor: :inline)
      {:ok, id} = Runner.start_execution(runner, :wf, 3)
      {:ok, _} = Runner.await_execution(runner, :wf, id)
      {:ok, actual} = Runner.get_results(runner, :wf, format: :structured)
      assert Enum.sort(actual.result) == [4, 5]
    end
  end

  test "aliases of one producer honor one explicit override or default to one on conflicting overrides" do
    request =
      Runic.step(
        fn n ->
          Runic.Workflow.ChildInvocation.new(
            target: Runic.TestSupport.ChildTargets.many_returns(),
            input: n
          )
        end,
        name: :request
      )

    for {out_card, copy_card, expected} <- [
          {:many, nil, :many},
          {:one, nil, :one},
          {:one, :many, :one},
          {:many, :many, :many}
        ] do
      out_opts = [from: :call, cardinality: out_card]
      copy_opts = if copy_card, do: [from: :call, cardinality: copy_card], else: [from: :call]

      child =
        Workflow.new(
          name: :nested,
          input_ports: [in: []],
          output_ports: [out: out_opts, copy: copy_opts]
        )
        |> Workflow.add(Runic.Workflow.Call.new(request, name: :call))

      base = Workflow.new(output_ports: [result: [from: :nested]]) |> Workflow.add(child)
      result = Workflow.react_until_satisfied(base, 3)
      values = Workflow.raw_productions(result, :nested)

      if expected == :many,
        do: assert(Enum.sort(Workflow.results(result).result) == [4, 5]),
        else: assert(Workflow.results(result).result == List.last(values))

      assert Enum.sort(
               Workflow.results(%{
                 result
                 | output_ports: [result: [from: :nested, cardinality: :many]]
               }).result
             ) == [4, 5]
    end
  end
end
