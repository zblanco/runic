defmodule Runic.Workflow.ExecutionObservationTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  require Runic

  alias Runic.Workflow
  alias Runic.Workflow.{Execution, RunnableDispatched, RunnableFailed}

  for async? <- [false, true] do
    test "an expired initial deadline is observed with async #{async?}" do
      owner = self()

      workflow =
        Workflow.new()
        |> Workflow.add(
          Runic.step(
            fn value ->
              send(owner, :executed)
              value
            end,
            name: :deadline
          )
        )
        |> Workflow.enable_event_emission()

      {workflow, execution} =
        Workflow.execute(workflow, :input,
          async: unquote(async?),
          deadline_at: System.monotonic_time(:millisecond) - 1
        )

      assert execution.status == :stopped
      assert execution.admission == :stopped
      assert execution.quiescent?
      assert execution.active == []
      assert execution.ready == []

      assert [%{kind: :failed, node_name: :deadline, error: {:deadline_exceeded, _}} = outcome] =
               Execution.failures(execution)

      assert outcome.attempt_id == Runic.Identity.derive(:attempt, [outcome.activation_id, 0])
      assert Execution.outputs(execution) == []
      assert [%RunnableFailed{}] = workflow.runnable_events
      refute_received :executed
    end

    test "a deadline reached before retry is observed with async #{async?}" do
      owner = self()
      deadline_at = System.monotonic_time(:millisecond) + 1_000

      retry_if = fn _error ->
        # Wait for the actual deadline, so the next attempt fails before dispatch.
        receive do
        after
          max(deadline_at - System.monotonic_time(:millisecond) + 1, 0) -> true
        end
      end

      workflow =
        Workflow.new()
        |> Workflow.add(
          Runic.step(
            fn _ ->
              send(owner, :attempted)
              raise "retry after failure"
            end,
            name: :retry_deadline
          )
        )
        |> Workflow.enable_event_emission()

      {workflow, execution} =
        Workflow.execute(workflow, :input,
          async: unquote(async?),
          deadline_at: deadline_at,
          scheduler_policies: [
            {:default, %{max_retries: 1, backoff: :none, retry_if: retry_if}}
          ]
        )

      assert_received :attempted
      refute_received :attempted
      assert execution.status == :stopped
      assert execution.admission == :stopped
      assert execution.quiescent?
      assert execution.active == []
      assert execution.ready == []

      assert [
               %{kind: :failed, node_name: :retry_deadline, error: {:deadline_exceeded, _}} =
                 outcome
             ] =
               Execution.failures(execution)

      assert outcome.attempt_id == Runic.Identity.derive(:attempt, [outcome.activation_id, 1])
      assert Execution.outputs(execution) == []

      assert [%RunnableDispatched{} = dispatched, %RunnableFailed{} = failed] =
               workflow.runnable_events

      refute dispatched.attempt_id == failed.attempt_id
      assert outcome.attempt_id == failed.attempt_id
    end

    test "a custom skipped result is observed with async #{async?}" do
      node = %Runic.Test.SkippedNode{
        name: :custom_skip,
        hash: Runic.Identity.derive(:component_definition, [:custom_skip])
      }

      workflow = Workflow.new() |> Workflow.add_step(node)
      {workflow, execution} = Workflow.execute(workflow, :input, async: unquote(async?))

      assert [%{kind: :skipped, node_name: :custom_skip, error: nil}] = execution.outcomes
      assert Execution.outputs(execution) == []
      assert execution.admission == :open
      assert execution.status == :quiescent
      assert execution.quiescent?
      assert execution.ready == []
      refute Workflow.is_runnable?(workflow)
      assert workflow.runnable_events == []
      refute workflow.emit_events
    end
  end

  test "run_context is applied before conditions and replaces old values" do
    rule =
      Runic.rule(
        condition: fn value -> value > context(:threshold) end,
        reaction: fn value -> {:accepted, value} end,
        name: :threshold_rule
      )

    workflow = Runic.transmute(rule)

    for initial_context <- [%{}, %{_global: %{threshold: 20}}] do
      workflow = Workflow.put_run_context(workflow, initial_context)

      {_workflow, execution} =
        Workflow.execute(workflow, 10, run_context: %{_global: %{threshold: 5}})

      assert Execution.outputs(execution) == [{:accepted, 10}]
      assert Execution.failures(execution) == []
      assert execution.quiescent?
    end
  end

  test "a retained planning failure stops the new scope without adding an older outcome" do
    rule = Runic.rule(fn value when is_atom(value) -> value end, name: :gate)

    workflow =
      Runic.workflow(rules: [rule], steps: [Runic.step(fn value -> value end, name: :echo)])

    [condition] = Workflow.get_component(workflow, {:gate, :condition})

    hook = fn _, context ->
      if context.input_fact.value == :old, do: {:error, :old_failed}, else: :ok
    end

    workflow = %{workflow | before_hooks: %{condition.hash => [hook]}}
    workflow = Workflow.plan(workflow, :old)
    {workflow, execution} = Workflow.execute(workflow, :new)

    assert execution.status == :stopped
    assert execution.admission == :stopped
    assert execution.quiescent?
    assert execution.active == []
    assert Enum.any?(execution.ready, &(&1.node_name == :echo))
    assert execution.outcomes == []
    assert execution.failures == []
    assert Workflow.is_runnable?(workflow)
  end

  test "a caller can supply the execution correlation identity" do
    execution_id = Runic.Identity.derive(:execution, [:customer_request, "request-123"])
    workflow = Runic.workflow(steps: [Runic.step(& &1, name: :echo)])

    {_workflow, execution} =
      Workflow.execute(workflow, :value, execution_id: execution_id)

    assert execution.id == execution_id
    assert execution.input_id.domain == :input_command
    assert execution.input_fact_id.domain == :fact_occurrence
    assert Enum.all?(execution.outcomes, &(&1.execution_id == execution_id))
  end

  test "immediate success returns scoped outcomes without enabling durable events" do
    workflow =
      Runic.workflow(
        steps: [
          {Runic.step(&(&1 + 1), name: :add), [Runic.step(&(&1 * 2), name: :double)]}
        ]
      )

    {workflow, execution} = Workflow.execute(workflow, 2)

    assert execution.status == :quiescent
    assert execution.admission == :open
    assert execution.quiescent?
    assert execution.active == []
    assert execution.ready == []

    assert Enum.map(execution.outcomes, &{&1.sequence, &1.kind, &1.node_name}) == [
             {1, :completed, :add},
             {2, :completed, :double}
           ]

    assert Execution.outputs(execution) == [3, 6]
    assert execution.persistence.status == :not_managed
    assert workflow.runnable_events == []
    refute workflow.emit_events
  end

  test "equal repeated inputs have distinct occurrence and outcome identities" do
    workflow = Runic.workflow(steps: [Runic.step(& &1, name: :echo)])
    {workflow, first} = Workflow.execute(workflow, :same)
    {_workflow, second} = Workflow.execute(workflow, :same)

    refute first.id == second.id
    refute first.input_id == second.input_id
    refute first.input_fact_id == second.input_fact_id
    refute hd(first.outcomes).id == hd(second.outcomes).id
    assert Execution.outputs(first) == [:same]
    assert Execution.outputs(second) == [:same]
  end

  test "immediate failure stops only its call scope" do
    workflow =
      Runic.workflow(
        steps: [
          Runic.step(
            fn value ->
              if value == :fail, do: raise("failed")
              value
            end,
            name: :maybe
          )
        ]
      )

    {workflow, failed} = Workflow.execute(workflow, :fail)

    assert failed.status == :stopped
    assert failed.admission == :stopped
    assert failed.quiescent?

    assert [%{kind: :failed, error: %RuntimeError{message: "failed"}}] =
             Execution.failures(failed)

    {_workflow, succeeded} = Workflow.execute(workflow, :ok)
    assert succeeded.status == :quiescent
    assert Execution.outputs(succeeded) == [:ok]
  end

  test "async executor loss is uncertain and keeps ready work" do
    workflow =
      Runic.workflow(steps: [Runic.step(fn _ -> Process.exit(self(), :kill) end, name: :lost)])

    {workflow, execution} = Workflow.execute(workflow, :input, async: true)

    assert execution.status == :stopped
    assert execution.quiescent?
    assert [%{kind: :uncertain, error: :killed}] = Execution.failures(execution)
    assert [%{node_name: :lost}] = execution.ready
    assert Workflow.is_runnable?(workflow)
  end

  test "a later immediate scope excludes outcomes from retained earlier work" do
    owner = self()

    workflow =
      Runic.workflow(
        steps: [
          Runic.step(
            fn value ->
              send(owner, {:started, value, self()})
              receive do: (:release -> :ok)
              if value == :first, do: Process.exit(self(), :kill), else: value
            end,
            name: :maybe_lost
          )
        ]
      )

    first_call = Task.async(fn -> Workflow.execute(workflow, :first, async: true) end)
    assert_receive {:started, :first, first_pid}, 2_000
    send(first_pid, :release)
    {workflow, first} = Task.await(first_call, 2_000)

    second_call =
      Task.async(fn -> Workflow.execute(workflow, :second, async: true, max_concurrency: 2) end)

    assert_receive {:started, :first, retained_pid}, 2_000
    assert_receive {:started, :second, second_pid}, 2_000
    send(retained_pid, :release)
    send(second_pid, :release)
    {_workflow, second} = Task.await(second_call, 2_000)

    assert [%{kind: :uncertain}] = Execution.failures(first)
    assert Execution.outputs(second) == [:second]
    assert Execution.failures(second) == []
    assert Enum.all?(second.outcomes, &(&1.kind == :completed))
    assert second.admission == :stopped
    assert second.status == :stopped
    assert second.quiescent?
    assert second.active == []
    assert second.ready == []
  end
end
