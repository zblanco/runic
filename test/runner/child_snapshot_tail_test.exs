defmodule Runic.Runner.ChildSnapshotTailTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  require Runic
  alias Runic.{Runner, Workflow}
  alias Runic.Workflow.{Call, ChildInvocation, Fact}
  alias Runic.Workflow.ChildInvocation.Occurrence
  alias Runic.TestSupport.{OrdinaryComponent, SnapshotTailStore}

  setup do
    runner = :"child_snapshot_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner, store: SnapshotTailStore})
    %{runner: runner, store: Runner.get_store(runner)}
  end

  defp workflow do
    request =
      Runic.step(
        fn input ->
          target =
            Workflow.new(
              name: :pipeline,
              input_ports: [in: []],
              output_ports: [out: [from: :second]]
            )
            |> Workflow.add(OrdinaryComponent.new(:first, :add, 1))
            |> Workflow.add(OrdinaryComponent.new(:second, :add, 1), to: :first)

          ChildInvocation.new(target: target, input: input)
        end,
        name: :request
      )

    Workflow.new()
    |> Workflow.add(Call.new(request, name: :call))
    |> Workflow.enable_event_emission()
  end

  for mode <- [:full, :hybrid] do
    test "resume applies attachment after a snapshot before request acceptance with #{mode} facts",
         ctx do
      base = workflow()
      planned = Workflow.plan_eagerly(base, 3)
      prefix = Workflow.build_log(base) ++ Enum.reverse(planned.uncommitted_events)
      snapshot = %{planned | uncommitted_events: []}
      attached = Workflow.react(snapshot)
      tail = Enum.reverse(attached.uncommitted_events)
      assert Enum.any?(tail, &is_struct(&1, Runic.Workflow.ComponentAdded))
      restored = Workflow.from_events(tail, snapshot)

      assert Enum.map(Workflow.build_log(restored), &{&1.name, &1.hash, &1.to}) ==
               Enum.map(Workflow.build_log(attached), &{&1.name, &1.hash, &1.to})

      assert restored |> Workflow.react_until_satisfied() |> Workflow.raw_productions(:call) == [
               5
             ]

      save(ctx.store, :wf, snapshot, prefix, tail)
      {:ok, _} = Runner.resume(ctx.runner, :wf, executor: :inline, rehydration: unquote(mode))
      {:ok, result} = Runner.get_workflow(ctx.runner, :wf)
      assert Workflow.raw_productions(result, :call) == [5]
      assert occurrences(result) |> length() == 1
      assert not Workflow.is_runnable?(result)
      {store, state} = ctx.store
      assert store.call_count(state, {:stream, :wf, :after_cursor}) == 1
      assert store.call_count(state, {:stream, :wf}) == 0
    end
  end

  test "a snapshot during one occurrence accepts another occurrence and child progress from its tail",
       ctx do
    base = workflow() |> Workflow.put_run_context(%{_global: %{observer: self()}})
    first_input = Fact.new(value: 3, id: Runic.Identity.derive(:fact_occurrence, [:first]))
    first = base |> Workflow.plan_eagerly(first_input) |> Workflow.react() |> Workflow.react()
    prefix = Workflow.build_log(base) ++ Enum.reverse(first.uncommitted_events)
    snapshot = %{first | uncommitted_events: []}
    assert occurrences(snapshot) |> length() == 1
    second_input = Fact.new(value: 10, id: Runic.Identity.derive(:fact_occurrence, [:second]))
    next = snapshot |> Workflow.plan_eagerly(second_input) |> Workflow.react()
    assert_receive {:work, :first, _}
    tail = Enum.reverse(next.uncommitted_events)
    assert occurrences(next) |> length() == 2
    save(ctx.store, :wf, snapshot, prefix, tail)

    {:ok, _} =
      Runner.resume(ctx.runner, :wf,
        executor: :inline,
        run_context: %{_global: %{observer: self()}}
      )

    {:ok, result} = Runner.get_workflow(ctx.runner, :wf)
    assert Enum.sort(Workflow.raw_productions(result, :call)) == [5, 12]
    assert occurrences(result) |> Enum.uniq_by(& &1.hash) |> length() == 2
    assert_receive {:work, :first, _}
    refute_received {:work, :first, _}
    assert_receive {:work, :second, _}
    assert_receive {:work, :second, _}
    refute_received {:work, :second, _}
    assert not Workflow.is_runnable?(result)
  end

  defp save({store, state}, id, snapshot, prefix, tail) do
    for %Runic.Workflow.Events.FactProduced{hash: hash, value: value} <- prefix ++ tail do
      :ok = store.save_fact(hash, value, state)
    end

    {:ok, _} = store.append(id, prefix ++ tail, state)
    :ok = store.save_snapshot(id, length(prefix), Runner.encode_snapshot(snapshot), state)
  end

  defp occurrences(workflow),
    do: Enum.filter(Multigraph.vertices(workflow.graph), &is_struct(&1, Occurrence))
end
