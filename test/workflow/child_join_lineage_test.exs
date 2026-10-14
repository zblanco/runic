defmodule Runic.Workflow.ChildJoinLineageTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  require Runic
  alias Runic.Workflow
  alias Runic.Workflow.{Call, ChildInvocation, Invokable, Join, PolicyDriver, SchedulerPolicy}
  alias Runic.TestSupport.ChildTargets

  defp definition(failure) do
    request =
      case failure do
        :request ->
          Runic.step(
            fn
              {:bad, _} -> raise "request failure"
              {:good, n} -> ChildInvocation.new(target: ChildTargets.delayed(:good), input: n)
            end,
            name: :request
          )

        :child ->
          Runic.step(
            fn {kind, n} -> ChildInvocation.new(target: ChildTargets.delayed(kind), input: n) end,
            name: :request
          )
      end

    Workflow.new()
    |> Workflow.add(Runic.step(fn n -> {:bad, n} end, name: :a))
    |> Workflow.add(Runic.step(fn n -> {:good, n} end, name: :b))
    |> Workflow.add(Call.new(request, name: :call),
      connections: [[from: {:a, :out}, to: :in], [from: {:b, :out}, to: :in]],
      input_mode: :any
    )
    |> Workflow.add(Runic.step(fn n -> n end, name: :other))
    |> Workflow.add(Runic.step(fn a, b -> {a, b} end, name: :joined), to: [:call, :other])
    |> Workflow.enable_event_emission()
  end

  for failure <- [:child, :request], last <- [:call, :other] do
    test "#{failure} skip preserves a completed sibling Join with #{last} arriving last, live and replay" do
      original = definition(unquote(failure))

      wf =
        Workflow.plan_eagerly(original, 6)
        |> advance(&(Map.get(&1.node, :name) == :a))
        |> advance(&(Map.get(&1.node, :name) == :b))

      wf =
        wf
        |> advance(&is_struct(&1.node, Runic.Workflow.InputBinding))
        |> advance(&is_struct(&1.node, Runic.Workflow.InputBinding))

      wf = advance(wf, &(&1.node.name == :call and &1.input_fact.value == {:good, 6}))
      wf = advance(wf, &is_struct(&1.node, Runic.Workflow.CallValue))

      wf =
        Enum.reduce([:g1, :g2, :g3], wf, fn name, acc ->
          advance(acc, &(Map.get(&1.node, :name) == name))
        end)

      wf =
        wf
        |> advance(&is_struct(&1.node, Runic.Workflow.InputBinding))
        |> advance(&is_struct(&1.node, Runic.Workflow.CallValue))
        |> advance(&is_struct(&1.node, Runic.Workflow.CallValue))

      wf = advance(wf, &(Map.get(&1.node, :name) == :other))
      order = if unquote(last) == :call, do: [6, 106], else: [106, 6]

      wf =
        Enum.reduce(order, wf, fn value, acc ->
          advance(acc, &(is_struct(&1.node, Join) and &1.input_fact.value == value))
        end)

      assert Enum.any?(Workflow.next_runnables(wf), fn {node, _} ->
               Map.get(node, :name) == :joined
             end)

      wf =
        case unquote(failure) do
          :request ->
            advance(
              wf,
              &(&1.node.name == :call and &1.input_fact.value == {:bad, 6}),
              %SchedulerPolicy{on_failure: :skip}
            )

          :child ->
            wf =
              advance(wf, &(&1.node.name == :call and &1.input_fact.value == {:bad, 6}))
              |> advance(&is_struct(&1.node, Runic.Workflow.CallValue))

            wf =
              Enum.reduce([:s1, :s2, :s3, :s4, :s5], wf, fn name, acc ->
                advance(acc, &(Map.get(&1.node, :name) == name))
              end)

            advance(wf, &(Map.get(&1.node, :name) == :s6), %SchedulerPolicy{on_failure: :skip})
        end

      replayed =
        Workflow.from_events(Workflow.build_log(original) ++ Enum.reverse(wf.uncommitted_events))

      for candidate <- [wf, replayed] do
        result = Workflow.react_until_satisfied(candidate)
        assert Workflow.raw_productions(result, :joined) == [{106, 6}]
      end
    end
  end

  test "independent ordinary any-input activations retain same-root suppression" do
    original =
      definition(:child)
      |> Workflow.add(Runic.step(fn n -> n end, name: :ordinary),
        connections: [[from: {:call, :out}, to: :in], [from: {:other, :out}, to: :in]],
        input_mode: :any
      )

    wf = Workflow.plan_eagerly(original, 6) |> advance(&(Map.get(&1.node, :name) == :other))
    ordinary = Workflow.get_component!(original, :ordinary)

    wf =
      advance(
        wf,
        &(is_struct(&1.node, Runic.Workflow.InputBinding) and
            &1.node.target_component_hash == ordinary.hash)
      )

    # Leave the ordinary independent branch pending while admitting only bad child.
    wf =
      wf
      |> advance(&(Map.get(&1.node, :name) == :a))
      |> advance(&is_struct(&1.node, Runic.Workflow.InputBinding))

    wf =
      advance(wf, &(&1.node.name == :call and &1.input_fact.value == {:bad, 6}))
      |> advance(&is_struct(&1.node, Runic.Workflow.CallValue))

    wf =
      Enum.reduce([:s1, :s2, :s3, :s4, :s5], wf, fn name, acc ->
        advance(acc, &(Map.get(&1.node, :name) == name))
      end)

    wf = advance(wf, &(Map.get(&1.node, :name) == :s6), %SchedulerPolicy{on_failure: :skip})
    # Suppression includes ordinary dependent activations, not just Join storage.
    assert [%{v1: %{value: 6}}] = Multigraph.in_edges(wf.graph, ordinary, by: :upstream_failed)

    replayed =
      Workflow.from_events(Workflow.build_log(original) ++ Enum.reverse(wf.uncommitted_events))

    assert [%{v1: %{value: 6}}] =
             Multigraph.in_edges(replayed.graph, ordinary, by: :upstream_failed)
  end

  defp advance(workflow, predicate, policy \\ nil) do
    {workflow, ready} = Workflow.prepare_for_dispatch(workflow)
    runnable = Enum.find(ready, predicate)
    assert runnable

    result =
      if policy,
        do: PolicyDriver.execute(runnable, policy),
        else: Invokable.execute(runnable.node, runnable)

    Workflow.apply_runnable(workflow, result)
  end
end
