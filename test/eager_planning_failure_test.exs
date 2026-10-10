defmodule Runic.EagerPlanningFailureTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  require Runic

  alias Runic.Workflow
  alias Runic.Workflow.{Condition, Conjunction, Fact, Invokable, Runnable}
  alias Runic.Workflow.Events.ActivationConsumed

  for node_type <- [:step, :condition, :conjunction] do
    test "failure consumption records the activation label for #{node_type}" do
      {node, label} =
        case unquote(node_type) do
          :step -> {Runic.step(fn value -> value end), :runnable}
          :condition -> {Condition.new(fn value -> value > 0 end), :matchable}
          :conjunction -> {Conjunction.new([]), :matchable}
        end

      input = Fact.new(value: 1)

      base =
        Workflow.new()
        |> Workflow.enable_event_emission()
        |> Workflow.draw_connection(input, node, label)

      {:ok, runnable} = Invokable.prepare(node, base, input)
      completed = Workflow.apply_runnable(base, Runnable.fail(runnable, :rejected))

      assert [%ActivationConsumed{} = consumed] = completed.uncommitted_events
      assert consumed.node_hash == node.hash
      assert consumed.fact_hash == input.hash
      assert consumed.from_label == label
      assert Multigraph.out_edges(completed.graph, input, by: label) == []
      assert [%{v2: ^node}] = Multigraph.out_edges(completed.graph, input, by: :ran)

      replayed = Workflow.from_events(Enum.reverse(completed.uncommitted_events), base)
      assert Workflow.next_runnables(replayed) == Workflow.next_runnables(completed)
    end
  end

  test "eager planning returns its failed Runnable and retains unstarted matches" do
    owner = self()
    rule = Runic.rule(fn value when value > 0 -> :unused end, name: :guarded)
    workflow = Runic.workflow(rules: [rule])
    [condition] = Workflow.get_component(workflow, {:guarded, :condition})
    inputs = [Fact.new(value: 1), Fact.new(value: 2)]

    hook = fn _, ctx ->
      send(owner, {:predicate, ctx.input_fact.value})
      {:error, :rejected}
    end

    workflow = %{workflow | before_hooks: %{condition.hash => [hook]}}
    workflow = Enum.reduce(inputs, workflow, &Workflow.plan(&2, &1))

    assert {planned, %Runnable{status: :failed} = failed} =
             Workflow.plan_eagerly_with_result(workflow)

    assert failed.node == condition
    assert_received {:predicate, value}
    assert failed.input_fact.value == value
    refute_received {:predicate, _}
    assert [{^condition, remaining}] = Workflow.next_runnables(planned)
    refute remaining.hash == failed.input_fact.hash

    {completed, %Runnable{status: :failed}} = Workflow.plan_eagerly_with_result(planned)
    assert_received {:predicate, _}
    refute Workflow.is_runnable?(completed)
    assert {^completed, nil} = Workflow.plan_eagerly_with_result(completed)
    refute_received {:predicate, _}
  end

  test "successful eager planning visits each pending match once" do
    owner = self()
    rule = Runic.rule(fn value when value > 0 -> value end, name: :guarded)
    workflow = Runic.workflow(rules: [rule])
    [condition] = Workflow.get_component(workflow, {:guarded, :condition})

    hook = fn _, ctx ->
      send(owner, {:predicate, ctx.input_fact.value})
      :ok
    end

    workflow = %{workflow | before_hooks: %{condition.hash => [hook]}}
    workflow = Enum.reduce([1, 2], workflow, &Workflow.plan(&2, &1))
    {planned, nil} = Workflow.plan_eagerly_with_result(workflow)
    assert_received {:predicate, 1}
    assert_received {:predicate, 2}
    refute_received {:predicate, _}

    completed = Workflow.react_until_satisfied(planned)
    assert Enum.sort(Workflow.raw_productions(completed)) == [1, 2]
    refute_received {:predicate, _}
  end
end
