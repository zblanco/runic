defmodule WorkflowTest do
  use ExUnit.Case
  require Runic
  alias Runic.Workflow
  alias Runic.Workflow.Invokable
  alias Runic.Workflow.Step
  alias Runic.Workflow.Fact

  defmodule TextProcessing do
    require Runic

    def text_processing_workflow do
      Runic.workflow(
        name: "basic text processing example",
        steps: [
          {Runic.step(name: "tokenize", work: &TextProcessing.tokenize/1),
           [
             {Runic.step(name: "count words", work: &TextProcessing.count_words/1),
              [
                Runic.step(name: "count unique words", work: &TextProcessing.count_uniques/1)
              ]},
             Runic.step(name: "first word", work: &TextProcessing.first_word/1),
             Runic.step(name: "last word", work: &TextProcessing.last_word/1)
           ]}
        ]
      )
    end

    def tokenize(text) do
      text
      |> String.downcase()
      |> String.split(~r/[^[:alnum:]\-]/u, trim: true)
    end

    def count_words(list_of_words) do
      list_of_words
      |> Enum.reduce(Map.new(), fn word, map ->
        Map.update(map, word, 1, &(&1 + 1))
      end)
    end

    def count_uniques(word_count) do
      Enum.count(word_count)
    end

    def first_word(list_of_words) do
      List.first(list_of_words)
    end

    def last_word(list_of_words) do
      List.last(list_of_words)
    end
  end

  defmodule Counting do
    def initiator(:start_count), do: true
    def initiation(_), do: 0

    def do_increment?(:count, _count), do: true
    def incrementer(count) when is_integer(count), do: count + 1
  end

  defmodule Lock do
    def locked?(:locked), do: true
    def locked?(_), do: false

    def lock(_), do: :locked
    def unlock(_), do: :unlocked
  end

  describe "example workflows" do
    test "text processing dag" do
      wrk = TextProcessing.text_processing_workflow()

      # initial planning should include the runnable of the first step in the tree
      assert [{%Step{}, %Fact{}}] =
               wrk
               |> Workflow.plan_eagerly("anybody want a peanut")
               |> Workflow.next_runnables()

      ran_workflow =
        wrk
        |> Workflow.react_until_satisfied("anybody want a peanut")

      # 5 steps in the workflow reacted until satisfied means 5 facts produced
      assert 5 ==
               ran_workflow
               |> Workflow.productions()
               |> Enum.count()

      for raw_production <- Workflow.raw_productions(ran_workflow) do
        assert raw_production in [
                 ["anybody", "want", "a", "peanut"],
                 "anybody",
                 "peanut",
                 4,
                 %{"a" => 1, "anybody" => 1, "peanut" => 1, "want" => 1}
               ]
      end
    end
  end

  describe "workflow composition" do
    test "merge/2 combines two workflows and their memory" do
      wrk =
        Runic.workflow(
          name: "merge test",
          steps: [
            {Runic.step(fn num -> num + 1 end),
             [
               Runic.step(fn num -> num + 2 end),
               Runic.step(fn num -> num + 4 end)
             ]}
          ]
        )
        |> Workflow.react(2)

      [{step_1, fact_1}, {step_2, fact_2} | _] = Workflow.next_runnables(wrk)

      new_wrk_1 = Invokable.invoke(step_1, wrk, fact_1)
      new_wrk_2 = Invokable.invoke(step_2, wrk, fact_2)

      merged_wrk = Workflow.merge(new_wrk_1, new_wrk_2)

      assert Enum.count(Workflow.reactions(merged_wrk)) == 4

      for reaction <- Workflow.raw_reactions(merged_wrk), do: assert(reaction in [2, 3, 5, 7])

      for reaction <- Workflow.raw_reactions(new_wrk_1) ++ Workflow.raw_reactions(new_wrk_2),
          do: assert(reaction in Workflow.raw_reactions(merged_wrk))

      assert Enum.empty?(Workflow.next_runnables(merged_wrk))
    end

    test "a workflow can be merged into another workflow" do
      text_processing_workflow = TextProcessing.text_processing_workflow()

      some_other_workflow =
        Runic.workflow(
          name: "test workflow",
          rules: [
            Runic.rule(
              fn
                :potato -> "potato!"
              end,
              name: "rule1"
            ),
            Runic.rule(
              fn item when is_integer(item) and item > 41 and item < 43 ->
                result = Enum.random(1..10)
                result
              end,
              name: "rule2"
            )
          ]
        )

      new_wrk = Workflow.merge(text_processing_workflow, some_other_workflow)
      assert match?(%Workflow{}, new_wrk)

      text_processing_workflow
      |> Workflow.react_until_satisfied("anybody want a peanut?")
      |> Workflow.reactions()
    end
  end

  describe "stateful workflow models" do
    test "joins are steps where many parents must have ran and produced consequent facts" do
      join_with_1_dependency =
        Runic.workflow(
          name: "workflow with joins",
          steps: [
            {[Runic.step(fn num -> num * 2 end), Runic.step(fn num -> num * 3 end)],
             [
               Runic.step(fn num_1, num_2 -> num_1 * num_2 end)
             ]}
          ]
        )

      assert match?(%Workflow{}, join_with_1_dependency)

      j_1 =
        join_with_1_dependency
        |> Workflow.plan_eagerly(2)

      assert Enum.count(Workflow.next_runnables(j_1)) == 3

      j_1_runnables_after_reaction =
        j_1
        |> Workflow.react()
        |> Workflow.next_runnables()

      assert Enum.count(j_1_runnables_after_reaction) == 2

      j_1_runnables_after_third_reaction =
        j_1
        |> Workflow.react()
        |> Workflow.react()
        |> Workflow.react()
        |> Workflow.raw_reactions()

      assert 24 in j_1_runnables_after_third_reaction

      join_with_many_dependencies =
        Runic.workflow(
          name: "workflow with joins",
          steps: [
            {[Runic.step(fn num -> num * 2 end), Runic.step(fn num -> num * 3 end)],
             [
               Runic.step(fn num_1, num_2 -> num_1 * num_2 end),
               Runic.step(fn num_1, num_2 -> num_1 + num_2 end),
               Runic.step(fn num_1, num_2 -> num_2 - num_1 end)
             ]}
          ]
        )

      assert match?(%Workflow{}, join_with_many_dependencies)

      assert join_with_many_dependencies
             |> Workflow.plan(2)
             |> Workflow.next_runnables()
             |> Enum.count() == 2

      assert join_with_many_dependencies
             |> Workflow.react(2)
             |> Workflow.react()
             |> Workflow.next_runnables()
             |> Enum.count() == 3

      reacted_join_with_many_dependencies =
        join_with_many_dependencies
        |> Workflow.react_until_satisfied(2)
        |> Workflow.raw_reactions()

      assert 24 in reacted_join_with_many_dependencies
      assert 10 in reacted_join_with_many_dependencies
      assert 2 in reacted_join_with_many_dependencies
    end
  end

  test "a workflow made of many rules and conditions can evaluate a composition of the rules" do
    workflow =
      Runic.workflow(
        name: "test workflow",
        rules: [
          Runic.rule(
            fn
              :potato -> "potato!"
            end,
            name: "rule1"
          ),
          Runic.rule(
            fn item when is_integer(item) and item > 41 and item < 43 ->
              result = Enum.random(1..10)
              result
            end,
            name: "rule2"
          )
        ]
      )

    wrk = Workflow.plan_eagerly(workflow, :potato)

    assert Enum.count(Workflow.next_runnables(wrk)) == 1
    assert not is_nil(Workflow.matches(wrk))

    next_facts =
      Workflow.react(wrk)
      |> Workflow.reactions()

    assert Enum.any?(next_facts, &match?(%{value: "potato!"}, &1))

    wrk = Workflow.plan_eagerly(workflow, 42)
    assert Enum.count(Workflow.next_runnables(wrk)) == 1

    [result_value] =
      Workflow.next_runnables(wrk)
      |> Enum.map(fn {step, fact} -> Runic.Workflow.Components.run(step.work, fact.value) end)

    assert is_integer(result_value)
  end

  describe "purge_memory/1" do
    test "purges memory from a workflow" do
      wrk =
        Runic.workflow(
          name: "purge test",
          steps: [
            {Runic.step(fn num -> num + 1 end),
             [
               Runic.step(fn num -> num + 2 end),
               Runic.step(fn num -> num + 4 end)
             ]}
          ]
        )
        |> Workflow.react(2)

      wrk = Workflow.purge_memory(wrk)

      assert Enum.empty?(Workflow.reactions(wrk))
    end
  end

  describe "named components" do
    test "workflow components that are given a named can be retrieved by their name" do
      wrk =
        Workflow.new()
        |> Workflow.add_step(Runic.step(name: "step 1", work: fn num -> num + 1 end))

      refute is_nil(Workflow.get_component(wrk, "step 1"))
    end

    test "workflow components that are not given a name cannot be retrieved by their name" do
      wrk =
        Workflow.new()
        |> Workflow.add_step(Runic.step(work: fn num -> num + 1 end))

      assert is_nil(Workflow.get_component(wrk, "step 1"))
    end

    test "get_component!/2 raises an error if the component is not present" do
      wrk =
        Workflow.new()
        |> Workflow.add_step(Runic.step(name: "step 1", work: fn num -> num + 1 end))

      refute is_nil(Workflow.get_component(wrk, "step 1"))
      assert_raise KeyError, fn -> Workflow.get_component!(wrk, "a step that isn't present") end
    end

    test "fetch_component/2 returns an {:ok, step} or {:error, :no_component_by_name}" do
      wrk =
        Workflow.new()
        |> Workflow.add_step(Runic.step(name: "step 1", work: fn num -> num + 1 end))

      return = Workflow.fetch_component(wrk, "step 1")
      assert match?({:ok, %Step{}}, return)

      assert Workflow.fetch_component(wrk, "a step that isn't present") ==
               {:error, :no_component_by_name}
    end

    test "component retrieval can return complex components in their original form" do
      state_machine =
        Runic.state_machine(
          name: "state_machine_test",
          init: 0,
          reducer: fn
            num, state when is_integer(num) and state >= 0 and state < 10 -> state + num * 1
            num, state when is_integer(num) and state >= 10 and state < 20 -> state + num * 2
            num, state when is_integer(num) and state >= 20 and state < 30 -> state + num * 3
            _num, state -> state
          end
        )

      rule =
        Runic.rule(
          fn num when is_integer(num) and num > 0 -> num * 2 end,
          name: "rule1"
        )

      wrk =
        Runic.workflow(
          name: "combined workflow",
          rules: [rule]
        )
        |> Workflow.merge(state_machine)
        |> Workflow.add_step(Runic.step(name: "step 1", work: fn num -> num + 1 end))

      assert Workflow.get_component(wrk, "state_machine_test") == state_machine
      assert Workflow.get_component(wrk, "rule1") == rule
      assert match?(%Step{}, Workflow.get_component(wrk, "step 1"))
    end

    test "component names can be used in construction for adding steps" do
      wrk =
        Runic.workflow(
          name: "named components",
          steps: [
            {Runic.step(name: "step 1", work: fn num -> num + 1 end),
             [
               Runic.step(name: "step 2", work: fn num -> num + 2 end),
               Runic.step(name: "step 3", work: fn num -> num + 3 end)
             ]}
          ]
        )

      wrk =
        Workflow.add_step(wrk, "step 2", Runic.step(name: "step 4", work: fn num -> num + 4 end))

      assert not is_nil(Workflow.get_component(wrk, "step 4"))

      results =
        wrk
        |> Workflow.react_until_satisfied(1)
        |> Workflow.raw_productions()

      assert 8 in results
    end

    test "adding a component with a name that is already in use raises an error" do
    end

    test "components can be removed by name" do
      wrk =
        Workflow.new()
        |> Workflow.add_step(Runic.step(name: "step 1", work: fn num -> num + 1 end))

      refute is_nil(Workflow.get_component(wrk, "step 1"))
      wrk = Workflow.remove_component(wrk, "step 1")
      assert Workflow.get_component(wrk, "step 1") == nil
    end

    test "removing a component that does not exist raises an error when using remove_component!/2" do
      wrk =
        Workflow.new()
        |> Workflow.add_step(Runic.step(name: "step 1", work: fn num -> num + 1 end))

      assert_raise KeyError, fn ->
        Workflow.remove_component!(wrk, "a step that isn't present")
      end
    end

    # test "components can be replaced by name" do
    #   wrk =
    #     Workflow.new()
    #     |> Workflow.add_step(Runic.step(name: "step 1", work: fn num -> num + 1 end))

    #   assert Workflow.get_component(wrk, "step 1") == %Step{}
    #   wrk = Workflow.replace_component(wrk, "step 1", Runic.step(name: "step 1", work: fn num -> num + 2 end))
    #   assert Workflow.get_component(wrk, "step 1").work.(1) == 3
    # end

    test "components can be connected and composed by name in a workflow" do
      wrk =
        Runic.workflow(
          name: "test workflow",
          rules: [
            Runic.rule(
              fn
                :potato -> "potato!"
              end,
              name: "rule1"
            ),
            Runic.rule(
              fn item when is_integer(item) and item > 41 and item < 43 ->
                item * Enum.random(1..10)
              end,
              name: "rule2"
            )
          ]
        )
        |> Workflow.merge(
          Runic.state_machine(
            name: "state_machine",
            init: 0,
            reducer: fn num, state -> state + num end
          )
        )

      # connection API should allow compatible components to be connected to eachother in the workflow
      # it should delegate to the component protocol for how to connect and if its possible

      wrk =
        Workflow.add(
          wrk,
          Runic.step(fn state -> state * 4 end),
          # name and kind of subcomponent?
          to: {"state_machine", :reducer},
          as: "reaction2"
        )

      # The component impl should know how to attach common components to each other
      wrk =
        Workflow.add(
          wrk,
          Runic.step(fn state -> state * 4 end, name: "reaction3"),
          to: "state_machine"
        )

      wrk =
        Workflow.add(
          wrk,
          Runic.step(fn n -> n + 1 end, name: "reaction4"),
          to: "rule2"
        )

      # assert %Step{} = Runic.component_of(wrk, "rule1", :reaction)
      # assert %Workflow.Condition{} = Workflow.component_of(wrk, "rule1", :condition)
      # assert not is_nil Workflow.component_of(wrk, "state_machine", :init)
      # assert not is_nil Workflow.component_of(wrk, "state_machine", :reducer)
    end
  end

  describe "map" do
    test "applies the function for every item in the enumerable" do
      wrk =
        Runic.workflow(
          name: "map test",
          steps: [
            {Runic.step(fn num -> Enum.map(0..3, &(&1 + num)) end),
             [
               Runic.map(fn num -> num * 2 end)
             ]}
          ]
        )

      wrk = Workflow.react_until_satisfied(wrk, 1)

      for reaction <- Workflow.raw_productions(wrk) do
        assert reaction in [0, 2, 4, 6, [1, 2, 3, 4], 8]
      end
    end

    test "map can apply pipelines of steps" do
      wrk =
        Runic.workflow(
          name: "map test",
          steps: [
            {Runic.step(fn num -> Enum.map(0..3, &(&1 + num)) end),
             [
               Runic.map(
                 {Runic.step(fn num -> num * 2 end),
                  [
                    Runic.step(fn num -> num + 1 end),
                    Runic.step(fn num -> num + 4 end)
                  ]}
               )
             ]}
          ]
        )

      wrk = Workflow.react_until_satisfied(wrk, 1)

      Workflow.raw_productions(wrk)

      Enum.count(Workflow.reactions(wrk))
    end

    test "expressions can include joins" do
      wrk =
        Runic.workflow(
          name: "map test",
          steps: [
            {Runic.step(fn num -> Enum.map(0..3, &(&1 + num)) end),
             [
               Runic.map(
                 {[Runic.step(fn num -> num * 2 end), Runic.step(fn num -> num * 3 end)],
                  [
                    Runic.step(fn num_1, num_2 -> num_1 * num_2 end)
                  ]}
               )
             ]}
          ]
        )

      wrk = Workflow.react_until_satisfied(wrk, 1)

      dbg(Workflow.productions(wrk))
    end

    test "map model" do
      map =
        Runic.map(
          {Runic.step(fn num -> num * 42 end),
           [
             Runic.step(fn num -> num + 69 end),
             Runic.step(fn num -> num + 420 end)
           ]}
        )
    end
  end

  describe "reduce" do
    test "reduces the enumerable with the function" do
      wrk =
        Runic.workflow(
          name: "reduce test",
          steps: [
            {Runic.step(fn num -> Enum.map(0..3, &(&1 + num)) end),
             [
               {Runic.map(fn num -> num * 2 end),
                [
                  Runic.reduce([], fn num, acc -> [num | acc] end)
                ]}
             ]}
          ]
        )

      wrk = Workflow.react_until_satisfied(wrk, 2)

      for num <- [4, 6, 8, 10] do
        assert num in Workflow.raw_productions(wrk)
      end

      dbg(Workflow.raw_productions(wrk))

      assert Enum.any?(Workflow.raw_productions(wrk), fn value ->
               set_value = MapSet.new([value])

               MapSet.member?(set_value, 4) and
                 MapSet.member?(set_value, 6) and MapSet.member?(set_value, 8) and
                 MapSet.member?(set_value, 10)
             end)
    end

    test "named map expressions can be reduced using the named components API" do
      wrk =
        Runic.workflow(
          name: "reduce test",
          steps: [
            {Runic.step(fn _input -> 0..3 end),
             [
               Runic.map(fn num -> num * 2 end, name: "map")
             ]}
          ]
        )

      wrk =
        Workflow.add(wrk, Runic.reduce(0, fn num, acc -> num + acc end, name: "reduce"),
          to: "map"
        )

      refute is_nil(Workflow.get_component(wrk, "reduce"))

      wrk = Workflow.react_until_satisfied(wrk, "potato")

      for reaction <- Workflow.raw_productions(wrk) do
        assert reaction in [0..3, 0, 2, 4, 6, 12]
      end
    end

    test "reduce can be used outside of the map expression inside a pipeline with a name" do
      wrk =
        Runic.workflow(
          name: "reduce test",
          steps: [
            {Runic.step(fn -> 0..3 end),
             [
               {Runic.map(fn num -> num + 1 end, name: "map"),
                [
                  Runic.reduce(0, fn num, acc -> num + acc end, map: "map")
                ]}
             ]}
          ]
        )
    end
  end

  # describe "continuations" do
  #   test "continuations can add additional steps and runnables to a workflow after a step has been run in order to continue a computation" do
  #     wrk =
  #       Runic.workflow(
  #         name: "continuation test",
  #         steps: [
  #           Runic.step(fn num -> Enum.map(0..3, fn _ -> num end) end,
  #             after: fn step, wrk, fact ->
  #               # we shouldn't expose complexity of internal invokables to user
  #               # instead we should return a workflow with an input fact to add as a runnable
  #               # the continuation must be a runnable pair of a component and a fact
  #               # we can merge the workflows together but once all steps resolve we should
  #               # remove the continuation components from the workflow with trust that memory
  #               # will be maintained with ancestry to the original step which produced the continuation

  #               # it's important to avoid running continuation workflows for new facts unless the after function wants to
  #               # in which case it should happen at runtime again because the prior continuation is invalid in the next runtime context

  #               Runic.workflow(steps: Enum.map(fact.value, &Runic.step(fn num -> &1 + 1 end)))
  #             end
  #           )
  #         ]
  #       )
  #       |> Workflow.react(2)

  #     Runic.workflow(
  #       name: "continuation test",
  #       steps: [
  #         {Runic.step(fn num -> Enum.map(0..3, fn _ -> num end) end),
  #          [
  #            {Runic.map(fn num -> num + 1 end),
  #             [
  #               Runic.reduce(0, fn num, acc -> num + acc end)
  #             ]}
  #          ]}
  #       ]
  #     )
  #   end

  #   test "continuations aren't present for separate generation / external fact" do
  #   end
  # end
end
