defmodule Runic.Workflow.RunnableTest do
  use ExUnit.Case, async: true

  alias Runic.Workflow.{Runnable, CausalContext, Fact}
  alias Runic.Workflow.Step

  describe "Runnable.new/3" do
    test "creates a pending runnable with computed id" do
      step = Step.new(work: &double/1)
      fact = Fact.new(value: 42)
      context = CausalContext.new(node_hash: step.hash, input_fact: fact, ancestry_depth: 0)

      runnable = Runnable.new(step, fact, context)

      assert runnable.status == :pending
      assert runnable.node == step
      assert runnable.input_fact == fact
      assert runnable.context == context
      assert is_integer(runnable.id)
      assert runnable.result == nil
      assert runnable.apply_fn == nil
      assert runnable.error == nil
    end

    test "generates stable id from node and fact hashes" do
      step = Step.new(work: &double/1)
      fact = Fact.new(value: 42)
      context = CausalContext.new()

      runnable1 = Runnable.new(step, fact, context)
      runnable2 = Runnable.new(step, fact, context)

      assert runnable1.id == runnable2.id
    end

    test "generates different id for different facts" do
      step = Step.new(work: &double/1)
      fact1 = Fact.new(value: 42)
      fact2 = Fact.new(value: 43)
      context = CausalContext.new()

      runnable1 = Runnable.new(step, fact1, context)
      runnable2 = Runnable.new(step, fact2, context)

      assert runnable1.id != runnable2.id
    end
  end

  describe "Runnable.new/4" do
    test "creates a runnable with explicit id" do
      step = Step.new(work: &double/1)
      fact = Fact.new(value: 42)
      context = CausalContext.new()

      runnable = Runnable.new(12345, step, fact, context)

      assert runnable.id == 12345
      assert runnable.status == :pending
    end
  end

  describe "Runnable.runnable_id/2" do
    test "generates id from node and fact" do
      step = Step.new(work: &double/1)
      fact = Fact.new(value: 42)

      id = Runnable.runnable_id(step, fact)

      assert is_integer(id)
      assert id == Runnable.runnable_id(step, fact)
    end
  end

  describe "Runnable.complete/3" do
    test "marks runnable as completed with result and apply_fn" do
      step = Step.new(work: &double/1)
      fact = Fact.new(value: 42)
      context = CausalContext.new()
      runnable = Runnable.new(step, fact, context)

      apply_fn = fn workflow -> workflow end
      completed = Runnable.complete(runnable, :some_result, apply_fn)

      assert completed.status == :completed
      assert completed.result == :some_result
      assert completed.apply_fn == apply_fn
      assert completed.error == nil
    end
  end

  describe "Runnable.fail/2" do
    test "marks runnable as failed with error" do
      step = Step.new(work: &double/1)
      fact = Fact.new(value: 42)
      context = CausalContext.new()
      runnable = Runnable.new(step, fact, context)

      error = %RuntimeError{message: "something went wrong"}
      failed = Runnable.fail(runnable, error)

      assert failed.status == :failed
      assert failed.error == error
      assert failed.result == nil
    end
  end

  describe "Runnable.skip/2" do
    test "marks runnable as skipped with apply_fn" do
      step = Step.new(work: &double/1)
      fact = Fact.new(value: 42)
      context = CausalContext.new()
      runnable = Runnable.new(step, fact, context)

      apply_fn = fn workflow -> workflow end
      skipped = Runnable.skip(runnable, apply_fn)

      assert skipped.status == :skipped
      assert skipped.apply_fn == apply_fn
    end
  end

  defp double(x), do: x * 2
end
