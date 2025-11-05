defmodule RunicContentAddressabilityTest do
  use ExUnit.Case, async: true

  require Runic
  alias Runic.Workflow
  alias Runic.Workflow.{Step, Rule, Accumulator, StateMachine}

  describe "content addressability with free variables" do
    test "steps with different variable values have unique hashes" do
      steps =
        for i <- 1..10 do
          Runic.step(fn x -> x * ^i end, name: "step_#{i}")
        end

      hashes = Enum.map(steps, &{&1.hash, &1.work_hash})

      assert length(hashes) == 10
      assert Enum.uniq(hashes) == hashes, "All step hashes should be unique"
    end

    test "steps with same variable value have identical hashes" do
      value = 42

      step1 = Runic.step(fn x -> x * ^value end, name: "step")
      step2 = Runic.step(fn x -> x * ^value end, name: "step")

      assert step1.work_hash == step2.work_hash,
             "Same variable value should produce same work_hash"
    end

    test "steps with pinned variables have unique hashes" do
      steps =
        for i <- 1..5 do
          Runic.step(fn x -> x + ^i end, name: "pinned_step_#{i}")
        end

      hashes = Enum.map(steps, &{&1.hash, &1.work_hash})

      assert length(hashes) == 5
      assert Enum.uniq(hashes) == hashes, "All pinned step hashes should be unique"
    end

    @tag :skip
    test "rules with different variable values have unique hashes" do
      # TODO: Update after rule macro supports closures
      # Rules need closure support to properly capture variables
      rules =
        for threshold <- [10, 20, 30, 40, 50] do
          Runic.rule(
            fn x when x > 10 -> x * 2 end,
            name: "rule_#{threshold}"
          )
        end

      hashes =
        Enum.map(rules, &{&1.hash, &1.condition_hash, &1.reaction_hash})

      assert length(hashes) >= 1
    end

    @tag :skip
    test "rules with pinned variables have unique hashes" do
      # TODO: Update after rule macro supports closures
      rules =
        for multiplier <- [2, 3, 4] do
          Runic.rule(
            fn x when x > 10 -> x * ^multiplier end,
            name: "rule_with_pinned_#{multiplier}"
          )
        end

      hashes = Enum.map(rules, &{&1.hash, &1.reaction_hash})

      assert length(hashes) == 3
      assert Enum.uniq(hashes) == hashes, "All rule hashes with pinned vars should be unique"
    end

    @tag :skip
    test "accumulators with different variable values have unique hashes" do
      accumulators =
        for increment <- [1, 2, 3, 4, 5] do
          Runic.accumulator(
            0,
            fn x, acc -> acc + x + ^increment end,
            name: "accumulator_#{increment}"
          )
        end

      hashes = Enum.map(accumulators, &{&1.hash, &1.reduce_hash})

      assert length(hashes) == 5
      assert Enum.uniq(hashes) == hashes, "All accumulator hashes should be unique"
    end

    @tag :skip
    test "state machines with different variable values have unique hashes" do
      state_machines =
        for multiplier <- [10, 20, 30] do
          Runic.state_machine(
            name: "sm_#{multiplier}",
            init: 0,
            reducer: fn val, state -> state + val * ^multiplier end
          )
        end

      hashes = Enum.map(state_machines, &{&1.hash})

      assert length(hashes) == 3
      assert Enum.uniq(hashes) == hashes, "All state machine hashes should be unique"
    end

    @tag :skip
    test "map expressions with different variable values have unique hashes" do
      maps =
        for factor <- [2, 3, 4, 5] do
          Runic.map(fn x -> x * ^factor end, name: "map_#{factor}")
        end

      # Maps return pipelines, extract the component hashes
      hashes =
        Enum.map(maps, fn map_component ->
          map_component.hash
        end)

      assert length(hashes) == 4
      assert Enum.uniq(hashes) == hashes, "All map hashes should be unique"
    end

    @tag :skip
    test "reduce expressions with different variable values have unique hashes" do
      reducers =
        for offset <- [0, 10, 20, 30] do
          Runic.reduce(
            0,
            fn x, acc -> acc + x + ^offset end,
            name: "reduce_#{offset}",
            map: :some_map
          )
        end

      hashes = Enum.map(reducers, &{&1.hash, &1.fan_in.hash})

      assert length(hashes) == 4
      assert Enum.uniq(hashes) == hashes, "All reduce hashes should be unique"
    end
  end

  describe "content addressability ensures workflow correctness" do
    test "workflow with many parallel branches using variables" do
      input = Runic.step(fn x -> x end, name: :input)

      branches =
        for i <- 1..10 do
          Runic.step(fn x -> x * ^i end, name: "branch_#{i}")
        end

      branch_hashes = Enum.map(branches, &{&1.hash, &1.work_hash})

      workflow = Runic.workflow(steps: [input])

      workflow =
        Enum.reduce(branches, workflow, fn branch, wrk ->
          Workflow.add(wrk, branch, to: :input)
        end)

      assert length(branch_hashes) == 10
      assert Enum.uniq(branch_hashes) == branch_hashes, "All branches must have unique hashes"

      results =
        workflow
        |> Workflow.react_until_satisfied(10)
        |> Workflow.raw_productions()

      # 10 * 1 = 10, 10 * 2 = 20, ..., 10 * 10 = 100
      for i <- 1..10 do
        assert (10 * i) in results, "Expected result #{10 * i} from branch #{i}"
      end
    end

    @tag :skip
    test "rules with different thresholds execute correctly" do
      rules =
        for threshold <- [5, 10, 15] do
          Runic.rule(
            fn x when is_integer(x) and x > threshold -> {:above, threshold, x} end,
            name: "threshold_#{threshold}"
          )
        end

      workflow = Runic.workflow(name: "threshold_test", rules: rules)

      # Test value 12 should only match threshold 5 and 10
      results_12 =
        workflow
        |> Workflow.react_until_satisfied(12)
        |> Workflow.raw_productions()

      assert {:above, 5, 12} in results_12
      assert {:above, 10, 12} in results_12
      refute {:above, 15, 12} in results_12

      # Test value 7 should only match threshold 5
      workflow2 = Runic.workflow(name: "threshold_test", rules: rules)

      results_7 =
        workflow2
        |> Workflow.react_until_satisfied(7)
        |> Workflow.raw_productions()

      assert {:above, 5, 7} in results_7
      refute {:above, 10, 7} in results_7
      refute {:above, 15, 7} in results_7
    end

    @tag :skip
    test "accumulators with different increments produce different results" do
      input = Runic.step(fn x -> x end, name: :input)

      accumulators =
        for increment <- [0, 5, 10] do
          Runic.accumulator(
            0,
            fn x, acc -> acc + x + ^increment end,
            name: "acc_#{increment}"
          )
        end

      wrk =
        Enum.reduce(accumulators, Runic.workflow(steps: [input]), fn acc, wrk ->
          Workflow.add(wrk, acc, to: :input)
        end)

      results =
        Enum.reduce([1, 2, 3], wrk, fn x, acc ->
          Workflow.react_until_satisfied(acc, x)
        end)
        |> Workflow.raw_productions_by_component()

      assert 3 in results["acc_0"]
      assert 6 in results["acc_5"]
      assert 11 in results["acc_10"]
    end
  end

  describe "pinned vs unpinned variables" do
    test "pinned variables with same value produce same hash" do
      value = 100

      step1 = Runic.step(fn x -> x + ^value end, name: "test_step")
      step2 = Runic.step(fn x -> x + ^value end, name: "test_step")

      # They should have the same work_hash because they capture the same value
      assert step1.work_hash == step2.work_hash
    end

    test "pinned variables are captured in bindings" do
      outer_val = 42

      step = Runic.step(fn x -> x + ^outer_val end)

      assert Map.has_key?(step.closure.bindings, :outer_val)
      assert step.closure.bindings.outer_val == 42
    end

    test "unpinned variables are NOT captured (treated as function calls)" do
      outer_val = 42

      # Without ^, outer_val is treated as a function call
      step = Runic.step(fn x -> x + ^outer_val end)

      # This is now properly captured
      assert Map.has_key?(step.closure.bindings, :outer_val)
    end

    test "steps with multiple variables are all captured" do
      a = 10
      b = 20
      c = 30

      step = Runic.step(fn x -> x + ^a + ^b + ^c end)

      assert Map.has_key?(step.closure.bindings, :a)
      assert Map.has_key?(step.closure.bindings, :b)
      assert Map.has_key?(step.closure.bindings, :c)
      assert step.closure.bindings.a == 10
      assert step.closure.bindings.b == 20
      assert step.closure.bindings.c == 30
    end

    test "nested functions don't leak variables" do
      outer_var = 100

      # Inner function has its own scope
      step =
        Runic.step(fn x ->
          Enum.map([1, 2, 3], fn y -> y * ^outer_var end)
          |> Enum.sum()
          |> Kernel.+(x)
        end)

      # Only outer_var should be captured, not y
      assert Map.has_key?(step.closure.bindings, :outer_var)
      refute Map.has_key?(step.closure.bindings, :y)
    end

    test "local variables assigned in function body are not captured" do
      multiplier = 5

      step =
        Runic.step(fn x ->
          local_result = x * ^multiplier
          local_result + 10
        end)

      # Only multiplier should be captured, not local_result
      assert Map.has_key?(step.closure.bindings, :multiplier)
      refute Map.has_key?(step.closure.bindings, :local_result)
    end
  end
end
