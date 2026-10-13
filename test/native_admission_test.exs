defmodule Runic.NativeAdmissionTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  require Runic
  alias Runic.{Runner, Workflow}

  alias Runic.Workflow.{
    Fact,
    Invokable,
    LocalBoundary,
    LocalFactError,
    LocalScope,
    RunnableFailed
  }

  defp invalid_roots do
    fact = Fact.local(1)
    foreign = %{fact.local_scope | vm: <<0::256>>}

    [
      {:stale, %{fact | value: 2}},
      {:swapped, %{fact | local_scope: LocalScope.new()}},
      {:missing_scope, %{fact | local_scope: nil}},
      {:absent_scope, Map.delete(fact, :local_scope)},
      {:missing_proof, %{fact | payload_digest: nil}},
      {:foreign, %{fact | local_scope: foreign}},
      {:portable_marker, %{fact | identity_mode: :portable}},
      {:nested_foreign, Fact.local(%{nested: [foreign]})}
    ]
  end

  defp definition(observer) do
    Runic.workflow(
      steps: [
        Runic.step(
          fn x ->
            send(observer, :input_callback)
            x
          end,
          name: :echo
        )
      ]
    )
  end

  defp call(:react2, wf, fact), do: Workflow.react(wf, fact)
  defp call(:react3, wf, fact), do: Workflow.react(wf, fact, [])
  defp call(:plan, wf, fact), do: Workflow.plan(wf, fact)
  defp call(:plan_eagerly, wf, fact), do: Workflow.plan_eagerly(wf, fact)
  defp call(:until2, wf, fact), do: Workflow.react_until_satisfied(wf, fact)
  defp call(:until3, wf, fact), do: Workflow.react_until_satisfied(wf, fact, [])
  defp call(:invoke, wf, fact), do: Workflow.invoke(wf, Workflow.root(), fact)
  defp call(:protocol_invoke, wf, fact), do: Invokable.invoke(Workflow.root(), wf, fact)
  defp call(:execute, wf, fact), do: Workflow.execute(wf, fact, identity_mode: :local)

  for api <- [
        :react2,
        :react3,
        :plan,
        :plan_eagerly,
        :until2,
        :until3,
        :invoke,
        :protocol_invoke,
        :execute
      ] do
    test "#{api} rejects the complete invalid-root matrix before callbacks" do
      wf = definition(self()) |> Workflow.enable_event_emission()

      for {_kind, fact} <- invalid_roots() do
        error = assert_raise LocalFactError, fn -> call(unquote(api), wf, fact) end
        assert error.field == :input
        refute_received :input_callback
      end
    end
  end

  test "both Worker admission paths reject invalid roots without changing state or stopping owner" do
    runner = :"native_admission_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner})

    {:ok, worker} =
      Runner.start_workflow(runner, :root, definition(self()),
        owner: self(),
        persistence: :disabled
      )

    monitor = Process.monitor(worker)
    before = :sys.get_state(worker)

    for {_kind, fact} <- invalid_roots() do
      assert {:error, %LocalFactError{field: :input}} = Runner.run(runner, :root, fact)
      assert :sys.get_state(worker) == before

      id =
        Runic.Identity.digest(:execution, {:rejected_input, System.unique_integer([:positive])})

      assert {:error, %LocalFactError{field: :input}} =
               Runner.start_execution(runner, :root, fact,
                 identity_mode: :local,
                 execution_id: id
               )

      assert {:error, :not_found} = Runner.execution(runner, :root, id)
      assert :sys.get_state(worker) == before
      assert Process.alive?(worker)
      refute_received :input_callback
      refute_received {:DOWN, ^monitor, :process, ^worker, _}
    end

    {:ok, id} = Runner.start_execution(runner, :root, 7, identity_mode: :local)
    assert {:ok, execution} = Runner.await_execution(runner, :root, id)
    assert execution.failures == []
    assert Workflow.Execution.outputs(execution) == [7]
    assert_receive :input_callback
    assert :ok = Runner.cancel(runner, :root)
  end

  test "malformed Root acceptance uses a safe failure coordinate" do
    wf = definition(self()) |> Workflow.enable_event_emission()
    fact = %{Fact.local(1) | payload_digest: nil}
    {:ok, prepared} = Invokable.prepare(Workflow.root(), wf, fact)
    attempt = Invokable.execute(Workflow.root(), prepared)
    {rejected, accepted, events} = Workflow.accept_runnable(wf, attempt)
    assert accepted.status == :failed
    assert %LocalFactError{reason: :missing_local_payload} = accepted.error
    assert [%RunnableFailed{node_hash: node_id, failure_action: :halt}] = events
    assert node_id == Workflow.Components.vertex_id_of(Workflow.root())
    assert Workflow.facts(rejected) == []
    assert Workflow.raw_productions(rejected) == []
    refute_received :input_callback
  end

  test "workflow admission checks known local links while allowing independent roots and handoffs" do
    wf = definition(self())
    parent = Fact.local(1)
    child = Fact.local(2, ancestry: {:external_producer, parent.hash})
    bad = wf |> Workflow.log_fact(parent) |> Workflow.log_fact(child)
    assert_raise LocalFactError, fn -> LocalBoundary.validate_workflow!(bad) end
    runner = :"native_graph_admission_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner})

    assert {:error, %LocalFactError{reason: :local_parent_scope_mismatch}} =
             Runner.start_workflow(runner, :bad, bad, owner: self(), persistence: :disabled)

    roots = wf |> Workflow.log_fact(parent) |> Workflow.log_fact(Fact.local(3))
    assert :ok = LocalBoundary.validate_workflow!(roots)

    {:ok, worker} =
      Runner.start_workflow(runner, :roots, roots, owner: self(), persistence: :disabled)

    assert Process.alive?(worker)
    assert :ok = Runner.cancel(runner, :roots)
    handoff = Workflow.log_fact(wf, child)
    assert :ok = LocalBoundary.validate_workflow!(handoff)

    {:ok, _} =
      Runner.start_workflow(runner, :handoff, handoff, owner: self(), persistence: :disabled)

    assert :ok = Runner.cancel(runner, :handoff)
  end

  test "both Root invocation paths reject a handoff to a known parent in a different scope" do
    wf = Workflow.react_until_satisfied(definition(self()), 1, identity_mode: :local)
    assert_receive :input_callback
    [parent] = Workflow.productions(wf)
    handoff = Fact.local(5, ancestry: {:handoff, parent.hash})
    error = assert_raise LocalFactError, fn -> call(:protocol_invoke, wf, handoff) end
    assert error.reason == :local_parent_scope_mismatch
    refute_received :input_callback
    rejected = call(:invoke, wf, handoff)
    refute Enum.any?(Workflow.facts(rejected), &(&1.hash == handoff.hash))

    assert Enum.any?(
             rejected.runnable_events,
             &match?(
               %RunnableFailed{error: %LocalFactError{reason: :local_parent_scope_mismatch}},
               &1
             )
           )

    assert Workflow.productions(rejected) == Workflow.productions(wf)
    refute_received :input_callback
  end

  test "both Root invocation paths retain valid handoffs with an absent parent" do
    parent = Fact.local(1)
    handoff = Fact.local(5, ancestry: {:handoff, parent.hash})

    for api <- [:protocol_invoke, :invoke] do
      admitted = call(api, definition(self()), handoff)
      assert Enum.any?(Workflow.facts(admitted), &(&1.hash == handoff.hash))
      completed = Workflow.react_until_satisfied(admitted)
      assert [output] = Workflow.productions(completed)
      assert output.value == 5
      assert output.local_scope == handoff.local_scope
      assert_receive :input_callback
    end
  end

  test "valid supplied roots and raw local values still admit normally" do
    for api <- [:react2, :react3, :until2, :until3] do
      fact = Fact.local(7)
      completed = call(api, definition(self()), fact)
      assert [output] = Workflow.productions(completed)
      assert output.value == 7
      assert output.local_scope == fact.local_scope
      assert_receive :input_callback
    end

    {wf, execution} = Workflow.execute(definition(self()), self(), identity_mode: :local)
    assert execution.failures == []
    assert [output] = Workflow.productions(wf)
    assert output.value == self()
  end
end
