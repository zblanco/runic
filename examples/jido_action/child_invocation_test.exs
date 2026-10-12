defmodule Runic.Examples.JidoDispatchBoundaryTest do
  use ExUnit.Case, async: true
  alias Runic.Examples.{JidoActionFixture, JidoDispatchBoundary}
  alias Runic.Workflow

  test "Call returns real Action output and Jido retains Frame/effect conversion" do
    workflow = JidoDispatchBoundary.workflow() |> Workflow.enable_event_emission()

    completed =
      Workflow.react_until_satisfied(workflow, %{target: JidoActionFixture, input: %{value: 2}})

    assert [%{value: %{value: 3}, meta: %{jido: %{effects: [:recorded]}}} = fact] =
             Workflow.productions(completed, :dispatch)

    frame = JidoDispatchBoundary.put_result(Jido.Exec.Frame.new(%{value: 2}), "dispatch", fact)
    assert Jido.Exec.Frame.fetch_result(frame, "dispatch") == {:ok, %{value: 3}}
    assert Jido.Exec.Frame.effects(frame, ["dispatch"]) == [:recorded]

    replayed =
      Workflow.from_events(
        Workflow.build_log(completed) ++ Enum.reverse(completed.uncommitted_events)
      )

    assert Workflow.productions(replayed, :dispatch) == [fact]
    refute Workflow.is_runnable?(replayed)
  end

  test "Action errors fail child execution without a public Dispatch placeholder" do
    completed =
      JidoDispatchBoundary.workflow()
      |> Workflow.react_until_satisfied(%{target: JidoActionFixture, input: %{value: -1}})

    assert Workflow.productions(completed, :dispatch) == []
  end

  test "nested Flow input uses public connections instead of endpoint lookup and Join" do
    require Runic

    left =
      Workflow.new(
        name: :left,
        input_ports: [in: []],
        output_ports: [result: [from: :left_output]]
      )
      |> Workflow.add(
        Runic.step(fn frame -> Jido.Exec.Frame.put_result(frame, "left", 4, []) end,
          name: :left_output
        )
      )

    right =
      Runic.step(fn frame -> Jido.Exec.Frame.put_result(frame, "right", 6, []) end, name: :right)

    child =
      Workflow.new(name: :flow, input_ports: [in: []], output_ports: [result: [from: :output]])
      |> Workflow.add(
        Runic.step(
          fn frames ->
            {:ok, merged} = Jido.Exec.Frame.merge(frames)
            merged
          end,
          name: :output
        )
      )

    workflow =
      Workflow.new()
      |> Workflow.add(left)
      |> Workflow.add(right)
      |> Workflow.add(child,
        connections: [
          [from: {:left, :result}, to: :in, target_path: [0]],
          [from: {:right, :out}, to: :in, target_path: [1]]
        ]
      )

    completed = Workflow.react_until_satisfied(workflow, Jido.Exec.Frame.new(%{value: 3}))
    assert [frame] = Workflow.raw_productions(completed, :flow)
    assert Jido.Exec.Frame.fetch_result(frame, "left") == {:ok, 4}
    assert Jido.Exec.Frame.fetch_result(frame, "right") == {:ok, 6}
  end
end
