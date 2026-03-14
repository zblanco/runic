defmodule Runic.StateMachineTest do
  use ExUnit.Case, async: true
  require Runic

  alias Runic.Workflow
  alias Runic.Workflow.{StateMachine, Accumulator, Rule}

  describe "Form 1: keyword-list constructor" do
    test "constructs a StateMachine with accumulator and no reactors" do
      sm =
        Runic.state_machine(
          name: :counter,
          init: 0,
          reducer: fn x, acc -> acc + x end
        )

      assert %StateMachine{name: :counter} = sm
      assert %Accumulator{} = sm.accumulator
      assert sm.accumulator.name == :counter_accumulator
      assert sm.reactor_rules == []
    end

    test "constructs a StateMachine with named reactors" do
      sm =
        Runic.state_machine(
          name: :threshold,
          init: 0,
          reducer: fn x, acc -> acc + x end,
          reactors: [
            over_limit: fn state when state > 100 -> :over_limit end,
            under_limit: fn state when state <= 100 -> :within_range end
          ]
        )

      assert length(sm.reactor_rules) == 2
      rule_names = Enum.map(sm.reactor_rules, & &1.name)
      assert :over_limit in rule_names
      assert :under_limit in rule_names
    end

    test "constructs a StateMachine with unnamed reactors (auto-named)" do
      sm =
        Runic.state_machine(
          name: :auto_named,
          init: 0,
          reducer: fn x, acc -> acc + x end,
          reactors: [
            fn state when state > 10 -> :over_ten end,
            fn state when state < 0 -> :negative end
          ]
        )

      assert length(sm.reactor_rules) == 2
      rule_names = Enum.map(sm.reactor_rules, & &1.name)
      assert :auto_named_reactor_0 in rule_names
      assert :auto_named_reactor_1 in rule_names
    end

    test "literal init value is wrapped in a thunk" do
      sm =
        Runic.state_machine(
          name: :literal_init,
          init: 42,
          reducer: fn _x, acc -> acc end
        )

      assert is_function(sm.accumulator.init, 0)
      assert sm.accumulator.init.() == 42
    end

    test "function init is preserved" do
      sm =
        Runic.state_machine(
          name: :fn_init,
          init: fn -> %{count: 0} end,
          reducer: fn _x, acc -> acc end
        )

      assert is_function(sm.accumulator.init, 0)
      assert sm.accumulator.init.() == %{count: 0}
    end

    test "basic accumulation works without reactors" do
      sm =
        Runic.state_machine(
          name: :simple_sum,
          init: 0,
          reducer: fn x, acc -> acc + x end
        )

      wrk =
        Workflow.new()
        |> Workflow.add(sm)
        |> Workflow.react_until_satisfied(5)

      prods = Workflow.raw_productions(wrk)
      assert 5 in prods
    end

    test "multi-clause reducer handles pattern matching" do
      sm =
        Runic.state_machine(
          name: :lock,
          init: %{code: "secret", state: :locked},
          reducer: fn
            :lock, state -> %{state | state: :locked}
            {:unlock, code}, %{code: code, state: :locked} = state -> %{state | state: :unlocked}
            _, state -> state
          end
        )

      wrk =
        Workflow.new()
        |> Workflow.add(sm)
        |> Workflow.react_until_satisfied({:unlock, "secret"})

      prods = Workflow.raw_productions(wrk)
      assert Enum.any?(prods, &match?(%{state: :unlocked}, &1))
    end
  end

  describe "reactor execution" do
    test "reactor fires when state matches pattern" do
      sm =
        Runic.state_machine(
          name: :reactor_test,
          init: 0,
          reducer: fn x, acc -> acc + x end,
          reactors: [
            over_ten: fn state when state > 10 -> :over_ten end
          ]
        )

      wrk =
        Workflow.new()
        |> Workflow.add(sm)
        |> Workflow.react_until_satisfied(15)

      prods = Workflow.raw_productions(wrk)
      assert :over_ten in prods
    end

    test "reactor does not fire when state does not match" do
      sm =
        Runic.state_machine(
          name: :no_match_test,
          init: 0,
          reducer: fn x, acc -> acc + x end,
          reactors: [
            over_hundred: fn state when state > 100 -> :over_hundred end
          ]
        )

      wrk =
        Workflow.new()
        |> Workflow.add(sm)
        |> Workflow.react_until_satisfied(5)

      prods = Workflow.raw_productions(wrk)
      refute :over_hundred in prods
    end

    test "multiple reactors fire independently" do
      sm =
        Runic.state_machine(
          name: :multi_reactor,
          init: 0,
          reducer: fn x, acc -> acc + x end,
          reactors: [
            positive: fn state when state > 0 -> :positive end,
            even: fn state when rem(state, 2) == 0 -> :even end
          ]
        )

      wrk =
        Workflow.new()
        |> Workflow.add(sm)
        |> Workflow.react_until_satisfied(4)

      prods = Workflow.raw_productions(wrk)
      assert :positive in prods
      assert :even in prods
    end
  end

  describe "sub-component access" do
    test "get_component returns accumulator" do
      sm =
        Runic.state_machine(
          name: :accessible,
          init: 0,
          reducer: fn x, acc -> acc + x end,
          reactors: [
            threshold: fn state when state > 10 -> :over end
          ]
        )

      wrk = Workflow.new() |> Workflow.add(sm)

      # Access accumulator by kind
      accumulators = Workflow.get_component(wrk, {:accessible, :accumulator})
      assert is_list(accumulators)
      assert Enum.any?(accumulators, &match?(%Accumulator{}, &1))
    end

    test "get_component returns reactor rules" do
      sm =
        Runic.state_machine(
          name: :reactor_access,
          init: 0,
          reducer: fn x, acc -> acc + x end,
          reactors: [
            threshold: fn state when state > 10 -> :over end
          ]
        )

      wrk = Workflow.new() |> Workflow.add(sm)

      # Access reactor rules by kind
      reactors = Workflow.get_component(wrk, {:reactor_access, :reactor})
      assert is_list(reactors)
      assert length(reactors) == 1
      assert Enum.any?(reactors, &match?(%Rule{}, &1))
    end
  end

  describe "composition" do
    test "state machine composes with other components" do
      sm =
        Runic.state_machine(
          name: :composable,
          init: 0,
          reducer: fn x, acc -> acc + x end
        )

      step = Runic.step(fn x -> x * 2 end, name: :doubler)

      wrk =
        Workflow.new()
        |> Workflow.add(step)
        |> Workflow.add(sm, to: :doubler)
        |> Workflow.react_until_satisfied(5)

      prods = Workflow.raw_productions(wrk)
      # Step doubles 5 to 10, accumulator receives 10
      assert 10 in prods
    end

    test "state machine transmutable to_workflow" do
      sm =
        Runic.state_machine(
          name: :transmutable_sm,
          init: 0,
          reducer: fn x, acc -> acc + x end
        )

      wrk = Runic.Transmutable.to_workflow(sm)
      assert %Workflow{} = wrk
      refute is_nil(wrk.components[:transmutable_sm])
    end
  end

  describe "content addressability" do
    test "state machine has a deterministic hash" do
      sm =
        Runic.state_machine(
          name: :hash_test,
          init: 0,
          reducer: fn x, acc -> acc + x end
        )

      assert is_integer(sm.hash)
      assert sm.hash != 0
    end

    test "different reducers produce different hashes" do
      sm1 =
        Runic.state_machine(
          name: :hash_diff,
          init: 0,
          reducer: fn x, acc -> acc + x end
        )

      sm2 =
        Runic.state_machine(
          name: :hash_diff,
          init: 0,
          reducer: fn x, acc -> acc * x end
        )

      assert sm1.hash != sm2.hash
    end
  end

  describe "run_context support" do
    test "state machine works with run_context present" do
      sm =
        Runic.state_machine(
          name: :ctx_sm,
          init: 0,
          reducer: fn x, acc -> acc + x end
        )

      wrk =
        Workflow.new()
        |> Workflow.add(sm)
        |> Workflow.put_run_context(%{_global: %{env: :test}})
        |> Workflow.react_until_satisfied(5)

      prods = Workflow.raw_productions(wrk)
      assert 5 in prods
    end
  end

  describe "no legacy node types" do
    test "state machine workflow contains only standard primitives" do
      sm =
        Runic.state_machine(
          name: :primitives_only,
          init: 0,
          reducer: fn x, acc -> acc + x end,
          reactors: [
            check: fn state when state > 0 -> :positive end
          ]
        )

      wrk = Workflow.new() |> Workflow.add(sm)
      vertices = Graph.vertices(wrk.graph)

      # Should contain only standard types: Root, Accumulator, Condition, Step, StateMachine, Facts
      vertex_types = Enum.map(vertices, & &1.__struct__) |> Enum.uniq()

      for type <- vertex_types do
        assert type in [
                 Runic.Workflow.Root,
                 Runic.Workflow.Accumulator,
                 Runic.Workflow.Condition,
                 Runic.Workflow.Step,
                 Runic.Workflow.StateMachine,
                 Runic.Workflow.Rule,
                 Runic.Workflow.Fact
               ],
               "Unexpected vertex type: #{inspect(type)}"
      end
    end
  end
end
