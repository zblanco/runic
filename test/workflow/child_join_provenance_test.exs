defmodule Runic.Workflow.ChildJoinProvenanceTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  require Runic
  alias Runic.Workflow

  alias Runic.Workflow.{
    Call,
    ChildInvocation,
    Fact,
    Invokable,
    Join,
    PolicyDriver,
    SchedulerPolicy
  }

  alias Runic.Workflow.Events.{FactProduced, JoinCompleted}
  alias Runic.TestSupport.ChildTargets

  defp emitting do
    request =
      Runic.step(fn n -> ChildInvocation.new(target: ChildTargets.emit_then_fail(), input: n) end,
        name: :request
      )

    Workflow.new()
    |> Workflow.add(Call.new(request, name: :call))
    |> Workflow.add(Runic.step(fn n -> n end, name: :other))
    |> Workflow.add(Runic.step(fn a, b -> {a, b} end, name: :joined), to: [:call, :other])
    |> Workflow.add(Runic.step(fn n -> n end, name: :after_call), to: :call)
    |> Workflow.enable_event_emission()
  end

  for last <- [:call, :other] do
    test "own emitted contribution is suppressed when #{last} completes Join last, full and ref replay" do
      original = emitting()

      wf =
        Workflow.plan_eagerly(original, 6)
        |> advance(&(Map.get(&1.node, :name) == :call))
        |> advance(&is_struct(&1.node, Runic.Workflow.CallValue))
        |> advance(&(Map.get(&1.node, :name) == :left))
        |> advance(&is_struct(&1.node, Runic.Workflow.InputBinding))
        |> advance(&(Map.get(&1.node, :name) == :selected))
        |> advance(&is_struct(&1.node, Runic.Workflow.InputBinding))
        |> advance(&is_struct(&1.node, Runic.Workflow.CallValue))
        |> advance(&is_struct(&1.node, Runic.Workflow.CallValue))
        |> advance(&(Map.get(&1.node, :name) == :other))

      order = if unquote(last) == :call, do: [6, 7], else: [7, 6]

      wf =
        Enum.reduce(order, wf, fn value, current ->
          advance(current, &(is_struct(&1.node, Join) and &1.input_fact.value == value))
        end)

      failure =
        executed(wf, &(Map.get(&1.node, :name) == :right), %SchedulerPolicy{on_failure: :skip})

      live = Workflow.apply_runnable(wf, failure)

      for candidate <- [live, replay(original, live, :full), replay(original, live, :ref)] do
        assert Workflow.raw_productions(candidate, :joined) == []
        assert Workflow.raw_productions(candidate, :after_call) == []
        assert not Workflow.is_runnable?(candidate)

        [edge] =
          Multigraph.in_edges(candidate.graph, Workflow.get_component!(candidate, :joined),
            by: :upstream_failed
          )

        assert {:known, [_, _]} = Workflow.join_contributions(candidate, edge.v1)
      end
    end
  end

  for last <- [:x, :other] do
    test "purely independent any-input Join is suppressed with #{last} last, full and ref replay" do
      request = Runic.step(fn _ -> raise "request failure" end, name: :request)

      original =
        Workflow.new()
        |> Workflow.add(Call.new(request, name: :call))
        |> Workflow.add(Runic.step(fn n -> n + 1000 end, name: :y))
        |> Workflow.add(Runic.step(fn n -> n end, name: :other))
        |> Workflow.add(Runic.step(fn n -> n end, name: :x),
          connections: [[from: {:call, :out}, to: :in], [from: {:y, :out}, to: :in]],
          input_mode: :any
        )
        |> Workflow.add(Runic.step(fn a, b -> {a, b} end, name: :joined), to: [:x, :other])
        |> Workflow.add(Runic.step(fn n -> n end, name: :ordinary_x), to: :x)
        |> Workflow.enable_event_emission()

      wf =
        Workflow.plan_eagerly(original, 6)
        |> advance(&(Map.get(&1.node, :name) == :y))
        |> advance(&is_struct(&1.node, Runic.Workflow.InputBinding))
        |> advance(&(Map.get(&1.node, :name) == :x))
        |> advance(&(Map.get(&1.node, :name) == :other))

      order = if unquote(last) == :x, do: [6, 1006], else: [1006, 6]

      wf =
        Enum.reduce(order, wf, fn value, current ->
          advance(current, &(is_struct(&1.node, Join) and &1.input_fact.value == value))
        end)

      wf = advance(wf, &(Map.get(&1.node, :name) == :call), %SchedulerPolicy{on_failure: :skip})

      for candidate <- [wf, replay(original, wf, :full), replay(original, wf, :ref)] do
        assert Workflow.raw_productions(candidate, :joined) == []
        assert Workflow.raw_productions(candidate, :ordinary_x) == []
        assert not Workflow.is_runnable?(candidate)
      end
    end
  end

  test "repeated same-root Join completions record only their selected inputs, not historical satisfied edges" do
    a = Runic.step(fn n -> n end, name: :a)
    b = Runic.step(fn n -> n end, name: :b)

    original =
      Workflow.new()
      |> Workflow.add(a)
      |> Workflow.add(b)
      |> Workflow.add(Runic.step(fn x, y -> {x, y} end, name: :out), to: [:a, :b])
      |> Workflow.enable_event_emission()

    join = Enum.find(Multigraph.vertices(original.graph), &is_struct(&1, Join))
    root = Fact.new(value: :root)
    wf = produced(original, root, :input)

    pairs =
      for {left, right} <- [{11, 21}, {12, 22}],
          do: [
            Fact.new(value: left, ancestry: {a.hash, root.hash}),
            Fact.new(value: right, ancestry: {b.hash, root.hash})
          ]

    wf =
      Enum.reduce(List.flatten(pairs), wf, fn fact, current ->
        current = produced(current, fact, :produced)
        {:ok, work} = Invokable.prepare(join, current, fact)
        Workflow.apply_runnable(current, Invokable.execute(join, work))
      end)

    completions = for %JoinCompleted{} = event <- Enum.reverse(wf.uncommitted_events), do: event

    assert Enum.map(completions, & &1.contribution_fact_hashes) ==
             Enum.map(pairs, &Enum.map(&1, fn f -> f.hash end))

    assert length(Multigraph.in_edges(wf.graph, join, by: :join_satisfied)) == 4

    for candidate <- [wf, replay(original, wf, :full), replay(original, wf, :ref)],
        {event, pair} <- Enum.zip(completions, pairs) do
      result = Map.fetch!(candidate.graph.vertices, event.result_fact_hash)
      assert {:known, inputs} = Workflow.join_contributions(candidate, result)
      assert Enum.map(inputs, & &1.hash) == Enum.map(pair, & &1.hash)
    end
  end

  test "old JoinCompleted events without contribution hashes remain unknown and fail closed on same-root pending work" do
    original = emitting()

    wf =
      Workflow.plan_eagerly(original, 6)
      |> advance(&(Map.get(&1.node, :name) == :call))
      |> advance(&is_struct(&1.node, Runic.Workflow.CallValue))
      |> advance(&(Map.get(&1.node, :name) == :left))
      |> advance(&is_struct(&1.node, Runic.Workflow.InputBinding))
      |> advance(&(Map.get(&1.node, :name) == :selected))
      |> advance(&is_struct(&1.node, Runic.Workflow.InputBinding))
      |> advance(&is_struct(&1.node, Runic.Workflow.CallValue))
      |> advance(&is_struct(&1.node, Runic.Workflow.CallValue))
      |> advance(&(Map.get(&1.node, :name) == :other))

    wf =
      advance(wf, &(is_struct(&1.node, Join) and &1.input_fact.value == 7))
      |> advance(&(is_struct(&1.node, Join) and &1.input_fact.value == 6))

    events =
      Enum.reverse(wf.uncommitted_events)
      |> Enum.map(fn
        %JoinCompleted{} = event -> Map.delete(event, :contribution_fact_hashes)
        event -> event
      end)

    legacy = Workflow.from_events(Workflow.build_log(original) ++ events)

    [edge] =
      Multigraph.in_edges(legacy.graph, Workflow.get_component!(legacy, :joined), by: :runnable)

    assert Workflow.join_contributions(legacy, edge.v1) == :unknown

    failure =
      executed(wf, &(Map.get(&1.node, :name) == :right), %SchedulerPolicy{on_failure: :skip})

    legacy = Workflow.apply_runnable(legacy, failure)
    assert not Workflow.is_runnable?(legacy)
    assert Workflow.raw_productions(legacy, :joined) == []
  end

  defp produced(wf, fact, label) do
    event = FactProduced.new(fact, producer_label: label, weight: 0)
    updated = Workflow.apply_event(wf, event)
    %{updated | uncommitted_events: [event | updated.uncommitted_events]}
  end

  defp replay(original, runtime, mode) do
    events = Enum.reverse(runtime.uncommitted_events)

    events =
      if mode == :ref,
        do:
          Enum.map(events, fn
            %FactProduced{} = event -> %{event | value: nil}
            event -> event
          end),
        else: events

    Workflow.from_events(Workflow.build_log(original) ++ events, nil, fact_mode: mode)
  end

  defp executed(wf, predicate, policy) do
    {_, ready} = Workflow.prepare_for_dispatch(wf)
    work = Enum.find(ready, predicate)
    assert work
    if policy, do: PolicyDriver.execute(work, policy), else: Invokable.execute(work.node, work)
  end

  defp advance(wf, predicate, policy \\ nil),
    do: Workflow.apply_runnable(wf, executed(wf, predicate, policy))
end
