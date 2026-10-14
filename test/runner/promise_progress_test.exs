defmodule Runic.Runner.PromiseProgressTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  require Runic
  alias Runic.{Runner, Workflow}
  alias Runic.Workflow.{Execution, RunnableCompleted, RunnableFailed}
  alias Runic.TestSupport.FailingStore

  setup do
    store = start_supervised!(FailingStore)
    runner = :"promise_progress_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner, store: FailingStore, store_opts: [agent: store]})
    %{runner: runner, store: store}
  end

  test "Task loss retains the accepted prefix and reports only its unresolved frontier", ctx do
    {worker, execution_id, outer} = start_chain(ctx)
    state = :sys.get_state(worker)
    [promise] = Map.values(state.active_promises)
    assert [frontier] = state.promise_progress[promise.id].frontier
    assert frontier.node.name == :b
    assert Workflow.raw_productions(state.workflow, :a) == [2]
    assert_received {:complete, :a}
    assert_received :hook_a

    assert {:ok, %{status: :saved, pending_events: 0}} =
             Runner.persistence_status(ctx.runner, :chain)

    Process.exit(outer, :kill)
    assert {:ok, execution} = Runner.await_execution(ctx.runner, :chain, execution_id)
    assert execution.admission != :open

    assert [%{kind: :completed, node_name: :a}, %{kind: :uncertain, node_name: :b}] =
             execution.outcomes

    assert Execution.outputs(execution) == [2]
    {:ok, wf} = Runner.get_workflow(ctx.runner, :chain)
    refute Enum.any?(Workflow.event_log(wf), &match?(%RunnableFailed{}, &1))

    assert [%{members: [%{node_name: :b}]}] =
             Enum.filter(Workflow.event_log(wf), &match?(%Workflow.ExecutionUncertain{}, &1))

    refute_received :c_ran

    # The Store-acknowledged prefix survives event replay with fresh runtime.
    :ok = Runner.stop(ctx.runner, :chain)

    {:ok, _} =
      Runner.resume(ctx.runner, :chain,
        run_context: %{_global: %{observer: self(), block: false}}
      )

    await_idle(ctx.runner)
    {:ok, recovered} = Runner.get_workflow(ctx.runner, :chain)
    assert Workflow.raw_productions(recovered, :c) == [4]
    refute_received :a_ran
    refute_received :hook_a
    assert_received :c_ran
  end

  test "native cancellation stops the Task and Store recovery retains the accepted prefix", ctx do
    {_worker, _execution_id, outer} = start_chain(ctx)
    assert_received {:complete, :a}
    assert_received :hook_a

    assert {:ok, %{status: :saved, pending_events: 0}} =
             Runner.persistence_status(ctx.runner, :chain)

    monitor = Process.monitor(outer)
    assert :ok = Runner.cancel(ctx.runner, :chain)
    assert_receive {:DOWN, ^monitor, :process, ^outer, _}, 2000

    {:ok, _} =
      Runner.resume(ctx.runner, :chain,
        run_context: %{_global: %{observer: self(), block: false}}
      )

    await_idle(ctx.runner)
    {:ok, workflow} = Runner.get_workflow(ctx.runner, :chain)
    assert Workflow.raw_productions(workflow, :c) == [4]
    refute_received :a_ran
    refute_received :hook_a
    assert_received :c_ran
  end

  for reply <- [:full, :partial] do
    @tag reply: reply
    test "duplicate progress and #{reply} replies apply the prefix once", ctx do
      {worker, _id, outer} = start_chain(ctx)
      assert_received {:complete, :a}
      assert_received :hook_a
      state = :sys.get_state(worker)
      [promise] = Map.values(state.active_promises)
      [{ref, _}] = Map.to_list(state.active_tasks)
      # Recreate the same accepted member as a late executor reply.
      {:ok, prepared} =
        Workflow.Invokable.prepare(
          Workflow.get_component!(state.workflow, :a),
          state.workflow,
          hd(Workflow.facts(state.workflow) |> Enum.filter(&is_nil(&1.ancestry)))
        )

      {executed, events} =
        Workflow.PolicyDriver.execute(
          prepared,
          %Workflow.SchedulerPolicy{execution_mode: :durable},
          emit_events: true
        )

      assert_received :a_ran
      assert_received :hook_a
      frontier = state.promise_progress[promise.id].frontier
      send(worker, {:promise_progress, promise.id, {executed, events}, frontier})

      message =
        if ctx.reply == :full,
          do: {:promise_result, promise.id, [{executed, events}, {executed, events}]},
          else:
            {:promise_partial, promise.id, [{executed, events}],
             Workflow.Runnable.fail(hd(frontier), :failed)}

      send(worker, {ref, message})
      :sys.get_state(worker)
      send(worker, {ref, message})
      send(worker, {:promise_progress, promise.id, {executed, events}, frontier})
      :sys.get_state(worker)
      refute_received {:complete, :a}
      refute_received :hook_a
      {:ok, wf} = Runner.get_workflow(ctx.runner, :chain)

      assert length(
               Enum.filter(
                 Workflow.event_log(wf),
                 &(match?(%RunnableCompleted{}, &1) and
                     &1.node_hash == Workflow.get_component!(wf, :a).hash)
               )
             ) == 1

      Process.exit(outer, :kill)
    end
  end

  test "local acceptance stays visible when Store writes fail", ctx do
    {worker, _id, outer} = start_chain(ctx, checkpoint_strategy: :manual)
    FailingStore.fail(ctx.store, :append)

    assert {:error, {:persistence_failed, :storage_unavailable}} =
             Runner.checkpoint(ctx.runner, :chain)

    assert {:ok, %{status: {:error, _}, pending_events: count}} =
             Runner.persistence_status(ctx.runner, :chain)

    assert count > 0
    assert Workflow.raw_productions(:sys.get_state(worker).workflow, :a) == [2]
    FailingStore.recover(ctx.store)
    assert :ok = Runner.checkpoint(ctx.runner, :chain)

    assert {:ok, %{status: :saved, pending_events: 0}} =
             Runner.persistence_status(ctx.runner, :chain)

    Process.exit(outer, :kill)
  end

  defp start_chain(ctx, opts \\ []) do
    a =
      Runic.step(
        fn value ->
          send(context(:observer), :a_ran)
          value + 1
        end,
        name: :a
      )

    b =
      Runic.step(
        fn value ->
          if context(:block) do
            send(context(:observer), {:b_started, self()})
            receive do: (:release -> :ok)
          end

          value + 1
        end,
        name: :b
      )

    c =
      Runic.step(
        fn value ->
          send(context(:observer), :c_ran)
          value + 1
        end,
        name: :c
      )

    observer = self()

    hook = fn _, _ ->
      send(observer, :hook_a)
      :ok
    end

    wf =
      Runic.workflow(steps: [{a, [{b, [c]}]}])
      |> Workflow.put_run_context(%{_global: %{observer: observer, block: true}})
      |> Workflow.set_scheduler_policies([{:default, %{execution_mode: :durable}}])
      |> Map.put(:after_hooks, %{a.hash => [hook]})

    {:ok, worker} =
      Runner.start_workflow(
        ctx.runner,
        :chain,
        wf,
        Keyword.merge(
          [
            promise_opts: [min_chain_length: 2],
            hooks: [on_complete: fn r, _, _ -> send(observer, {:complete, r.node.name}) end]
          ],
          opts
        )
      )

    {:ok, id} = Runner.start_execution(ctx.runner, :chain, 1)
    assert_receive {:b_started, outer}, 2000
    assert_receive {:complete, :a}, 2000
    assert_receive :hook_a, 2000
    assert_receive :a_ran, 2000
    # Keep these messages for each test's acceptance assertions.
    send(self(), {:complete, :a})
    send(self(), :hook_a)
    {worker, id, outer}
  end

  defp await_idle(runner, attempts \\ 200)

  defp await_idle(runner, 0),
    do:
      flunk(
        "workflow did not become idle: #{inspect(:sys.get_state(Runner.lookup(runner, :chain)), limit: 15)}"
      )

  defp await_idle(runner, attempts) do
    case :sys.get_state(Runner.lookup(runner, :chain)) do
      %{status: :idle} ->
        :ok

      _ ->
        Process.sleep(10)
        await_idle(runner, attempts - 1)
    end
  end
end
