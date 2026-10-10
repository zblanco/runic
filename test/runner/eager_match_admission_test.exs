defmodule Runic.Runner.EagerMatchAdmissionTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  require Runic

  alias Runic.Runner
  alias Runic.Workflow

  setup do
    runner = :"eager_match_admission_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner})
    %{runner: runner}
  end

  for executor <- [:inline, Runic.Runner.Executor.Task],
      mode <- [:automatic, :manual],
      timing <- [:before, :after] do
    test "#{timing} match failure stops #{mode} admission with #{executor}", %{runner: runner} do
      owner = self()
      {workflow, condition} = failing_match_workflow(owner, unquote(timing))

      {:ok, _} =
        Runner.start_workflow(runner, :match, workflow,
          executor: unquote(executor),
          dispatch_mode: unquote(mode),
          on_complete: fn _, _ -> send(owner, :drained) end,
          hooks: [
            on_failed: fn runnable, _, _ -> send(owner, {:failed, runnable}) end
          ]
        )

      assert :ok = Runner.run(runner, :match, 1)
      assert_receive :drained, 5_000
      assert_received {:predicate, 1}
      assert_received {:failed, failed}
      assert failed.node.hash == condition.hash
      assert failed.input_fact.value == 1
      assert failed.status == :failed

      assert {:ok,
              %{
                status: :stopped,
                active_units: 0,
                causes: [%{kind: :failed, unit: {:runnable, id}, reason: reason}]
              }} = Runner.admission_status(runner, :match)

      assert id == failed.id
      assert reason == failed.error
      assert reason == {:hook_error, {:hook_error, :forced_match_failure}}
      refute_received {:rhs, _, _}
      refute_received {:failed, _}
      assert {:error, :admission_stopped} = Runner.step(runner, :match)

      # Input admission retains work but must not execute predicates while stopped.
      assert :ok = Runner.run(runner, :match, 2)
      assert {:ok, %{status: :stopped, causes: [_]}} = Runner.admission_status(runner, :match)
      refute_received {:predicate, _}
      refute_received {:rhs, _, _}

      assert :ok = Runner.continue(runner, :match)
      assert_receive :drained, 5_000
      assert {:ok, %{status: :open, active_units: 0}} = Runner.admission_status(runner, :match)
      assert_received {:predicate, 2}
      refute_received {:predicate, 1}
      assert_received {:rhs, :independent, 1}
      assert_received {:rhs, :independent, 2}
      assert_received {:rhs, :guarded, 2}
      refute_received {:rhs, _, _}
      refute_received {:failed, _}
    end
  end

  test "planning failure stops admission while previously admitted work drains", %{runner: runner} do
    owner = self()

    blocked =
      Runic.step(
        fn value ->
          send(owner, {:started, self(), value})

          receive do
            :release -> value
          end
        end,
        name: :blocked
      )

    rule = Runic.rule(fn value when value == 2 -> :unexpected end, name: :guarded)
    workflow = Runic.workflow(steps: [blocked], rules: [rule])
    [condition] = Workflow.get_component(workflow, {:guarded, :condition})

    workflow = %{
      workflow
      | before_hooks: %{
          condition.hash => [
            fn _, ctx ->
              if ctx.input_fact.value == 2, do: {:error, :rejected}, else: :ok
            end
          ]
        }
    }

    {:ok, _} =
      Runner.start_workflow(runner, :active, workflow,
        max_concurrency: 1,
        on_complete: fn _, _ -> send(owner, :drained) end
      )

    assert :ok = Runner.run(runner, :active, 1)
    assert_receive {:started, task, 1}, 5_000

    try do
      assert :ok = Runner.run(runner, :active, 2)

      assert {:ok, %{status: :stopped, active_units: 1, causes: [%{kind: :failed}]}} =
               Runner.admission_status(runner, :active)

      assert {:error, :busy} = Runner.continue(runner, :active)
    after
      send(task, :release)
    end

    assert_receive :drained, 5_000
    assert {:ok, %{status: :stopped, active_units: 0}} = Runner.admission_status(runner, :active)
    assert {:ok, completed} = Runner.get_workflow(runner, :active)
    assert Workflow.raw_productions(completed, :blocked) == [1]
    assert Workflow.is_runnable?(completed)
    refute_received {:started, _, 2}
  end

  test "recorded pending matches stop recovery admission on planning failure", %{runner: runner} do
    owner = self()
    {workflow, condition} = failing_match_workflow(owner, :before)
    input = Runic.Workflow.Fact.new(value: 1)
    workflow = Workflow.plan(workflow, input)
    {:ok, runnable} = Runic.Workflow.Invokable.prepare(condition, workflow, input)

    # Model a recorded dispatch whose reply was lost before the Worker recovered.
    workflow =
      Workflow.append_runnable_events(workflow, [
        %Runic.Workflow.RunnableDispatched{
          runnable_id: runnable.id,
          activation_id: runnable.activation_id,
          attempt_id: runnable.attempt_id,
          node_hash: condition.hash,
          input_fact: input,
          attempt: 0
        }
      ])

    assert {:ok, _} =
             Runner.start_workflow(runner, :pending, workflow,
               executor: :inline,
               on_complete: fn _, _ -> send(owner, :drained) end
             )

    assert_receive :drained, 5_000
    assert_received {:predicate, 1}

    assert {:ok, %{status: :stopped, active_units: 0, causes: [%{kind: :failed}]}} =
             Runner.admission_status(runner, :pending)

    refute_received {:rhs, _, _}
  end

  test "acknowledged failed-match consumption replays against the authored topology", %{
    runner: runner
  } do
    owner = self()
    {workflow, condition} = failing_match_workflow(owner, :after)

    assert {:ok, _} =
             Runner.start_workflow(runner, :persisted, workflow,
               executor: :inline,
               on_complete: fn _, _ -> send(owner, :drained) end
             )

    assert :ok = Runner.run(runner, :persisted, 1)
    assert_receive :drained, 5_000
    assert_received {:predicate, 1}
    refute_received {:rhs, _, _}
    assert :ok = Runner.checkpoint(runner, :persisted)

    {store, store_state} = Runner.get_store(runner)
    assert {:ok, stream} = store.stream(:persisted, store_state)

    events = Enum.to_list(stream)

    consumed =
      Enum.filter(events, fn
        %Runic.Workflow.Events.ActivationConsumed{node_hash: hash} -> hash == condition.hash
        _ -> false
      end)

    assert [%{from_label: :matchable}] = consumed
    assert :ok = Runner.stop(runner, :persisted)

    # Replay against the authored topology, then hydrate compacted input payloads.
    replayed = Workflow.from_events(events, workflow, fact_mode: :ref)

    refs =
      for {hash, %Workflow.FactRef{}} <- replayed.graph.vertices,
          into: MapSet.new(),
          do: hash

    resolver = Workflow.FactResolver.new({store, store_state})
    {replayed, _} = Workflow.Rehydration.resolve_hot(replayed, refs, resolver)
    completed = Workflow.react_until_satisfied(replayed)
    assert Workflow.raw_productions(completed) == [1]
    assert_received {:rhs, :independent, 1}
    refute_received {:predicate, 1}
    refute_received {:rhs, _, _}
  end

  defp failing_match_workflow(owner, timing) do
    guarded =
      Runic.rule(
        fn value when value < 10 ->
          send(context(:observer), {:rhs, :guarded, value})
          value
        end,
        name: :guarded
      )

    independent =
      Runic.rule(
        fn value when value > 0 ->
          send(context(:observer), {:rhs, :independent, value})
          value
        end,
        name: :independent
      )

    workflow =
      Runic.workflow(rules: [guarded, independent])
      |> Workflow.put_run_context(%{_global: %{observer: owner}})

    [condition | _] = Workflow.get_component(workflow, {:guarded, :condition})

    hook = fn _, ctx ->
      send(owner, {:predicate, ctx.input_fact.value})
      if ctx.input_fact.value == 1, do: {:error, :forced_match_failure}, else: :ok
    end

    field = if timing == :before, do: :before_hooks, else: :after_hooks
    {Map.put(workflow, field, %{condition.hash => [hook]}), condition}
  end
end
