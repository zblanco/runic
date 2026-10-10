defmodule Runic.Workflow.Execution.OutcomeTest do
  use ExUnit.Case, async: true

  alias Runic.Identity
  alias Runic.Runner.Promise
  alias Runic.Workflow
  alias Runic.Workflow.{CausalContext, Execution, Fact, Invokable, Runnable, Step}
  alias Runic.Workflow.Execution.Outcome

  test "opaque runnable IDs remain metadata for completed, skipped, and uncertain outcomes" do
    execution_id = execution_id()

    for id <- [make_ref(), self(), fn -> :opaque end] do
      runnable = runnable(id)
      activation_id = Runnable.runnable_id(runnable.node, runnable.input_fact)
      attempt_id = Identity.derive(:attempt, [activation_id, 0])

      completed = Outcome.from_runnable(execution_id, Runnable.complete(runnable, :value, []), 1)
      skipped = Outcome.from_runnable(execution_id, Runnable.skip(runnable, []), 2)
      uncertain = Outcome.uncertain(execution_id, {:runnable, runnable}, :executor_lost, 3)

      for outcome <- [completed, skipped, uncertain] do
        assert %Identity{domain: :event} = outcome.id
        assert outcome.runnable_ids == [id]
        assert outcome.activation_id == activation_id
        assert outcome.order_key == {0, activation_id}
      end

      assert completed.kind == :completed
      assert completed.result == :value
      assert completed.attempt_id == attempt_id
      assert skipped.kind == :skipped
      assert skipped.failure_action == :skip
      assert skipped.attempt_id == attempt_id
      assert uncertain.kind == :uncertain
      assert uncertain.error == :executor_lost
      assert uncertain.attempt_id == nil
    end
  end

  test "outcome identity uses the logical activation instead of the opaque runnable ID" do
    first = runnable(make_ref())
    replacement = %{first | id: self()}
    first_outcome = completed(first)
    replacement_outcome = completed(replacement)

    assert first_outcome.id == replacement_outcome.id
    assert first_outcome.order_key == replacement_outcome.order_key
    refute first_outcome.runnable_ids == replacement_outcome.runnable_ids
    refute first_outcome.id == completed(runnable(make_ref(), value: :other_input)).id
    refute first_outcome.id == completed(runnable(make_ref(), name: :other_node)).id
  end

  test "attempt, outcome kind, and execution distinguish terminal outcome identities" do
    runnable = runnable(make_ref())
    attempt_zero = completed(runnable)
    attempt_one = completed(Runnable.for_attempt(runnable, 1))
    attempt_two = completed(Runnable.for_attempt(runnable, 2))
    skipped = Outcome.from_runnable(execution_id(), Runnable.skip(runnable, []), 1)
    failed = Outcome.from_runnable(execution_id(), Runnable.fail(runnable, :failed), 1)
    uncertain = Outcome.uncertain(execution_id(), {:runnable, runnable}, :lost, 1)

    assert attempt_zero.activation_id == attempt_one.activation_id
    assert attempt_one.activation_id == attempt_two.activation_id
    assert attempt_one.attempt_id == Identity.derive(:attempt, [attempt_one.activation_id, 1])
    assert attempt_two.attempt_id == Identity.derive(:attempt, [attempt_two.activation_id, 2])

    outcomes = [attempt_zero, attempt_one, attempt_two, skipped, failed, uncertain]
    assert outcomes |> Enum.map(& &1.id) |> Enum.uniq() |> length() == length(outcomes)

    terminal = Runnable.complete(runnable, :value, [])
    assert Outcome.from_runnable(execution_id(), terminal, 9).id == attempt_zero.id

    refute Outcome.from_runnable(Identity.derive(:execution, [:other]), terminal, 1).id ==
             attempt_zero.id
  end

  test "uncertain Promise identities distinguish members and ignore their opaque IDs" do
    first = runnable(make_ref(), name: :first)
    second = runnable(self(), name: :second)
    third = runnable(fn -> :opaque end, name: :third)
    members = [first, second, third]
    outcome = uncertain(members)

    assert outcome.runnable_ids == Enum.map(members, & &1.id)
    assert %Identity{domain: :event} = outcome.id
    refute outcome.id == uncertain([first, second]).id
    refute outcome.id == uncertain([first, third]).id

    replacements = Enum.map(members, &%{&1 | id: make_ref()})
    replacement_outcome = uncertain(replacements)
    assert outcome.id == replacement_outcome.id
    assert outcome.activation_id == replacement_outcome.activation_id
    assert outcome.order_key == replacement_outcome.order_key
  end

  test "built-in runnable outcome identities and order keys are preserved" do
    custom = runnable(make_ref())
    builtin = Runnable.new(custom.node, custom.input_fact, custom.context)
    retry = Runnable.for_attempt(builtin, 2)
    outcome = completed(retry)

    assert outcome.id ==
             Identity.derive(:event, [
               execution_id(),
               :completed,
               retry.activation_id,
               retry.attempt_id,
               [retry.id]
             ])

    assert outcome.order_key == Runnable.order_key(retry)

    other = runnable(make_ref(), name: :other, depth: 1)
    other = Runnable.new(other.node, other.input_fact, other.context)
    uncertain = uncertain([builtin, other])

    assert uncertain.id ==
             Identity.derive(:event, [
               execution_id(),
               :uncertain,
               builtin.activation_id,
               nil,
               [builtin.id, other.id]
             ])

    assert uncertain.order_key == Runnable.order_key(builtin)
  end

  test "accepted completed and skipped custom IDs pass through the shared execution recorder" do
    step = Step.new(name: :echo, work: &Function.identity/1)

    skipped_node = %Runic.Test.SkippedNode{
      name: :skipped,
      hash: Identity.derive(:component_definition, [:skipped])
    }

    for node <- [step, skipped_node], id <- [make_ref(), self(), fn -> :opaque end] do
      workflow = Workflow.new() |> Workflow.add_step(node)
      {execution, fact} = Execution.start(workflow, :input)
      workflow = Workflow.plan(workflow, fact)
      {:ok, prepared} = Invokable.prepare(node, workflow, fact)
      custom = %{prepared | id: id, activation_id: nil, attempt_id: nil}
      terminal = Invokable.execute(node, custom)
      workflow = Workflow.apply_runnable(workflow, terminal)
      execution = Execution.record(execution, workflow, terminal)

      assert [outcome] = execution.outcomes
      assert outcome.runnable_ids == [id]
      assert outcome.kind == terminal.status
      assert outcome.activation_id == Runnable.runnable_id(node, fact)

      expected_outputs = if terminal.status == :completed, do: [:input], else: []
      assert Execution.outputs(execution) == expected_outputs

      execution = Execution.record_uncertain(execution, workflow, {:runnable, custom}, :lost)
      assert [^outcome, %{kind: :uncertain, runnable_ids: [^id]}] = execution.outcomes
    end
  end

  defp execution_id, do: Identity.derive(:execution, [:outcome_test])

  defp runnable(id, opts \\ []) do
    name = Keyword.get(opts, :name, :work)

    node = %Step{
      name: name,
      hash: Identity.derive(:component_definition, [name])
    }

    fact = Fact.new(value: Keyword.get(opts, :value, :input))
    context = CausalContext.basic(node.hash, fact, Keyword.get(opts, :depth, 0))
    Runnable.new(id, node, fact, context)
  end

  defp completed(runnable) do
    Outcome.from_runnable(execution_id(), Runnable.complete(runnable, :value, []), 1)
  end

  defp uncertain(runnables) do
    Outcome.uncertain(execution_id(), {:promise, Promise.new(runnables)}, :executor_lost, 1)
  end
end
