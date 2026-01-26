defmodule Runic.ThreePhaseTest do
  @moduledoc """
  Tests for the three-phase execution model (prepare/execute/apply).

  The three-phase model is now the default execution path for all react functions.
  These tests validate the prepare_for_dispatch/apply_runnable APIs for external
  schedulers and the async execution option.
  """

  use ExUnit.Case, async: true

  alias Runic.Workflow
  alias Runic.Workflow.{Fact, Runnable, Invokable}
  require Runic

  describe "prepared_runnables/1" do
    test "returns list of Runnable structs" do
      workflow =
        Runic.workflow(
          name: "test",
          steps: [Runic.step(fn x -> x * 2 end)]
        )
        |> Workflow.plan("test")

      runnables = Workflow.prepared_runnables(workflow)

      assert is_list(runnables)
      assert Enum.all?(runnables, fn r -> is_struct(r, Runnable) end)
    end

    test "runnables have pending status" do
      workflow =
        Runic.workflow(
          name: "test",
          steps: [Runic.step(fn x -> x * 2 end)]
        )
        |> Workflow.plan(5)

      [runnable] = Workflow.prepared_runnables(workflow)

      assert runnable.status == :pending
      assert runnable.input_fact.value == 5
    end
  end

  describe "prepare_for_dispatch/1" do
    test "returns workflow and runnables tuple" do
      workflow =
        Runic.workflow(
          name: "test",
          steps: [Runic.step(fn x -> x + 1 end)]
        )
        |> Workflow.plan(10)

      {result_workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

      assert is_struct(result_workflow, Workflow)
      assert is_list(runnables)
      assert length(runnables) == 1
    end
  end

  describe "apply_runnable/2" do
    test "applies completed runnable to workflow" do
      workflow =
        Runic.workflow(
          name: "test",
          steps: [Runic.step(fn x -> x * 3 end)]
        )
        |> Workflow.plan(7)

      [runnable] = Workflow.prepared_runnables(workflow)
      executed = Invokable.execute(runnable.node, runnable)

      assert executed.status == :completed
      assert executed.result.value == 21

      updated_workflow = Workflow.apply_runnable(workflow, executed)

      reactions = Workflow.reactions(updated_workflow)
      assert Enum.any?(reactions, fn f -> f.value == 21 end)
    end

    test "handles failed runnable gracefully" do
      workflow =
        Runic.workflow(
          name: "test",
          steps: [Runic.step(fn _ -> raise "boom" end)]
        )
        |> Workflow.plan("input")

      [runnable] = Workflow.prepared_runnables(workflow)
      executed = Invokable.execute(runnable.node, runnable)

      assert executed.status == :failed
      assert executed.error != nil

      updated_workflow = Workflow.apply_runnable(workflow, executed)
      assert is_struct(updated_workflow, Workflow)
    end
  end

  describe "react/1 (serial execution)" do
    test "executes single reaction cycle" do
      workflow =
        Runic.workflow(
          name: "test",
          steps: [Runic.step(fn x -> x + 10 end)]
        )

      result =
        workflow
        |> Workflow.plan(5)
        |> Workflow.react()
        |> Workflow.reactions()
        |> Enum.map(& &1.value)

      assert 15 in result
    end

    test "handles multiple steps in sequence" do
      workflow =
        Runic.workflow(
          name: "test",
          steps: [
            {Runic.step(fn x -> x * 2 end, name: :double),
             [Runic.step(fn x -> x + 1 end, name: :inc)]}
          ]
        )

      result =
        workflow
        |> Workflow.react(10)
        |> Workflow.react()
        |> Workflow.reactions()
        |> Enum.map(& &1.value)

      assert 20 in result
      assert 21 in result
    end
  end

  describe "react/2 with input" do
    test "plans and reacts in one call" do
      workflow =
        Runic.workflow(
          name: "test",
          steps: [Runic.step(fn x -> String.upcase(x) end)]
        )

      result =
        workflow
        |> Workflow.react("hello")
        |> Workflow.reactions()

      assert Enum.any?(result, fn f -> f.value == "HELLO" end)
    end

    test "handles Fact input" do
      workflow =
        Runic.workflow(
          name: "test",
          steps: [Runic.step(fn x -> x <> "!" end)]
        )

      fact = Fact.new(value: "wow")

      result =
        workflow
        |> Workflow.react(fact)
        |> Workflow.reactions()

      assert Enum.any?(result, fn f -> f.value == "wow!" end)
    end
  end

  describe "react/2 with async: true" do
    test "produces same results as serial execution" do
      workflow =
        Runic.workflow(
          name: "test",
          steps: [
            {Runic.step(fn x -> x + 1 end, name: :a), []},
            {Runic.step(fn x -> x + 2 end, name: :b), []},
            {Runic.step(fn x -> x + 3 end, name: :c), []}
          ]
        )

      serial =
        workflow
        |> Workflow.react(10)
        |> Workflow.reactions()
        |> Enum.map(& &1.value)
        |> Enum.sort()

      async =
        workflow
        |> Workflow.react(10, async: true, max_concurrency: 3)
        |> Workflow.reactions()
        |> Enum.map(& &1.value)
        |> Enum.sort()

      assert serial == async
    end

    test "respects max_concurrency option" do
      workflow =
        Runic.workflow(
          name: "test",
          steps: [Runic.step(fn x -> x end, name: :passthrough)]
        )

      result =
        workflow
        |> Workflow.react("test", async: true, max_concurrency: 1)
        |> Workflow.reactions()

      assert length(result) >= 1
    end
  end

  describe "react_until_satisfied/2" do
    test "reacts through full workflow pipeline" do
      workflow =
        Runic.workflow(
          name: "test",
          steps: [
            {Runic.step(fn x -> x * 2 end, name: :double),
             [
               {Runic.step(fn x -> x + 1 end, name: :add_one),
                [Runic.step(fn x -> x * x end, name: :square)]}
             ]}
          ]
        )

      result =
        workflow
        |> Workflow.react_until_satisfied(5)
        |> Workflow.reactions()
        |> Enum.map(& &1.value)
        |> Enum.sort()

      # 5 -> 10 -> 11 -> 121
      assert 10 in result
      assert 11 in result
      assert 121 in result
    end

    test "handles branching workflows" do
      workflow =
        Runic.workflow(
          name: "test",
          steps: [
            {Runic.step(fn x -> x + 1 end, name: :inc), []},
            {Runic.step(fn x -> x * 2 end, name: :double), []}
          ]
        )

      result =
        workflow
        |> Workflow.react_until_satisfied(10)
        |> Workflow.reactions()
        |> Enum.map(& &1.value)

      assert 11 in result
      assert 20 in result
    end
  end

  describe "react_until_satisfied/3 with async: true" do
    test "produces same results as serial execution" do
      workflow =
        Runic.workflow(
          name: "test",
          steps: [
            {Runic.step(fn x -> x * 2 end, name: :double),
             [Runic.step(fn x -> x + 1 end, name: :inc)]}
          ]
        )

      serial =
        workflow
        |> Workflow.react_until_satisfied(5)
        |> Workflow.reactions()
        |> Enum.map(& &1.value)
        |> Enum.sort()

      async =
        workflow
        |> Workflow.react_until_satisfied(5, async: true, max_concurrency: 4)
        |> Workflow.reactions()
        |> Enum.map(& &1.value)
        |> Enum.sort()

      assert serial == async
    end
  end

  describe "three-phase with conditions (rules)" do
    test "rules work with react" do
      rule = Runic.rule(fn x when is_integer(x) and x > 5 -> x * 10 end, name: :gt_5)

      workflow =
        Runic.workflow(
          name: "test",
          rules: [rule]
        )

      result =
        workflow
        |> Workflow.react_until_satisfied(10)
        |> Workflow.reactions()
        |> Enum.map(& &1.value)

      assert 100 in result
    end

    test "unsatisfied rules don't trigger" do
      rule = Runic.rule(fn x when is_integer(x) and x > 100 -> x * 10 end, name: :gt_100)

      workflow =
        Runic.workflow(
          name: "test",
          rules: [rule]
        )

      result =
        workflow
        |> Workflow.react_until_satisfied(50)
        |> Workflow.reactions()
        |> Enum.map(& &1.value)

      refute 500 in result
    end
  end

  describe "three-phase with FanOut/FanIn" do
    test "map-reduce produces correct results" do
      workflow =
        Runic.workflow(
          name: "test",
          steps: [
            {Runic.step(fn _ -> [1, 2, 3] end, name: :source),
             [
               {Runic.map(fn x -> x * 2 end, name: :double_map),
                [Runic.reduce(0, fn num, acc -> num + acc end, name: :sum, map: :double_map)]}
             ]}
          ]
        )

      result =
        workflow
        |> Workflow.react_until_satisfied("input")

      raw_values = Workflow.raw_productions(result)

      # [1,2,3] gets fanned out, each element doubled -> 2, 4, 6, then reduced to 12
      assert 2 in raw_values
      assert 4 in raw_values
      assert 6 in raw_values
      assert 12 in raw_values
    end
  end

  describe "three-phase with Join" do
    test "join waits for all parents" do
      a_step = Runic.step(fn x -> x + 1 end, name: :a)
      b_step = Runic.step(fn x -> x * 2 end, name: :b)
      sum_step = Runic.step(fn [a, b] -> a + b end, name: :sum)

      workflow =
        Runic.workflow(name: "test")
        |> Workflow.add(a_step)
        |> Workflow.add(b_step)
        |> Workflow.add(sum_step, to: [:a, :b])

      result =
        workflow
        |> Workflow.react_until_satisfied(5)
        |> Workflow.reactions()
        |> Enum.map(& &1.value)

      # 5 -> (6, 10) -> 16
      assert 6 in result
      assert 10 in result
      assert 16 in result
    end
  end

  describe "three-phase with Accumulator" do
    test "accumulator produces state from input" do
      acc = Runic.accumulator(0, fn x, acc -> x + acc end, name: :counter)

      workflow =
        Runic.workflow(
          name: "test",
          steps: [{acc, []}]
        )

      # First input: init(0) + 5 = 5
      result = Workflow.react_until_satisfied(workflow, 5)
      raw_values = Workflow.raw_productions(result)

      # Accumulator initializes to 0 then produces 0 + 5 = 5
      assert 0 in raw_values
      assert 5 in raw_values
    end
  end

  describe "external scheduler workflow" do
    test "manual three-phase cycle produces same results as react" do
      workflow =
        Runic.workflow(
          name: "equivalence_test",
          steps: [
            {Runic.step(fn x -> x * 2 end, name: :double),
             [Runic.step(fn x -> x + 1 end, name: :inc)]}
          ]
        )

      # Using react (internal three-phase)
      react_result =
        workflow
        |> Workflow.react_until_satisfied(10)
        |> Workflow.reactions()
        |> Enum.map(& &1.value)
        |> Enum.sort()

      # Using manual three-phase (external scheduler simulation)
      manual_result =
        workflow
        |> manual_react_until_satisfied(10)
        |> Workflow.reactions()
        |> Enum.map(& &1.value)
        |> Enum.sort()

      assert react_result == manual_result
    end
  end

  # Simulates external scheduler using prepare_for_dispatch/apply_runnable
  defp manual_react_until_satisfied(workflow, input) do
    workflow
    |> Workflow.plan(input)
    |> do_manual_react()
  end

  defp do_manual_react(workflow) do
    if Workflow.is_runnable?(workflow) do
      {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

      executed =
        Enum.map(runnables, fn runnable ->
          Invokable.execute(runnable.node, runnable)
        end)

      workflow =
        Enum.reduce(executed, workflow, fn r, wrk ->
          Workflow.apply_runnable(wrk, r)
        end)

      do_manual_react(workflow)
    else
      workflow
    end
  end
end
