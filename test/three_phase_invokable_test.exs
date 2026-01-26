defmodule Runic.Workflow.ThreePhaseInvokableTest do
  use ExUnit.Case, async: true

  alias Runic.Workflow
  alias Runic.Workflow.{Step, Condition, Fact, Runnable, Invokable}

  describe "Workflow.ancestry_depth/2" do
    test "returns 0 for root facts (no ancestry)" do
      workflow = Workflow.new()
      fact = Fact.new(value: 42)

      assert Workflow.ancestry_depth(workflow, fact) == 0
    end

    test "returns correct depth for facts with ancestry" do
      step1 = Step.new(work: &double/1)
      step2 = Step.new(work: &add_one/1)

      workflow =
        Workflow.new()
        |> Workflow.add(step1)
        |> Workflow.add(step2, to: step1.hash)

      root_fact = Fact.new(value: 5)
      workflow = Workflow.react(workflow, root_fact)

      # After react, there should be facts at depth 1 (from step1)
      step1_facts =
        workflow.graph
        |> Graph.out_edges(step1)
        |> Enum.filter(&(&1.label == :produced))
        |> Enum.map(& &1.v2)

      assert length(step1_facts) == 1
      [step1_fact] = step1_facts
      assert Workflow.ancestry_depth(workflow, step1_fact) == 1
    end
  end

  describe "Workflow.get_hooks/2" do
    test "returns empty hooks when none registered" do
      workflow = Workflow.new()
      step = Step.new(work: &identity/1)

      {before, after_hooks} = Workflow.get_hooks(workflow, step.hash)

      assert before == []
      assert after_hooks == []
    end
  end

  describe "Three-phase protocol - Step" do
    test "prepare returns {:ok, Runnable}" do
      step = Step.new(work: &double/1)
      workflow = Workflow.new() |> Workflow.add(step)
      fact = Fact.new(value: 5)

      result = Invokable.prepare(step, workflow, fact)

      assert {:ok, %Runnable{} = runnable} = result
      assert runnable.node == step
      assert runnable.input_fact == fact
      assert runnable.status == :pending
    end

    test "execute returns completed Runnable with result and apply_fn" do
      step = Step.new(work: &double/1)
      workflow = Workflow.new() |> Workflow.add(step)
      fact = Fact.new(value: 5)

      {:ok, runnable} = Invokable.prepare(step, workflow, fact)
      executed = Invokable.execute(step, runnable)

      assert executed.status == :completed
      assert %Fact{value: 10} = executed.result
      assert is_function(executed.apply_fn, 1)
    end

    test "apply_fn properly updates workflow" do
      step = Step.new(work: &double/1)
      workflow = Workflow.new() |> Workflow.add(step)
      root_fact = Fact.new(value: 5)

      # Simulate the root handling
      workflow =
        workflow
        |> Workflow.log_fact(root_fact)
        |> Workflow.prepare_next_runnables(Workflow.root(), root_fact)

      {:ok, runnable} = Invokable.prepare(step, workflow, root_fact)
      executed = Invokable.execute(step, runnable)

      # Apply the result
      updated_workflow = executed.apply_fn.(workflow)

      # Check the result fact is in the graph
      result_facts =
        updated_workflow.graph
        |> Graph.out_edges(step)
        |> Enum.filter(&(&1.label == :produced))
        |> Enum.map(& &1.v2)

      assert length(result_facts) == 1
      [result_fact] = result_facts
      assert result_fact.value == 10
    end

    test "three-phase produces same result as legacy invoke" do
      step = Step.new(work: &double/1)
      workflow = Workflow.new() |> Workflow.add(step)
      root_fact = Fact.new(value: 5)

      # Setup workflow for both paths
      setup_workflow =
        workflow
        |> Workflow.log_fact(root_fact)
        |> Workflow.prepare_next_runnables(Workflow.root(), root_fact)

      # Legacy path
      legacy_result = Invokable.invoke(step, setup_workflow, root_fact)

      # Three-phase path
      {:ok, runnable} = Invokable.prepare(step, setup_workflow, root_fact)
      executed = Invokable.execute(step, runnable)
      three_phase_result = executed.apply_fn.(setup_workflow)

      # Compare produced facts
      legacy_facts = get_produced_facts(legacy_result, step)
      three_phase_facts = get_produced_facts(three_phase_result, step)

      assert length(legacy_facts) == length(three_phase_facts)
      assert hd(legacy_facts).value == hd(three_phase_facts).value
    end
  end

  describe "Three-phase protocol - Condition" do
    test "prepare returns {:ok, Runnable}" do
      condition = Condition.new(&positive?/1)
      workflow = Workflow.new()
      fact = Fact.new(value: 5)

      result = Invokable.prepare(condition, workflow, fact)

      assert {:ok, %Runnable{} = runnable} = result
      assert runnable.node == condition
      assert runnable.status == :pending
    end

    test "execute returns satisfied status for matching condition" do
      condition = Condition.new(&positive?/1)
      workflow = Workflow.new()
      fact = Fact.new(value: 5)

      {:ok, runnable} = Invokable.prepare(condition, workflow, fact)
      executed = Invokable.execute(condition, runnable)

      assert executed.status == :completed
      assert executed.result == true
    end

    test "execute returns not satisfied status for non-matching condition" do
      condition = Condition.new(&positive?/1)
      workflow = Workflow.new()
      fact = Fact.new(value: -5)

      {:ok, runnable} = Invokable.prepare(condition, workflow, fact)
      executed = Invokable.execute(condition, runnable)

      assert executed.status == :completed
      assert executed.result == false
    end
  end

  defp get_produced_facts(workflow, step) do
    workflow.graph
    |> Graph.out_edges(step)
    |> Enum.filter(&(&1.label == :produced))
    |> Enum.map(& &1.v2)
  end

  defp double(x), do: x * 2
  defp add_one(x), do: x + 1
  defp identity(x), do: x
  defp positive?(x), do: x > 0
end
