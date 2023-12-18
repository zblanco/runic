defmodule RunicTest do
  # Component constructor API tests
  use ExUnit.Case
  doctest Runic

  alias Runic.Workflow.Step
  alias Runic.Workflow.Rule
  alias Runic.Workflow.StateMachine
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

    # test "escapes runtime values with '^'" do
    #   some_values = [:potato, :ham, :tomato]

    #   escaped_rule =
    #     Runic.rule(
    #       name: "escaped_rule",
    #       condition: fn val when val in ^some_values -> true end,
    #       reaction: "food"
    #     )

    #   assert match?(%Rule{}, escaped_rule)
    #   assert Rule.check(escaped_rule, :potato)
    # end

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

  describe "Runic.state_machine/1" do
    test "constructs a Flowable %StateMachine{} given a name, init, and a reducer expression" do
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

      wrk = Runic.Flowable.to_workflow(state_machine)

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

      assert Enum.count(productions_from_1_cycles) == 2

      workflow_after_2_cycles =
        potato_lock.workflow
        |> Workflow.plan_eagerly({:unlock, "potato"})
        |> Workflow.react()
        |> Workflow.plan()
        |> Workflow.react()

      assert Enum.count(Workflow.productions(workflow_after_2_cycles)) == 3

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
      # construct and invoke the Flowable protocol on each component type and common data types like lists of steps and rules
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

      assert %Workflow{} == Runic.transmute(step)
      assert %Workflow{} == Runic.transmute(rule)
      assert %Workflow{} == Runic.transmute(state_machine)
      assert %Workflow{} == Runic.transmute(condition)
      assert %Workflow{} == Runic.transmute([step, rule, state_machine, condition])
    end
  end
end
