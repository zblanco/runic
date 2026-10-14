defmodule Runic.Runner.PromiseProgressContractTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  require Runic
  alias Runic.{Runner, Workflow}
  alias Runic.TestSupport.{OrdinaryComponent, PromiseProgressScheduler, FailingStore}

  for executor <- [Runic.Runner.Executor.Task, :inline, Runic.TestSupport.ReleasingExecutor] do
    @tag executor: executor
    test "deferred hooks change continuation context and topology once with #{executor}", ctx do
      runner = runner()
      observer = self()

      workflow =
        Workflow.new()
        |> Workflow.add(OrdinaryComponent.new(:a, :add, 1))
        |> Workflow.add(OrdinaryComponent.new(:b, :add, 1), to: :a)
        |> Workflow.attach_after_hook(:a, fn _, workflow, _ ->
          send(observer, :hook_applied)

          workflow
          |> Workflow.put_run_context(%{b: %{offset: 100}})
          |> Workflow.add(OrdinaryComponent.new(:new_child, :add, 200), to: :a)
        end)

      {:ok, _} =
        Runner.start_workflow(runner, :hook, workflow,
          promise_opts: [min_chain_length: 2],
          executor: ctx.executor,
          executor_opts: [test_pid: observer]
        )

      {:ok, id} = Runner.start_execution(runner, :hook, 0)
      assert {:ok, _} = Runner.await_execution(runner, :hook, id)
      {:ok, completed} = Runner.get_workflow(runner, :hook)
      assert Workflow.raw_productions(completed, :b) == [102]
      assert Workflow.raw_productions(completed, :new_child) == [201]
      assert_receive :hook_applied
      refute_received :hook_applied
    end
  end

  for outcome <- [:success, :partial, :loss] do
    @tag outcome: outcome
    test "scheduler completion retains its original descriptor for #{outcome}", ctx do
      {runner, worker, id, task, promise} = start_chain(ctx.outcome)
      attach_stop(promise.id)
      if ctx.outcome == :loss, do: Process.exit(task, :kill), else: send(task, :release)
      assert {:ok, _} = Runner.await_execution(runner, :chain, id)
      assert_receive {:scheduler_complete, returned}, 2000
      assert Enum.map(returned.runnables, & &1.id) == Enum.map(promise.runnables, & &1.id)
      assert returned.node_hashes == promise.node_hashes
      assert :sys.get_state(worker).scheduler_state.active == MapSet.new()
      assert :sys.get_state(worker).promise_progress == %{}
      assert_receive {:promise_stop, %{runnable_count: 1}}, 2000
    end
  end

  test "loss of the final control reply after all accepted members invents no uncertainty" do
    {runner, worker, id, task, promise} = start_chain(:success)
    attach_stop(promise.id)
    state = :sys.get_state(worker)
    [{handle, _}] = Map.to_list(state.active_tasks)
    scope = state.task_scope
    :sys.suspend(scope)
    on_exit(fn -> if Process.alive?(scope), do: :sys.resume(scope) end)
    send(task, :release)
    assert_receive {:accepted, :c}, 2000
    wait_control(scope, handle)
    {:ok, pending} = Runner.execution(runner, :chain, id)
    assert pending.status == :active
    refute pending.quiescent?
    assert [%{control_pending?: true, runnable_ids: []}] = pending.active

    :sys.replace_state(scope, fn state ->
      receive do
        {:result, ^handle, _} -> state
      after
        0 -> raise "control result was not queued"
      end
    end)

    :sys.resume(scope)
    assert {:ok, execution} = Runner.await_execution(runner, :chain, id)
    assert execution.admission == :stopped
    assert Enum.map(execution.outcomes, & &1.kind) == [:completed, :completed, :completed]
    {:ok, workflow} = Runner.get_workflow(runner, :chain)
    refute Enum.any?(Workflow.event_log(workflow), &match?(%Workflow.ExecutionUncertain{}, &1))
    assert_receive {:scheduler_complete, returned}, 2000
    assert returned.runnables == promise.runnables
    assert :sys.get_state(worker).scheduler_state.active == MapSet.new()
    assert_receive {:promise_stop, %{executor_loss: true, runnable_count: 1}}, 2000
  end

  test "invalid or stale frontier messages leave Worker state unchanged" do
    {_runner, worker, _id, task, promise} = start_chain(:success)
    state = :sys.get_state(worker)
    [current] = state.promise_progress[promise.id].frontier
    executed = Workflow.SingleOutput.complete_value(current, 2)

    {:ok, child} =
      Workflow.Invokable.prepare(
        Workflow.get_component!(state.workflow, :c),
        state.workflow,
        executed.result
      )

    invalid = [
      :invalid,
      [],
      [current],
      [child, child],
      [%{child | activation_id: Runic.Identity.derive(:activation, [:wrong])}],
      [%{child | input_fact: current.input_fact}],
      [%{child | id: nil}],
      [%{child | activation_id: nil}],
      [%{child | attempt_id: nil}],
      [%{child | node: nil}]
    ]

    for frontier <- invalid do
      send(worker, {:promise_progress, promise.id, executed, frontier})
      assert :sys.get_state(worker) == state
    end

    for invalid_member <- [%{executed | node: nil}, %{executed | input_fact: nil}] do
      send(worker, {:promise_progress, promise.id, invalid_member, [child]})
      assert :sys.get_state(worker) == state
    end

    send(worker, {:promise_progress, make_ref(), executed, [child]})
    assert :sys.get_state(worker) == state
    stale = Workflow.SingleOutput.complete_value(hd(promise.runnables), 1)
    send(worker, {:promise_progress, promise.id, stale, [current]})
    assert :sys.get_state(worker) == state
    send(worker, {:promise_progress, promise.id, current, [child]})
    assert :sys.get_state(worker) == state
    Process.exit(task, :kill)
  end

  test "automatic checkpoint rejection keeps accepted progress and retries the original events" do
    store = start_supervised!(FailingStore)
    runner = runner(store)
    workflow = chain(:success)
    observer = self()

    {:ok, worker} =
      Runner.start_workflow(runner, :chain, workflow,
        promise_opts: [min_chain_length: 2],
        hooks: [on_complete: fn r, _, _ -> send(observer, {:accepted, r.node.name}) end]
      )

    {:ok, id} = Runner.start_execution(runner, :chain, 0)
    assert_receive {:stage, :a, task}, 2000
    FailingStore.fail(store, :append)
    send(task, :release)
    assert_receive {:stage, :b, ^task}, 2000
    assert_receive {:accepted, :a}, 2000

    assert {:ok, %{status: {:error, _}, pending_events: pending}} =
             Runner.persistence_status(runner, :chain)

    assert pending > 0
    assert Workflow.raw_productions(:sys.get_state(worker).workflow, :a) == [1]
    FailingStore.recover(store)
    assert :ok = Runner.checkpoint(runner, :chain)
    assert {:ok, %{status: :saved, pending_events: 0}} = Runner.persistence_status(runner, :chain)
    Process.exit(task, :kill)
    assert {:ok, _} = Runner.await_execution(runner, :chain, id)
  end

  defp runner(store \\ nil) do
    name = :"progress_contract_#{System.unique_integer([:positive])}"
    opts = if store, do: [store: FailingStore, store_opts: [agent: store]], else: []
    start_supervised!({Runner, [name: name] ++ opts})
    name
  end

  defp chain(mode) do
    a =
      Runic.step(
        fn value ->
          send(context(:observer), {:stage, :a, self()})
          receive do: (:release -> value + 1)
        end,
        name: :a
      )

    b =
      Runic.step(
        fn value ->
          send(context(:observer), {:stage, :b, self()})
          receive do: (:release -> :ok)
          if ^mode == :partial, do: raise("stop"), else: value + 1
        end,
        name: :b
      )

    c = Runic.step(fn value -> value + 1 end, name: :c)

    Runic.workflow(steps: [{a, [{b, [c]}]}])
    |> Workflow.put_run_context(%{_global: %{observer: self()}})
    |> Workflow.set_scheduler_policies([{:default, %{execution_mode: :durable}}])
  end

  defp start_chain(mode) do
    runner = runner()
    observer = self()

    {:ok, worker} =
      Runner.start_workflow(runner, :chain, chain(mode),
        scheduler: PromiseProgressScheduler,
        scheduler_opts: [observer: observer],
        hooks: [on_complete: fn r, _, _ -> send(observer, {:accepted, r.node.name}) end]
      )

    {:ok, id} = Runner.start_execution(runner, :chain, 0)
    assert_receive {:stage, :a, task}, 2000
    assert_receive {:scheduler_dispatch, promise}, 2000
    send(task, :release)
    assert_receive {:stage, :b, ^task}, 2000
    assert_receive {:accepted, :a}, 2000
    {runner, worker, id, task, promise}
  end

  defp attach_stop(promise_id) do
    owner = self()
    key = {:promise_contract, make_ref()}

    :telemetry.attach(
      key,
      [:runic, :runner, :promise, :stop],
      fn _, _, metadata, _ ->
        if metadata.promise_id == promise_id, do: send(owner, {:promise_stop, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(key) end)
  end

  defp wait_control(scope, handle, tries \\ 200)
  defp wait_control(_scope, _handle, 0), do: flunk("control result was not queued")

  defp wait_control(scope, handle, tries) do
    {:messages, messages} = Process.info(scope, :messages)

    if Enum.any?(messages, &match?({:result, ^handle, _}, &1)),
      do: :ok,
      else:
        (
          Process.sleep(5)
          wait_control(scope, handle, tries - 1)
        )
  end
end
