defmodule WorkflowTest do
  use ExUnit.Case
  require Runic
  alias Runic.Workflow
  alias Runic.Workflow.Invokable
  alias Runic.Workflow.Step
  alias Runic.Workflow.Fact
  require Runic

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
      |> String.split(~R/[^[:alnum:]\-]/u, trim: true)
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

    assert Enum.count(Workflow.next_runnables(wrk) |> dbg(label: "next_runnables")) == 1
    assert not is_nil(Workflow.matches(wrk))

    next_facts =
      Workflow.react(wrk)
      |> Workflow.reactions()

    assert Enum.any?(next_facts, &match?(%{value: "potato!"}, &1))

    wrk = Workflow.plan_eagerly(workflow, 42)
    assert Enum.count(Workflow.next_runnables(wrk)) == 1

    [%{value: result_value} | _rest] =
      Workflow.next_runnables(wrk)
      |> Enum.map(fn {step, fact} -> Runic.Workflow.Components.run(step.work, fact.value) end)

    assert is_integer(result_value)
  end
end
