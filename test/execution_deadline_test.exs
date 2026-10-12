defmodule Runic.ExecutionDeadlineTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  require Runic
  alias Runic.Workflow

  for emit_events? <- [false, true], async? <- [false, true] do
    test "an expired deadline prevents work with events #{emit_events?} and async #{async?}" do
      owner = self()

      workflow =
        Runic.workflow(
          steps: [
            Runic.step(
              fn value ->
                send(owner, :executed)
                value
              end,
              name: :must_not_run
            )
          ]
        )
        |> Map.put(:emit_events, unquote(emit_events?))

      result =
        Workflow.react_until_satisfied(workflow, :input,
          deadline_at: System.monotonic_time(:millisecond) - 1,
          async: unquote(async?)
        )

      refute_receive :executed
      assert Workflow.raw_productions(result) == []
      refute Workflow.is_runnable?(result)
    end
  end
end
