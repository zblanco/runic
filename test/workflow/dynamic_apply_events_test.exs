defmodule Runic.Workflow.DynamicApplyEventsTest do
  use ExUnit.Case, async: true

  alias Runic.Workflow
  alias Runic.Workflow.ComponentAdded

  require Runic

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
