defmodule Runic.TransmutableProtocolTest do
  use ExUnit.Case, async: true
  require Runic

  setup do
    step = Runic.step(fn x -> x * 2 end, name: "doubler")
    rule = Runic.rule(fn :input -> :output end, name: "transformer")

    state_machine =
      Runic.state_machine(
        name: "counter",
        init: 0,
        reducer: fn
          :inc, state -> state + 1
          :dec, state -> state - 1
        end
      )

    # Custom user data structure for testing to_component
    custom_data = %{
      type: :custom_processor,
      function: fn x -> x * 3 end,
      metadata: %{name: "tripler", description: "Multiplies by 3"}
    }

    %{
      step: step,
      rule: rule,
      state_machine: state_machine,
      custom_data: custom_data
    }
  end

  describe "to_workflow/1 (renamed from transmute/1)" do
    test "converts step to workflow", %{step: step} do
      workflow = Runic.Transmutable.to_workflow(step)

      assert %Runic.Workflow{} = workflow
      assert workflow.graph |> Graph.vertices() |> Enum.any?(&(&1 == step))
    end

    test "converts rule to workflow", %{rule: rule} do
      workflow = Runic.Transmutable.to_workflow(rule)

      assert %Runic.Workflow{} = workflow
      refute is_nil(workflow.components[rule.name])
    end

    test "converts state machine to workflow", %{state_machine: state_machine} do
      workflow = Runic.Transmutable.to_workflow(state_machine)

      assert %Runic.Workflow{} = workflow
      refute is_nil(workflow.components[state_machine.name])
    end

    test "converts list of components to workflow", %{step: step, rule: rule} do
      workflow = Runic.Transmutable.to_workflow([step, rule])

      assert %Runic.Workflow{} = workflow
      assert workflow.graph |> Graph.vertices() |> Enum.any?(&(&1 == step))
      refute is_nil(workflow.components[rule.name])
    end

    test "workflow passes through unchanged", %{step: step} do
      original_workflow = Runic.Transmutable.to_workflow(step)
      converted_workflow = Runic.Transmutable.to_workflow(original_workflow)

      assert original_workflow == converted_workflow
    end
  end

  describe "to_component/1" do
    test "converts custom data to runic step component", %{custom_data: custom_data} do
      component = Runic.Transmutable.to_component(custom_data)

      assert %Runic.Workflow.Step{} = component
      assert component.name == custom_data.metadata.name
      assert is_function(component.work)
    end

    test "converts function to runic step component" do
      fun = fn x -> x + 10 end
      component = Runic.Transmutable.to_component(fun)

      assert %Runic.Workflow.Step{} = component
      assert is_function(component.work)
    end

    test "converts anonymous function AST to runic rule component" do
      ast =
        quote do
          fn :match -> :result end
        end

      component = Runic.Transmutable.to_component(ast)

      assert %Runic.Workflow.Rule{} = component
      assert component.arity == 1
    end

    test "runic components pass through unchanged", %{step: step, rule: rule} do
      assert Runic.Transmutable.to_component(step) == step
      assert Runic.Transmutable.to_component(rule) == rule
    end
  end

  describe "compatibility between to_workflow and to_component" do
    test "to_component -> to_workflow roundtrip works", %{custom_data: custom_data} do
      component = Runic.Transmutable.to_component(custom_data)
      workflow = Runic.Transmutable.to_workflow(component)

      assert %Runic.Workflow{} = workflow
      assert workflow.graph |> Graph.vertices() |> Enum.any?(&(&1 == component))
    end

    test "user data -> component -> workflow preserves functionality", %{custom_data: custom_data} do
      component = Runic.Transmutable.to_component(custom_data)
      workflow = Runic.Transmutable.to_workflow(component)

      # Should be able to invoke the workflow and get expected results
      assert %Runic.Workflow{} = workflow
      assert %Runic.Workflow.Step{} = component

      # Test that the function behavior is preserved
      test_input = 5
      expected_output = custom_data.function.(test_input)
      actual_output = component.work.(test_input)

      assert actual_output == expected_output
    end
  end

  describe "backward compatibility" do
    test "transmute/1 still works but is deprecated", %{step: step} do
      # Test that existing transmute calls still work
      workflow = Runic.Transmutable.transmute(step)

      assert %Runic.Workflow{} = workflow

      # Should be equivalent to to_workflow
      workflow2 = Runic.Transmutable.to_workflow(step)
      assert workflow == workflow2
    end
  end

  describe "Workflow.add/3 auto-transmutation" do
    alias Runic.Test.ScoringRule
    alias Runic.Workflow

    test "adding a transmutable struct to a workflow converts it to a component" do
      scoring_rule = ScoringRule.new(name: :high_score, threshold: 10, score: 5, comparator: :gt)

      workflow = Workflow.new() |> Workflow.add(scoring_rule)

      component = Workflow.get_component(workflow, :high_score)
      assert %Runic.Workflow.Step{} = component
      assert component.name == :high_score
    end

    test "transmuted component is executable in the workflow" do
      scoring_rule = ScoringRule.new(name: :high_score, threshold: 10, score: 5, comparator: :gt)

      workflow = Workflow.new() |> Workflow.add(scoring_rule)

      results =
        workflow
        |> Workflow.react_until_satisfied(15)
        |> Workflow.raw_productions()

      assert 5 in results

      zero_results =
        workflow
        |> Workflow.react_until_satisfied(3)
        |> Workflow.raw_productions()

      assert 0 in zero_results
    end

    test "adding a transmutable struct as a child of another component" do
      parent = Runic.step(fn x -> x end, name: :passthrough)

      scoring_rule =
        ScoringRule.new(name: :child_scorer, threshold: 0, score: 10, comparator: :gt)

      workflow =
        Workflow.new()
        |> Workflow.add(parent)
        |> Workflow.add(scoring_rule, to: :passthrough)

      assert Workflow.get_component(workflow, :child_scorer)

      results =
        workflow
        |> Workflow.react_until_satisfied(5)
        |> Workflow.raw_productions()

      assert 10 in results
    end

    test "adding multiple transmutable structs with different comparators" do
      gt_rule = ScoringRule.new(name: :above_ten, threshold: 10, score: 1, comparator: :gt)
      lt_rule = ScoringRule.new(name: :below_five, threshold: 5, score: 2, comparator: :lt)

      workflow =
        Workflow.new()
        |> Workflow.add(gt_rule)
        |> Workflow.add(lt_rule)

      above_results =
        workflow
        |> Workflow.react_until_satisfied(15)
        |> Workflow.raw_productions()

      assert 1 in above_results
      assert 0 in above_results

      below_results =
        workflow
        |> Workflow.react_until_satisfied(3)
        |> Workflow.raw_productions()

      assert 0 in below_results
      assert 2 in below_results
    end

    test "to_component protocol dispatch for domain struct" do
      scoring_rule = ScoringRule.new(name: :scorer, threshold: 50, score: 100, comparator: :gte)
      component = Runic.Transmutable.to_component(scoring_rule)

      assert %Runic.Workflow.Step{} = component
      assert component.name == :scorer
      assert component.work.(50) == 100
      assert component.work.(49) == 0
    end

    test "to_workflow protocol dispatch for domain struct" do
      scoring_rule = ScoringRule.new(name: :scorer, threshold: 5, score: 3, comparator: :lt)
      workflow = Runic.Transmutable.to_workflow(scoring_rule)

      assert %Runic.Workflow{} = workflow

      results =
        workflow
        |> Workflow.react_until_satisfied(2)
        |> Workflow.raw_productions()

      assert 3 in results
    end
  end
end
