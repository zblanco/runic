defmodule Runic.Workflow.ChildJoinInputScopeTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  require Runic
  alias Runic.Workflow
  alias Runic.Workflow.{Call, ChildInvocation, Invokable, PolicyDriver, SchedulerPolicy}
  alias Runic.TestSupport.{ChildTargets, OrdinaryComponent}

  defp forward do
    request =
      Runic.step(
        fn n ->
          target =
            if n == 6,
              do: ChildTargets.long_failure(),
              else: OrdinaryComponent.new(:success, :add, 100)

          ChildInvocation.new(target: target, input: n)
        end,
        name: :request
      )

    base = Workflow.new() |> Workflow.add(Call.new(request, name: :call))

    {base, _} =
      Enum.reduce([:o1, :o2, :o3, :o4, :o5, :o6, :o7, :o8], {base, nil}, fn name, {wf, parent} ->
        node = OrdinaryComponent.new(name, :data, 1)
        {Workflow.add(wf, node, if(parent, do: [to: parent], else: [])), name}
      end)

    Workflow.add(base, Runic.step(fn a, b -> {a, b} end, name: :joined), to: [:call, :o8])
    |> Workflow.enable_event_emission()
  end

  defp reverse do
    request =
      Runic.step(
        fn {kind, n} ->
          target =
            if kind == :bad and n == 6,
              do: ChildTargets.long_failure(),
              else: OrdinaryComponent.new(:success, :add, 100)

          ChildInvocation.new(target: target, input: n)
        end,
        name: :request
      )

    Workflow.new()
    |> Workflow.add(Runic.step(fn n -> {:good, n} end, name: :a))
    |> Workflow.add(Runic.step(fn n -> {:bad, n} end, name: :b))
    |> Workflow.add(Call.new(request, name: :call),
      connections: [[from: {:a, :out}, to: :in], [from: {:b, :out}, to: :in]],
      input_mode: :any
    )
    |> Workflow.add(Runic.rule(fn n when n != 6 -> n end, name: :other))
    |> Workflow.add(Runic.step(fn n -> n end, name: :plain), to: :call)
    |> Workflow.add(Runic.step(fn a, b -> {a, b} end, name: :joined, inputs: [a: [], b: []]),
      connections: [[from: {:call, :out}, to: :a], [from: {:other, :out}, to: :b]]
    )
    |> Workflow.enable_event_emission()
  end

  for direction <- [:forward, :reverse] do
    test "#{direction} stale contribution never pairs across three execution inputs, live or replay" do
      original = unquote(direction)()

      for recover? <- [false, true] do
        {first, scope} =
          Workflow.execute(original, 6, scheduler_policies: [{:b12, %{on_failure: :skip}}])

        assert scope.quiescent?
        assert Workflow.raw_productions(first, :joined) == []

        if unquote(direction) == :reverse do
          assert Workflow.raw_productions(first, :plain) == [106]
          assert Multigraph.edges(first.graph, by: :joined) != []
        else
          assert Multigraph.edges(first.graph, by: :joined) == []
          assert Multigraph.edges(first.graph, by: :upstream_failed) != []
        end

        first = if recover?, do: replay(original, first), else: first
        {second, _} = Workflow.execute(first, 10)
        assert Workflow.raw_productions(second, :joined) == [{110, 10}]
        second = if recover?, do: replay(original, second), else: second
        {third, _} = Workflow.execute(second, 20)
        assert Enum.sort(Workflow.raw_productions(third, :joined)) == [{110, 10}, {120, 20}]
      end
    end
  end

  for phase <- [:entry_pending, :output_pending, :sink_pending] do
    test "request skip preserves attached sibling at #{phase} before attachment of the failed request" do
      request =
        Runic.step(
          fn
            {:bad, _} -> raise "request unavailable"
            {:good, n} -> ChildInvocation.new(target: ChildTargets.delayed(:good), input: n)
          end,
          name: :request
        )

      original =
        Workflow.new()
        |> Workflow.add(Runic.step(fn n -> {:bad, n} end, name: :a))
        |> Workflow.add(Runic.step(fn n -> {:good, n} end, name: :b))
        |> Workflow.add(Call.new(request, name: :call),
          connections: [[from: {:a, :out}, to: :in], [from: {:b, :out}, to: :in]],
          input_mode: :any
        )
        |> Workflow.add(Runic.step(fn n -> n end, name: :sink), to: :call)
        |> Workflow.enable_event_emission()

      wf = original |> Workflow.plan_eagerly(6) |> Workflow.react() |> Workflow.react()
      wf = advance(wf, &(&1.node.name == :call and &1.input_fact.value == {:good, 6}))

      wf =
        case unquote(phase) do
          :entry_pending ->
            wf

          _ ->
            wf = advance(wf, &is_struct(&1.node, Runic.Workflow.CallValue))

            wf =
              Enum.reduce([:g1, :g2, :g3], wf, fn name, acc ->
                advance(acc, &(Map.get(&1.node, :name) == name))
              end)

            wf =
              advance(wf, &is_struct(&1.node, Runic.Workflow.InputBinding))
              |> advance(&is_struct(&1.node, Runic.Workflow.CallValue))

            if unquote(phase) == :sink_pending,
              do: advance(wf, &is_struct(&1.node, Runic.Workflow.CallValue)),
              else: wf
        end

      wf =
        advance(
          wf,
          &(&1.node.name == :call and &1.input_fact.value == {:bad, 6}),
          %SchedulerPolicy{on_failure: :skip}
        )

      for current <- [wf, replay(original, wf)] do
        complete = Workflow.react_until_satisfied(current)
        assert Workflow.raw_productions(complete, :call) == [106]
        assert Workflow.raw_productions(complete, :sink) == [106]
      end
    end
  end

  test "upstream non-Call failure retains native same-root suppression" do
    request =
      Runic.step(
        fn {:good, n} -> ChildInvocation.new(target: ChildTargets.delayed(:good), input: n) end,
        name: :request
      )

    original =
      Workflow.new()
      |> Workflow.add(OrdinaryComponent.new(:a, :failure, :bad))
      |> Workflow.add(Runic.step(fn n -> {:good, n} end, name: :b))
      |> Workflow.add(Call.new(request, name: :call),
        connections: [[from: {:a, :out}, to: :in], [from: {:b, :out}, to: :in]],
        input_mode: :any
      )
      |> Workflow.add(Runic.step(fn n -> n end, name: :sink), to: :call)
      |> Workflow.enable_event_emission()

    wf =
      Workflow.plan_eagerly(original, 6)
      |> advance(&(&1.node.name == :b))
      |> advance(&is_struct(&1.node, Runic.Workflow.InputBinding))
      |> advance(&(Map.get(&1.node, :name) == :call))

    wf = advance(wf, &(Map.get(&1.node, :name) == :a), %SchedulerPolicy{on_failure: :skip})

    for current <- [wf, replay(original, wf)] do
      complete = Workflow.react_until_satisfied(current)
      assert Workflow.raw_productions(complete, :call) == []
      assert Workflow.raw_productions(complete, :sink) == []
    end
  end

  for direction <- [:forward, :reverse] do
    test "Runner.start_execution keeps #{direction} Join roots separate across repeated inputs" do
      runner = :"join_roots_#{System.unique_integer([:positive])}"
      start_supervised!({Runic.Runner, name: runner})
      original = unquote(direction)()
      {:ok, _} = Runic.Runner.start_workflow(runner, :wf, original)

      for input <- [6, 10, 20] do
        {:ok, id} =
          Runic.Runner.start_execution(runner, :wf, input,
            scheduler_policies: [{:b12, %{on_failure: :skip}}]
          )

        {:ok, observed} = Runic.Runner.await_execution(runner, :wf, id)
        assert observed.quiescent?
      end

      {:ok, result} = Runic.Runner.get_workflow(runner, :wf)
      assert Enum.sort(Workflow.raw_productions(result, :joined)) == [{110, 10}, {120, 20}]
    end
  end

  test "lazy FactRef-only old contribution cannot pair with a new execution root" do
    original = reverse()
    {first, _} = Workflow.execute(original, 6, scheduler_policies: [{:b12, %{on_failure: :skip}}])
    runner = :"lazy_join_roots_#{System.unique_integer([:positive])}"
    start_supervised!({Runic.Runner, name: runner, store: Runic.TestSupport.SnapshotTailStore})
    {store, state} = Runic.Runner.get_store(runner)
    events = Enum.reverse(first.uncommitted_events)

    for %Runic.Workflow.Events.FactProduced{hash: hash, value: value} <- events,
        do: store.save_fact(hash, value, state)

    stripped =
      Enum.map(events, fn
        %Runic.Workflow.Events.FactProduced{} = event -> %{event | value: nil}
        event -> event
      end)

    {:ok, _} = store.append(:wf, Workflow.build_log(original) ++ stripped, state)
    {:ok, _} = Runic.Runner.resume(runner, :wf, rehydration: :lazy)
    {:ok, resumed} = Runic.Runner.get_workflow(runner, :wf)

    facts =
      Enum.filter(
        Multigraph.vertices(resumed.graph),
        &(is_struct(&1, Runic.Workflow.Fact) or is_struct(&1, Runic.Workflow.FactRef))
      )

    assert facts != []
    assert Enum.all?(facts, &is_struct(&1, Runic.Workflow.FactRef))

    for input <- [10, 20] do
      {:ok, id} = Runic.Runner.start_execution(runner, :wf, input)
      {:ok, observed} = Runic.Runner.await_execution(runner, :wf, id)
      assert observed.quiescent?
    end

    {:ok, result} = Runic.Runner.get_workflow(runner, :wf)
    assert Enum.sort(Workflow.raw_productions(result, :joined)) == [{110, 10}, {120, 20}]
  end

  defp replay(original, runtime),
    do:
      Workflow.from_events(
        Workflow.build_log(original) ++ Enum.reverse(runtime.uncommitted_events)
      )
      |> Workflow.enable_event_emission()

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
