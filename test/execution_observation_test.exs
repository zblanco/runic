defmodule Runic.Workflow.ExecutionObservationTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  require Runic

  alias Runic.Workflow
  alias Runic.Workflow.Execution

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
    workflow =
      Runic.workflow(
        steps: [
          Runic.step(
            fn
              :first -> Process.exit(self(), :kill)
              value -> value
            end,
            name: :maybe_lost
          )
        ]
      )

    {workflow, first} = Workflow.execute(workflow, :first, async: true)
    {_workflow, second} = Workflow.execute(workflow, :second, async: true, max_concurrency: 2)

    assert [%{kind: :uncertain}] = Execution.failures(first)
    assert Execution.outputs(second) == [:second]
    assert Execution.failures(second) == []
  end
end
