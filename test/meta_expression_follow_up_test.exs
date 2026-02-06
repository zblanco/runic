defmodule Runic.MetaExpressionFollowUpTest do
  @moduledoc """
  Tests for Phases 1-3 of the meta-expression follow-up plan.

  Phase 1: where clause function body compilation (pin operators, non-guard expressions)
  Phase 2: Extended given pattern matching (direct map/tuple patterns)
  Phase 3: Keyword API unification (given/where/then in keyword form)
  """

  use ExUnit.Case
  require Runic
  alias Runic.Workflow
  alias Runic.Workflow.Rule

  # =============================================================================
  # Phase 1: where clause as function body (not guard)
  # =============================================================================

  describe "Phase 1: where clause with pin operators" do
    test "where clause supports pinned variable" do
      threshold = 100

      rule =
        Runic.rule do
          given(value: v)
          where(v > ^threshold)
          then(fn %{value: v} -> {:over_threshold, v} end)
        end

      assert %Rule{} = rule

      workflow =
        Workflow.new()
        |> Workflow.add(rule)

      # Should fire for value > 100
      result =
        workflow
        |> Workflow.react_until_satisfied(150)
        |> Workflow.raw_productions()

      assert {:over_threshold, 150} in result

      # Should not fire for value <= 100
      result2 =
        Workflow.new()
        |> Workflow.add(rule)
        |> Workflow.react_until_satisfied(50)
        |> Workflow.raw_productions()

      refute Enum.any?(result2, &match?({:over_threshold, _}, &1))
    end

    test "where clause supports non-guard function calls" do
      rule =
        Runic.rule do
          given(name: name)
          where(String.starts_with?(name, "prefix_"))
          then(fn %{name: n} -> {:matched, n} end)
        end

      assert %Rule{} = rule

      workflow =
        Workflow.new()
        |> Workflow.add(rule)

      # Should fire for names starting with "prefix_"
      result =
        workflow
        |> Workflow.react_until_satisfied("prefix_foo")
        |> Workflow.raw_productions()

      assert {:matched, "prefix_foo"} in result

      # Should not fire for other names
      result2 =
        Workflow.new()
        |> Workflow.add(rule)
        |> Workflow.react_until_satisfied("other_name")
        |> Workflow.raw_productions()

      refute Enum.any?(result2, &match?({:matched, _}, &1))
    end

    test "where clause supports higher-order functions" do
      rule =
        Runic.rule do
          given(items: items)
          where(Enum.any?(items, &(&1 > 0)))
          then(fn %{items: items} -> {:has_positive, length(items)} end)
        end

      assert %Rule{} = rule

      workflow =
        Workflow.new()
        |> Workflow.add(rule)

      # Should fire when any item is positive
      result =
        workflow
        |> Workflow.react_until_satisfied([-1, 0, 5])
        |> Workflow.raw_productions()

      assert {:has_positive, 3} in result

      # Should not fire when all items are non-positive
      result2 =
        Workflow.new()
        |> Workflow.add(rule)
        |> Workflow.react_until_satisfied([-1, -2, 0])
        |> Workflow.raw_productions()

      refute Enum.any?(result2, &match?({:has_positive, _}, &1))
    end

    test "existing guard-style expressions still work" do
      rule =
        Runic.rule do
          given(x: x)
          where(is_integer(x) and x > 10 and x < 100)
          then(fn %{x: x} -> {:in_range, x} end)
        end

      workflow =
        Workflow.new()
        |> Workflow.add(rule)

      result =
        workflow
        |> Workflow.react_until_satisfied(50)
        |> Workflow.raw_productions()

      assert {:in_range, 50} in result
    end
  end

  # =============================================================================
  # Phase 2: Extended given pattern matching
  # =============================================================================

  describe "Phase 2: direct map pattern in given" do
    test "given with direct map pattern binds variables" do
      rule =
        Runic.rule do
          given(%{item: i, quantity: q})
          where(q > 0)
          then(fn %{item: i, quantity: q} -> {:valid_item, i, q} end)
        end

      assert %Rule{} = rule

      workflow =
        Workflow.new()
        |> Workflow.add(rule)

      result =
        workflow
        |> Workflow.react_until_satisfied(%{item: "apple", quantity: 5})
        |> Workflow.raw_productions()

      assert {:valid_item, "apple", 5} in result
    end

    test "given with nested map destructuring" do
      rule =
        Runic.rule do
          given(%{user: %{name: name, age: age}})
          where(age >= 18)
          then(fn %{name: name} -> {:adult_user, name} end)
        end

      assert %Rule{} = rule

      workflow =
        Workflow.new()
        |> Workflow.add(rule)

      result =
        workflow
        |> Workflow.react_until_satisfied(%{user: %{name: "Alice", age: 25}})
        |> Workflow.raw_productions()

      assert {:adult_user, "Alice"} in result
    end

    test "pattern match failure produces no output" do
      rule =
        Runic.rule do
          given(%{required_key: v})
          then(fn %{required_key: v} -> {:found, v} end)
        end

      workflow =
        Workflow.new()
        |> Workflow.add(rule)

      # Input missing the required key should not trigger the rule
      result =
        workflow
        |> Workflow.react_until_satisfied(%{other_key: 42})
        |> Workflow.raw_productions()

      refute Enum.any?(result, &match?({:found, _}, &1))
    end
  end

  describe "Phase 2: tuple pattern in given" do
    test "given with two-element tuple pattern" do
      rule =
        Runic.rule do
          given({:ok, value})
          then(fn %{value: v} -> {:processed, v} end)
        end

      assert %Rule{} = rule

      workflow =
        Workflow.new()
        |> Workflow.add(rule)

      result =
        workflow
        |> Workflow.react_until_satisfied({:ok, "data"})
        |> Workflow.raw_productions()

      assert {:processed, "data"} in result

      # Should not fire for :error tuples
      result2 =
        Workflow.new()
        |> Workflow.add(rule)
        |> Workflow.react_until_satisfied({:error, "failure"})
        |> Workflow.raw_productions()

      refute Enum.any?(result2, &match?({:processed, _}, &1))
    end

    test "given with three-element tuple pattern" do
      rule =
        Runic.rule do
          given({:event, type, payload})
          where(type == :created)
          then(fn %{type: t, payload: p} -> {:handled, t, p} end)
        end

      assert %Rule{} = rule

      workflow =
        Workflow.new()
        |> Workflow.add(rule)

      result =
        workflow
        |> Workflow.react_until_satisfied({:event, :created, %{id: 1}})
        |> Workflow.raw_productions()

      assert {:handled, :created, %{id: 1}} in result
    end
  end

  # =============================================================================
  # Phase 3: Keyword API unification
  # =============================================================================

  describe "Phase 3: keyword form with given/where/then" do
    test "keyword form produces correct Rule struct" do
      rule =
        Runic.rule(
          name: :keyword_rule,
          given: [value: v],
          where: v > 10,
          then: fn %{value: v} -> {:big, v} end
        )

      assert %Rule{name: :keyword_rule} = rule
    end

    test "keyword form executes correctly" do
      rule =
        Runic.rule(
          name: :threshold_check,
          given: [order: %{total: total}],
          where: total > 100,
          then: fn %{order: order} -> {:apply_discount, order} end
        )

      workflow =
        Workflow.new()
        |> Workflow.add(rule)

      result =
        workflow
        |> Workflow.react_until_satisfied(%{total: 150})
        |> Workflow.raw_productions()

      assert {:apply_discount, %{total: 150}} in result
    end

    test "keyword form with only given and then (no where)" do
      rule =
        Runic.rule(
          given: [x: x],
          then: fn %{x: x} -> {:got, x} end
        )

      assert %Rule{} = rule

      workflow =
        Workflow.new()
        |> Workflow.add(rule)

      result =
        workflow
        |> Workflow.react_until_satisfied(42)
        |> Workflow.raw_productions()

      assert {:got, 42} in result
    end

    test "keyword form with only then (matches anything)" do
      rule =
        Runic.rule(
          name: :catch_all,
          then: fn %{input: i} -> {:caught, i} end
        )

      assert %Rule{name: :catch_all} = rule
    end

    test "keyword form with pin operators in where" do
      threshold = 50

      rule =
        Runic.rule(
          name: :pinned_rule,
          given: [v: v],
          where: v > ^threshold,
          then: fn %{v: v} -> {:over, v} end
        )

      workflow =
        Workflow.new()
        |> Workflow.add(rule)

      # Should fire for value > 50
      result =
        workflow
        |> Workflow.react_until_satisfied(75)
        |> Workflow.raw_productions()

      assert {:over, 75} in result
    end

    test "keyword form with direct map pattern" do
      rule =
        Runic.rule(
          name: :map_pattern_rule,
          given: %{x: x, y: y},
          where: x + y > 10,
          then: fn %{x: x, y: y} -> {:sum, x + y} end
        )

      workflow =
        Workflow.new()
        |> Workflow.add(rule)

      result =
        workflow
        |> Workflow.react_until_satisfied(%{x: 5, y: 8})
        |> Workflow.raw_productions()

      assert {:sum, 13} in result
    end

    test "error for mixing given/where/then with condition/reaction" do
      assert_raise ArgumentError, ~r/Cannot mix/, fn ->
        Code.eval_quoted(
          quote do
            require Runic

            Runic.rule(
              given: [x: x],
              condition: fn _ -> true end,
              then: fn _ -> :bad end
            )
          end
        )
      end
    end

    test "original condition/reaction keyword form still works" do
      rule =
        Runic.rule(
          name: :condition_style,
          condition: fn x -> is_integer(x) and x > 0 end,
          reaction: fn x -> x * 2 end
        )

      assert %Rule{name: :condition_style} = rule
      assert Rule.check(rule, 5)
      assert Rule.run(rule, 5) == 10
    end
  end

  # =============================================================================
  # Integration: All phases working together
  # =============================================================================

  describe "integration: phases 1-3 together" do
    test "keyword form with pin, non-guard where, and direct pattern" do
      multiplier = 2
      prefix = "item_"

      rule =
        Runic.rule(
          name: :complex_rule,
          given: %{name: name, value: v},
          where: String.starts_with?(name, ^prefix) and v * ^multiplier > 10,
          then: fn %{name: n, value: v} -> {:matched, n, v * multiplier} end
        )

      workflow =
        Workflow.new()
        |> Workflow.add(rule)

      # Should fire: name starts with "item_" and 8 * 2 = 16 > 10
      result =
        workflow
        |> Workflow.react_until_satisfied(%{name: "item_foo", value: 8})
        |> Workflow.raw_productions()

      assert {:matched, "item_foo", 16} in result

      # Should not fire: wrong prefix
      result2 =
        Workflow.new()
        |> Workflow.add(rule)
        |> Workflow.react_until_satisfied(%{name: "other_foo", value: 8})
        |> Workflow.raw_productions()

      refute Enum.any?(result2, &match?({:matched, _, _}, &1))

      # Should not fire: value too small
      result3 =
        Workflow.new()
        |> Workflow.add(rule)
        |> Workflow.react_until_satisfied(%{name: "item_bar", value: 2})
        |> Workflow.raw_productions()

      refute Enum.any?(result3, &match?({:matched, _, _}, &1))
    end
  end

  # =============================================================================
  # Phase 4: Strict Meta Reference Validation
  # =============================================================================

  describe "Phase 4: strict meta reference validation" do
    test "adding rule with missing target raises UnresolvedReferenceError" do
      rule =
        Runic.rule name: :check_counter do
          given(event: e)
          where(state_of(:counter) > 10)
          then(fn %{event: e} -> {:over, e} end)
        end

      assert_raise Runic.UnresolvedReferenceError, ~r/state_of\(:counter\)/, fn ->
        Workflow.new()
        |> Workflow.add(rule)
      end
    end

    test "error message includes component name" do
      rule =
        Runic.rule name: :my_named_rule do
          given(x: x)
          where(state_of(:nonexistent) > 0)
          then(fn %{x: x} -> x end)
        end

      assert_raise Runic.UnresolvedReferenceError, ~r/:my_named_rule/, fn ->
        Workflow.new()
        |> Workflow.add(rule)
      end
    end

    test "error message includes hint about adding target first" do
      rule =
        Runic.rule name: :needs_target do
          given(v: v)
          where(state_of(:target) > 5)
          then(fn %{v: v} -> v end)
        end

      error =
        assert_raise Runic.UnresolvedReferenceError, fn ->
          Workflow.new()
          |> Workflow.add(rule)
        end

      assert error.message =~ "Hint:"
      assert error.message =~ ":target"
    end

    test "adding rule after target works (no regression)" do
      counter = Runic.accumulator(0, fn x, acc -> acc + x end, name: :counter)

      rule =
        Runic.rule name: :check_counter do
          given(event: e)
          where(state_of(:counter) > 5)
          then(fn %{event: e} -> {:threshold_exceeded, e} end)
        end

      # This should work: counter is added before the rule
      workflow =
        Workflow.new()
        |> Workflow.add(counter)
        |> Workflow.add(rule)

      # Verify workflow is usable
      result =
        workflow
        |> Workflow.react_until_satisfied(10)
        |> Workflow.react_until_satisfied(1)
        |> Workflow.raw_productions()

      assert {:threshold_exceeded, 1} in result
    end

    test "state_of in then clause with missing target raises" do
      rule =
        Runic.rule name: :emit_missing do
          given(x: x)
          then(fn %{x: _x} -> {:value, state_of(:missing)} end)
        end

      assert_raise Runic.UnresolvedReferenceError, ~r/:missing/, fn ->
        Workflow.new()
        |> Workflow.add(rule)
      end
    end

    test "fact_count with missing target raises" do
      rule =
        Runic.rule name: :count_check do
          given(x: x)
          where(fact_count(:nonexistent_step) > 0)
          then(fn %{x: x} -> x end)
        end

      assert_raise Runic.UnresolvedReferenceError, ~r/:nonexistent_step/, fn ->
        Workflow.new()
        |> Workflow.add(rule)
      end
    end

    test "subcomponent reference to missing parent raises" do
      # Reference {parent_name, :subcomponent} where parent doesn't exist
      rule =
        Runic.rule name: :sub_ref_missing do
          given(x: x)
          where(state_of({:missing_parent, :accumulator}) > 0)
          then(fn %{x: x} -> x end)
        end

      error =
        assert_raise Runic.UnresolvedReferenceError, fn ->
          Workflow.new()
          |> Workflow.add(rule)
        end

      assert error.message =~ "{:missing_parent, :accumulator}"
    end

    test "multiple rules with one missing target reports the failing one" do
      counter = Runic.accumulator(0, fn x, acc -> acc + x end, name: :counter)

      valid_rule =
        Runic.rule name: :valid_rule do
          given(x: x)
          where(state_of(:counter) > 0)
          then(fn %{x: x} -> {:valid, x} end)
        end

      invalid_rule =
        Runic.rule name: :invalid_rule do
          given(y: y)
          where(state_of(:missing) > 0)
          then(fn %{y: y} -> {:invalid, y} end)
        end

      # Valid rule added after counter should work
      workflow =
        Workflow.new()
        |> Workflow.add(counter)
        |> Workflow.add(valid_rule)

      # Adding invalid rule should raise with its name
      assert_raise Runic.UnresolvedReferenceError, ~r/:invalid_rule/, fn ->
        Workflow.add(workflow, invalid_rule)
      end
    end
  end
end
