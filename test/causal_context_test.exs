defmodule Runic.Workflow.CausalContextTest do
  use ExUnit.Case, async: true

  alias Runic.Workflow.{CausalContext, Fact}

  describe "CausalContext.new/1" do
    test "creates context with default values" do
      context = CausalContext.new()

      assert context.node_hash == nil
      assert context.input_fact == nil
      assert context.ancestry_depth == 0
      assert context.hooks == {[], []}
      assert context.last_known_state == nil
      assert context.is_state_initialized == false
      assert context.satisfied_conditions == nil
      assert context.join_context == nil
      assert context.fan_out_context == nil
      assert context.fan_in_context == nil
    end

    test "creates context with specified values" do
      fact = Fact.new(value: 42)

      context =
        CausalContext.new(
          node_hash: 12345,
          input_fact: fact,
          ancestry_depth: 3,
          hooks: {[:before], [:after]}
        )

      assert context.node_hash == 12345
      assert context.input_fact == fact
      assert context.ancestry_depth == 3
      assert context.hooks == {[:before], [:after]}
    end
  end

  describe "CausalContext.basic/3" do
    test "creates a basic context" do
      fact = Fact.new(value: 42)

      context = CausalContext.basic(12345, fact, 2)

      assert context.node_hash == 12345
      assert context.input_fact == fact
      assert context.ancestry_depth == 2
    end
  end

  describe "CausalContext.with_hooks/2" do
    test "adds hooks to context" do
      context = CausalContext.new()
      before_hooks = [fn x -> x end]
      after_hooks = [fn x -> x + 1 end]

      updated = CausalContext.with_hooks(context, {before_hooks, after_hooks})

      assert updated.hooks == {before_hooks, after_hooks}
    end
  end

  describe "CausalContext.with_state/3" do
    test "adds state to context" do
      context = CausalContext.new()

      updated = CausalContext.with_state(context, %{count: 5}, true)

      assert updated.last_known_state == %{count: 5}
      assert updated.is_state_initialized == true
    end

    test "defaults is_initialized to true" do
      context = CausalContext.new()

      updated = CausalContext.with_state(context, %{count: 5})

      assert updated.is_state_initialized == true
    end
  end

  describe "CausalContext.with_fan_out_context/2" do
    test "adds fan_out context" do
      context = CausalContext.new()
      fan_out_ctx = %{is_reduced: true, source_fact_hash: 123}

      updated = CausalContext.with_fan_out_context(context, fan_out_ctx)

      assert updated.fan_out_context == fan_out_ctx
    end
  end

  describe "CausalContext.with_fan_in_context/2" do
    test "adds fan_in context" do
      context = CausalContext.new()
      fan_in_ctx = %{mode: :simple}

      updated = CausalContext.with_fan_in_context(context, fan_in_ctx)

      assert updated.fan_in_context == fan_in_ctx
    end
  end

  describe "CausalContext.with_join_context/2" do
    test "adds join context" do
      context = CausalContext.new()
      join_ctx = %{joins: [1, 2, 3], satisfied: %{1 => true}}

      updated = CausalContext.with_join_context(context, join_ctx)

      assert updated.join_context == join_ctx
    end
  end

  describe "CausalContext.with_satisfied_conditions/2" do
    test "adds satisfied conditions" do
      context = CausalContext.new()
      conditions = MapSet.new([1, 2, 3])

      updated = CausalContext.with_satisfied_conditions(context, conditions)

      assert updated.satisfied_conditions == conditions
    end
  end

  describe "CausalContext.before_hooks/1" do
    test "returns before hooks" do
      before_hooks = [fn x -> x end]
      context = CausalContext.new(hooks: {before_hooks, []})

      assert CausalContext.before_hooks(context) == before_hooks
    end
  end

  describe "CausalContext.after_hooks/1" do
    test "returns after hooks" do
      after_hooks = [fn x -> x + 1 end]
      context = CausalContext.new(hooks: {[], after_hooks})

      assert CausalContext.after_hooks(context) == after_hooks
    end
  end
end
