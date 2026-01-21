defmodule Runic.RuleDSLTest do
  @moduledoc """
  Tests for the explicit Rule DSL with given/when/then syntax.

  This DSL extends Runic's pattern-matching-only rules to support:
  - Explicit variable bindings with optional type/pattern constraints (given)
  - Boolean expressions with meta-conditions (when/if)
  - Pure function reactions receiving bound variables (then/do)

  Compilation strategy:
  - given compiles to a pattern extractor function: fn input -> {:ok, bindings} | :no_match
  - when compiles to a 2-arity condition: fn bindings_map, workflow_context -> boolean
  - then compiles to a standard Runic step
  """

  use ExUnit.Case
  require Runic
  alias Runic.Workflow
  alias Runic.Workflow.Rule

  # =============================================================================
  # Block Syntax: rule do given ... when ... then ... end
  # =============================================================================

  describe "rule do given/where/then end block syntax" do
    test "compiles simple given/where/then rule" do
      rule =
        Runic.rule do
          given(order: %{status: status, total: total})
          where(status == :pending and total > 100)
          then(fn %{order: order} -> {:apply_discount, order} end)
        end

      assert %Rule{} = rule
      assert is_binary(rule.name) or is_atom(rule.name)
      assert is_integer(rule.hash)
    end

    test "compiles rule with simple binding (any type)" do
      rule =
        Runic.rule do
          given(value: value)
          where(is_integer(value) and value > 0)
          then(fn %{value: v} -> v * 2 end)
        end

      assert %Rule{} = rule
    end

    test "compiles rule with struct pattern binding" do
      rule =
        Runic.rule do
          given(order: %{id: id, items: items})
          where(length(items) > 0)

          then(fn %{order: order, id: id, items: items} ->
            %{order_id: id, item_count: length(items), order: order}
          end)
        end

      assert %Rule{} = rule
    end

    test "compiles rule with multiple bindings (map input)" do
      rule =
        Runic.rule do
          given(
            order: %{status: :pending},
            user: %{tier: tier}
          )

          where(tier == :premium)

          then(fn %{order: order, user: user} ->
            {:process_premium_order, order, user}
          end)
        end

      assert %Rule{} = rule
    end

    test "compiles rule with named option" do
      rule =
        Runic.rule name: :my_discount_rule do
          given(order: %{total: total})
          where(total > 100)
          then(fn %{order: order} -> {:apply_discount, order} end)
        end

      assert %Rule{name: :my_discount_rule} = rule
    end

    test "evaluates given/where/then rule correctly" do
      rule =
        Runic.rule do
          given(order: %{status: status, total: total})
          where(status == :pending and total > 100)

          then(fn %{order: order, total: total} ->
            {:discounted, order, total * 0.9}
          end)
        end

      workflow =
        Workflow.new()
        |> Workflow.add(rule)

      # Matching input
      result =
        workflow
        |> Workflow.react_until_satisfied(%{status: :pending, total: 150})
        |> Workflow.raw_productions()

      assert {:discounted, %{status: :pending, total: 150}, 135.0} in result

      # Non-matching input (status != :pending)
      result2 =
        Workflow.new()
        |> Workflow.add(rule)
        |> Workflow.react_until_satisfied(%{status: :confirmed, total: 150})
        |> Workflow.raw_productions()

      refute Enum.any?(result2, &match?({:discounted, _, _}, &1))

      # Non-matching input (total <= 100)
      result3 =
        Workflow.new()
        |> Workflow.add(rule)
        |> Workflow.react_until_satisfied(%{status: :pending, total: 50})
        |> Workflow.raw_productions()

      refute Enum.any?(result3, &match?({:discounted, _, _}, &1))
    end

    test "rule with only then clause (matches anything)" do
      rule =
        Runic.rule do
          then(fn _ -> :always_triggers end)
        end

      assert %Rule{} = rule

      workflow =
        Workflow.new()
        |> Workflow.add(rule)

      result =
        workflow
        |> Workflow.react_until_satisfied("anything")
        |> Workflow.raw_productions()

      assert :always_triggers in result
    end

    test "rule with given and then (no when clause)" do
      rule =
        Runic.rule do
          given(value: %{x: x})
          then(fn %{x: x} -> {:got_x, x} end)
        end

      assert %Rule{} = rule

      workflow =
        Workflow.new()
        |> Workflow.add(rule)

      result =
        workflow
        |> Workflow.react_until_satisfied(%{x: 42})
        |> Workflow.raw_productions()

      assert {:got_x, 42} in result
    end
  end

  # =============================================================================
  # Given Clause: Pattern Extraction
  # =============================================================================

  describe "given clause pattern extraction" do
    test "extracts nested field bindings" do
      rule =
        Runic.rule do
          given(order: %{customer: %{id: customer_id, tier: tier}, items: items})
          where(tier == :premium)

          then(fn %{customer_id: cid, items: items} ->
            {:premium_customer, cid, length(items)}
          end)
        end

      workflow =
        Workflow.new()
        |> Workflow.add(rule)

      result =
        workflow
        |> Workflow.react_until_satisfied(%{
          customer: %{id: "C123", tier: :premium},
          items: [1, 2, 3]
        })
        |> Workflow.raw_productions()

      assert {:premium_customer, "C123", 3} in result
    end

    test "extracts tuple bindings" do
      rule =
        Runic.rule do
          given(result: {status, payload})
          where(status == :ok)

          then(fn %{payload: p} ->
            {:processed, p}
          end)
        end

      workflow =
        Workflow.new()
        |> Workflow.add(rule)

      result =
        workflow
        |> Workflow.react_until_satisfied({:ok, "data"})
        |> Workflow.raw_productions()

      assert {:processed, "data"} in result
    end

    test "extracts list pattern bindings" do
      rule =
        Runic.rule do
          given(items: [head | tail])
          where(is_integer(head))

          then(fn %{head: h, tail: t} ->
            {h, length(t)}
          end)
        end

      workflow =
        Workflow.new()
        |> Workflow.add(rule)

      result =
        workflow
        |> Workflow.react_until_satisfied([1, 2, 3, 4])
        |> Workflow.raw_productions()

      assert {1, 3} in result
    end
  end

  # =============================================================================
  # When Clause: Boolean Expressions
  # =============================================================================

  describe "when clause boolean expressions" do
    test "supports simple comparisons" do
      rule =
        Runic.rule do
          given(value: value)
          where(value > 100)
          then(fn %{value: v} -> {:large, v} end)
        end

      workflow =
        Workflow.new()
        |> Workflow.add(rule)

      result =
        workflow
        |> Workflow.react_until_satisfied(150)
        |> Workflow.raw_productions()

      assert {:large, 150} in result
    end

    test "supports and/or logical operators" do
      rule =
        Runic.rule do
          given(value: value)
          where((value > 0 and value < 100) or value == 999)
          then(fn %{value: v} -> {:in_range_or_special, v} end)
        end

      workflow =
        Workflow.new()
        |> Workflow.add(rule)

      # Test value in range
      result1 =
        workflow
        |> Workflow.react_until_satisfied(50)
        |> Workflow.raw_productions()

      assert {:in_range_or_special, 50} in result1

      # Test special value
      result2 =
        Workflow.new()
        |> Workflow.add(rule)
        |> Workflow.react_until_satisfied(999)
        |> Workflow.raw_productions()

      assert {:in_range_or_special, 999} in result2

      # Test out of range
      result3 =
        Workflow.new()
        |> Workflow.add(rule)
        |> Workflow.react_until_satisfied(500)
        |> Workflow.raw_productions()

      refute Enum.any?(result3, &match?({:in_range_or_special, _}, &1))
    end

    test "supports negation with not" do
      rule =
        Runic.rule do
          given(value: value)
          where(not is_nil(value))
          then(fn %{value: v} -> {:not_nil, v} end)
        end

      workflow =
        Workflow.new()
        |> Workflow.add(rule)

      result =
        workflow
        |> Workflow.react_until_satisfied("hello")
        |> Workflow.raw_productions()

      assert {:not_nil, "hello"} in result
    end

    test "supports function calls in when clause" do
      rule =
        Runic.rule do
          given(items: items)
          where(length(items) > 3 and Enum.all?(items, &is_integer/1))
          then(fn %{items: items} -> {:valid_list, Enum.sum(items)} end)
        end

      workflow =
        Workflow.new()
        |> Workflow.add(rule)

      result =
        workflow
        |> Workflow.react_until_satisfied([1, 2, 3, 4])
        |> Workflow.raw_productions()

      assert {:valid_list, 10} in result
    end

    test "supports in operator" do
      rule =
        Runic.rule do
          given(value: %{status: status})
          where(status in [:pending, :processing, :confirmed])
          then(fn %{value: v} -> {:valid_status, v} end)
        end

      workflow =
        Workflow.new()
        |> Workflow.add(rule)

      result =
        workflow
        |> Workflow.react_until_satisfied(%{status: :pending})
        |> Workflow.raw_productions()

      assert Enum.any?(result, &match?({:valid_status, _}, &1))
    end
  end

  # =============================================================================
  # Then Clause: Reaction Functions
  # =============================================================================

  describe "then clause reaction functions" do
    test "receives all bindings from given clause" do
      rule =
        Runic.rule do
          given(data: %{id: id, name: name})
          where(id != nil)

          then(fn bindings ->
            # All bindings should be available
            %{
              data: bindings.data,
              id: bindings.id,
              name: bindings.name
            }
          end)
        end

      workflow =
        Workflow.new()
        |> Workflow.add(rule)

      result =
        workflow
        |> Workflow.react_until_satisfied(%{id: 1, name: "test"})
        |> Workflow.raw_productions()

      assert %{data: %{id: 1, name: "test"}, id: 1, name: "test"} in result
    end

    test "then function can access external bindings with ^" do
      multiplier = 2

      rule =
        Runic.rule do
          given(value: value)
          where(is_integer(value))

          then(fn %{value: v} ->
            v * ^multiplier
          end)
        end

      workflow =
        Workflow.new()
        |> Workflow.add(rule)

      result =
        workflow
        |> Workflow.react_until_satisfied(5)
        |> Workflow.raw_productions()

      assert 10 in result
    end
  end

  # =============================================================================
  # Named Rules with Options
  # =============================================================================

  describe "named rules with options" do
    test "rule with name option" do
      rule =
        Runic.rule name: :my_named_rule do
          given(value: value)
          where(is_integer(value))
          then(fn %{value: v} -> v end)
        end

      assert %Rule{name: :my_named_rule} = rule
    end

    test "rule with inputs/outputs options" do
      rule =
        Runic.rule name: :io_rule, inputs: [:input1], outputs: [:output1] do
          given(value: value)
          where(is_integer(value))
          then(fn %{value: v} -> v * 2 end)
        end

      assert %Rule{name: :io_rule, inputs: [:input1], outputs: [:output1]} = rule
    end
  end

  # =============================================================================
  # Edge Cases and Error Handling
  # =============================================================================

  describe "edge cases and error handling" do
    test "missing then clause raises ArgumentError" do
      assert_raise ArgumentError, ~r/then/, fn ->
        Code.eval_string("""
        require Runic
        Runic.rule do
          given value: value
          where is_integer(value)
        end
        """)
      end
    end

    test "missing when clause defaults to always true" do
      rule =
        Runic.rule do
          given(value: value)
          then(fn %{value: v} -> {:always, v} end)
        end

      workflow =
        Workflow.new()
        |> Workflow.add(rule)

      result =
        workflow
        |> Workflow.react_until_satisfied(42)
        |> Workflow.raw_productions()

      assert {:always, 42} in result
    end
  end

  # =============================================================================
  # Integration with Workflow Execution
  # =============================================================================

  describe "integration with workflow execution" do
    test "rule integrates with existing steps in workflow" do
      step = Runic.step(fn x -> x * 2 end, name: :doubler)

      rule =
        Runic.rule name: :large_detector do
          given(value: value)
          where(is_integer(value) and value > 10)
          then(fn %{value: v} -> {:large_doubled, v} end)
        end

      # Rule is connected downstream of step, so it sees step's output
      workflow =
        Workflow.new()
        |> Workflow.add(step)
        |> Workflow.add(rule, to: :doubler)

      result =
        workflow
        |> Workflow.react_until_satisfied(6)
        |> Workflow.raw_productions()

      # Step should produce 12
      assert 12 in result
      # Rule should trigger for the doubled value (12 > 10)
      assert {:large_doubled, 12} in result
    end

    test "build log captures rule closure" do
      rule =
        Runic.rule name: :logged_rule do
          given(order: %{total: total})
          where(total > 100)
          then(fn %{order: order} -> {:processed, order} end)
        end

      workflow =
        Workflow.new()
        |> Workflow.add(rule)

      build_log = Workflow.build_log(workflow)

      assert length(build_log) >= 1

      assert Enum.any?(build_log, fn event ->
               Map.get(event, :name) == :logged_rule
             end)
    end

    test "workflow can be rebuilt from log" do
      rule =
        Runic.rule name: :threshold_rule do
          given(order: %{total: total})
          where(total > 100)
          then(fn %{order: order} -> {:over_threshold, order} end)
        end

      workflow =
        Workflow.new()
        |> Workflow.add(rule)

      build_log = Workflow.build_log(workflow)
      rebuilt_workflow = Workflow.from_log(build_log)

      # Test that rebuilt workflow works the same
      result =
        rebuilt_workflow
        |> Workflow.react_until_satisfied(%{total: 150})
        |> Workflow.raw_productions()

      assert Enum.any?(result, &match?({:over_threshold, _}, &1))
    end
  end

  # =============================================================================
  # Complex Business Logic Patterns
  # =============================================================================

  describe "complex business logic patterns" do
    test "order processing with multiple conditions" do
      rule =
        Runic.rule name: :premium_order do
          given(
            order: %{
              customer: %{tier: tier, id: customer_id},
              items: items,
              total: total
            }
          )

          where(tier == :premium and total > 50 and length(items) > 0)

          then(fn %{customer_id: cid, total: total, items: items} ->
            {:premium_order, cid, total, length(items)}
          end)
        end

      workflow =
        Workflow.new()
        |> Workflow.add(rule)

      result =
        workflow
        |> Workflow.react_until_satisfied(%{
          customer: %{tier: :premium, id: "C123"},
          items: [1, 2, 3],
          total: 100
        })
        |> Workflow.raw_productions()

      assert {:premium_order, "C123", 100, 3} in result
    end

    test "conditional branching based on input type" do
      string_rule =
        Runic.rule name: :string_handler do
          given(value: value)
          where(is_binary(value))
          then(fn %{value: v} -> {:string, String.upcase(v)} end)
        end

      integer_rule =
        Runic.rule name: :integer_handler do
          given(value: value)
          where(is_integer(value))
          then(fn %{value: v} -> {:integer, v * 2} end)
        end

      workflow =
        Workflow.new()
        |> Workflow.add(string_rule)
        |> Workflow.add(integer_rule)

      # Test with string
      result1 =
        workflow
        |> Workflow.react_until_satisfied("hello")
        |> Workflow.raw_productions()

      assert {:string, "HELLO"} in result1
      refute Enum.any?(result1, &match?({:integer, _}, &1))

      # Test with integer
      result2 =
        Workflow.new()
        |> Workflow.add(string_rule)
        |> Workflow.add(integer_rule)
        |> Workflow.react_until_satisfied(5)
        |> Workflow.raw_productions()

      assert {:integer, 10} in result2
      refute Enum.any?(result2, &match?({:string, _}, &1))
    end
  end

  # =============================================================================
  # Backward Compatibility with Existing Rule Syntax
  # =============================================================================

  describe "backward compatibility with existing rule syntax" do
    test "anonymous function rules still work" do
      rule = Runic.rule(fn :potato -> :found_potato end)

      assert %Rule{} = rule
      assert Rule.check(rule, :potato)
      assert Rule.run(rule, :potato) == :found_potato
    end

    test "condition/reaction keyword syntax still works" do
      rule =
        Runic.rule(
          condition: fn x -> is_integer(x) and x > 0 end,
          reaction: fn x -> x * 2 end
        )

      assert %Rule{} = rule
      assert Rule.check(rule, 5)
      assert Rule.run(rule, 5) == 10
    end

    test "if/do alternative keyword syntax still works" do
      rule =
        Runic.rule(
          if: fn x -> is_atom(x) end,
          do: fn x -> {:atom_found, x} end
        )

      assert %Rule{} = rule
    end

    test "named rule with anonymous function still works" do
      rule = Runic.rule(fn x when is_binary(x) -> String.upcase(x) end, name: :upcaser)

      assert %Rule{name: :upcaser} = rule
      assert Rule.run(rule, "hello") == "HELLO"
    end

    test "rule with guards in anonymous function works" do
      rule =
        Runic.rule(fn item when is_integer(item) and item > 41 and item < 43 -> "fourty two" end)

      assert %Rule{} = rule
      assert Rule.check(rule, 42)
      refute Rule.check(rule, 45)
      assert Rule.run(rule, 42) == "fourty two"
    end

    test "rules with pinned bindings work" do
      some_values = [:potato, :ham, :tomato]

      escaped_rule =
        Runic.rule(
          name: "escaped rule",
          condition: fn val when is_atom(val) -> true end,
          reaction: fn val ->
            Enum.map(^some_values, fn x -> {val, x} end)
          end
        )

      assert %Rule{} = escaped_rule
      assert Rule.check(escaped_rule, :potato)

      wrk =
        Runic.workflow(
          name: "test workflow",
          rules: [escaped_rule]
        )

      results = wrk |> Workflow.react_until_satisfied(:potato) |> Workflow.productions()
      result_values = Enum.map(results, & &1.value)

      assert Enum.any?(result_values, fn v ->
               is_list(v) and {:potato, :potato} in v
             end)
    end
  end
end
