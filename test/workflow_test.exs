defmodule WorkflowTest do
  use ExUnit.Case
  require Runic

  alias Runic.Workflow
  alias Runic.Workflow.Invokable
  alias Runic.Workflow.Step
  alias Runic.Workflow.Fact
  alias Runic.Workflow.ReactionOccurred
  alias Runic.Workflow.HookEvent

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

    test "components/1 lists all registered components by name" do
      wrk =
        Runic.workflow(
          steps: [
            {Runic.step(fn num -> num + 1 end, name: "step 1"),
             [
               Runic.step(fn num -> num + 2 end, name: "step 2"),
               Runic.step(fn num -> num + 4 end, name: "step 3")
             ]}
          ],
          rules: [
            Runic.rule(
              fn num when is_integer(num) and num > 0 -> num * 2 end,
              name: "double positive"
            )
          ]
        )

      components = Workflow.components(wrk)

      assert %{
               "step 1" => %Step{},
               "step 2" => %Step{},
               "step 3" => %Step{},
               "double positive" => %Runic.Workflow.Rule{}
             } = components
    end

    test "sub_components/2 lists all sub-components of the given component by kind" do
      wrk =
        Runic.workflow(
          steps: [
            {Runic.step(fn num -> num + 1 end, name: "step 1"),
             [
               Runic.step(fn num -> num + 2 end, name: "step 2"),
               Runic.step(fn num -> num + 4 end, name: "step 3")
             ]}
          ],
          rules: [
            Runic.rule(
              fn num when is_integer(num) and num > 0 -> num * 2 end,
              name: "double positive"
            )
          ]
        )

      sub_components = Workflow.sub_components(wrk, "double positive")

      assert Keyword.has_key?(sub_components, :condition)
      assert Keyword.has_key?(sub_components, :reaction)
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

    test "join marks runnable as ran even when not fully satisfied to prevent infinite loop" do
      # This test simulates parallel execution where a Join may be invoked
      # before all its parent steps have produced facts. The Join should
      # mark the runnable edge as :ran to prevent infinite re-invocation.

      step_a = Runic.step(fn num -> num * 2 end, name: :step_a)
      step_b = Runic.step(fn num -> num * 3 end, name: :step_b)
      join_step = Runic.step(fn a, b -> a + b end, name: :join_result)

      workflow =
        Runic.workflow(
          name: "join loop test",
          steps: [
            {[step_a, step_b], [join_step]}
          ]
        )

      # Plan with input
      planned = Workflow.plan_eagerly(workflow, 5)

      # Get initial runnables - should be step_a and step_b
      initial_runnables = Workflow.next_runnables(planned)
      assert length(initial_runnables) == 2

      # Invoke just one parent step (step_a) to simulate parallel execution
      {step_a_runnable, fact_a} =
        Enum.find(initial_runnables, fn {step, _fact} ->
          step.name == :step_a
        end)

      workflow_after_a = Workflow.invoke(planned, step_a_runnable, fact_a)

      # Now get runnables again - should include the Join as runnable
      runnables_after_a = Workflow.next_runnables(workflow_after_a)

      # Find the join in runnables
      join_runnable =
        Enum.find(runnables_after_a, fn {step, _fact} ->
          match?(%Runic.Workflow.Join{}, step)
        end)

      # The join should be runnable (waiting for other parent)
      assert join_runnable != nil

      {join, join_fact} = join_runnable

      # Invoke the Join - it's not yet satisfied (step_b hasn't run)
      workflow_after_join_invoked = Workflow.invoke(workflow_after_a, join, join_fact)

      # KEY ASSERTION: After invoking an unsatisfied Join, the runnable edge
      # should be marked as :ran so it doesn't appear in next_runnables again
      runnables_after_join = Workflow.next_runnables(workflow_after_join_invoked)

      # The same (join, join_fact) pair should NOT appear again
      same_join_runnable =
        Enum.find(runnables_after_join, fn {step, fact} ->
          match?(%Runic.Workflow.Join{}, step) and fact.hash == join_fact.hash
        end)

      assert same_join_runnable == nil,
             "Join should not reappear in runnables after being invoked (causes infinite loop)"

      # But step_b should still be runnable
      step_b_runnable =
        Enum.find(runnables_after_join, fn {step, _fact} ->
          step.name == :step_b
        end)

      assert step_b_runnable != nil, "step_b should still be runnable"
    end

    test "join completes successfully after all parents produce facts in parallel execution" do
      # This test verifies that a Join correctly completes when invoked
      # multiple times as each parent produces facts (simulating parallel execution).

      step_a = Runic.step(fn num -> num * 2 end, name: :step_a)
      step_b = Runic.step(fn num -> num * 3 end, name: :step_b)
      join_step = Runic.step(fn a, b -> a + b end, name: :join_result)

      workflow =
        Runic.workflow(
          name: "join completion test",
          steps: [
            {[step_a, step_b], [join_step]}
          ]
        )

      # Plan with input
      planned = Workflow.plan_eagerly(workflow, 5)

      # Get initial runnables
      initial_runnables = Workflow.next_runnables(planned)
      assert length(initial_runnables) == 2

      # Run step_a first
      {step_a_runnable, fact_a} =
        Enum.find(initial_runnables, fn {step, _fact} ->
          step.name == :step_a
        end)

      workflow_after_a = Workflow.invoke(planned, step_a_runnable, fact_a)

      # Now run step_b
      {step_b_runnable, fact_b} =
        Enum.find(initial_runnables, fn {step, _fact} ->
          step.name == :step_b
        end)

      workflow_after_b = Workflow.invoke(workflow_after_a, step_b_runnable, fact_b)

      # After both parents have run, the join should be runnable with both facts connected
      runnables_after_both = Workflow.next_runnables(workflow_after_b)

      # There should be join runnables now (one for each fact that connected)
      join_runnables =
        Enum.filter(runnables_after_both, fn {step, _fact} ->
          match?(%Runic.Workflow.Join{}, step)
        end)

      assert length(join_runnables) > 0, "Join should be runnable after both parents produced"

      # Run the join with one of the facts
      {join, join_fact} = hd(join_runnables)
      workflow_after_join = Workflow.invoke(workflow_after_b, join, join_fact)

      # After both parents ran and we invoked join once, there may still be
      # a second join invocation needed. Let's run until join_result is runnable.
      workflow_current = workflow_after_join

      # Keep invoking joins until join_result becomes runnable
      max_iterations = 10

      for _ <- 1..max_iterations, reduce: {workflow_current, nil} do
        {wrk, nil} ->
          runnables = Workflow.next_runnables(wrk)

          # Check for join_result
          result_step =
            Enum.find(runnables, fn {step, _fact} ->
              match?(%Step{name: :join_result}, step)
            end)

          if result_step != nil do
            {wrk, result_step}
          else
            # Check for remaining join
            join_step =
              Enum.find(runnables, fn {step, _fact} ->
                match?(%Runic.Workflow.Join{}, step)
              end)

            if join_step != nil do
              {join_node, join_fact} = join_step
              new_wrk = Workflow.invoke(wrk, join_node, join_fact)
              {new_wrk, nil}
            else
              {wrk, nil}
            end
          end

        {wrk, found} ->
          {wrk, found}
      end
      |> case do
        {final_wrk, {final_step, final_fact}} ->
          final_workflow = Workflow.invoke(final_wrk, final_step, final_fact)
          productions = Workflow.raw_productions(final_workflow)
          assert 25 in productions

        {_wrk, nil} ->
          flunk("join_result step never became runnable")
      end
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

      _wrk =
        workflow
        |> Workflow.plan_eagerly(4)
        |> Workflow.react_until_satisfied()
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

    test "reduce supports reduce_while semantics with {:cont, acc} tuples" do
      wrk =
        Runic.workflow(
          name: "reduce_while cont test",
          steps: [
            {Runic.step(fn _input -> [1, 2, 3, 4] end),
             [
               {Runic.map(fn num -> num end),
                [
                  Runic.reduce(0, fn num, acc -> {:cont, num + acc} end)
                ]}
             ]}
          ]
        )

      wrk = Workflow.react_until_satisfied(wrk, :start)

      assert 10 in Workflow.raw_productions(wrk)
    end

    test "reduce supports reduce_while semantics with {:halt, acc} to stop early" do
      wrk =
        Runic.workflow(
          name: "reduce_while halt test",
          steps: [
            {Runic.step(fn _input -> [1, 2, 3, 4, 5] end),
             [
               {Runic.map(fn num -> num end),
                [
                  Runic.reduce(0, fn num, acc ->
                    if num >= 3 do
                      {:halt, acc}
                    else
                      {:cont, num + acc}
                    end
                  end)
                ]}
             ]}
          ]
        )

      wrk = Workflow.react_until_satisfied(wrk, :start)

      # Should sum 1 + 2 = 3, then halt when it sees 3
      assert 3 in Workflow.raw_productions(wrk)
      refute 15 in Workflow.raw_productions(wrk)
    end

    test "reduce with map supports reduce_while semantics with halt" do
      wrk =
        Runic.workflow(
          name: "map reduce_while test",
          steps: [
            {Runic.step(fn _input -> 0..5 end),
             [
               {Runic.map(fn num -> num * 2 end),
                [
                  Runic.reduce([], fn num, acc ->
                    if num > 6 do
                      {:halt, acc}
                    else
                      {:cont, [num | acc]}
                    end
                  end)
                ]}
             ]}
          ]
        )

      wrk = Workflow.react_until_satisfied(wrk, :start)

      productions = Workflow.raw_productions(wrk)

      reduced_result =
        Enum.find(productions, fn val ->
          is_list(val) and Enum.all?(val, &is_integer/1)
        end)

      # Values 0*2=0, 1*2=2, 2*2=4, 3*2=6 should be included
      # 4*2=8 should trigger halt
      assert reduced_result != nil
      assert Enum.all?([0, 2, 4, 6], &(&1 in reduced_result))
      refute 8 in reduced_result
    end

    test "reduce backward compatible with plain acc return values in map" do
      wrk =
        Runic.workflow(
          name: "backward compat test",
          steps: [
            {Runic.step(fn _input -> [1, 2, 3] end),
             [
               {Runic.map(fn num -> num end),
                [
                  Runic.reduce(0, fn num, acc -> num + acc end)
                ]}
             ]}
          ]
        )

      wrk = Workflow.react_until_satisfied(wrk, :start)

      assert 6 in Workflow.raw_productions(wrk)
    end

    test "reduce maintains deterministic order from fan_out emission" do
      wrk =
        Runic.workflow(
          name: "deterministic order test",
          steps: [
            {Runic.step(fn _input -> [:a, :b, :c, :d] end),
             [
               {Runic.map(fn elem -> elem end),
                [
                  Runic.reduce([], fn elem, acc -> acc ++ [elem] end)
                ]}
             ]}
          ]
        )

      wrk = Workflow.react_until_satisfied(wrk, :start)

      productions = Workflow.raw_productions(wrk)

      ordered_result =
        Enum.find(productions, fn val ->
          is_list(val) and length(val) == 4
        end)

      # Should preserve order: [:a, :b, :c, :d]
      assert ordered_result == [:a, :b, :c, :d]
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
        |> Workflow.attach_before_hook({"rule2", :reaction}, fn step, wrk, _fact ->
          send(self(), {:before, step.__struct__})
          wrk
        end)
        |> Workflow.attach_after_hook({"rule2", :reaction}, fn step, wrk, _fact ->
          send(self(), {:after, step.__struct__})
          wrk
        end)
        |> Workflow.attach_before_hook({"rule3", :condition}, fn step, wrk, _fact ->
          send(self(), {:before, step.__struct__})
          wrk
        end)
        |> Workflow.attach_after_hook({"rule3", :condition}, fn step, wrk, _fact ->
          send(self(), {:after, step.__struct__})
          wrk
        end)

      _ran_wrk = Workflow.react_until_satisfied(wrk, 42)

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

    test "new-style hooks (arity-2) execute with HookEvent and CausalContext" do
      test_pid = self()

      new_style_before_hook = fn %HookEvent{timing: :before} = event, ctx ->
        send(test_pid, {:new_before, event.node.__struct__, ctx.ancestry_depth})
        :ok
      end

      new_style_after_hook = fn %HookEvent{timing: :after, result: result} = _event, _ctx ->
        send(test_pid, {:new_after, result.value})
        :ok
      end

      wrk =
        Runic.workflow(
          name: "new-style hooks test",
          steps: [
            Runic.step(fn num -> num * 2 end, name: :doubler)
          ],
          before_hooks: [
            doubler: [new_style_before_hook]
          ],
          after_hooks: [
            doubler: [new_style_after_hook]
          ]
        )

      _ran_wrk = Workflow.react_until_satisfied(wrk, 5)

      assert_received {:new_before, Runic.Workflow.Step, 0}
      assert_received {:new_after, 10}
    end

    test "new-style hooks can return {:apply, fn} for deferred workflow updates" do
      test_pid = self()

      hook_with_apply = fn %HookEvent{timing: :after}, _ctx ->
        {:apply,
         fn workflow ->
           send(test_pid, :apply_fn_executed)
           workflow
         end}
      end

      wrk =
        Runic.workflow(
          name: "hook with apply_fn test",
          steps: [
            Runic.step(fn num -> num + 1 end, name: :adder)
          ],
          after_hooks: [
            adder: [hook_with_apply]
          ]
        )

      _ran_wrk = Workflow.react_until_satisfied(wrk, 5)

      assert_received :apply_fn_executed
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

  describe "add_with_events/3" do
    test "can add a Rule component with closure without Access behaviour error" do
      rule =
        Runic.rule do
          given(order: %{total: total})
          where(total > 100)
          then(fn %{order: order} -> {:discounted, order} end)
        end

      workflow = Runic.workflow(name: "test workflow")

      assert {%Workflow{}, events} = Workflow.add_with_events(workflow, rule)
      assert [%Runic.Workflow.ComponentAdded{} = event] = events
      assert event.name == rule.name
    end

    test "Step component produces ComponentAdded event" do
      step = Runic.step(fn x -> x * 2 end, name: :doubler)
      workflow = Workflow.new()

      assert {%Workflow{}, events} = Workflow.add_with_events(workflow, step)
      assert [%Runic.Workflow.ComponentAdded{} = event] = events
      assert event.name == :doubler
      assert event.closure != nil
    end

    test "adding multiple components to same parent produces multiple events" do
      step1 = Runic.step(fn x -> x end, name: :parent)
      step2 = Runic.step(fn x -> x + 1 end, name: :child_a)
      step3 = Runic.step(fn x -> x + 2 end, name: :child_b)

      {workflow, _} = Workflow.add_with_events(Workflow.new(), step1)
      {workflow, events_a} = Workflow.add_with_events(workflow, step2, to: :parent)
      {_workflow, events_b} = Workflow.add_with_events(workflow, step3, to: :parent)

      assert [%Runic.Workflow.ComponentAdded{name: :child_a, to: :parent}] = events_a
      assert [%Runic.Workflow.ComponentAdded{name: :child_b, to: :parent}] = events_b
    end

    test "StateMachine component produces ComponentAdded event" do
      state_machine =
        Runic.state_machine(
          name: :counter,
          init: 0,
          reducer: fn num, state -> state + num end
        )

      workflow = Workflow.new()

      assert {%Workflow{}, events} = Workflow.add_with_events(workflow, state_machine)
      assert [%Runic.Workflow.ComponentAdded{} = event] = events
      assert event.name == :counter
    end

    test "Map component produces ComponentAdded event" do
      map = Runic.map(fn x -> x + 1 end, name: :increment_map)
      workflow = Workflow.new()

      assert {%Workflow{}, events} = Workflow.add_with_events(workflow, map)
      assert [%Runic.Workflow.ComponentAdded{} = event] = events
      assert event.name == :increment_map
    end

    test "Reduce component produces ComponentAdded event" do
      reduce = Runic.reduce(0, fn x, acc -> x + acc end, name: :sum_reduce, map: :my_map)
      workflow = Workflow.new()

      assert {%Workflow{}, events} = Workflow.add_with_events(workflow, reduce)
      assert [%Runic.Workflow.ComponentAdded{} = event] = events
      assert event.name == :sum_reduce
    end

    test "adding component with :to option sets parent in event" do
      step1 = Runic.step(fn x -> x end, name: :first)
      step2 = Runic.step(fn x -> x * 2 end, name: :second)

      {workflow, _} = Workflow.add_with_events(Workflow.new(), step1)
      {_workflow, events} = Workflow.add_with_events(workflow, step2, to: :first)

      assert [%Runic.Workflow.ComponentAdded{to: :first}] = events
    end

    test "events from add_with_events can deterministically recreate the same workflow" do
      step1 = Runic.step(fn x -> x + 1 end, name: :add_one)
      step2 = Runic.step(fn x -> x * 2 end, name: :double)
      rule = Runic.rule(fn x when x > 10 -> {:big, x} end, name: :big_check)

      workflow = Workflow.new(name: "original")
      {workflow, events1} = Workflow.add_with_events(workflow, step1)
      {workflow, events2} = Workflow.add_with_events(workflow, step2, to: :add_one)
      {original_workflow, events3} = Workflow.add_with_events(workflow, rule, to: :double)

      all_events = events1 ++ events2 ++ events3

      # Rebuild from events
      rebuilt_workflow = Workflow.apply_events(Workflow.new(), all_events)

      # Run both workflows with same input
      original_results =
        original_workflow
        |> Workflow.plan_eagerly(5)
        |> Workflow.react_until_satisfied()
        |> Workflow.raw_productions()

      rebuilt_results =
        rebuilt_workflow
        |> Workflow.plan_eagerly(5)
        |> Workflow.react_until_satisfied()
        |> Workflow.raw_productions()

      assert Enum.sort(original_results) == Enum.sort(rebuilt_results)
    end

    test "combined add_with_events events match build_log output" do
      step1 = Runic.step(fn x -> x + 1 end, name: :step_a)
      step2 = Runic.step(fn x -> x * 2 end, name: :step_b)
      step3 = Runic.step(fn x -> x > 5 end, name: :check)

      workflow = Workflow.new()
      {workflow, events1} = Workflow.add_with_events(workflow, step1)
      {workflow, events2} = Workflow.add_with_events(workflow, step2, to: :step_a)
      {final_workflow, events3} = Workflow.add_with_events(workflow, step3, to: :step_b)

      combined_events = events1 ++ events2 ++ events3
      build_log = Workflow.build_log(final_workflow)

      # build_log reverses the internal log which is appended by add_with_events
      # so build_log output should be in reverse order of combined_events
      assert length(combined_events) == length(build_log)

      # Compare by reversing the build_log to match combined_events order
      for {combined, logged} <- Enum.zip(combined_events, Enum.reverse(build_log)) do
        assert combined.name == logged.name
        assert combined.to == logged.to
        assert combined.closure == logged.closure
      end
    end

    test "events with bindings can recreate workflow in separate environment" do
      multiplier = 10

      step = Runic.step(fn x -> x * ^multiplier + 5 end, name: :transform)

      rule =
        Runic.rule(fn x when is_integer(x) -> {:above_offset, x} end, name: :above_offset_check)

      map = Runic.map(fn x -> x * ^multiplier end, name: :scale_map)

      reduce =
        Runic.reduce(0, fn x, acc -> x + acc + 5 end, name: :sum_with_offset, map: :scale_map)

      # Build workflow incrementally with add_with_events
      workflow = Workflow.new()
      {workflow, step_events} = Workflow.add_with_events(workflow, step)
      {workflow, rule_events} = Workflow.add_with_events(workflow, rule, to: :transform)
      {workflow, map_events} = Workflow.add_with_events(workflow, map)
      {final_workflow, reduce_events} = Workflow.add_with_events(workflow, reduce, to: :scale_map)

      all_events = step_events ++ rule_events ++ map_events ++ reduce_events

      # Get original results
      original_step_results =
        final_workflow
        |> Workflow.plan_eagerly(3)
        |> Workflow.react_until_satisfied()
        |> Workflow.raw_productions()

      # Recover in a separate environment using Code.eval_string
      recovery_code = """
      defmodule TestAddWithEventsRecovery do
        def recover_and_test(events) do
          alias Runic.Workflow

          recovered_workflow = Workflow.apply_events(Workflow.new(), events)

          recovered_workflow
          |> Workflow.plan_eagerly(3)
          |> Workflow.react_until_satisfied()
          |> Workflow.raw_productions()
        end
      end

      TestAddWithEventsRecovery.recover_and_test(events)
      """

      {recovered_results, _binding} = Code.eval_string(recovery_code, events: all_events)

      # Verify results match - the bindings were properly captured and restored
      for result <- original_step_results do
        assert result in recovered_results
      end
    end

    test "events preserve closure bindings correctly" do
      some_constant = 42

      step = Runic.step(fn x -> x + ^some_constant end, name: :add_constant)
      workflow = Workflow.new()

      {_workflow, events} = Workflow.add_with_events(workflow, step)
      [event] = events

      assert event.closure != nil
      assert event.closure.bindings[:some_constant] == 42
    end

    test "multiple components chained together produce correct event sequence" do
      step1 = Runic.step(fn x -> x + 1 end, name: :s1)
      step2 = Runic.step(fn x -> x * 2 end, name: :s2)
      step3 = Runic.step(fn x -> x - 1 end, name: :s3)

      workflow = Workflow.new()
      {workflow, e1} = Workflow.add_with_events(workflow, step1)
      {workflow, e2} = Workflow.add_with_events(workflow, step2, to: :s1)
      {_workflow, e3} = Workflow.add_with_events(workflow, step3, to: :s2)

      # Verify each event has correct parent relationship
      assert [%{name: :s1, to: nil}] = e1
      assert [%{name: :s2, to: :s1}] = e2
      assert [%{name: :s3, to: :s2}] = e3
    end

    test "workflow rebuilt from events produces identical execution results" do
      factor = 3

      step = Runic.step(fn x -> x * ^factor end, name: :multiply)
      rule = Runic.rule(fn x when x > 10 -> {:large, x} end, name: :size_check)
      step2 = Runic.step(fn x -> rem(x, 2) == 0 end, name: :is_even)

      workflow = Workflow.new()
      {workflow, e1} = Workflow.add_with_events(workflow, step)
      {workflow, e2} = Workflow.add_with_events(workflow, rule, to: :multiply)
      {original, e3} = Workflow.add_with_events(workflow, step2, to: :multiply)

      all_events = e1 ++ e2 ++ e3

      # Multiple rebuild cycles should be identical
      rebuilt1 = Workflow.apply_events(Workflow.new(), all_events)
      rebuilt2 = Workflow.apply_events(Workflow.new(), all_events)

      test_inputs = [1, 5, 10, 15]

      for input <- test_inputs do
        original_result =
          original
          |> Workflow.plan_eagerly(input)
          |> Workflow.react_until_satisfied()
          |> Workflow.raw_productions()
          |> Enum.sort()

        rebuilt1_result =
          rebuilt1
          |> Workflow.plan_eagerly(input)
          |> Workflow.react_until_satisfied()
          |> Workflow.raw_productions()
          |> Enum.sort()

        rebuilt2_result =
          rebuilt2
          |> Workflow.plan_eagerly(input)
          |> Workflow.react_until_satisfied()
          |> Workflow.raw_productions()
          |> Enum.sort()

        assert original_result == rebuilt1_result
        assert original_result == rebuilt2_result
      end
    end

    test "Rule with pattern matching produces correct event" do
      rule =
        Runic.rule do
          given(order: %{total: total, customer: _customer})
          where(total > 100)
          then(fn %{order: _order} -> {:vip_discount, total} end)
        end

      workflow = Workflow.new()
      {_workflow, events} = Workflow.add_with_events(workflow, rule)

      assert [%Runic.Workflow.ComponentAdded{} = event] = events
      assert event.closure != nil
      assert event.name == rule.name
    end
  end

  describe "FanIn + Join + multi-arity step" do
    test "a reduce FanIn joined with another step feeds correct values to multi-arity step" do
      # This reproduces the Gatsby workflow pattern:
      # - One step produces an overall analysis (single value)
      # - Another branch produces enumerable, maps over it, reduces into a map
      # - Both join into a 2-arity step that combines them

      wrk =
        Runic.workflow(
          name: "fanin-join-multiarity test",
          steps: [
            # First branch: single value producer
            Runic.step(fn input -> "overall: #{input}" end, name: :overall_step),
            # Second branch: produce enumerable
            Runic.step(fn _input -> [1, 2, 3] end, name: :enumerate_step)
          ]
        )

      # Map over the enumerable
      map_step = Runic.map(fn num -> {num, "chapter_#{num}"} end, name: :per_item_analysis)

      # Reduce into a map
      combine_items =
        Runic.reduce(
          %{},
          fn {num, text}, acc -> Map.put(acc, num, text) end,
          name: :combined_items,
          map: :per_item_analysis
        )

      # Multi-arity step that joins both branches
      final_step =
        Runic.step(
          fn overall, per_item_map ->
            # overall should be a string, per_item_map should be a map
            {overall, per_item_map}
          end,
          name: :final_combined
        )

      wrk =
        wrk
        |> Workflow.add(map_step, to: :enumerate_step)
        |> Workflow.add(combine_items, to: :per_item_analysis)
        |> Workflow.add(final_step, to: [:overall_step, :combined_items])

      # Run the workflow
      ran_wrk = Workflow.react_until_satisfied(wrk, "test_input")

      # Get the final production
      productions = Workflow.productions_by_component(ran_wrk)
      final_result = Map.get(productions, :final_combined)

      assert final_result != nil, "final_combined should have produced a result"

      # Get the value from the fact
      fact = List.first(final_result)
      {overall, per_item_map} = fact.value

      # The result should be a tuple of (overall_string, map_of_chapters)
      assert is_binary(overall), "First argument should be a string, got: #{inspect(overall)}"

      assert is_map(per_item_map),
             "Second argument should be a map, got: #{inspect(per_item_map)}"

      assert overall == "overall: test_input"
      assert per_item_map == %{1 => "chapter_1", 2 => "chapter_2", 3 => "chapter_3"}
    end
  end
end
