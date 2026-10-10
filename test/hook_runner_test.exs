defmodule Runic.Workflow.HookRunnerTest do
  use ExUnit.Case, async: true

  alias Runic.Workflow
  alias Runic.Workflow.{HookRunner, HookEvent, CausalContext, Fact}
  alias Runic.Workflow.Step

  describe "HookRunner.run_before/3" do
    test "returns empty list when no hooks" do
      ctx = CausalContext.new(hooks: {[], []})
      step = %Step{hash: 123, work: fn x -> x end}
      fact = Fact.new(value: 42, ancestry: nil)

      assert {:ok, []} = HookRunner.run_before(ctx, step, fact)
    end

    test "new-style hook (arity-2) returning :ok" do
      hook = fn %HookEvent{timing: :before}, _ctx -> :ok end
      ctx = CausalContext.new(hooks: {[hook], []})
      step = %Step{hash: 123, work: fn x -> x end}
      fact = Fact.new(value: 42, ancestry: nil)

      assert {:ok, []} = HookRunner.run_before(ctx, step, fact)
    end

    test "new-style hook returning {:apply, fn}" do
      apply_fn = fn workflow -> workflow end
      hook = fn %HookEvent{timing: :before}, _ctx -> {:apply, apply_fn} end
      ctx = CausalContext.new(hooks: {[hook], []})
      step = %Step{hash: 123, work: fn x -> x end}
      fact = Fact.new(value: 42, ancestry: nil)

      assert {:ok, [^apply_fn]} = HookRunner.run_before(ctx, step, fact)
    end

    test "new-style hook returning {:apply, [fns]}" do
      apply_fn1 = fn workflow -> workflow end
      apply_fn2 = fn workflow -> workflow end
      hook = fn %HookEvent{}, _ctx -> {:apply, [apply_fn1, apply_fn2]} end
      ctx = CausalContext.new(hooks: {[hook], []})
      step = %Step{hash: 123, work: fn x -> x end}
      fact = Fact.new(value: 42, ancestry: nil)

      assert {:ok, [^apply_fn1, ^apply_fn2]} = HookRunner.run_before(ctx, step, fact)
    end

    test "new-style hook returning {:error, reason}" do
      hook = fn %HookEvent{}, _ctx -> {:error, :some_error} end
      ctx = CausalContext.new(hooks: {[hook], []})
      step = %Step{hash: 123, work: fn x -> x end}
      fact = Fact.new(value: 42, ancestry: nil)

      assert {:error, {:hook_error, :some_error}} = HookRunner.run_before(ctx, step, fact)
    end

    test "legacy hook is deferred and receives the input Fact" do
      owner = self()

      legacy_hook = fn step, workflow, fact ->
        send(owner, {:before, step, fact})
        workflow
      end

      ctx = CausalContext.new(hooks: {[legacy_hook], []})
      step = %Step{hash: 123, work: fn x -> x end}
      fact = Fact.new(value: 42, meta: %{domain: :input})

      {:ok, [apply_fn]} = HookRunner.run_before(ctx, step, fact)

      refute_received {:before, _, _}
      workflow = Workflow.new()
      assert apply_fn.(workflow) == workflow
      assert_received {:before, ^step, ^fact}
    end

    test "multiple hooks are executed in order and apply_fns collected" do
      apply_fn1 = fn workflow -> workflow end
      apply_fn2 = fn workflow -> workflow end

      hook1 = fn %HookEvent{}, _ctx -> {:apply, apply_fn1} end
      hook2 = fn %HookEvent{}, _ctx -> {:apply, apply_fn2} end

      ctx = CausalContext.new(hooks: {[hook1, hook2], []})
      step = %Step{hash: 123, work: fn x -> x end}
      fact = Fact.new(value: 42, ancestry: nil)

      assert {:ok, [^apply_fn1, ^apply_fn2]} = HookRunner.run_before(ctx, step, fact)
    end

    test "hook exception returns error" do
      hook = fn %HookEvent{}, _ctx -> raise "boom" end
      ctx = CausalContext.new(hooks: {[hook], []})
      step = %Step{hash: 123, work: fn x -> x end}
      fact = Fact.new(value: 42, ancestry: nil)

      assert {:error, {:hook_exception, %RuntimeError{message: "boom"}, _}} =
               HookRunner.run_before(ctx, step, fact)
    end
  end

  describe "HookRunner.run_after/4" do
    test "after hook receives result in event" do
      test_pid = self()

      hook = fn %HookEvent{timing: :after, input_fact: input, result: result}, _ctx ->
        send(test_pid, {:result, input, result})
        :ok
      end

      ctx = CausalContext.new(hooks: {[], [hook]})
      step = %Step{hash: 123, work: fn x -> x end}
      input_fact = Fact.new(value: 42, ancestry: nil)
      result_fact = Fact.new(value: 84, ancestry: {123, input_fact.hash})

      {:ok, []} = HookRunner.run_after(ctx, step, input_fact, result_fact)

      assert_received {:result, ^input_fact, ^result_fact}
    end

    test "legacy after hook is deferred and receives the produced Fact" do
      owner = self()

      hook = fn step, workflow, fact ->
        send(owner, {:after, step, fact})
        workflow
      end

      ctx = CausalContext.new(hooks: {[], [hook]})
      step = %Step{hash: 123, work: fn x -> x * 2 end}
      input = Fact.new(value: 42, meta: %{domain: :input})
      output = Fact.new(value: 84, ancestry: {step.hash, input.hash}, meta: %{domain: :output})

      {:ok, [apply_fn]} = HookRunner.run_after(ctx, step, input, output)

      refute_received {:after, _, _}
      workflow = Workflow.new()
      assert apply_fn.(workflow) == workflow
      assert_received {:after, ^step, ^output}
    end

    test "legacy after hook receives the input Fact when no Fact is produced" do
      owner = self()

      hook = fn node, workflow, fact ->
        send(owner, {:after, node, fact})
        workflow
      end

      ctx = CausalContext.new(hooks: {[], [hook]})
      condition = Runic.Workflow.Condition.new(work: fn value -> value > 0 end)
      input = Fact.new(value: 42, meta: %{domain: :input})

      for satisfied <- [true, false] do
        {:ok, [apply_fn]} = HookRunner.run_after(ctx, condition, input, satisfied)

        refute_received {:after, _, _}
        workflow = Workflow.new()
        assert apply_fn.(workflow) == workflow
        assert_received {:after, ^condition, ^input}
      end
    end
  end
end
