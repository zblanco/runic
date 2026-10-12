defmodule Runic.Workflow.ExecutionMatchPolicyTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  require Runic

  alias Runic.Identity
  alias Runic.Workflow
  alias Runic.Workflow.{Condition, Execution, RunnableDispatched, RunnableFailed}

  for emit_events? <- [false, true], async? <- [false, true] do
    test "expired deadlines stop eager predicates and hooks with events #{emit_events?} and async #{async?}" do
      owner = self()

      condition =
        condition(fn _ ->
          send(owner, :predicate_ran)
          true
        end)

      hook = fn _, _ ->
        send(owner, :hook_ran)
        :ok
      end

      workflow =
        workflow(condition)
        |> Map.put(:emit_events, unquote(emit_events?))
        |> Map.put(:before_hooks, %{condition.hash => [hook]})

      {workflow, execution} =
        Workflow.execute(workflow, :input,
          deadline_at: System.monotonic_time(:millisecond) - 1,
          async: unquote(async?)
        )

      assert execution.admission == :stopped
      assert execution.quiescent?

      assert [%{kind: :failed, node_name: :gate, error: {:deadline_exceeded, _}}] =
               execution.outcomes

      assert Execution.outputs(execution) == []
      refute_received :predicate_ran
      refute_received :hook_ran

      if unquote(emit_events?) do
        assert [%RunnableFailed{}] = workflow.runnable_events
      else
        assert workflow.runnable_events == []
      end
    end

    test "relative deadlines include eager predicate time with events #{emit_events?} and async #{async?}" do
      owner = self()

      condition =
        condition(fn _ ->
          send(owner, :predicate_started)
          Process.sleep(1_000)
          send(owner, :predicate_finished)
          true
        end)

      workflow = workflow(condition) |> Map.put(:emit_events, unquote(emit_events?))

      {_workflow, execution} =
        Workflow.execute(workflow, :input, deadline_ms: 100, async: unquote(async?))

      assert_received :predicate_started
      refute_received :predicate_finished
      assert execution.admission == :stopped
      assert [%{kind: :failed, node_name: :gate, error: {:timeout, _}}] = execution.outcomes
      assert Execution.outputs(execution) == []
    end
  end

  for mode <- [:retry, :fallback, :skip] do
    @tag match_policy_mode: mode
    test "eager matches honor #{mode} policy and record the terminal result", %{
      match_policy_mode: mode
    } do
      owner = self()
      counter = :counters.new(1, [])
      condition = condition(fn _ -> true end)

      hook = fn _, _ ->
        :counters.add(counter, 1, 1)
        if :counters.get(counter, 1) == 1, do: {:error, :transient}, else: :ok
      end

      policy =
        case mode do
          :retry ->
            %{max_retries: 1, backoff: :none}

          :fallback ->
            %{
              fallback: fn runnable, _ ->
                send(owner, :fallback_ran)
                runnable
              end
            }

          :skip ->
            %{on_failure: :skip}
        end

      workflow =
        workflow(condition)
        |> Workflow.enable_event_emission()
        |> Map.put(:before_hooks, %{condition.hash => [hook]})
        |> Workflow.set_scheduler_policies([{:gate, %{on_failure: :halt}}])

      {workflow, execution} =
        Workflow.execute(workflow, :input,
          scheduler_policies: [{:gate, policy}],
          scheduler_policies_mode: :replace
        )

      assert execution.admission == :open
      assert execution.quiescent?
      assert [%{node_name: :gate} = outcome | _] = execution.outcomes

      if mode == :skip do
        assert outcome.kind == :skipped
        assert outcome.failure_action == :skip
        assert Execution.outputs(execution) == []
        assert :counters.get(counter, 1) == 1

        assert [%RunnableFailed{failure_action: :skip}] =
                 Enum.filter(workflow.runnable_events, &is_struct(&1, RunnableFailed))
      else
        assert outcome.kind == :completed
        assert Execution.outputs(execution) == [true, {:accepted, :input}]
        assert :counters.get(counter, 1) == 2
        assert Execution.failures(execution) == []
      end

      if mode == :retry do
        assert outcome.attempt_id == Identity.derive(:attempt, [outcome.activation_id, 1])

        assert [0, 1] ==
                 workflow.runnable_events
                 |> Enum.filter(&(is_struct(&1, RunnableDispatched) and &1.node_name == :gate))
                 |> Enum.map(& &1.attempt)
      end

      if mode == :fallback, do: assert_received(:fallback_ran)
    end
  end

  test "eager matches use workflow policies without runtime overrides" do
    condition = condition(fn _ -> true end)
    hook = fn _, _ -> {:error, :failed} end

    workflow =
      workflow(condition)
      |> Map.put(:before_hooks, %{condition.hash => [hook]})
      |> Workflow.set_scheduler_policies([{:gate, %{on_failure: :skip}}])

    {_workflow, execution} = Workflow.execute(workflow, :input)

    assert [%{kind: :skipped, node_name: :gate}] = execution.outcomes
    assert execution.admission == :open
    assert execution.quiescent?
  end

  defp condition(work),
    do:
      Condition.new(
        work: work,
        arity: 1,
        name: :gate,
        hash: Identity.derive(:component_definition, [:gate])
      )

  defp workflow(condition) do
    Workflow.new()
    |> Workflow.add_step(condition)
    |> Workflow.add(Runic.step(fn value -> {:accepted, value} end, name: :reaction),
      to: condition
    )
  end
end
