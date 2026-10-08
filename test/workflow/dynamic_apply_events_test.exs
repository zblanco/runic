defmodule Runic.Workflow.DynamicApplyEventsTest do
  use ExUnit.Case, async: true

  alias Runic.Workflow
  alias Runic.Workflow.ComponentAdded

  require Runic

  test "multiple additions follow the producing event and precede their activations after a prefix" do
    seed = Runic.step(fn n -> n + 1 end, name: :seed)
    trigger = Runic.step(fn n -> n * 2 end, name: :trigger)
    left = Runic.step(fn n -> n + 10 end, name: :left)
    right = Runic.step(fn n -> n + 20 end, name: :right)

    hook = fn _, wf, _ ->
      wf |> Workflow.add(left, to: :trigger) |> Workflow.add(right, to: :trigger)
    end

    workflow =
      Runic.workflow(steps: [{seed, [trigger]}])
      |> Workflow.attach_after_hook(:trigger, hook)
      |> Workflow.enable_event_emission()

    build = Workflow.build_log(workflow)
    prefix = Workflow.react(workflow, 1)
    prefix_events = Enum.reverse(prefix.uncommitted_events)
    assert prefix_events != []
    expanded = Workflow.react(%{prefix | uncommitted_events: []})
    tail = Enum.reverse(expanded.uncommitted_events)
    assert [:left, :right] == for(%ComponentAdded{name: name} <- tail, do: name)

    produced =
      Enum.find_index(
        tail,
        &match?(
          %Runic.Workflow.Events.FactProduced{ancestry: {hash, _}} when hash == trigger.hash,
          &1
        )
      )

    additions =
      for {event, index} <- Enum.with_index(tail), match?(%ComponentAdded{}, event), do: index

    activations =
      for {%Runic.Workflow.Events.RunnableActivated{node_hash: hash}, index} <-
            Enum.with_index(tail),
          hash in [left.hash, right.hash],
          do: index

    assert is_integer(produced)
    assert length(activations) == 2
    assert produced < Enum.min(additions)
    assert Enum.max(additions) < Enum.min(activations)

    rebuilt =
      Workflow.from_events(build ++ prefix_events ++ tail) |> Workflow.react_until_satisfied()

    assert Enum.sort(Workflow.raw_productions(rebuilt)) == [2, 4, 14, 24]
  end

  test "component additions from the apply phase enter the durable event stream" do
    first = Runic.step(fn value -> value + 1 end, name: :first)
    second = Runic.step(fn value -> value * 2 end, name: :second)

    hook = fn _step, workflow, _fact -> Workflow.add(workflow, second, to: :first) end

    workflow =
      Workflow.new()
      |> Workflow.add(first)
      |> Workflow.attach_after_hook(:first, hook)
      |> Workflow.enable_event_emission()

    build_events = Workflow.build_log(workflow)
    workflow = Workflow.react(workflow, 2)

    assert Enum.any?(workflow.uncommitted_events, fn
             %ComponentAdded{name: :second, to: :first} -> true
             _event -> false
           end)

    restored =
      Workflow.from_events(build_events ++ Enum.reverse(workflow.uncommitted_events))

    assert Workflow.get_component(restored, :second)
    assert Workflow.is_runnable?(restored)

    completed = Workflow.react_until_satisfied(restored)
    assert 6 in Workflow.raw_productions(completed)
  end
end
