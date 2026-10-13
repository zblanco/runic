defmodule Runic.Workflow.ChildOccurrenceScopeTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  require Runic
  alias Runic.Workflow
  alias Runic.Workflow.{Call, ChildInvocation, Invokable, PolicyDriver, SchedulerPolicy}

  defp base do
    request =
      Runic.step(
        fn {kind, input} ->
          ChildInvocation.new(target: Runic.TestSupport.ChildTargets.delayed(kind), input: input)
        end,
        name: :request
      )

    Workflow.new()
    |> Workflow.add(Runic.step(fn n -> {:bad, n} end, name: :a))
    |> Workflow.add(Runic.step(fn n -> {:good, n} end, name: :b))
    |> Workflow.add(Call.new(request, name: :call),
      connections: [[from: {:a, :out}, to: :in], [from: {:b, :out}, to: :in]],
      input_mode: :any
    )
    |> Workflow.add(Runic.step(fn n -> n end, name: :sink), to: :call)
    |> Workflow.enable_event_emission()
  end

  for phase <- [:output_pending, :sink_pending, :sink_completed] do
    test "delayed skip preserves a sibling at #{phase} under the same root and replay" do
      original = base()

      wf =
        original
        |> Workflow.plan_eagerly(6)
        |> Workflow.react()
        |> Workflow.react()
        |> Workflow.react()
        |> Workflow.react()

      wf =
        Enum.reduce([:g1, :g2, :g3], wf, fn name, current ->
          advance(current, &(&1.node.name == name))
        end)

      wf = advance(wf, &is_struct(&1.node, Runic.Workflow.InputBinding))
      wf = advance(wf, &is_struct(&1.node, Runic.Workflow.CallValue))

      wf =
        case unquote(phase) do
          :output_pending ->
            wf

          :sink_pending ->
            advance(wf, &is_struct(&1.node, Runic.Workflow.CallValue))

          :sink_completed ->
            wf
            |> advance(&is_struct(&1.node, Runic.Workflow.CallValue))
            |> advance(&(&1.node.name == :sink))
        end

      wf =
        Enum.reduce([:s1, :s2, :s3, :s4, :s5], wf, fn name, current ->
          advance(current, &(&1.node.name == name))
        end)

      wf = advance(wf, &(&1.node.name == :s6), %SchedulerPolicy{on_failure: :skip})

      replayed =
        Workflow.from_events(Workflow.build_log(original) ++ Enum.reverse(wf.uncommitted_events))

      for current <- [wf, replayed] do
        complete = Workflow.react_until_satisfied(current)
        assert Workflow.raw_productions(complete, :call) == [106]
        assert Workflow.raw_productions(complete, :sink) == [106]
        assert not Workflow.is_runnable?(complete)
      end
    end
  end

  test "a missing child contribution leaves an all-input Join incomplete without fabricating output" do
    request =
      Runic.step(
        fn n ->
          ChildInvocation.new(target: Runic.TestSupport.ChildTargets.delayed(:bad), input: n)
        end,
        name: :request
      )

    original =
      Workflow.new()
      |> Workflow.add(Call.new(request, name: :call))
      |> Workflow.add(Runic.step(fn n -> n + 1 end, name: :other))
      |> Workflow.add(Runic.step(fn a, b -> {a, b} end, name: :joined), to: [:call, :other])
      |> Workflow.enable_event_emission()

    {wf, execution} =
      Workflow.execute(original, 6, scheduler_policies: [{:s6, %{on_failure: :skip}}])

    assert execution.quiescent?
    assert Workflow.raw_productions(wf, :joined) == []
    assert Multigraph.edges(wf.graph, by: :joined) != []

    restored =
      Workflow.from_events(Workflow.build_log(original) ++ Enum.reverse(wf.uncommitted_events))

    assert Workflow.raw_productions(restored, :joined) == []
    assert not Workflow.is_runnable?(restored)
  end

  test "halt still stops admission and can leave a sibling's ready delivery unaccepted" do
    original = base()

    wf =
      original
      |> Workflow.plan_eagerly(6)
      |> Workflow.react()
      |> Workflow.react()
      |> Workflow.react()
      |> Workflow.react()

    wf =
      Enum.reduce([:g1, :g2, :g3], wf, fn name, current ->
        advance(current, &(&1.node.name == name))
      end)

    wf =
      advance(wf, &is_struct(&1.node, Runic.Workflow.InputBinding))
      |> advance(&is_struct(&1.node, Runic.Workflow.CallValue))

    wf =
      Enum.reduce([:s1, :s2, :s3, :s4, :s5], wf, fn name, current ->
        advance(current, &(&1.node.name == name))
      end)

    runner = :"child_halt_#{System.unique_integer([:positive])}"
    start_supervised!({Runic.Runner, name: runner})

    {:ok, _} =
      Runic.Runner.start_workflow(runner, :wf, wf,
        resumed: true,
        executor: :inline,
        max_concurrency: 1,
        scheduler: Runic.TestSupport.PreferFailureScheduler
      )

    assert {:ok, %{status: :stopped, active_units: 0, causes: [%{kind: :failed}]}} =
             Runic.Runner.admission_status(runner, :wf)

    {:ok, stopped} = Runic.Runner.get_workflow(runner, :wf)
    assert Workflow.raw_productions(stopped, :sink) == []
    assert Workflow.is_runnable?(stopped)
  end

  defp advance(wf, predicate, policy \\ nil) do
    {wf, ready} = Workflow.prepare_for_dispatch(wf)
    runnable = Enum.find(ready, predicate)
    assert runnable, "expected controlled child activation"

    result =
      if policy,
        do: PolicyDriver.execute(runnable, policy),
        else: Invokable.execute(runnable.node, runnable)

    Workflow.apply_runnable(wf, result)
  end
end
