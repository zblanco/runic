defmodule Runic.NativeCoordinatorContractTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  alias Runic.{Runner, Workflow}

  alias Runic.Workflow.{
    Fact,
    Invokable,
    LocalFactError,
    PolicyDriver,
    RunnableDispatched,
    RunnableFailed,
    SchedulerPolicy
  }

  alias Runic.TestSupport.NativeCoordinator

  defp coordinator_parent(:declared), do: Fact.local(8)
  defp coordinator_parent(_), do: nil
  defp execution_options(:scope_error), do: []
  defp execution_options(_), do: [identity_mode: :local]
  defp log_parent(workflow, nil), do: workflow
  defp log_parent(workflow, parent), do: Workflow.log_fact(workflow, parent)

  defp attempted(mode, input, parent \\ nil) do
    node = NativeCoordinator.new(mode, self())
    wf = Workflow.new() |> Workflow.add_step(node)
    wf = %{wf | mapped: Map.put(wf.mapped, :native_coord_parent, parent)}
    wf = wf |> Workflow.log_fact(input)
    wf = log_parent(wf, parent)
    {:ok, prepared} = Invokable.prepare(node, wf, input)

    {attempt, events} =
      PolicyDriver.execute(prepared, SchedulerPolicy.default_policy(), emit_events: true)

    {wf, attempt, events}
  end

  test "declared custom parents reject conflicting scopes before finalization" do
    {wf, attempt, events} = attempted(:declared, Fact.local(7), Fact.local(8))
    {wf, accepted, events} = Workflow.accept_runnable(wf, attempt, events)
    assert accepted.status == :failed
    assert %ArgumentError{} = accepted.error
    assert [%RunnableDispatched{}, %RunnableFailed{failure_action: :halt}] = events
    assert Workflow.productions(wf) == []
    refute_received :custom_finalize
  end

  test "a custom coordinator can declare one local scope with portable input" do
    parent = Fact.local(8)
    {wf, attempt, events} = attempted(:declared, Fact.new(value: 7), parent)
    {wf, accepted, _} = Workflow.accept_runnable(wf, attempt, events)
    assert accepted.status == :completed
    assert_receive :custom_finalize

    assert Enum.any?(
             Workflow.productions(wf),
             &(&1.value == :combined and &1.local_scope == parent.local_scope)
           )
  end

  test "undeclared local coordination is rejected but portable coordination still works" do
    {wf, attempt, events} = attempted(:unsupported, Fact.local(7))
    {_wf, accepted, _} = Workflow.accept_runnable(wf, attempt, events)
    assert %LocalFactError{reason: :unsupported_local_coordinator} = accepted.error
    refute_received :custom_finalize
    {wf, attempt, events} = attempted(:unsupported, Fact.new(value: 7))
    {_wf, accepted, _} = Workflow.accept_runnable(wf, attempt, events)
    assert accepted.status == :completed
    assert_receive :custom_finalize
  end

  test "the bounded safety net rejects a finalization scope error without retaining staged output" do
    {wf, attempt, events} = attempted(:scope_error, Fact.new(value: 7))
    {wf, accepted, events} = Workflow.accept_runnable(wf, attempt, events)
    assert accepted.status == :failed

    assert %ArgumentError{message: "cannot combine facts from different local scopes"} =
             accepted.error

    assert [%RunnableDispatched{}, %RunnableFailed{}] = events
    assert Workflow.productions(wf) == []
    assert_receive :custom_finalize
  end

  test "an unrelated coordinator exception is not converted to a scope failure" do
    {wf, attempt, events} = attempted(:argument_error, Fact.new(value: 7))

    assert_raise ArgumentError, "unrelated coordinator bug", fn ->
      Workflow.accept_runnable(wf, attempt, events)
    end
  end

  for mode <- [:declared, :unsupported, :scope_error] do
    test "#{mode} failure records Worker outcomes and leaves the Worker alive" do
      mode = unquote(mode)
      node = NativeCoordinator.new(mode, self())
      parent = coordinator_parent(mode)
      wf = Workflow.new() |> Workflow.add_step(node)
      wf = %{wf | mapped: Map.put(wf.mapped, :native_coord_parent, parent)}
      wf = log_parent(wf, parent)
      runner = :"native_coord_#{System.unique_integer([:positive])}"
      start_supervised!({Runner, name: runner})
      observer = self()

      {:ok, worker} =
        Runner.start_workflow(runner, :coord, wf,
          owner: observer,
          persistence: :disabled,
          hooks: [
            on_complete: fn _, _, _ -> send(observer, :custom_complete) end,
            on_failed: fn _, error, _ -> send(observer, {:custom_failed, error}) end
          ]
        )

      opts = execution_options(mode)
      {:ok, id} = Runner.start_execution(runner, :coord, 7, opts)
      assert {:ok, result} = Runner.await_execution(runner, :coord, id)
      assert [%{kind: :failed}] = result.outcomes
      assert_receive {:custom_failed, _}
      refute_received :custom_complete
      assert Process.alive?(worker)
      assert :ok = Runner.cancel(runner, :coord)
    end
  end
end
