defmodule Runic.Workflow.HookRunnerTest do
  use ExUnit.Case, async: true

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

    test "legacy hook (arity-3) is converted to apply_fn" do
      legacy_hook = fn _step, workflow, _fact -> workflow end
      ctx = CausalContext.new(hooks: {[legacy_hook], []})
      step = %Step{hash: 123, work: fn x -> x end}
      fact = Fact.new(value: 42, ancestry: nil)

      {:ok, [apply_fn]} = HookRunner.run_before(ctx, step, fact)

      assert is_function(apply_fn, 1)
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

      hook = fn %HookEvent{timing: :after, result: result}, _ctx ->
        send(test_pid, {:result, result})
        :ok
      end

      ctx = CausalContext.new(hooks: {[], [hook]})
      step = %Step{hash: 123, work: fn x -> x end}
      input_fact = Fact.new(value: 42, ancestry: nil)
      result_fact = Fact.new(value: 84, ancestry: {123, input_fact.hash})

      {:ok, []} = HookRunner.run_after(ctx, step, input_fact, result_fact)

      assert_received {:result, ^result_fact}
    end
  end
end
