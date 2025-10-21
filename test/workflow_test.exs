defmodule WorkflowTest do
  use ExUnit.Case
  require Runic

  alias Runic.Workflow
  alias Runic.Workflow.Invokable
  alias Runic.Workflow.Step
  alias Runic.Workflow.Fact
  alias Runic.Workflow.ReactionOccurred

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

  describe "Runic.Workflow" do
    test "invoke_with_events/2 returns a tuple containing the new workflow, a list of runnables, and events produced from the invokation" do
      wrk =
        Runic.workflow(
          name: "test workflow",
          steps: [
            {Runic.step(fn num -> num + 1 end),
             [
               Runic.step(fn num -> num + 2 end),
               Runic.step(fn num -> num + 4 end)
             ]}
          ]
        )
        |> Workflow.plan_eagerly(2)
        |> Workflow.react()

      [{step, fact} | _] = Workflow.next_runnables(wrk)

      {invoked_wrk, _events} = result = Workflow.invoke_with_events(wrk, step, fact)

      assert {%Workflow{name: "test workflow"}, [%ReactionOccurred{}]} = result

      invoked_wrk
      |> Workflow.next_runnables()
      |> Enum.reduce(invoked_wrk, fn {step, fact}, wrk ->
        {invoked_wrk, _events} = Workflow.invoke_with_events(wrk, step, fact)
        invoked_wrk
      end)
    end

    test "events_produced_since/2 returns all events produced since the given fact was produced" do
      wrk =
        Runic.workflow(
          name: "test workflow",
          steps: [
            {Runic.step(fn num -> num + 1 end),
             [
               Runic.step(fn num -> num + 2 end),
               Runic.step(fn num -> num + 4 end)
             ]}
          ]
        )
        |> Workflow.plan_eagerly(2)
        |> Workflow.react()

      [fact | _] = Workflow.productions(wrk)

      assert fact.value == 3

      wrk =
        wrk
        |> Workflow.react()

      events = Workflow.events_produced_since(wrk, fact)

      for event <- events do
        assert match?(%ReactionOccurred{to: %{value: 5}, reaction: :produced}, event) or
                 match?(%ReactionOccurred{to: %{value: 7}, reaction: :produced}, event)

        assert event.to.value !== fact.value
      end
    end

    test "react_until_satisfied/2 reacts eagerly until no more runnables caused by the input fact are available" do
      wrk =
        Runic.workflow(
          name: "test workflow",
          steps: [
            {Runic.step(fn num -> num + 1 end),
             [
               Runic.step(fn num -> num + 2 end),
               Runic.step(fn num -> num + 4 end)
             ]}
          ]
        )

      wrk = Workflow.react_until_satisfied(wrk, 2)

      assert Enum.count(Workflow.productions(wrk)) == 3
      assert Enum.count(Workflow.next_runnables(wrk)) == 0
    end

    test "react/1 invokes one set of runnables" do
      wrk =
        Runic.workflow(
          name: "test workflow",
          steps: [
            {Runic.step(fn num -> num + 1 end),
             [
               Runic.step(fn num -> num + 2 end),
               Runic.step(fn num -> num + 4 end)
             ]}
          ]
        )
        |> Workflow.plan_eagerly(2)

      new_wrk = Workflow.react(wrk)

      assert Enum.count(Workflow.productions(new_wrk)) == 1
      assert [%Fact{value: 3}] = Workflow.productions(new_wrk)

      assert Enum.count(Workflow.next_runnables(new_wrk)) == 2

      new_wrk = Workflow.react(new_wrk)

      assert Enum.count(Workflow.productions(new_wrk)) == 3
    end

    test "plan/2 invokes one set of match runnables - ignoring any productions" do
      wrk =
        Runic.workflow(
          name: "test workflow",
          rules: [
            Runic.rule(
              fn num when is_integer(num) and num > 0 -> num * 2 end,
              name: "double positive"
            )
          ]
        )
        |> Workflow.add(Runic.step(fn num -> num + 1 end, name: "increment"),
          to: {"double positive", :reaction}
        )

      new_wrk = Workflow.plan(wrk, 2)

      assert Enum.count(Workflow.productions(new_wrk)) == 0
      assert Enum.count(Workflow.matches(new_wrk)) == 1

      new_wrk_1 = Workflow.plan_eagerly(new_wrk)
      assert Enum.count(Workflow.next_runnables(new_wrk_1)) == 1
    end

    test "plan_eagerly/2 invokes all possible match runnables eagerly - ignoring any productions" do
      wrk =
        Runic.workflow(
          name: "test workflow",
          rules: [
            Runic.rule(
              fn num when is_integer(num) and num > 0 -> num * 2 end,
              name: "double positive"
            ),
            Runic.rule(
              fn num when is_integer(num) and num < 0 -> num * 3 end,
              name: "triple negative"
            ),
            Runic.rule(
              fn num when is_integer(num) and rem(num, 2) == 0 -> div(num, 2) end,
              name: "half even"
            )
          ]
        )
        |> Workflow.add(Runic.step(fn num -> num + 1 end, name: "increment"),
          to: {"double positive", :reaction}
        )
        |> Workflow.add(Runic.step(fn num -> num - 1 end, name: "decrement"),
          to: {"triple negative", :reaction}
        )

      new_wrk = Workflow.plan_eagerly(wrk, 2)

      assert Enum.count(Workflow.productions(new_wrk)) == 0
      assert Enum.count(Workflow.matches(new_wrk)) == 2
      assert Enum.count(Workflow.next_runnables(new_wrk)) == 2

      new_wrk = Workflow.plan_eagerly(wrk, -3)

      assert Enum.count(Workflow.productions(new_wrk)) == 0
      assert Enum.count(Workflow.matches(new_wrk)) == 1
      assert Enum.count(Workflow.next_runnables(new_wrk)) == 1

      new_wrk = Workflow.plan_eagerly(wrk, 4)

      assert Enum.count(Workflow.productions(new_wrk)) == 0
      assert Enum.count(Workflow.matches(new_wrk)) == 2
      assert Enum.count(Workflow.next_runnables(new_wrk)) == 2
    end

    test "next_runnables/2 reflects the next pairs of {invokable_step, input_fact} that are prepared" do
      wrk =
        Runic.workflow(
          name: "test workflow",
          steps: [
            {Runic.step(fn num -> num + 1 end),
             [
               Runic.step(fn num -> num + 2 end),
               Runic.step(fn num -> num + 4 end)
             ]}
          ]
        )
        |> Workflow.plan_eagerly(2)
        |> Workflow.react()

      assert Enum.count(Workflow.next_runnables(wrk)) == 2

      [{step_1, fact_1}, {step_2, fact_2}] = Workflow.next_runnables(wrk)

      assert step_1.work.(fact_1.value) in [5, 7]
      assert step_2.work.(fact_2.value) in [5, 7]
      assert fact_1.value == 3
      assert fact_2.value == 3
    end

    test "next_steps/2 returns the next outgoing neighbor dataflow steps for any given step" do
      wrk =
        Runic.workflow(
          name: "test workflow",
          steps: [
            {Runic.step(fn num -> num + 1 end, name: "step 1"),
             [
               Runic.step(fn num -> num + 2 end, name: "step 2"),
               Runic.step(fn num -> num + 4 end, name: "step 3")
             ]}
          ]
        )

      from_step_1 = Workflow.next_steps(wrk, Workflow.get_component(wrk, "step 1"))

      for step <- from_step_1 do
        assert step.name in ["step 2", "step 3"]
      end

      assert [] = Workflow.next_steps(wrk, Workflow.get_component(wrk, "step 2"))
      assert [] = Workflow.next_steps(wrk, Workflow.get_component(wrk, "step 3"))
    end
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

      assert Enum.count(Workflow.next_runnables(j_1)) == 2

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

    test "accumulator evaluation with rules over many generations" do
      workflow =
        Runic.workflow(name: "accumulator test")
        |> Workflow.add(Runic.accumulator(0, fn num, state -> num + state end, name: "adder"))
        |> Workflow.add(Runic.step(fn num -> num * 2 end, name: "multiplier"), to: "adder")
        |> Workflow.add(
          Runic.rule(fn num when num > 3 -> num * 3 end, name: "rule1"),
          to: "adder"
        )

      wrk =
        workflow
        |> Workflow.plan_eagerly(4)
        |> Workflow.react_until_satisfied()

      # dbg(Workflow.facts(wrk))

      # dbg(Graph.edges(wrk.graph, by: :state_produced))
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

  describe "add/3" do
    test "adds a component to the workflow" do
      wrk =
        Runic.workflow(name: "add step test")
        |> Workflow.add(Runic.step(name: "step 1", work: fn num -> num + 1 end))

      assert %Step{} = Workflow.get_component(wrk, "step 1")
      assert [%Step{name: "step 1"}] = Workflow.next_steps(wrk, Workflow.root())
    end

    test "adds a component to another named component" do
      wrk =
        Runic.workflow(name: "add step to another test")
        |> Workflow.add(Runic.step(name: "step 1", work: fn num -> num + 1 end))
        |> Workflow.add(Runic.step(name: "step 2", work: fn num -> num + 2 end), to: "step 1")

      assert %Step{} = Workflow.get_component(wrk, "step 1")
      assert %Step{} = Workflow.get_component(wrk, "step 2")
      assert [%Step{name: "step 1"}] = Workflow.next_steps(wrk, Workflow.root())

      assert [%Step{name: "step 2"}] =
               Workflow.next_steps(wrk, Workflow.get_component(wrk, "step 1"))

      assert [%Step{name: "step 2"}] =
               Workflow.next_steps(wrk, Workflow.get_component(wrk, {"step 1", :step}))
    end

    test "`log: false` option doesn't append the build log" do
      wrk =
        Runic.workflow(name: "add step test")
        |> Workflow.add(Runic.step(name: "step 1", work: fn num -> num + 1 end), log: false)
        |> Workflow.add(Runic.step(name: "step 2", work: fn num -> num + 2 end))

      assert Enum.count(Workflow.build_log(wrk)) == 1
    end
  end

  describe "named components" do
    test "register_component/2 registers components by name so they can be retrieved later" do
      wrk =
        Workflow.new()
        |> Workflow.add(Runic.step(name: "step 1", work: fn num -> num + 1 end))

      assert Map.has_key?(wrk.components, "step 1")
      assert %Step{} = Workflow.get_component(wrk, "step 1")
    end

    test "workflow components that are given a name can be retrieved by their name" do
      wrk =
        Workflow.new()
        |> Workflow.add(Runic.step(name: "step 1", work: fn num -> num + 1 end))

      refute is_nil(Workflow.get_component(wrk, "step 1"))
    end

    test "workflow components that are not given a name cannot be retrieved by their name" do
      wrk =
        Workflow.new()
        |> Workflow.add(Runic.step(work: fn num -> num + 1 end))

      assert is_nil(Workflow.get_component(wrk, "step 1"))
    end

    test "get_component!/2 raises an error if the component is not present" do
      wrk =
        Workflow.new()
        |> Workflow.add(Runic.step(name: "step 1", work: fn num -> num + 1 end))

      refute is_nil(Workflow.get_component(wrk, "step 1"))
      assert_raise KeyError, fn -> Workflow.get_component!(wrk, "a step that isn't present") end
    end

    test "fetch_component/2 returns an {:ok, step} or {:error, :no_component_by_name}" do
      wrk =
        Workflow.new()
        |> Workflow.add(Runic.step(name: "step 1", work: fn num -> num + 1 end))

      return = Workflow.fetch_component(wrk, "step 1")
      assert match?({:ok, %Step{}}, return)

      assert Workflow.fetch_component(wrk, "a step that isn't present") ==
               {:error, :no_component_by_name}
    end

    @tag :skip
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
        Workflow.add(wrk, Runic.step(name: "step 4", work: fn num -> num + 4 end), to: "step 2")

      assert not is_nil(Workflow.get_component(wrk, "step 4"))

      results =
        wrk
        |> Workflow.react_until_satisfied(1)
        |> Workflow.raw_productions()

      assert 8 in results
    end

    @tag :skip
    test "state machines can be connected to other components" do
      wrk =
        Runic.workflow(
          name: "state machine connection",
          rules: [
            Runic.rule(
              name: "add until 10",
              condition: fn num -> num <= 10 end,
              reaction: fn num -> num + 1 end
            )
          ]
        )

      state_machine =
        Runic.state_machine(
          name: "state_machine_test",
          init: 0,
          reducer: fn num, state -> state + num end
        )

      wrk = Workflow.add(wrk, state_machine, to: {"add until 10", :reaction})

      assert not is_nil(Workflow.get_component(wrk, "state_machine_test"))
      assert Enum.any?(wrk.graph |> Graph.vertices(), &match?(%Runic.Workflow.Accumulator{}, &1))
    end

    test "productions/2 returns facts produced by the named component" do
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

      wrk = Workflow.react_until_satisfied(wrk, 1)

      assert [%Fact{value: 2}] = Workflow.productions(wrk, "step 1")
    end

    test "productions_by_component/1 returns all facts produced grouped by the component names" do
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

      wrk = Workflow.react_until_satisfied(wrk, 1)

      assert %{
               "step 1" => [%Fact{value: 2}],
               "step 2" => [%Fact{value: 4}],
               "step 3" => [%Fact{value: 5}]
             } = Workflow.productions_by_component(wrk)
    end

    test "raw_productions/2 returns raw values produced by the named component" do
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

      wrk = Workflow.react_until_satisfied(wrk, 1)

      assert [2] = Workflow.raw_productions(wrk, "step 1")
    end

    test "raw_productions_by_component/1 returns all fact values produced grouped by the component names" do
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

      wrk = Workflow.react_until_satisfied(wrk, 1)

      assert %{
               "step 1" => [2],
               "step 2" => [4],
               "step 3" => [5]
             } = Workflow.raw_productions_by_component(wrk)
    end

    test "adding a component with a name that is already in use raises an error" do
    end

    # test "components can be removed by name" do
    #   wrk =
    #     Workflow.new()
    #     |> Workflow.add_step(Runic.step(name: "step 1", work: fn num -> num + 1 end))

    #   refute is_nil(Workflow.get_component(wrk, "step 1"))
    #   wrk = Workflow.remove_component(wrk, "step 1")
    #   assert Workflow.get_component(wrk, "step 1") == nil
    # end

    # test "removing a component that does not exist raises an error when using remove_component!/2" do
    #   wrk =
    #     Workflow.new()
    #     |> Workflow.add_step(Runic.step(name: "step 1", work: fn num -> num + 1 end))

    #   assert_raise KeyError, fn ->
    #     Workflow.remove_component!(wrk, "a step that isn't present")
    #   end
    # end

    # test "components can be replaced by name" do
    #   wrk =
    #     Workflow.new()
    #     |> Workflow.add_step(Runic.step(name: "step 1", work: fn num -> num + 1 end))

    #   assert Workflow.get_component(wrk, "step 1") == %Step{}
    #   wrk = Workflow.replace_component(wrk, "step 1", Runic.step(name: "step 1", work: fn num -> num + 2 end))
    #   assert Workflow.get_component(wrk, "step 1").work.(1) == 3
    # end

    @tag :skip
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

      assert %Workflow{} = wrk

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

      assert %Workflow{} = wrk

      # The component impl should know how to attach common components to each other
      wrk =
        Workflow.add(
          wrk,
          Runic.step(fn state -> state * 4 end, name: "reaction3"),
          to: "state_machine"
        )

      assert %Workflow{} = wrk

      wrk =
        Workflow.add(
          wrk,
          Runic.step(fn n -> n + 1 end, name: "reaction4"),
          to: "rule2"
        )

      assert %Workflow{} = wrk
    end

    test "a step can be added to multiple components assuming a join in order of `:to` names" do
      wrk =
        Runic.workflow(
          name: "test workflow",
          steps: [
            {Runic.step(fn num -> num + 1 end, name: "step 1"),
             [
               Runic.step(fn num -> num + 2 end, name: "step 2"),
               Runic.step(fn num -> num + 4 end, name: "step 3")
             ]}
          ]
        )

      wrk =
        Workflow.add(
          wrk,
          Runic.step(fn num, num2 -> num + num2 + 3 end, name: "joined_step"),
          to: ["step 2", "step 3"]
        )

      step = Workflow.get_component(wrk, "joined_step")

      assert %Step{} = step

      assert Enum.any?(Graph.vertices(wrk.graph), &match?(%Workflow.Join{}, &1))
    end

    test "a step can be added to multiple reduces assuming a join in order of `:to` names" do
      wrk =
        Runic.workflow(
          name: "test workflow",
          steps: [
            {Runic.step(fn _ -> 0..5 end),
             [
               Runic.reduce(0, fn num, acc -> num + acc end, name: "reduce 1"),
               Runic.reduce(0, fn num, acc -> num + acc end, name: "reduce 2")
             ]}
          ]
        )

      wrk =
        Workflow.add(
          wrk,
          Runic.step(fn num, num2 -> num + num2 + 3 end, name: "joined_step"),
          to: ["reduce 1", "reduce 2"]
        )

      step = Workflow.get_component(wrk, "joined_step")

      join = Graph.in_edges(wrk.graph, step, by: :flow) |> List.first() |> Map.get(:v1)

      assert match?(%Workflow.Join{}, join)

      assert Graph.in_degree(wrk.graph, join) == 2

      assert match?(%Workflow.FanIn{}, Graph.in_neighbors(wrk.graph, join) |> List.first())
    end
  end

  describe "map" do
    test "map component construction" do
      map = Runic.map(fn num -> num * 2 end, name: "map step")

      # dbg(map)

      assert %Runic.Workflow.Map{} = map

      assert not is_nil(map.pipeline.components)

      assert %Workflow{} = map.pipeline

      workflow = Runic.workflow(name: "map test") |> Workflow.add(map)

      fan_out = Workflow.get_component(workflow, {"map step", :fan_out})

      assert not is_nil(fan_out)

      # Graph.in_edges(map.pipeline.graph, fan_out, by: :component_of)
    end

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
            {Runic.step(fn num -> Enum.map(0..3, &(&1 + num)) end, name: "enumerable to map"),
             [
               Runic.map(
                 {Runic.step(fn num -> num * 2 end, name: "x2"),
                  [
                    Runic.step(fn num -> num + 1 end, name: "+1"),
                    Runic.step(fn num -> num + 4 end, name: "+4")
                  ]},
                 name: "map pipeline"
               )
             ]}
          ]
        )

      # dbg(wrk)

      components = Workflow.components(wrk)

      for name <- ["enumerable to map", "x2", "+1", "+4", "map pipeline"] do
        assert Map.has_key?(components, name)
      end

      for {name, value} <- wrk.components do
        assert not is_nil(name)
        assert not is_nil(value)
        assert is_atom(name) or is_binary(name)
        assert is_integer(value)
      end

      for node <- Graph.vertices(wrk.graph) do
        assert not is_nil(node)
      end

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

      assert %Workflow{} = wrk
    end

    test "steps in a map pipeline can have names" do
      Runic.workflow(
        name: "map test",
        steps: [
          {Runic.step(fn num -> Enum.map(0..3, &(&1 + num)) end),
           [
             Runic.map(
               {[Runic.step(fn num -> num * 2 end), Runic.step(fn num -> num * 3 end)],
                [
                  Runic.step(fn num_1, num_2 -> num_1 * num_2 end, name: "multiply")
                ]}
             )
           ]}
        ]
      )
    end

    test "map pipelines can be a list of steps that run independently for each fan out" do
      wrk =
        Runic.workflow(
          name: "list of fan out steps",
          steps: [
            {Runic.step(fn _ -> 1..4 end),
             [
               Runic.map([
                 Runic.step(fn num -> num * 2 end),
                 Runic.step(fn num -> num + 1 end),
                 Runic.step(fn num -> num + 4 end)
               ])
             ]}
          ]
        )

      wrk = Workflow.react_until_satisfied(wrk, 2)

      assert %Workflow{} = wrk
    end

    test "map pipelines can include nested map expressions" do
      wrk =
        Runic.workflow(
          name: "list of fan out steps",
          steps: [
            {Runic.step(fn _ -> 1..4 end),
             [
               Runic.map(
                 [
                   {Runic.step(fn num -> [num * 2, num * 3] end),
                    [
                      Runic.map(
                        [
                          Runic.step(fn num -> num + 6 end, name: :nested_plus_6),
                          Runic.step(fn num -> num + 8 end, name: :nested_plus_8)
                        ],
                        name: :inner_map
                      )
                    ]},
                   Runic.step(fn num -> num * 2 end, name: :x2),
                   Runic.step(fn num -> num + 1 end, name: :x1),
                   Runic.step(fn num -> num + 4 end, name: :x4)
                 ],
                 name: :first_map
               )
             ]}
          ]
        )

      first_fan_out =
        Workflow.get_component(wrk, {:first_map, :fan_out}) |> List.first()

      inner_fan_out =
        Workflow.get_component(wrk, {:inner_map, :fan_out}) |> List.first()

      refute is_nil(inner_fan_out)

      assert [%{v1: %Runic.Workflow.Map{}}] =
               Graph.in_edges(wrk.graph, inner_fan_out, by: :component_of)

      assert Enum.count(Graph.vertices(wrk.graph), &match?(%Runic.Workflow.FanOut{}, &1)) == 2

      assert Workflow.next_steps(wrk, first_fan_out) |> Enum.count() == 4

      assert Graph.in_edges(wrk.graph, first_fan_out, by: :flow) |> Enum.count() == 1
    end

    test "map expressions can be named" do
      wrk1 =
        Runic.workflow(
          name: "map test",
          steps: [
            {Runic.step(fn _ -> 1..4 end),
             [
               Runic.map(
                 {Runic.step(fn num -> num * 2 end),
                  [
                    Runic.map(
                      {Runic.step(fn num -> num * 1 end),
                       [
                         Runic.step(fn num -> num + 1 end),
                         Runic.step(fn num -> num + 4 end)
                       ]}
                    )
                  ]},
                 name: "map"
               )
             ]}
          ]
        )

      assert %Workflow{} = wrk1
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

      assert Enum.any?(Workflow.raw_productions(wrk), fn value ->
               set_value = MapSet.new([value])

               MapSet.member?(set_value, 4) or
                 MapSet.member?(set_value, 6) or MapSet.member?(set_value, 8) or
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
            {Runic.step(fn -> 0..3 end, name: "source step"),
             [
               {Runic.map(fn num -> num + 1 end, name: "map"),
                [
                  Runic.reduce(0, fn num, acc -> num + acc end, name: "reduce", map: "map")
                ]}
             ]}
          ]
        )

      assert %Workflow{} = wrk

      assert not is_nil(Workflow.get_component(wrk, "map"))
      assert not is_nil(Workflow.get_component(wrk, "reduce"))
      assert not is_nil(Workflow.get_component(wrk, "source step"))
    end

    test "reduce can be added to a step in a map expression and reduce over each fanned out fact of the map" do
      wrk =
        Runic.workflow(
          name: "reduce test",
          steps: [
            {Runic.step(fn _ -> 0..3 end),
             [
               Runic.map(
                 {step(fn num -> num + 1 end),
                  [
                    Runic.step(fn num -> num + 4 end),
                    Runic.step(fn num -> num + 2 end, name: :plus2)
                  ]},
                 name: "map"
               )
             ]}
          ]
        )

      wrk =
        Workflow.add(
          wrk,
          Runic.reduce(0, fn num, acc -> num + acc end, name: "reduce", map: "map"),
          to: :plus2
        )

      wrk = Workflow.react_until_satisfied(wrk, "potato")

      for reaction <- Workflow.raw_productions(wrk) do
        assert reaction in [5, 6, 7, 8, 18, 4, 5, 3, 6, 3, 4, 2, 1, 0..3]
      end
    end
  end

  describe "hooks / continuations" do
    test "hooks run before/after invokation of a step" do
      wrk =
        Runic.workflow(
          name: "continuation test",
          steps: [
            Runic.step(fn num -> Enum.map(0..3, fn _ -> num end) end, name: :step_1)
          ],
          before_hooks: [
            step_1: [
              fn _step, wrk, _fact ->
                send(self(), :before)
                wrk
              end
            ]
          ],
          after_hooks: [
            step_1: [
              fn _step, wrk, _fact ->
                send(self(), :after)
                wrk
              end
            ]
          ]
        )

      _ran_wrk = Workflow.react_until_satisfied(wrk, 2)

      assert {:messages, [:before, :after]} = Process.info(self(), :messages)
    end

    test "multiple hooks can run for a step" do
      wrk =
        Runic.workflow(
          name: "continuation test",
          steps: [
            Runic.step(fn num -> Enum.map(0..3, fn _ -> num end) end, name: :step_1)
          ],
          before_hooks: [
            step_1: [
              fn _step, wrk, _fact ->
                send(self(), :before_1)
                wrk
              end,
              fn _step, wrk, _fact ->
                send(self(), :before_2)
                wrk
              end
            ]
          ],
          after_hooks: [
            step_1: [
              fn _step, wrk, _fact ->
                send(self(), :after_1)
                wrk
              end,
              fn _step, wrk, _fact ->
                send(self(), :after_2)
                wrk
              end
            ]
          ]
        )

      _ran_wrk = Workflow.react_until_satisfied(wrk, 2)

      assert {:messages, [:before_1, :before_2, :after_1, :after_2]} =
               Process.info(self(), :messages)
    end

    test "hooks can be added to a workflow after it has been created" do
      wrk =
        Runic.workflow(
          name: "continuation test",
          steps: [
            Runic.step(fn num -> Enum.map(0..3, fn _ -> num end) end, name: :step_1)
          ]
        )

      wrk =
        Workflow.attach_before_hook(
          wrk,
          :step_1,
          fn _step, wrk, _fact ->
            send(self(), :before)
            wrk
          end
        )

      wrk =
        Workflow.attach_after_hook(
          wrk,
          :step_1,
          fn _step, wrk, _fact ->
            send(self(), :after)
            wrk
          end
        )

      _ran_wrk = Workflow.react_until_satisfied(wrk, 2)

      assert {:messages, [:before, :after]} = Process.info(self(), :messages)
    end

    test "can add additional steps and runnables to a workflow after a step has been run in order to continue a computation" do
      wrk =
        Runic.workflow(
          name: "continuation test",
          steps: [
            Runic.step(fn num -> num + 1 end, name: :step_1)
          ],
          after_hooks: [
            step_1: [
              fn _step, wrk, _fact ->
                wrk
                |> Workflow.add(Runic.step(fn num -> num + 2 end), to: :step_1)
              end
            ]
          ]
        )

      ran_wrk = Workflow.react_until_satisfied(wrk, 2)

      assert Enum.count(Workflow.reactions(ran_wrk)) == 3
    end

    test "hooks can be attached to sub-components" do
      wrk =
        Runic.workflow(
          name: "test workflow",
          rules: [
            Runic.rule(
              fn item when is_integer(item) and item > 41 and item < 43 ->
                item * Enum.random(1..10)
              end,
              name: "rule2"
            ),
            Runic.rule(
              fn item when is_integer(item) and item > 41 ->
                item * Enum.random(1..12)
              end,
              name: "rule3"
            )
          ]
        )

      wrk =
        wrk
        |> Workflow.attach_before_hook({"rule2", :reaction}, fn step, wrk, fact ->
          send(self(), {:before, step.__struct__})
          wrk
        end)
        |> Workflow.attach_after_hook({"rule2", :reaction}, fn step, wrk, fact ->
          send(self(), {:after, step.__struct__})
          wrk
        end)
        |> Workflow.attach_before_hook({"rule3", :condition}, fn step, wrk, fact ->
          send(self(), {:before, step.__struct__})
          wrk
        end)
        |> Workflow.attach_after_hook({"rule3", :condition}, fn step, wrk, fact ->
          send(self(), {:after, step.__struct__})
          wrk
        end)

      ran_wrk = Workflow.react_until_satisfied(wrk, 42)

      {:messages, messages} = Process.info(self(), :messages)

      assert length(messages) == 4

      for msg <- messages do
        assert msg in [
                 {:before, Runic.Workflow.Condition},
                 {:after, Runic.Workflow.Condition},
                 {:before, Runic.Workflow.Step},
                 {:after, Runic.Workflow.Step}
               ]
      end
    end
  end

  describe "component management" do
    test "connectables/2 lists components in a workflow that a given component can be added/connected to" do
      wrk =
        Runic.workflow(
          name: "test workflow",
          steps: [
            Runic.step(fn num -> num + 1 end, name: :step_1)
          ]
        )

      assert [%Step{}] =
               Workflow.connectables(wrk, Runic.step(fn num -> num * 2 end, name: :step_2))
    end

    test "connectables/2 lists only components that are compatible by arity" do
      step_1 = Runic.step(fn num -> num + 1 end, name: :step_1)
      step_2 = Runic.step(fn num, num2 -> num + num2 end, name: :step_2)

      wrk =
        Runic.workflow(
          name: "test workflow",
          steps: [
            step_1,
            step_2
          ]
        )

      connectables = Workflow.connectables(wrk, Runic.step(fn num -> num * 3 end, name: :step_3))

      assert step_1 in connectables
      refute step_2 in connectables
    end

    test "connectable?/3 returns an :ok if the component can be added or an error tuple with a list of errors" do
      wrk =
        Runic.workflow(
          name: "test workflow",
          steps: [
            Runic.step(fn num -> num + 1 end, name: :step_1),
            Runic.step(fn num, num_2 -> num * num_2 end, name: :step_2)
          ]
        )

      assert Workflow.connectable?(wrk, Runic.step(fn num -> num * 2 end, name: :step_3),
               to: :step_1
             ) ==
               :ok

      assert {:error, _} =
               Workflow.connectable?(wrk, Runic.step(fn num -> num * 2 end, name: :step_3),
                 to: :step_2
               )
    end

    @tag :skip
    test "connect reactors to a state machine" do
      wrk =
        Runic.state_machine(
          name: "state_machine",
          init: 0,
          reducer: fn num, state -> state + num end
        )
        |> Runic.transmute()
        |> Workflow.add(
          Runic.step(fn num -> num + 1 end, name: :add_one),
          to: {"state_machine", :reducer}
        )

      assert %Step{} = Workflow.get_component(wrk, :add_one)
    end
  end

  describe "log based workflow reconstruction for encode/decode" do
    test "a workflow can be encoded and decoded from a log" do
      # event to rebuild workflow: component_added
      # event to rebuild workflow state: fact_produced
      wrk =
        Runic.workflow(
          name: "test workflow",
          steps: [
            Runic.step(fn num -> num + 1 end, name: :step_1),
            Runic.step(fn num -> num * 2 end, name: :step_2)
          ]
        )

      build_log = Workflow.build_log(wrk)
      # log of JSON/binary encodeable structs e.g. `[%WorkflowComponentAdded{}, ...]`
      assert [%Runic.Workflow.ComponentAdded{} | _] = build_log

      event = List.first(build_log)

      assert not is_nil(event.name)

      # rebuild just the workflow steps from log
      built_wrk = Workflow.from_log(build_log)

      assert %Workflow{} = built_wrk

      assert Enum.empty?(Workflow.facts(built_wrk))

      ran_wrk = Workflow.react_until_satisfied(wrk, 2)

      build_and_execution_log = Workflow.log(ran_wrk)

      refute Enum.empty?(build_and_execution_log)
      assert Enum.any?(build_and_execution_log, &match?(%ReactionOccurred{}, &1))
    end

    test "a rebuilt workflow can be replayed from log state" do
      wrk =
        Runic.workflow(
          name: "test workflow",
          steps: [
            Runic.step(fn num -> num + 1 end, name: :step_1),
            Runic.step(fn num -> num * 2 end, name: :step_2)
          ]
        )

      ran_wrk = Workflow.react_until_satisfied(wrk, 2)

      build_and_execution_log = Workflow.log(ran_wrk)

      built_wrk = Workflow.from_log(build_and_execution_log)

      assert Enum.any?(build_and_execution_log, &match?(%ReactionOccurred{}, &1))

      edge_labels = Graph.edges(built_wrk.graph) |> Enum.map(& &1.label)

      for edge <- Graph.edges(ran_wrk.graph) do
        assert edge.label in edge_labels
      end
    end

    # test "encode/decode workflow logs to JSON" do
    #   wrk =
    #     Runic.workflow(
    #       name: "test workflow",
    #       steps: [
    #         Runic.step(fn num -> num + 1 end, name: :step_1),
    #         Runic.step(fn num -> num * 2 end, name: :step_2)
    #       ]
    #     )

    #   ran_wrk = Workflow.react_until_satisfied(wrk, 2)

    #   log = Workflow.log(ran_wrk) |> dbg()

    #   json_log = Enum.map(log, &JSON.encode!/1)

    #   decoded_log = Enum.map(json_log, &JSON.decode!/1)

    #   assert log = decoded_log

    #   rebuilt_wrk = Workflow.from_log(decoded_log)

    #   assert rebuilt_wrk = ran_wrk
    # end
  end
end
