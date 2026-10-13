defmodule Runic.Workflow.LineageWalkBoundTest do
  use ExUnit.Case, async: true
  require Runic
  alias Runic.Workflow
  alias Runic.Workflow.{Call, ChildInvocation, Fact, Join}
  alias Runic.Workflow.Events.{FactProduced, JoinCompleted}

  test "a 24-diamond contribution DAG expands each Fact at most once across all branches" do
    request =
      Runic.step(
        fn n ->
          ChildInvocation.new(target: Runic.step(fn x -> x end, name: :target), input: n)
        end,
        name: :request
      )

    call = Call.new(request, name: :call)
    base = Workflow.new() |> Workflow.add(call)
    root = Fact.new(value: 6)

    request_value =
      ChildInvocation.new(target: Runic.step(fn n -> n end, name: :target), input: 6)

    invocation = Fact.new(value: request_value, ancestry: {call.hash, root.hash})
    output = Fact.new(value: 6, ancestry: {call.output.hash, invocation.hash})
    initial = Enum.reduce([root, invocation, output], base, &put_fact(&2, &1))

    {workflow, last, ids} =
      Enum.reduce(
        1..24,
        {initial, output, MapSet.new([root.hash, invocation.hash, output.hash])},
        fn level, {wf, prior, ids} ->
          p_name = "p#{level}"
          q_name = "q#{level}"
          out_name = "out#{level}"
          p = Runic.step(fn n -> n end, name: p_name)
          q = Runic.step(fn n -> n end, name: q_name)
          out = Runic.step(fn a, _b -> a end, name: out_name)
          wf = wf |> Workflow.add(p) |> Workflow.add(q) |> Workflow.add(out, to: [p.name, q.name])
          join = Join.new([p.hash, q.hash])
          left = Fact.new(value: 6, ancestry: {p.hash, prior.hash})
          right = Fact.new(value: 6, ancestry: {q.hash, prior.hash})
          joined = Fact.new(value: [6, 6], ancestry: {join.hash, right.hash})
          next = Fact.new(value: 6, ancestry: {out.hash, joined.hash})

          wf =
            wf
            |> put_fact(left)
            |> put_fact(right)
            |> Workflow.apply_event(%JoinCompleted{
              join_hash: join.hash,
              result_fact_hash: joined.hash,
              result_value: joined.value,
              result_ancestry: joined.ancestry,
              contribution_fact_hashes: [left.hash, right.hash],
              weight: 0
            })
            |> put_fact(next)

          {wf, next, Enum.reduce([left, right, joined, next], ids, &MapSet.put(&2, &1.hash))}
        end
      )

    expected_visits = MapSet.size(ids)
    assert expected_visits == 99
    absent_fact = Runic.Identity.derive(:fact_occurrence, [:absent])
    absent_call = Runic.Identity.derive(:component_definition, [:absent])

    assert Workflow.lineage_reachability(workflow, last, {:fact, absent_fact}) ==
             {false, expected_visits}

    assert Workflow.lineage_reachability(workflow, last, {:call_request, absent_call}) ==
             {false, expected_visits}

    assert {true, visits} =
             Workflow.lineage_reachability(workflow, last, {:fact, invocation.hash})

    assert visits <= expected_visits

    assert {true, visits} =
             Workflow.lineage_reachability(workflow, last, {:call_request, call.hash})

    assert visits <= expected_visits
  end

  test "known provenance and ordinary parent cycles terminate without repeating a Fact" do
    join = Join.new([:parent])
    wf = %{Workflow.new() | graph: Multigraph.add_vertex(Workflow.new().graph, join)}
    result = Fact.new(value: :cycle, ancestry: {join.hash, :parent})

    wf =
      Workflow.apply_event(wf, %JoinCompleted{
        join_hash: join.hash,
        result_fact_hash: result.hash,
        result_value: result.value,
        result_ancestry: result.ancestry,
        contribution_fact_hashes: [result.hash],
        weight: 0
      })

    assert {false, 1} = Workflow.lineage_reachability(wf, result, {:fact, :missing})
    assert {false, 1} = Workflow.lineage_reachability(wf, result, {:call_request, :missing})
    first = Fact.new(value: :a)
    second = Fact.new(value: :b, ancestry: {:step, first.hash})
    first = %{first | ancestry: {:step, second.hash}}
    wf = wf |> put_fact(first) |> put_fact(second)
    assert {false, 2} = Workflow.lineage_reachability(wf, first, {:fact, :missing})
    assert {false, 2} = Workflow.lineage_reachability(wf, first, {:call_request, :missing})

    unknown = Fact.new(value: :unknown, ancestry: {join.hash, first.hash})
    wf = put_fact(wf, unknown)
    assert :unknown = Workflow.join_contributions(wf, unknown)
    assert {false, 1} = Workflow.lineage_reachability(wf, unknown, {:fact, first.hash})
  end

  defp put_fact(wf, fact),
    do: Workflow.apply_event(wf, FactProduced.new(fact, producer_label: :produced, weight: 0))
end
