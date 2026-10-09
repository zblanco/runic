defmodule Runic.Workflow.SingleOutputExampleTest do
  use ExUnit.Case, async: true
  alias Runic.Workflow
  alias Runic.Examples.Scale

  test "the unrelated example composes, rebuilds, and returns explicit metadata" do
    definition = Workflow.new() |> Workflow.add(Scale.new(:scale, 3))
    rebuilt = definition |> Workflow.build_log() |> Workflow.from_log()
    completed = Workflow.react_until_satisfied(rebuilt, 4)
    assert [%{value: 12, meta: %{scale: %{factor: 3}}}] = Workflow.productions(completed, :scale)
  end

  test "the example's validation is a failure, not data" do
    node = Scale.new(:scale, 3)

    {:ok, runnable} =
      Workflow.Invokable.prepare(
        node,
        Workflow.new() |> Workflow.add(node),
        Workflow.Fact.new(value: :invalid)
      )

    assert %{status: :failed, error: :expected_number} =
             Workflow.Invokable.execute(node, runnable)
  end
end
