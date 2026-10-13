defmodule Runic.Examples.JidoNativeContractTest do
  use ExUnit.Case, async: true
  require Runic
  alias Runic.Examples.{JidoAction, JidoNativeFixture}
  alias Runic.{Runner, Workflow}
  alias Runic.Workflow.{Execution, LocalBoundary, LocalFactError}

  defp definition do
    node = Jido.Instruction.new!(target: JidoNativeFixture) |> JidoAction.new(name: :native)
    Workflow.new() |> Workflow.add(node)
  end

  test "real Action schema and effects work with a bare local reference" do
    token = make_ref()

    {wf, execution} =
      Workflow.execute(definition(), %{value: 2, token: token}, identity_mode: :local)

    assert Execution.outputs(execution) == [%{value: 3, token: token}]

    assert [
             %{
               identity_mode: :local,
               value: %{token: ^token},
               meta: %{jido: %{effects: [:recorded]}}
             }
           ] =
             Workflow.productions(wf, :native)

    assert Enum.all?(Workflow.facts(wf), &(&1.identity_mode == :local))
    assert {:error, %LocalFactError{}} = LocalBoundary.check(wf, :workflow)
  end

  test "native mode still uses Jido input validation and explicit Action failure" do
    for value <- [-1, "invalid"] do
      {_wf, execution} =
        Workflow.execute(definition(), %{value: value, token: self()}, identity_mode: :local)

      assert Execution.outputs(execution) == []
      assert [%{error: error}] = execution.failures
      assert is_exception(error)
    end
  end

  test "portable Action execution still rejects process-local data" do
    {_wf, execution} = Workflow.execute(definition(), %{value: 2, token: :portable})
    assert Execution.outputs(execution) == [%{value: 3, token: :portable}]

    assert_raise Runic.Identity.CanonicalError, fn ->
      Workflow.execute(definition(), %{value: 2, token: self()})
    end
  end

  test "a scalar native child remains local after the Action" do
    wf =
      definition()
      |> Workflow.add(Runic.step(fn %{value: value} -> value end, name: :scalar), to: :native)

    {wf, _} = Workflow.execute(wf, %{value: 2, token: self()}, identity_mode: :local)
    assert [%{identity_mode: :local, value: 3}] = Workflow.productions(wf, :scalar)
  end

  test "a native managed Action runs without persistence or wrappers" do
    runner = :"jido_native_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner})

    {:ok, _} =
      Runner.start_workflow(runner, :native, definition(), owner: self(), persistence: :disabled)

    {:ok, id} =
      Runner.start_execution(runner, :native, %{value: 2, token: self()}, identity_mode: :local)

    assert {:ok, result} = Runner.await_execution(runner, :native, id)
    assert Execution.outputs(result) == [%{value: 3, token: self()}]
    assert result.persistence.status == :not_managed
  end
end
