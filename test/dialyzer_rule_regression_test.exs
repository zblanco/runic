defmodule Runic.DialyzerRuleRegressionTest do
  use ExUnit.Case, async: true

  alias Runic.Workflow
  alias Runic.Workflow.{Fact, Rule}

  test "literal true and nil rules compile, match their input, and rebuild" do
    for literal <- [true, nil] do
      {rule, _} =
        Code.eval_quoted(
          quote do
            require Runic
            Runic.rule(fn unquote(literal) -> :matched end)
          end
        )

      assert Rule.check(rule, literal)
      refute Rule.check(rule, false)
      assert Rule.run(rule, literal) == :matched

      workflow = Workflow.new() |> Workflow.add(rule)
      rebuilt = workflow |> Workflow.build_log() |> Workflow.from_log()

      assert Workflow.raw_productions(
               Workflow.react_until_satisfied(rebuilt, Fact.new(value: literal))
             ) == [:matched]

      assert Workflow.raw_productions(Workflow.react_until_satisfied(rebuilt, false)) == []
    end
  end

  test "literal rules with context references match and rebuild" do
    for literal <- [true, nil] do
      {rule, _} =
        Code.eval_quoted(
          quote do
            require Runic
            Runic.rule(fn unquote(literal) -> context(:result) end)
          end
        )

      workflow =
        Workflow.new()
        |> Workflow.add(rule)
        |> Workflow.put_run_context(%{_global: %{result: :matched}})

      rebuilt =
        workflow
        |> Workflow.build_log()
        |> Workflow.from_log()
        |> Workflow.put_run_context(%{_global: %{result: :matched}})

      assert Workflow.raw_productions(
               Workflow.react_until_satisfied(workflow, Fact.new(value: literal))
             ) == [:matched]

      assert Workflow.raw_productions(
               Workflow.react_until_satisfied(rebuilt, Fact.new(value: literal))
             ) == [:matched]

      assert Workflow.raw_productions(Workflow.react_until_satisfied(rebuilt, false)) == []
    end
  end
end
