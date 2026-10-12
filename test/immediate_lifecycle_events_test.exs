defmodule Runic.Workflow.ImmediateLifecycleEventsTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  require Runic
  alias Runic.Workflow
  alias Runic.Workflow.{RunnableCompleted, RunnableDispatched, RunnableFailed}

  for async? <- [false, true] do
    test "immediate failure records its policy events with async #{async?}" do
      node = Runic.step(fn _ -> raise "failed attempt" end, name: :attempt)

      workflow =
        Workflow.new()
        |> Workflow.add(node)
        |> Workflow.enable_event_emission()
        |> Workflow.react_until_satisfied(1,
          async: unquote(async?),
          scheduler_policies: [{:default, %{max_retries: 1, backoff: :none}}]
        )

      assert [
               %RunnableDispatched{} = first,
               %RunnableDispatched{} = second,
               %RunnableFailed{} = failed
             ] = workflow.runnable_events

      assert first.activation_id == second.activation_id
      refute first.attempt_id == second.attempt_id
      assert failed.attempt_id == second.attempt_id
      assert failed.attempts == 2
      assert failed.error.message == "failed attempt"
      assert Workflow.raw_productions(workflow) == []
    end

    test "immediate success records completion without explicit policy with async #{async?}" do
      workflow =
        Workflow.new()
        |> Workflow.add(Runic.step(fn value -> value + 1 end, name: :attempt))
        |> Workflow.enable_event_emission()
        |> Workflow.react_until_satisfied(1, async: unquote(async?))

      assert [%RunnableDispatched{} = dispatched, %RunnableCompleted{} = completed] =
               workflow.runnable_events

      assert dispatched.attempt_id == completed.attempt_id
      assert completed.result_fact.value == 2
      assert Workflow.raw_productions(workflow, :attempt) == [2]
    end
  end

  test "ordinary immediate execution keeps event recording disabled" do
    workflow =
      Workflow.new()
      |> Workflow.add(Runic.step(fn value -> value + 1 end))
      |> Workflow.react_until_satisfied(1,
        scheduler_policies: [{:default, %{max_retries: 1}}]
      )

    assert workflow.runnable_events == []
    assert Workflow.raw_productions(workflow) == [2]
  end

  test "recorded outer loss preserves its reason and the unresolved activation on replay" do
    node = Runic.step(fn _ -> Process.exit(self(), :kill) end, name: :lost)

    workflow =
      Workflow.new()
      |> Workflow.add(node)
      |> Workflow.enable_event_emission()
      |> Workflow.react_until_satisfied(1, async: true)

    assert [
             %{
               __struct__: Runic.Workflow.ExecutionUncertain,
               reason: :killed,
               unit_kind: :runnable,
               runnable_ids: [id]
             }
           ] = workflow.runnable_events

    [pending] = Workflow.prepared_runnables(workflow)
    assert pending.id == id
    assert Workflow.raw_productions(workflow) == []

    replayed =
      Workflow.from_events(
        Workflow.build_log(workflow) ++
          Enum.reverse(workflow.uncommitted_events) ++
          workflow.runnable_events
      )

    assert replayed.runnable_events == workflow.runnable_events
    assert [%{id: ^id}] = Workflow.prepared_runnables(replayed)
  end
end
