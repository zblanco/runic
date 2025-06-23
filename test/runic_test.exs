defmodule RunicTest do
  # Component constructor API tests
  use ExUnit.Case
  # doctest Runic

  alias Runic.Workflow.Step
  alias Runic.Workflow.Rule
  alias Runic.Workflow.StateMachine
  alias Runic.Workflow.Condition
  alias Runic.Workflow
  require Runic

  defmodule Examples do
    def is_potato?(:potato), do: true
    def is_potato?("potato"), do: true

    def new_potato(), do: :potato
    def new_potato(_), do: :potato

    def potato_baker(:potato), do: :baked_potato
    def potato_baker("potato"), do: :baked_potato

    def potato_transformer(_), do: :potato

    def potato_masher(:potato, :potato), do: :mashed_potato
    def potato_masher("potato", "potato"), do: :mashed_potato
  end

  describe "Runic.rule/2 macro" do
    test "creates rules using anonymous functions" do
      rule1 = Runic.rule(fn :potato -> "potato!" end)
      rule2 = Runic.rule(fn "potato" -> "potato!" end)
      rule3 = Runic.rule(fn :tomato -> "tomato!" end)

      rule4 =
        Runic.rule(fn item when is_integer(item) and item > 41 and item < 43 -> "fourty two" end)

      rule5 =
        Runic.rule(fn item when is_integer(item) and item > 41 and item < 43 ->
          result = Enum.random(1..10)
          result
        end)

      rules = [rule1, rule2, rule3, rule4, rule5]

      for rule <- rules, do: assert(match?(%Rule{}, rule))
    end

    test "created rules can be evaluated" do
      some_rule =
        Runic.rule(fn item when is_integer(item) and item > 41 and item < 43 -> "fourty two" end)

      assert Rule.check(some_rule, 42)
      refute Rule.check(some_rule, 45)
      assert Rule.run(some_rule, 42) == "fourty two"
    end

    test "a valid rule can be created from functions of arity > 1" do
      rule =
        Runic.rule(fn num, other_num when is_integer(num) and is_integer(other_num) ->
          num * other_num
        end)

      assert match?(%Rule{}, rule)
      assert Rule.check(rule, :potato) == false
      assert Rule.check(rule, 10) == false
      assert Rule.check(rule, 1) == false
      assert Rule.check(rule, [1, 2]) == true
      assert Rule.check(rule, [:potato, "tomato"]) == false
      assert Rule.run(rule, [10, 2]) == 20
      assert Rule.run(rule, [2, 90]) == 180
    end

    test "escapes runtime values with '^'" do
      some_values = [:potato, :ham, :tomato]

      escaped_rule =
        Runic.rule(
          name: "escaped rule",
          condition: fn val when is_atom(val) -> true end,
          reaction: fn val ->
            Enum.map(^some_values, fn x ->
              {val, x}
            end)
          end
        )

      assert match?(%Rule{}, escaped_rule)
      assert Rule.check(escaped_rule, :potato)

      wrk =
        Runic.workflow(
          name: "test workflow",
          rules: [escaped_rule]
        )

      build_log = wrk |> Workflow.build_log()

      rebuilt_wrk = Workflow.from_log(build_log)

      assert wrk |> Workflow.react_until_satisfied(:potato) |> Workflow.productions() ==
               rebuilt_wrk |> Workflow.react_until_satisfied(:potato) |> Workflow.productions()
    end

    test "escapes other opts with `^`" do
      some_values = [:potato, :ham, :tomato]
      name = "escaped rule"

      escaped_rule =
        Runic.rule(
          name: ^name,
          condition: fn val when is_atom(val) -> true end,
          reaction: fn val ->
            Enum.map(^some_values, fn x ->
              {val, x}
            end)
          end
        )

      assert match?(%Rule{}, escaped_rule)
      assert Rule.check(escaped_rule, :potato)

      wrk =
        Runic.workflow(
          name: "test workflow",
          rules: [escaped_rule]
        )

      build_log = wrk |> Workflow.build_log()

      rebuilt_wrk = Workflow.from_log(build_log)

      assert wrk |> Workflow.react_until_satisfied(:potato) |> Workflow.productions() ==
               rebuilt_wrk |> Workflow.react_until_satisfied(:potato) |> Workflow.productions()
    end

    test "a function can wrap construction to build custom rules at runtime" do
      builder = fn list_of_things ->
        Runic.rule(
          name: "dynamic rule",
          condition: fn thing -> Enum.member?(list_of_things, thing) end,
          reaction: fn thing -> "#{thing} in list_of_things!" end
        )
      end

      dynamic_rule = builder.([:potato, :ham, :tomato])
      assert match?(%Rule{}, dynamic_rule)
      assert Rule.check(dynamic_rule, :potato)
      refute Rule.check(dynamic_rule, :yam)
    end

    # test "supports `if` macro as a valid rule" do
    #   rule = Runic.rule :potato -> :is_potato end

    #   assert match?(%Rule{}, rule)
    #   assert Rule.check(rule, true)
    #   refute Rule.check(rule, false)
    # end

    # test "rule does not support if statement's `else` clause and raises recommending to use a `workflow/1` constructor instead" do
    #   assert_raise Runic.Rule.InvalidRuleError, fn ->
    #     Runic.rule(if(true, do: "true", else: "false"))
    #   end
    # end

    # test "supports `unless` macro as a valid rule" do

    # end
  end

  describe "Runic.step constructors" do
    test "a Step can be created with params using Runic.step/1" do
      assert match?(%Step{}, Runic.step(work: fn -> :potato end, name: "potato"))
    end

    test "a Step can be created with params using Runic.step/2" do
      assert match?(%Step{}, Runic.step(fn -> :potato end, name: "potato"))
      assert match?(%Step{}, Runic.step(fn _ -> :potato end, name: "potato"))

      assert match?(
               %Step{},
               Runic.step(fn something -> something * something end, name: "squarifier")
             )

      assert match?(%Step{}, Runic.step(&Examples.potato_baker/1, name: "potato_baker"))
      assert match?(%Step{}, Runic.step(&Examples.potato_transformer/1, name: "potato_baker"))
      assert match?(%Step{}, Runic.step(&Examples.potato_baker/1))
      assert match?(%Step{}, Runic.step(&Examples.potato_transformer/1))
    end

    test "a Step can be run for localized testing" do
      squarifier_step = Runic.step(fn something -> something * something end, name: "squarifier")

      assert 4 == Runic.Workflow.Step.run(squarifier_step, 2)
    end
  end

  describe "Runic.condition/1" do
    test "conditions can be made from kinds of elixir functions that return a boolean" do
      assert match?(%Condition{}, Runic.condition(fn :potato -> true end))
      assert match?(%Condition{}, Runic.condition(&Examples.is_potato?/1))
      assert match?(%Condition{}, Runic.condition({Examples, :is_potato?, 1}))
    end
  end

  describe "Runic.state_machine/1" do
    test "constructs a %StateMachine{} given a name, init, and a reducer expression" do
      state_machine =
        Runic.state_machine(
          name: "adds integers of some factor to its state up until 30 then stops",
          init: 0,
          reducer: fn
            num, state when is_integer(num) and state >= 0 and state < 10 -> state + num * 1
            num, state when is_integer(num) and state >= 10 and state < 20 -> state + num * 2
            num, state when is_integer(num) and state >= 20 and state < 30 -> state + num * 3
            _num, state -> state
          end
        )

      assert match?(%StateMachine{}, state_machine)

      wrk = Runic.transmute(state_machine)

      assert match?(%Workflow{}, wrk)
    end

    test "reactors can be included to respond to state changes" do
      potato_lock =
        Runic.state_machine(
          name: "potato lock",
          init: %{code: "potato", state: :locked, contents: "ham"},
          reducer: fn
            :lock, state ->
              %{state | state: :locked}

            {:unlock, input_code}, %{code: code, state: :locked} = state
            when input_code == code ->
              %{state | state: :unlocked}

            {:unlock, _input_code}, %{state: :locked} = state ->
              state

            _input_code, %{state: :unlocked} = state ->
              state
          end,
          reactors: [
            fn %{state: :unlocked, contents: contents} -> contents end,
            fn %{state: :locked} -> {:error, :locked} end
          ]
        )

      productions_from_1_cycles =
        potato_lock.workflow
        |> Workflow.plan_eagerly({:unlock, "potato"})
        |> Workflow.react()
        |> Workflow.productions()

      assert Enum.count(productions_from_1_cycles) == 3

      workflow_after_2_cycles =
        potato_lock.workflow
        |> Workflow.plan_eagerly({:unlock, "potato"})
        |> Workflow.react()
        |> Workflow.plan()
        |> Workflow.react()

      assert Enum.count(Workflow.productions(workflow_after_2_cycles)) == 4

      assert "ham" in Workflow.raw_reactions(workflow_after_2_cycles)
    end
  end

  describe "Runic.workflow/1 constructor" do
    test "constructs an operable %Workflow{} given a set of steps" do
      steps_to_add = [
        Runic.step(fn something -> something * something end, name: "squarifier"),
        Runic.step(fn something -> something * 2 end, name: "doubler"),
        Runic.step(fn something -> something * -1 end, name: "negator")
      ]

      workflow =
        Runic.workflow(
          name: "a test workflow",
          steps: steps_to_add
        )

      assert match?(%Workflow{}, workflow)

      steps = Runic.Workflow.steps(workflow)

      assert Enum.any?(steps, &Enum.member?(steps_to_add, &1))
    end

    test "constructs an operable %Workflow{} given a tree of dependent steps" do
      workflow =
        Runic.workflow(
          name: "a test workflow with dependent steps",
          steps: [
            {Runic.step(fn x -> x * x end, name: "squarifier"),
             [
               Runic.step(fn x -> x * -1 end, name: "negator"),
               Runic.step(fn x -> x * 2 end, name: "doubler")
             ]},
            {Runic.step(fn x -> x * 2 end, name: "doubler"),
             [
               {Runic.step(fn x -> x * 2 end, name: "doubler"),
                [
                  Runic.step(fn x -> x * 2 end, name: "doubler"),
                  Runic.step(fn x -> x * -1 end, name: "negator")
                ]}
             ]}
          ]
        )

      assert match?(%Workflow{}, workflow)
    end

    test "constructs an operable %Workflow{} given a set of rules" do
      workflow =
        Runic.workflow(
          name: "a test workflow",
          rules: [
            Runic.rule(fn :foo -> :bar end, name: "foobar"),
            Runic.rule(fn :potato -> :tomato end, name: "tomato when potato"),
            Runic.rule(
              fn item when is_integer(item) and item > 41 and item < 43 ->
                "the answer to life the universe and everything"
              end,
              name: "what about the question?"
            )
          ]
        )

      assert match?(%Workflow{}, workflow)
    end
  end

  describe "transmute/1" do
    test "invokes the Component protocol to return a workflow of the component" do
      # construct and invoke the Component protocol on each component type and common data types like lists of steps and rules
      step = Runic.step(fn x -> x * x end, name: "squarifier")
      rule = Runic.rule(fn :potato -> :tomato end, name: "tomato when potato")

      state_machine =
        Runic.state_machine(
          name: "transitional_factor",
          init: 0,
          reducer: fn
            num, state when is_integer(num) and state >= 0 and state < 10 -> state + num * 1
            num, state when is_integer(num) and state >= 10 and state < 20 -> state + num * 2
            num, state when is_integer(num) and state >= 20 and state < 30 -> state + num * 3
            _num, state -> state
          end
        )

      condition = Runic.condition(fn :potato -> true end)

      assert %Workflow{} = Runic.transmute(step)
      assert %Workflow{} = Runic.transmute(rule)
      assert %Workflow{} = Runic.transmute(state_machine)
      assert %Workflow{} = Runic.transmute(condition)
      assert %Workflow{} = Runic.transmute([step, rule, state_machine, condition])
    end
  end

  test "all runic components can be recovered from a log with bindings and their original environment" do
    some_var = 1
    some_other_var = 2

    step = Runic.step(fn num -> num + ^some_var end, name: :step_1)
    rule = Runic.rule(fn num when is_integer(num) -> num + ^some_var end, name: :rule_1)

    state_machine =
      Runic.state_machine(
        name: "state_machine",
        init: 0,
        reducer: fn num, state -> state + num + ^some_var end
      )

    map = Runic.map(fn num -> num + ^some_var end, name: :map_1)

    reduce =
      Runic.reduce(0, fn num, acc -> num + acc + ^some_var end, name: :reduce_1, map: :map_1)

    # Assert that some_var is present in the bindings of each component
    assert step.bindings[:some_var] == 1
    assert rule.bindings[:some_var] == 1
    assert state_machine.bindings[:some_var] == 1
    assert map.bindings[:some_var] == 1
    assert reduce.bindings[:some_var] == 1

    # Assert that some_other_var is NOT present in the bindings of any component
    refute Map.has_key?(step.bindings, :some_other_var)
    refute Map.has_key?(rule.bindings, :some_other_var)
    refute Map.has_key?(state_machine.bindings, :some_other_var)
    refute Map.has_key?(map.bindings, :some_other_var)
    refute Map.has_key?(reduce.bindings, :some_other_var)

    # Create workflows using explicit add to ensure components are properly added
    step_workflow =
      Workflow.new()
      |> Workflow.add(step)

    rule_workflow =
      Workflow.new()
      |> Workflow.add(rule)

    state_machine_workflow =
      Workflow.new()
      |> Workflow.add(state_machine)

    map_workflow =
      Workflow.new()
      |> Workflow.add(map)

    reduce_with_map_workflow =
      map_workflow
      |> Workflow.add(reduce, to: :map_1)

    step_results =
      step_workflow
      |> Workflow.react_until_satisfied(2)
      |> Workflow.raw_productions()

    rule_results =
      rule_workflow
      |> Workflow.react_until_satisfied(2)
      |> Workflow.raw_productions()

    state_machine_results =
      state_machine_workflow
      |> Workflow.plan_eagerly(2)
      |> Workflow.react_until_satisfied()
      |> Workflow.raw_productions()

    reduce_results =
      reduce_with_map_workflow
      |> Workflow.plan_eagerly([1, 2, 3])
      |> Workflow.react_until_satisfied()
      |> Workflow.raw_productions()

    map_results =
      map_workflow
      |> Workflow.plan_eagerly([1, 2, 3])
      |> Workflow.react_until_satisfied()
      |> Workflow.raw_productions()

    step_log = Workflow.build_log(step_workflow)
    rule_log = Workflow.build_log(rule_workflow)
    state_machine_log = Workflow.build_log(state_machine_workflow)
    map_log = Workflow.build_log(map_workflow)
    reduce_log = Workflow.build_log(reduce_with_map_workflow)

    recovery_code = """
    defmodule TestRecovery do
      # This is a separate module that doesn't have access to our test's bindings

      def recover_and_test(step_log, rule_log, state_machine_log, map_log, reduce_log) do
        require Runic
        alias Runic.Workflow

        # Recover workflows from logs
        recovered_step_workflow = Workflow.from_log(step_log)

        recovered_rule_workflow = Workflow.from_log(rule_log)

        recovered_state_machine_workflow = Workflow.from_log(state_machine_log)
        recovered_map_workflow = Workflow.from_log(map_log)
        recovered_reduce_workflow = Workflow.from_log(reduce_log)

        recovered_reduce_workflow.graph

        # evaluate rebuilt workflows

        rule_result =
          recovered_rule_workflow
          |> Workflow.react_until_satisfied(2)
          |> Workflow.raw_productions()

        state_machine_result =
          recovered_state_machine_workflow
          |> Workflow.plan_eagerly(2)
          |> Workflow.react_until_satisfied()
          |> Workflow.raw_productions()

        map_result =
          recovered_map_workflow
          |> Workflow.plan_eagerly([1, 2, 3])
          |> Workflow.react_until_satisfied()
          |> Workflow.raw_productions()

        reduce_result =
          recovered_reduce_workflow
          |> Workflow.plan_eagerly([1, 2, 3])
          |> Workflow.react_until_satisfied()
          |> Workflow.raw_productions()

        step_result =
          recovered_step_workflow
          |> Workflow.react_until_satisfied(2)
          |> Workflow.raw_productions()

        %{
          step_result: step_result,
          rule_result: rule_result,
          state_machine_result: state_machine_result,
          map_result: map_result,
          reduce_result: reduce_result
        }
      end
    end

    TestRecovery.recover_and_test(step_log, rule_log, state_machine_log, map_log, reduce_log)
    """

    # Evaluate the recovery code in a separate context
    {results, _binding} =
      Code.eval_string(recovery_code,
        step_log: step_log,
        rule_log: rule_log,
        state_machine_log: state_machine_log,
        map_log: map_log,
        reduce_log: reduce_log
      )

    for result <- step_results do
      assert result in results.step_result
    end

    for result <- rule_results do
      assert result in results.rule_result
    end

    for result <- state_machine_results do
      assert result in results.state_machine_result
    end

    for result <- map_results do
      assert result in results.map_result
    end

    for result <- reduce_results do
      assert result in results.reduce_result
    end
  end
end
