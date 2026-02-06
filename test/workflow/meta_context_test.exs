defmodule Runic.Workflow.MetaContextTest do
  @moduledoc """
  Tests for meta expression infrastructure (Phase 1).

  These tests validate the core infrastructure for meta expressions:
  - CausalContext.meta_context field and helpers
  - Condition and Step meta_refs field
  - Workflow.prepare_meta_context/2
  - Workflow.meta_dependencies/2 and meta_dependents/2
  - Workflow.build_getter_fn/1 for state_of
  """

  use ExUnit.Case
  require Runic
  alias Runic.Workflow
  alias Runic.Workflow.{CausalContext, Condition, Step}

  # =============================================================================
  # CausalContext Tests
  # =============================================================================

  describe "CausalContext meta_context" do
    test "new context has empty meta_context by default" do
      ctx = CausalContext.new()
      assert ctx.meta_context == %{}
    end

    test "with_meta_context/2 sets the meta context" do
      ctx =
        CausalContext.new()
        |> CausalContext.with_meta_context(%{cart_state: %{total: 150}})

      assert ctx.meta_context == %{cart_state: %{total: 150}}
    end

    test "meta_context/1 returns the meta context" do
      ctx =
        CausalContext.new()
        |> CausalContext.with_meta_context(%{foo: :bar})

      assert CausalContext.meta_context(ctx) == %{foo: :bar}
    end

    test "has_meta_context?/1 returns false for empty context" do
      ctx = CausalContext.new()
      refute CausalContext.has_meta_context?(ctx)
    end

    test "has_meta_context?/1 returns true when context is populated" do
      ctx =
        CausalContext.new()
        |> CausalContext.with_meta_context(%{state: 42})

      assert CausalContext.has_meta_context?(ctx)
    end
  end

  # =============================================================================
  # Condition meta_refs Tests
  # =============================================================================

  describe "Condition meta_refs" do
    test "new condition has empty meta_refs by default" do
      condition = Condition.new(fn _ -> true end)
      assert condition.meta_refs == []
    end

    test "condition can be created with meta_refs" do
      meta_refs = [
        %{kind: :state_of, target: :cart, field_path: [:total], context_key: :cart_total}
      ]

      condition = Condition.new(work: fn _, _ -> true end, meta_refs: meta_refs, arity: 2)
      assert condition.meta_refs == meta_refs
    end

    test "has_meta_refs?/1 returns false for empty meta_refs" do
      condition = Condition.new(fn _ -> true end)
      refute Condition.has_meta_refs?(condition)
    end

    test "has_meta_refs?/1 returns true when meta_refs is populated" do
      meta_refs = [
        %{kind: :state_of, target: :cart, field_path: [], context_key: :cart_state}
      ]

      condition = Condition.new(work: fn _, _ -> true end, meta_refs: meta_refs, arity: 2)
      assert Condition.has_meta_refs?(condition)
    end

    test "check_with_meta_context/3 uses 2-arity work function" do
      condition =
        Condition.new(
          work: fn input, meta_ctx -> input > 0 and meta_ctx.threshold < 100 end,
          arity: 2,
          meta_refs: [%{kind: :state_of, target: :threshold_acc, context_key: :threshold}]
        )

      assert Condition.check_with_meta_context(condition, 50, %{threshold: 50})
      refute Condition.check_with_meta_context(condition, 50, %{threshold: 150})
      refute Condition.check_with_meta_context(condition, -5, %{threshold: 50})
    end

    test "check_with_meta_context/3 falls back to check/2 for 1-arity" do
      condition = Condition.new(fn x -> x > 10 end)

      assert Condition.check_with_meta_context(condition, 15, %{ignored: :value})
      refute Condition.check_with_meta_context(condition, 5, %{ignored: :value})
    end
  end

  # =============================================================================
  # Step meta_refs Tests
  # =============================================================================

  describe "Step meta_refs" do
    test "new step has empty meta_refs by default" do
      step = Step.new(work: fn x -> x end)
      assert step.meta_refs == []
    end

    test "step can be created with meta_refs" do
      meta_refs = [
        %{kind: :state_of, target: :counter, field_path: [], context_key: :counter_state}
      ]

      step = Step.new(work: fn _, _ -> :ok end, meta_refs: meta_refs)
      assert step.meta_refs == meta_refs
    end

    test "has_meta_refs?/1 returns false for empty meta_refs" do
      step = Step.new(work: fn x -> x end)
      refute Step.has_meta_refs?(step)
    end

    test "has_meta_refs?/1 returns true when meta_refs is populated" do
      meta_refs = [
        %{kind: :state_of, target: :acc, field_path: [], context_key: :acc_state}
      ]

      step = Step.new(work: fn _, _ -> :ok end, meta_refs: meta_refs)
      assert Step.has_meta_refs?(step)
    end

    test "run_with_meta_context/3 uses 2-arity work function" do
      step =
        Step.new(
          work: fn input, meta_ctx -> input + meta_ctx.offset end,
          meta_refs: [%{kind: :state_of, target: :offset_acc, context_key: :offset}]
        )

      assert Step.run_with_meta_context(step, 10, %{offset: 5}) == 15
    end

    test "run_with_meta_context/3 uses 1-arity work function when arity is 1" do
      step = Step.new(work: fn x -> x * 2 end)

      assert Step.run_with_meta_context(step, 10, %{ignored: :value}) == 20
    end
  end

  # =============================================================================
  # Workflow.build_getter_fn/1 Tests
  # =============================================================================

  describe "Workflow.build_getter_fn/1 for :state_of" do
    test "builds getter that returns accumulator state" do
      accumulator = Runic.accumulator(0, fn x, acc -> acc + x end, name: :counter)

      workflow =
        Workflow.new()
        |> Workflow.add(accumulator)
        |> Workflow.react_until_satisfied(10)

      getter_fn = Workflow.build_getter_fn(%{kind: :state_of, field_path: []})
      acc_component = Workflow.get_component(workflow, :counter)
      state = getter_fn.(workflow, acc_component.hash)

      assert state == 10
    end

    test "builds getter that returns full state (field access done in macro code)" do
      # NOTE: The getter returns the full state; field path extraction happens
      # in the macro-generated condition/step code, not in the getter.
      accumulator =
        Runic.accumulator(
          %{total: 0, items: []},
          fn item, acc ->
            %{acc | total: acc.total + item.price, items: [item | acc.items]}
          end,
          name: :cart
        )

      workflow =
        Workflow.new()
        |> Workflow.add(accumulator)
        |> Workflow.react_until_satisfied(%{name: "Widget", price: 50})

      getter_fn = Workflow.build_getter_fn(%{kind: :state_of, field_path: [:total]})
      acc_component = Workflow.get_component(workflow, :cart)
      state = getter_fn.(workflow, acc_component.hash)

      # Getter returns full state, macro code does field access
      assert state.total == 50
      assert length(state.items) == 1
    end

    test "builds getter that returns init value before any invocations" do
      accumulator = Runic.accumulator(42, fn x, acc -> acc + x end, name: :counter)

      workflow =
        Workflow.new()
        |> Workflow.add(accumulator)

      getter_fn = Workflow.build_getter_fn(%{kind: :state_of, field_path: []})
      acc_component = Workflow.get_component(workflow, :counter)
      state = getter_fn.(workflow, acc_component.hash)

      assert state == 42
    end

    test "builds getter that resolves target by name" do
      accumulator = Runic.accumulator(100, fn x, acc -> acc + x end, name: :named_counter)

      workflow =
        Workflow.new()
        |> Workflow.add(accumulator)

      getter_fn = Workflow.build_getter_fn(%{kind: :state_of, field_path: []})
      state = getter_fn.(workflow, :named_counter)

      assert state == 100
    end

    test "builds getter that returns nil for missing component" do
      workflow = Workflow.new()

      getter_fn = Workflow.build_getter_fn(%{kind: :state_of, field_path: []})
      state = getter_fn.(workflow, :nonexistent)

      assert is_nil(state)
    end
  end

  # =============================================================================
  # Workflow.draw_meta_ref_edge/4 Tests
  # =============================================================================

  describe "Workflow.draw_meta_ref_edge/4" do
    test "creates :meta_ref edge with getter_fn in properties" do
      accumulator = Runic.accumulator(0, fn x, acc -> acc + x end, name: :counter)

      condition = Condition.new(fn _, _ -> true end, 2)

      workflow =
        Workflow.new()
        |> Workflow.add(accumulator)
        |> Workflow.add_step(condition)

      acc = Workflow.get_component(workflow, :counter)

      workflow =
        Workflow.draw_meta_ref_edge(
          workflow,
          condition.hash,
          acc.hash,
          %{kind: :state_of, field_path: [:total], context_key: :counter_total}
        )

      edges = Graph.out_edges(workflow.graph, condition.hash, by: :meta_ref)
      assert length(edges) == 1

      [edge] = edges
      assert edge.v2.hash == acc.hash
      assert edge.properties.context_key == :counter_total
      assert edge.properties.kind == :state_of
      assert is_function(edge.properties.getter_fn, 2)
    end
  end

  # =============================================================================
  # Workflow.prepare_meta_context/2 Tests
  # =============================================================================

  describe "Workflow.prepare_meta_context/2" do
    test "returns empty map when node has no meta_ref edges" do
      step = Runic.step(fn x -> x end, name: :plain_step)

      workflow =
        Workflow.new()
        |> Workflow.add(step)

      step_component = Workflow.get_component(workflow, :plain_step)
      meta_context = Workflow.prepare_meta_context(workflow, step_component)

      assert meta_context == %{}
    end

    test "populates meta context from :meta_ref edges" do
      accumulator = Runic.accumulator(42, fn x, acc -> acc + x end, name: :counter)

      condition =
        Condition.new(
          work: fn _, meta_ctx -> meta_ctx.counter_state > 0 end,
          arity: 2,
          meta_refs: [
            %{kind: :state_of, target: :counter, field_path: [], context_key: :counter_state}
          ]
        )

      workflow =
        Workflow.new()
        |> Workflow.add(accumulator)
        |> Workflow.add_step(condition)

      acc = Workflow.get_component(workflow, :counter)

      workflow =
        Workflow.draw_meta_ref_edge(
          workflow,
          condition.hash,
          acc.hash,
          %{kind: :state_of, field_path: [], context_key: :counter_state}
        )

      meta_context = Workflow.prepare_meta_context(workflow, condition)

      assert meta_context == %{counter_state: 42}
    end

    test "populates multiple context keys from multiple meta_ref edges" do
      acc1 = Runic.accumulator(10, fn x, acc -> acc + x end, name: :counter1)
      acc2 = Runic.accumulator(20, fn x, acc -> acc + x end, name: :counter2)

      condition =
        Condition.new(
          work: fn _, meta_ctx -> meta_ctx.state1 + meta_ctx.state2 > 0 end,
          arity: 2,
          meta_refs: []
        )

      workflow =
        Workflow.new()
        |> Workflow.add(acc1)
        |> Workflow.add(acc2)
        |> Workflow.add_step(condition)

      acc1_component = Workflow.get_component(workflow, :counter1)
      acc2_component = Workflow.get_component(workflow, :counter2)

      workflow =
        workflow
        |> Workflow.draw_meta_ref_edge(
          condition.hash,
          acc1_component.hash,
          %{kind: :state_of, field_path: [], context_key: :state1}
        )
        |> Workflow.draw_meta_ref_edge(
          condition.hash,
          acc2_component.hash,
          %{kind: :state_of, field_path: [], context_key: :state2}
        )

      meta_context = Workflow.prepare_meta_context(workflow, condition)

      assert meta_context == %{state1: 10, state2: 20}
    end
  end

  # =============================================================================
  # Workflow.meta_dependencies/2 and meta_dependents/2 Tests
  # =============================================================================

  describe "Workflow.meta_dependencies/2" do
    test "returns empty list when node has no meta_ref edges" do
      step = Runic.step(fn x -> x end, name: :plain_step)

      workflow =
        Workflow.new()
        |> Workflow.add(step)

      step_component = Workflow.get_component(workflow, :plain_step)
      deps = Workflow.meta_dependencies(workflow, step_component)

      assert deps == []
    end

    test "returns list of target components from meta_ref edges" do
      accumulator = Runic.accumulator(0, fn x, acc -> acc + x end, name: :counter)

      condition = Condition.new(fn _, _ -> true end, 2)

      workflow =
        Workflow.new()
        |> Workflow.add(accumulator)
        |> Workflow.add_step(condition)

      acc = Workflow.get_component(workflow, :counter)

      workflow =
        Workflow.draw_meta_ref_edge(
          workflow,
          condition.hash,
          acc.hash,
          %{kind: :state_of, field_path: [], context_key: :counter_state}
        )

      deps = Workflow.meta_dependencies(workflow, condition)

      assert length(deps) == 1
      assert hd(deps).name == :counter
    end
  end

  describe "Workflow.meta_dependents/2" do
    test "returns empty list when component has no dependents" do
      accumulator = Runic.accumulator(0, fn x, acc -> acc + x end, name: :counter)

      workflow =
        Workflow.new()
        |> Workflow.add(accumulator)

      acc = Workflow.get_component(workflow, :counter)
      dependents = Workflow.meta_dependents(workflow, acc)

      assert dependents == []
    end

    test "returns list of nodes that depend on this component via meta_ref" do
      accumulator = Runic.accumulator(0, fn x, acc -> acc + x end, name: :counter)

      condition = Condition.new(fn _, _ -> true end, 2)

      workflow =
        Workflow.new()
        |> Workflow.add(accumulator)
        |> Workflow.add_step(condition)

      acc = Workflow.get_component(workflow, :counter)

      workflow =
        Workflow.draw_meta_ref_edge(
          workflow,
          condition.hash,
          acc.hash,
          %{kind: :state_of, field_path: [], context_key: :counter_state}
        )

      dependents = Workflow.meta_dependents(workflow, acc)

      assert length(dependents) == 1
      assert hd(dependents) == condition
    end
  end

  # =============================================================================
  # Workflow.build_getter_fn/1 Tests for Phase 3 kinds
  # =============================================================================

  describe "Workflow.build_getter_fn/1 for :step_ran?" do
    test "returns false when step has no :ran edges" do
      step = Runic.step(fn x -> x * 2 end, name: :doubler)

      workflow =
        Workflow.new()
        |> Workflow.add(step)

      getter_fn = Workflow.build_getter_fn(%{kind: :step_ran?})
      result = getter_fn.(workflow, :doubler)

      assert result == false
    end

    test "returns false for missing step" do
      workflow = Workflow.new()

      getter_fn = Workflow.build_getter_fn(%{kind: :step_ran?})
      result = getter_fn.(workflow, :nonexistent)

      assert result == false
    end
  end

  describe "Workflow.build_getter_fn/1 for :fact_count" do
    test "returns 0 when no facts produced" do
      step = Runic.step(fn x -> x * 2 end, name: :processor)

      workflow =
        Workflow.new()
        |> Workflow.add(step)

      getter_fn = Workflow.build_getter_fn(%{kind: :fact_count})
      count = getter_fn.(workflow, :processor)

      assert count == 0
    end

    test "counts produced facts from step" do
      step = Runic.step(fn x -> x * 2 end, name: :processor)

      workflow =
        Workflow.new()
        |> Workflow.add(step)
        |> Workflow.react_until_satisfied(5)
        |> Workflow.react_until_satisfied(10)

      getter_fn = Workflow.build_getter_fn(%{kind: :fact_count})
      count = getter_fn.(workflow, :processor)

      assert count == 2
    end

    test "returns 0 for missing component" do
      workflow = Workflow.new()

      getter_fn = Workflow.build_getter_fn(%{kind: :fact_count})
      count = getter_fn.(workflow, :nonexistent)

      assert count == 0
    end
  end

  describe "Workflow.build_getter_fn/1 for :latest_value_of" do
    test "returns nil when no facts produced" do
      step = Runic.step(fn x -> x * 2 end, name: :processor)

      workflow =
        Workflow.new()
        |> Workflow.add(step)

      getter_fn = Workflow.build_getter_fn(%{kind: :latest_value_of, field_path: []})
      value = getter_fn.(workflow, :processor)

      assert is_nil(value)
    end

    test "returns latest produced value" do
      # Build a chain where second step's output depends on first step's output
      step1 = Runic.step(fn x -> x * 2 end, name: :step1)
      step2 = Runic.step(fn x -> x + 100 end, name: :step2)

      workflow =
        Workflow.new()
        |> Workflow.add(step1)
        |> Workflow.add(step2, to: :step1)
        |> Workflow.react_until_satisfied(5)

      getter_fn = Workflow.build_getter_fn(%{kind: :latest_value_of, field_path: []})
      value = getter_fn.(workflow, :step2)

      # step2 receives 10 (5*2) and produces 110 (10+100)
      assert value == 110
    end

    test "returns nil for missing component" do
      workflow = Workflow.new()

      getter_fn = Workflow.build_getter_fn(%{kind: :latest_value_of, field_path: []})
      value = getter_fn.(workflow, :nonexistent)

      assert is_nil(value)
    end
  end

  describe "Workflow.build_getter_fn/1 for :latest_fact_of" do
    test "returns nil when no facts produced" do
      step = Runic.step(fn x -> x * 2 end, name: :processor)

      workflow =
        Workflow.new()
        |> Workflow.add(step)

      getter_fn = Workflow.build_getter_fn(%{kind: :latest_fact_of})
      fact = getter_fn.(workflow, :processor)

      assert is_nil(fact)
    end

    test "returns latest produced fact struct" do
      # Build a chain where second step's output depends on first step's output
      step1 = Runic.step(fn x -> x * 2 end, name: :step1)
      step2 = Runic.step(fn x -> x + 100 end, name: :step2)

      workflow =
        Workflow.new()
        |> Workflow.add(step1)
        |> Workflow.add(step2, to: :step1)
        |> Workflow.react_until_satisfied(5)

      getter_fn = Workflow.build_getter_fn(%{kind: :latest_fact_of})
      fact = getter_fn.(workflow, :step2)

      assert %Runic.Workflow.Fact{} = fact
      # step2 receives 10 (5*2) and produces 110 (10+100)
      assert fact.value == 110
    end

    test "returns nil for missing component" do
      workflow = Workflow.new()

      getter_fn = Workflow.build_getter_fn(%{kind: :latest_fact_of})
      fact = getter_fn.(workflow, :nonexistent)

      assert is_nil(fact)
    end
  end

  describe "Workflow.build_getter_fn/1 for :all_values_of" do
    test "returns empty list when no facts produced" do
      step = Runic.step(fn x -> x * 2 end, name: :processor)

      workflow =
        Workflow.new()
        |> Workflow.add(step)

      getter_fn = Workflow.build_getter_fn(%{kind: :all_values_of})
      values = getter_fn.(workflow, :processor)

      assert values == []
    end

    test "returns all produced values" do
      step = Runic.step(fn x -> x * 2 end, name: :processor)

      workflow =
        Workflow.new()
        |> Workflow.add(step)
        |> Workflow.react_until_satisfied(5)
        |> Workflow.react_until_satisfied(10)

      getter_fn = Workflow.build_getter_fn(%{kind: :all_values_of})
      values = getter_fn.(workflow, :processor)

      assert length(values) == 2
      assert Enum.sort(values) == [10, 20]
    end

    test "returns empty list for missing component" do
      workflow = Workflow.new()

      getter_fn = Workflow.build_getter_fn(%{kind: :all_values_of})
      values = getter_fn.(workflow, :nonexistent)

      assert values == []
    end
  end

  describe "Workflow.build_getter_fn/1 for :all_facts_of" do
    test "returns empty list when no facts produced" do
      step = Runic.step(fn x -> x * 2 end, name: :processor)

      workflow =
        Workflow.new()
        |> Workflow.add(step)

      getter_fn = Workflow.build_getter_fn(%{kind: :all_facts_of})
      facts = getter_fn.(workflow, :processor)

      assert facts == []
    end

    test "returns all produced facts" do
      step = Runic.step(fn x -> x * 2 end, name: :processor)

      workflow =
        Workflow.new()
        |> Workflow.add(step)
        |> Workflow.react_until_satisfied(5)
        |> Workflow.react_until_satisfied(10)

      getter_fn = Workflow.build_getter_fn(%{kind: :all_facts_of})
      facts = getter_fn.(workflow, :processor)

      assert length(facts) == 2
      assert Enum.all?(facts, &match?(%Runic.Workflow.Fact{}, &1))
      values = Enum.map(facts, & &1.value) |> Enum.sort()
      assert values == [10, 20]
    end

    test "returns empty list for missing component" do
      workflow = Workflow.new()

      getter_fn = Workflow.build_getter_fn(%{kind: :all_facts_of})
      facts = getter_fn.(workflow, :nonexistent)

      assert facts == []
    end
  end

  # =============================================================================
  # Phase 7: Serialization & Build Log Tests
  # =============================================================================

  describe "meta_ref edge serialization" do
    test "getter_fn is stripped from :meta_ref edges during log/1" do
      accumulator = Runic.accumulator(0, fn x, acc -> acc + x end, name: :counter)

      rule =
        Runic.rule name: :threshold_check do
          given(event: e)
          where(state_of(:counter) > 10)
          then(fn %{event: e} -> {:threshold_exceeded, e} end)
        end

      workflow =
        Workflow.new()
        |> Workflow.add(accumulator)
        |> Workflow.add(rule)

      log = Workflow.log(workflow)

      # Find the :meta_ref ReactionOccurred event
      meta_ref_event =
        Enum.find(log, fn
          %Runic.Workflow.ReactionOccurred{reaction: :meta_ref} -> true
          _ -> false
        end)

      assert meta_ref_event != nil
      # getter_fn should NOT be in the serialized properties
      refute Map.has_key?(meta_ref_event.properties, :getter_fn)
      # But the serializable fields should still be present
      assert Map.has_key?(meta_ref_event.properties, :kind)
      assert Map.has_key?(meta_ref_event.properties, :context_key)
    end

    test "log/1 output is serializable with term_to_binary" do
      accumulator = Runic.accumulator(0, fn x, acc -> acc + x end, name: :counter)

      rule =
        Runic.rule name: :threshold_check do
          given(event: e)
          where(state_of(:counter) > 10)
          then(fn %{event: e} -> {:threshold_exceeded, e} end)
        end

      workflow =
        Workflow.new()
        |> Workflow.add(accumulator)
        |> Workflow.add(rule)

      log = Workflow.log(workflow)

      # This should NOT raise - getter_fn is stripped
      binary = :erlang.term_to_binary(log)
      assert is_binary(binary)

      # Should round-trip successfully
      roundtrip = :erlang.binary_to_term(binary)
      assert roundtrip == log
    end

    test "from_log/1 rebuilds getter_fn for :meta_ref edges" do
      accumulator = Runic.accumulator(0, fn x, acc -> acc + x end, name: :counter)

      rule =
        Runic.rule name: :threshold_check do
          given(event: e)
          where(state_of(:counter) > 10)
          then(fn %{event: e} -> {:threshold_exceeded, e} end)
        end

      workflow =
        Workflow.new()
        |> Workflow.add(accumulator)
        |> Workflow.add(rule)

      log = Workflow.log(workflow)
      restored = Workflow.from_log(log)

      # Find the condition hash in the restored workflow
      rule_component = Workflow.get_component(restored, :threshold_check)
      assert rule_component != nil

      # Access condition via the rule's condition_hash
      condition = Map.get(rule_component.workflow.graph.vertices, rule_component.condition_hash)
      assert condition != nil

      # Verify the :meta_ref edge exists with a rebuilt getter_fn
      meta_ref_edges = Graph.out_edges(restored.graph, condition.hash, by: :meta_ref)
      assert length(meta_ref_edges) == 1

      edge = hd(meta_ref_edges)
      assert is_function(edge.properties.getter_fn, 2)
    end

    test "round-trip serialize → restore → execute produces same results" do
      # Create workflow with meta expression
      accumulator = Runic.accumulator(0, fn x, acc -> acc + x end, name: :counter)

      rule =
        Runic.rule name: :threshold_check do
          given(event: e)
          where(state_of(:counter) > 10)
          then(fn %{event: e} -> {:above_threshold, e} end)
        end

      workflow =
        Workflow.new()
        |> Workflow.add(accumulator)
        |> Workflow.add(rule)

      # Run the original workflow
      original =
        workflow
        |> Workflow.react_until_satisfied(5)
        |> Workflow.react_until_satisfied(8)

      original_results = Workflow.raw_productions(original)

      # Serialize and restore
      log = Workflow.log(workflow)
      binary = :erlang.term_to_binary(log)
      restored_log = :erlang.binary_to_term(binary)
      restored = Workflow.from_log(restored_log)

      # Run the restored workflow with same inputs
      restored_executed =
        restored
        |> Workflow.react_until_satisfied(5)
        |> Workflow.react_until_satisfied(8)

      restored_results = Workflow.raw_productions(restored_executed)

      # Results should be equivalent (threshold exceeded after sum > 10)
      assert Enum.sort(original_results) == Enum.sort(restored_results)
    end

    test "restored workflow with state_of in then clause executes correctly" do
      # Test that state_of in then clause works after serialization
      # Using the pattern from the working end-to-end test in runic_test.exs

      counter_acc = Runic.accumulator(0, fn x, acc -> acc + x end, name: :counter)

      emit_rule =
        Runic.rule name: :emit_counter do
          given(x: x)
          then(fn %{x: x} -> {:emitted, x, state_of(:counter)} end)
        end

      workflow =
        Workflow.new()
        |> Workflow.add(counter_acc)
        |> Workflow.add(emit_rule)

      # Serialize and restore
      log = Workflow.log(workflow)
      binary = :erlang.term_to_binary(log)
      restored = Workflow.from_log(:erlang.binary_to_term(binary))

      # Execute restored workflow
      result = Workflow.react_until_satisfied(restored, 10)
      productions = Workflow.raw_productions(result)

      # Find the emitted result
      emitted =
        Enum.find(productions, fn
          {:emitted, _, _} -> true
          _ -> false
        end)

      assert emitted != nil
      {:emitted, input, counter_state} = emitted
      assert input == 10
      assert is_integer(counter_state)
    end

    test "restored workflow with multiple meta expression kinds" do
      # Build workflow with multiple meta expression types
      step1 = Runic.step(fn x -> x * 2 end, name: :doubler)
      counter = Runic.accumulator(0, fn _, acc -> acc + 1 end, name: :counter)

      # Rule that checks both state_of and fact_count
      multi_rule =
        Runic.rule name: :multi_check do
          given(input: i)
          where(state_of(:counter) >= 2 and fact_count(:doubler) >= 2)
          then(fn %{input: _} -> :multi_triggered end)
        end

      workflow =
        Workflow.new()
        |> Workflow.add(step1)
        |> Workflow.add(counter)
        |> Workflow.add(multi_rule)

      # Serialize, restore, and verify edges
      log = Workflow.log(workflow)
      binary = :erlang.term_to_binary(log)
      restored = Workflow.from_log(:erlang.binary_to_term(binary))

      # Find the condition and verify both meta_ref edges exist
      rule_component = Workflow.get_component(restored, :multi_check)

      condition =
        Map.get(rule_component.workflow.graph.vertices, rule_component.condition_hash)

      meta_ref_edges = Graph.out_edges(restored.graph, condition.hash, by: :meta_ref)

      # Should have 2 meta_ref edges (one for state_of, one for fact_count)
      assert length(meta_ref_edges) == 2

      # Both should have functional getter_fns
      for edge <- meta_ref_edges do
        assert is_function(edge.properties.getter_fn, 2)
      end
    end

    test "restored workflow with state_of in then clause" do
      # Accumulator that tracks a counter
      accumulator = Runic.accumulator(42, fn x, acc -> acc + x end, name: :state)

      # Rule that emits the current state in then clause
      rule =
        Runic.rule name: :emit_state do
          given(value: v)
          then(fn %{value: _} -> state_of(:state) end)
        end

      workflow =
        Workflow.new()
        |> Workflow.add(accumulator)
        |> Workflow.add(rule)

      # Serialize and restore
      log = Workflow.log(workflow)
      binary = :erlang.term_to_binary(log)
      restored = Workflow.from_log(:erlang.binary_to_term(binary))

      # Execute restored workflow - accumulator will add 10 (42 + 10 = 52)
      # Rule runs and accesses state_of(:state) which should be 52
      result =
        restored
        |> Workflow.react_until_satisfied(10)

      # state_of(:state) should return 52 (42 + 10)
      productions = Workflow.raw_productions(result)
      assert 52 in productions
    end

    test "meta_ref edges point to correct target components after restoration" do
      # Verify the edge connectivity is correct after restoration
      accumulator = Runic.accumulator(0, fn x, acc -> acc + x end, name: :target_acc)

      rule =
        Runic.rule name: :check_target do
          given(event: e)
          where(state_of(:target_acc) > 5)
          then(fn %{event: e} -> {:triggered, e} end)
        end

      workflow =
        Workflow.new()
        |> Workflow.add(accumulator)
        |> Workflow.add(rule)

      # Serialize and restore
      log = Workflow.log(workflow)
      restored = Workflow.from_log(log)

      # Get the meta_ref edge
      rule_component = Workflow.get_component(restored, :check_target)

      condition =
        Map.get(rule_component.workflow.graph.vertices, rule_component.condition_hash)

      meta_ref_edges = Graph.out_edges(restored.graph, condition.hash, by: :meta_ref)

      assert length(meta_ref_edges) == 1
      edge = hd(meta_ref_edges)

      # Verify edge points to the accumulator (edge.v2 is the full struct or hash)
      target_acc = Workflow.get_component(restored, :target_acc)

      # edge.v2 could be the struct or its hash
      target_hash =
        case edge.v2 do
          %{hash: h} -> h
          h when is_integer(h) -> h
        end

      assert target_hash == target_acc.hash

      # Verify context_key is preserved
      assert edge.properties.context_key == :target_acc_state
    end

    test "workflow with runtime bindings in then clause serializes correctly" do
      # Test that pinned variables in then clause are preserved through serialization
      multiplier = 3

      rule =
        Runic.rule name: :multiplier_rule do
          given(value: v)
          then(fn %{value: v} -> v * ^multiplier end)
        end

      workflow =
        Workflow.new()
        |> Workflow.add(rule)

      # Serialize and restore
      log = Workflow.log(workflow)
      binary = :erlang.term_to_binary(log)
      restored = Workflow.from_log(:erlang.binary_to_term(binary))

      # Execute - should multiply by 3
      result =
        restored
        |> Workflow.react_until_satisfied(10)

      # 10 * 3 = 30
      productions = Workflow.raw_productions(result)
      assert 30 in productions
    end

    test "workflow with meta expressions and regular bindings serializes correctly" do
      # Test combining meta expressions with runtime bindings in then clause
      accumulator = Runic.accumulator(0, fn x, acc -> acc + x end, name: :counter)
      multiplier = 10

      # Rule that uses both state_of and pinned binding in then clause
      rule =
        Runic.rule name: :scaled_emit do
          given(x: x)
          then(fn %{x: x} -> {:scaled, x, state_of(:counter) * ^multiplier} end)
        end

      workflow =
        Workflow.new()
        |> Workflow.add(accumulator)
        |> Workflow.add(rule)

      # Serialize and restore
      log = Workflow.log(workflow)
      binary = :erlang.term_to_binary(log)
      restored = Workflow.from_log(:erlang.binary_to_term(binary))

      # Execute
      result = Workflow.react_until_satisfied(restored, 5)
      productions = Workflow.raw_productions(result)

      # Find the scaled result - it uses both state_of and pinned multiplier
      scaled =
        Enum.find(productions, fn
          {:scaled, _, _} -> true
          _ -> false
        end)

      assert scaled != nil
      {:scaled, input, scaled_state} = scaled
      assert input == 5
      # scaled_state = state_of(:counter) * multiplier
      assert is_integer(scaled_state)
      # counter state after accumulating 5 is 5, * 10 = 50
      assert scaled_state == 50
    end
  end
end
