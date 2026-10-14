defmodule Runic.Runner.ChildPersistenceReviewTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  require Runic
  alias Runic.{Runner, Workflow}
  alias Runic.Workflow.{Call, ChildInvocation}
  alias Runic.Workflow.Events.FactProduced
  alias Runic.TestSupport.{OrdinaryComponent, OrdinaryChildComposite, SnapshotTailStore}

  setup do
    runner = :"child_portable_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner, store: SnapshotTailStore})
    %{runner: runner, store: Runner.get_store(runner)}
  end

  defp data_workflow do
    request =
      Runic.step(
        fn value ->
          ChildInvocation.new(target: OrdinaryComponent.new(:target, :data, 1), input: value)
        end,
        name: :request
      )

    Workflow.new()
    |> Workflow.add(Call.new(request, name: :call))
    |> Workflow.enable_event_emission()
  end

  test "large child input is absent from construction and the value-stripped attachment tail" do
    input = Enum.to_list(1..50_000)
    base = data_workflow()
    attached = base |> Workflow.plan_eagerly(input) |> Workflow.react()
    events = Enum.reverse(attached.uncommitted_events)
    stripped = strip(events)
    additions = Enum.filter(stripped, &is_struct(&1, Runic.Workflow.ComponentAdded))
    input_bytes = :erlang.term_to_binary(input)
    construction_bytes = :erlang.term_to_binary(additions)
    assert byte_size(construction_bytes) < div(byte_size(input_bytes), 20)
    assert :binary.match(construction_bytes, input_bytes) == :nomatch
    assert :binary.match(:erlang.term_to_binary(stripped), input_bytes) == :nomatch

    occurrence =
      Enum.find(
        Multigraph.vertices(attached.graph),
        &is_struct(&1, Runic.Workflow.ChildInvocation.Occurrence)
      )

    refute Map.has_key?(occurrence, :request)
    entry = Map.fetch!(attached.graph.vertices, occurrence.entry_hash)
    assert entry.value == nil
  end

  for mode <- [:full, :hybrid, :lazy] do
    test "stripped request values recover through #{mode} fact mode before child entry", ctx do
      input = Enum.to_list(1..1_000)
      base = data_workflow()
      attached = base |> Workflow.plan_eagerly(input) |> Workflow.react()
      prefix = Workflow.build_log(base)
      tail = Enum.reverse(attached.uncommitted_events)
      save(ctx.store, :wf, base, prefix, tail)
      {:ok, _} = Runner.resume(ctx.runner, :wf, executor: :inline, rehydration: unquote(mode))
      {:ok, result} = Runner.get_workflow(ctx.runner, :wf)
      assert Workflow.raw_productions(result, :call) == [input]
      assert not Workflow.is_runnable?(result)
    end

    test "stripped accepted child progress is not repeated in #{mode} recovery", ctx do
      request =
        Runic.step(
          fn value ->
            target =
              Workflow.new(
                name: :target,
                input_ports: [in: []],
                output_ports: [out: [from: :second]]
              )
              |> Workflow.add(OrdinaryComponent.new(:first, :add, 1))
              |> Workflow.add(OrdinaryComponent.new(:second, :add, 1), to: :first)

            ChildInvocation.new(target: target, input: value)
          end,
          name: :request
        )

      base =
        Workflow.new()
        |> Workflow.add(Call.new(request, name: :call))
        |> Workflow.put_run_context(%{_global: %{observer: self()}})
        |> Workflow.enable_event_emission()

      accepted =
        base
        |> Workflow.plan_eagerly(3)
        |> Workflow.react()
        |> Workflow.react()
        |> Workflow.react()

      assert_receive {:work, :first, _}
      prefix = Workflow.build_log(base)
      tail = Enum.reverse(accepted.uncommitted_events)
      save(ctx.store, :wf, base, prefix, tail)

      {:ok, _} =
        Runner.resume(ctx.runner, :wf,
          executor: :inline,
          rehydration: unquote(mode),
          run_context: %{_global: %{observer: self()}}
        )

      assert_receive {:work, :second, _}
      refute_received {:work, :first, _}
      {:ok, result} = Runner.get_workflow(ctx.runner, :wf)
      assert Workflow.raw_productions(result, :call) == [5]
    end
  end

  test "invalid fallback target is a recorded failure and does not terminate its owner", %{
    runner: runner
  } do
    request = Runic.step(fn _ -> raise "request failed" end, name: :request)
    base = Workflow.new() |> Workflow.add(Call.new(request, name: :call))
    target = OrdinaryChildComposite.new()
    valid = ChildInvocation.new(target: target, input: 3)

    invalid_event = %{
      valid.target
      | source: quote(do: raise("target cannot rebuild")),
        closure: nil
    }

    invalid = %{valid | target: invalid_event}
    fallback = fn _, _ -> {:value, invalid} end
    {:ok, worker} = Runner.start_workflow(runner, :wf, base)

    {:ok, id} =
      Runner.start_execution(runner, :wf, 3, scheduler_policies: [{:call, %{fallback: fallback}}])

    {:ok, execution} = Runner.await_execution(runner, :wf, id)
    assert Process.alive?(worker)
    assert execution.admission == :stopped

    assert [%{kind: :failed, error: {:child_construction_failed, %RuntimeError{}}}] =
             execution.failures

    {:ok, result} = Runner.get_workflow(runner, :wf)
    assert Workflow.raw_productions(result, :call) == []

    refute Enum.any?(
             Multigraph.vertices(result.graph),
             &is_struct(&1, Runic.Workflow.ChildInvocation.Occurrence)
           )
  end

  test "parallel Promise applies prepared Calls without owner-time reconstruction", %{
    runner: runner
  } do
    request =
      Runic.step(
        fn value ->
          ChildInvocation.new(target: OrdinaryComponent.new(:target, :add, 1), input: value)
        end,
        name: :request
      )

    base =
      Enum.reduce([:call1, :call2, :call3, :call4], Workflow.new(), fn name, wf ->
        Workflow.add(wf, Call.new(request, name: name))
      end)

    planned = Workflow.plan_eagerly(base, 3)
    {planned, ready} = Workflow.prepare_for_dispatch(planned)
    {:ok, state} = Runic.Runner.Scheduler.FlowBatch.init(min_batch_size: 2)
    {units, _} = Runic.Runner.Scheduler.FlowBatch.plan_dispatch(planned, ready, state)
    assert [{:promise, %{strategy: :parallel, runnables: runnables}}] = units
    assert length(runnables) == 4

    {:ok, _} =
      Runner.start_workflow(runner, :wf, base,
        scheduler: Runic.Runner.Scheduler.FlowBatch,
        scheduler_opts: [min_batch_size: 2]
      )

    {:ok, id} = Runner.start_execution(runner, :wf, 3)
    {:ok, execution} = Runner.await_execution(runner, :wf, id)
    assert execution.quiescent?
    {:ok, result} = Runner.get_workflow(runner, :wf)

    for name <- [:call1, :call2, :call3, :call4],
        do: assert(Workflow.raw_productions(result, name) == [4])
  end

  defp save({store, state}, id, base, prefix, tail) do
    for %FactProduced{hash: hash, value: value} <- tail, do: store.save_fact(hash, value, state)
    {:ok, _} = store.append(id, prefix ++ strip(tail), state)
    :ok = store.save_snapshot(id, length(prefix), Runner.encode_snapshot(base), state)
  end

  defp strip(events),
    do:
      Enum.map(events, fn
        %FactProduced{} = event -> %{event | value: nil}
        event -> event
      end)
end
