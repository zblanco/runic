defmodule Runic.Runner.OwnershipTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  require Runic
  alias Runic.Runner
  alias Runic.Workflow
  alias Runic.TestSupport.FailingStore
  alias Runic.TestSupport.ReleasingExecutor

  setup do
    runner = :"ownership_#{System.unique_integer([:positive])}"
    store = start_supervised!(FailingStore)
    start_supervised!({Runner, name: runner, store: FailingStore, store_opts: [agent: store]})
    %{runner: runner, store: store}
  end

  for timeout <- [:infinity, 60_000] do
    test "stop confirms death of active work with timeout #{inspect(timeout)}", ctx do
      {worker, task} = start_blocked(ctx.runner, timeout_ms: unquote(timeout))
      task_ref = Process.monitor(task)
      worker_ref = Process.monitor(worker)

      assert :ok = Runner.stop(ctx.runner, :wf, persist: false)
      refute Process.alive?(task)
      assert_receive {:DOWN, ^task_ref, :process, ^task, _}, 1_000
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}, 1_000
    end

    test "abrupt Worker death stops active work with timeout #{inspect(timeout)}", ctx do
      {worker, task} = start_blocked(ctx.runner, timeout_ms: unquote(timeout))
      task_ref = Process.monitor(task)
      Process.exit(worker, :kill)
      assert_receive {:DOWN, ^task_ref, :process, ^task, _}, 1_000
    end
  end

  test "failed persistent stop preserves the same Worker and live work", ctx do
    {worker, task} = start_blocked(ctx.runner)
    task_ref = Process.monitor(task)
    FailingStore.fail(ctx.store, :append)

    assert {:error, {:persistence_failed, :storage_unavailable}} = Runner.stop(ctx.runner, :wf)
    assert Runner.lookup(ctx.runner, :wf) == worker
    assert Process.alive?(worker)
    token = make_ref()
    send(task, {:probe, self(), token})
    assert_receive {:alive, ^token}

    FailingStore.recover(ctx.store)
    assert :ok = Runner.stop(ctx.runner, :wf)
    refute Process.alive?(task)
    assert_receive {:DOWN, ^task_ref, :process, ^task, _}, 1_000
  end

  for reason <- [:normal, :kill] do
    test "owned execution stops after owner exit #{reason}", ctx do
      owner = spawn(fn -> receive do: (:finish -> :ok) end)
      owner_ref = Process.monitor(owner)
      {worker, task} = start_blocked(ctx.runner, [], owner: owner)
      task_ref = Process.monitor(task)
      worker_ref = Process.monitor(worker)

      if unquote(reason) == :normal, do: send(owner, :finish), else: Process.exit(owner, :kill)
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, _}, 1_000
      assert_receive {:DOWN, ^task_ref, :process, ^task, _}, 1_000
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 1_000
      assert Runner.lookup(ctx.runner, :wf) == nil
    end
  end

  test "background execution outlives the caller and completes", ctx do
    observer = self()
    workflow = blocked_workflow(observer, [])

    caller =
      spawn(fn ->
        {:ok, worker} =
          Runner.start_workflow(ctx.runner, :wf, workflow,
            owner: :background,
            hooks: [on_idle: fn _ -> send(observer, :idle) end]
          )

        send(observer, {:worker, worker})
        Runner.run(ctx.runner, :wf, 1)
      end)

    caller_ref = Process.monitor(caller)
    assert_receive {:worker, worker}, 1_000
    assert_receive {:started, task}, 1_000
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}, 1_000
    assert Process.alive?(worker)
    token = make_ref()
    send(task, {:probe, self(), token})
    assert_receive {:alive, ^token}
    send(task, :release)
    assert_receive :idle, 1_000
    assert {:ok, [1]} = Runner.get_results(ctx.runner, :wf)
  end

  test "cancel confirms quiescence without attempting persistence", ctx do
    {worker, task} = start_blocked(ctx.runner, timeout_ms: 60_000)
    task_ref = Process.monitor(task)
    worker_ref = Process.monitor(worker)
    FailingStore.fail(ctx.store, :append)
    calls = FailingStore.data(ctx.store).calls

    assert :ok = Runner.cancel(ctx.runner, :wf)
    refute Process.alive?(task)
    refute Process.alive?(worker)
    assert_receive {:DOWN, ^task_ref, :process, ^task, _}, 1_000
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 1_000
    assert FailingStore.data(ctx.store).calls == calls
    assert Runner.lookup(ctx.runner, :wf) == nil
  end

  for opts <- [[async: true], [scheduler_policies: [{:blocked, %{timeout_ms: 60_000}}]]] do
    test "immediate owner death stops native work with #{inspect(opts)}" do
      workflow = blocked_workflow(self(), [])

      caller =
        spawn(fn -> Workflow.react_until_satisfied(workflow, 1, unquote(Macro.escape(opts))) end)

      assert_receive {:started, task}, 1_000
      task_ref = Process.monitor(task)
      on_exit(fn -> if Process.alive?(task), do: Process.exit(task, :kill) end)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^task_ref, :process, ^task, _}, 1_000
    end
  end

  for order <- [:result_first, :cancel_first] do
    test "result/cancel order #{order} cannot apply an old handle to a replacement Worker", ctx do
      observer = self()
      workflow = Runic.workflow(steps: [Runic.step(fn n -> n + 1 end, name: :increment)])

      opts = [
        executor: ReleasingExecutor,
        executor_opts: [test_pid: observer, outcome: :deferred],
        hooks: [on_complete: fn _, _, _ -> send(observer, :completed) end]
      ]

      assert {:ok, worker} = Runner.start_workflow(ctx.runner, :wf, workflow, opts)
      assert :ok = Runner.run(ctx.runner, :wf, 1)
      assert_receive {:executor_result, ^worker, handle, result}, 1_000

      if unquote(order) == :result_first do
        send(worker, {handle, result})
        assert {:ok, [2]} = Runner.get_results(ctx.runner, :wf)
        assert_receive :completed
      end

      assert :ok = Runner.cancel(ctx.runner, :wf)
      assert {:ok, replacement} = Runner.start_workflow(ctx.runner, :wf, workflow)
      send(replacement, {handle, result})
      send(replacement, {:DOWN, handle, :process, worker, :normal})
      assert {:ok, []} = Runner.get_results(ctx.runner, :wf)
      refute_received :completed
    end
  end

  test "cancellation prevents admission of the next Step", ctx do
    observer = self()
    first = Runic.step(fn input -> block(observer, input) end, name: :first)

    second =
      Runic.step(
        fn input ->
          send(observer, :second_started)
          input
        end,
        name: :second
      )

    workflow = Runic.workflow(steps: [{first, [second]}])
    assert {:ok, _worker} = Runner.start_workflow(ctx.runner, :wf, workflow)
    assert :ok = Runner.run(ctx.runner, :wf, 1)
    assert_receive {:started, task}
    assert :ok = Runner.cancel(ctx.runner, :wf)
    refute Process.alive?(task)
    refute_received :second_started
  end

  for mode <- [:sequential, :parallel] do
    test "cancel stops #{mode} Promise work that traps exits", ctx do
      observer = self()
      first = Runic.step(fn input -> block(observer, input) end, name: :first)
      second = Runic.step(fn input -> block(observer, input) end, name: :second)

      {workflow, opts, count} =
        if unquote(mode) == :sequential do
          {Runic.workflow(steps: [{first, [second]}]),
           [scheduler: Runic.Runner.Scheduler.ChainBatching], 1}
        else
          {Runic.workflow(steps: [first, second]),
           [
             scheduler: Runic.Runner.Scheduler.FlowBatch,
             scheduler_opts: [min_batch_size: 2, flow_stages: 2]
           ], 2}
        end

      assert {:ok, _worker} = Runner.start_workflow(ctx.runner, :wf, workflow, opts)
      assert :ok = Runner.run(ctx.runner, :wf, 1)

      tasks =
        for _ <- 1..count do
          assert_receive {:started, task}, 1_000
          task
        end

      assert :ok = Runner.cancel(ctx.runner, :wf)
      Enum.each(tasks, fn task -> refute Process.alive?(task) end)
    end
  end

  test "completed native tasks release executor tracking", ctx do
    observer = self()
    workflow = Runic.workflow(steps: [Runic.step(fn n -> n + 1 end, name: :increment)])

    assert {:ok, worker} =
             Runner.start_workflow(ctx.runner, :wf, workflow,
               hooks: [on_idle: fn _ -> send(observer, :idle) end]
             )

    assert :ok = Runner.run(ctx.runner, :wf, 1)
    assert_receive :idle, 1_000
    assert :sys.get_state(worker).executor_state.tasks == %{}
    assert {:ok, [2]} = Runner.get_results(ctx.runner, :wf)
  end

  test "an invalid or dead owner cannot start a Worker", ctx do
    assert {:error, {:invalid_owner, :invalid}} =
             Runner.start_workflow(ctx.runner, :invalid, blocked_workflow(self(), []),
               owner: :invalid
             )

    owner = spawn(fn -> :ok end)
    ref = Process.monitor(owner)
    assert_receive {:DOWN, ^ref, :process, ^owner, _}

    assert {:error, {:owner_not_alive, ^owner}} =
             Runner.start_workflow(ctx.runner, :dead, blocked_workflow(self(), []), owner: owner)

    assert Runner.list_workflows(ctx.runner) == []
  end

  test "an immediate asynchronous work-process crash is contained and retains uncertain work" do
    observer = self()

    workflow =
      Runic.workflow(steps: [Runic.step(fn _ -> Process.exit(self(), :kill) end, name: :killed)])

    caller =
      spawn(fn ->
        Logger.put_process_level(self(), :error)
        result = Workflow.react_until_satisfied(workflow, 1, async: true)
        send(observer, {:returned, Workflow.is_runnable?(result)})
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    assert_receive {:returned, true}, 1_000
  end

  test "cancel can stop an inline Worker that traps exits", ctx do
    {worker, task} = start_blocked(ctx.runner, [], executor: :inline)
    assert task == worker
    ref = Process.monitor(worker)
    assert :ok = Runner.cancel(ctx.runner, :wf)
    refute Process.alive?(worker)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}
  end

  test "task-scope failure cannot leave a Worker waiting for lost results", ctx do
    {worker, task} = start_blocked(ctx.runner, [], owner: self())
    worker_ref = Process.monitor(worker)
    task_ref = Process.monitor(task)
    Process.exit(:sys.get_state(worker).task_scope, :kill)
    assert_receive {:DOWN, ^task_ref, :process, ^task, _}, 1_000
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 1_000
  end

  test "timeout rejects a queued child dispatch after killing its parent", ctx do
    observer = self()

    inner =
      Runic.workflow(
        steps: [
          Runic.step(
            fn input ->
              send(observer, :child_started)
              block(observer, input)
            end,
            name: :inner
          )
        ]
      )
      |> Workflow.set_scheduler_policies([{:inner, %{timeout_ms: 60_000}}])

    outer =
      Runic.workflow(
        steps: [
          Runic.step(
            fn input ->
              send(observer, {:outer_started, self(), Runic.TaskScope.current()})
              receive do: (:nested -> :ok)
              Workflow.react_until_satisfied(inner, input)
            end,
            name: :outer
          )
        ]
      )
      |> Workflow.set_scheduler_policies([{:outer, %{timeout_ms: 150}}])

    assert {:ok, _worker} =
             Runner.start_workflow(ctx.runner, :wf, outer,
               owner: self(),
               hooks: [
                 on_failed: fn _, reason, _ -> send(observer, {:failed, reason}) end,
                 on_idle: fn _ -> send(observer, :idle) end
               ]
             )

    assert :ok = Runner.run(ctx.runner, :wf, 1)
    assert_receive {:outer_started, parent, scope}, 1_000
    parent_ref = Process.monitor(parent)
    :ok = :sys.suspend(scope)
    on_exit(fn -> if Process.alive?(scope), do: :sys.resume(scope) end)

    # Queue cancellation first, then let the still-live parent request its child.
    wait_for_call(scope, :cancel)
    send(parent, :nested)
    wait_for_call(scope, :supervisor)
    :ok = :sys.resume(scope)

    assert_receive {:DOWN, ^parent_ref, :process, ^parent, :killed}, 1_000
    assert_receive {:failed, {:timeout, 150}}, 1_000
    assert_receive :idle, 1_000
    state = :sys.get_state(scope)
    refute Enum.any?(state.tasks, fn {_ref, task} -> task.parent == parent end)
    refute_received :child_started
  end

  for ownership <- [:owned, :background] do
    test "scope failure stops blocked inline work with #{ownership} ownership", ctx do
      observer = self()
      owner = spawn(fn -> receive do: (:finish -> :ok) end)
      owner_ref = Process.monitor(owner)
      on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)

      step =
        Runic.step(
          fn input ->
            send(observer, {:scope, Runic.TaskScope.current()})
            block(observer, input)
          end,
          name: :blocked
        )

      selected_owner = if unquote(ownership) == :owned, do: owner, else: :background

      assert {:ok, worker} =
               Runner.start_workflow(ctx.runner, :wf, Runic.workflow(steps: [step]),
                 executor: :inline,
                 owner: selected_owner
               )

      on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)
      worker_ref = Process.monitor(worker)
      assert :ok = Runner.run(ctx.runner, :wf, 1)
      assert_receive {:scope, scope}, 1_000
      assert_receive {:started, ^worker}, 1_000
      scope_ref = Process.monitor(scope)
      Process.exit(scope, :kill)
      assert_receive {:DOWN, ^scope_ref, :process, ^scope, :killed}, 1_000
      send(owner, :finish)
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}, 1_000
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 1_000
    end
  end

  test "cancel stops inline work even when its scope registration is unavailable", ctx do
    {worker, _task} = start_blocked(ctx.runner, [], executor: :inline, owner: self())
    [{scope, _}] = Registry.lookup(Module.concat(ctx.runner, Registry), {Runic.TaskScope, worker})

    :sys.replace_state(scope, fn state ->
      Registry.unregister(Module.concat(ctx.runner, Registry), {Runic.TaskScope, worker})
      state
    end)

    worker_ref = Process.monitor(worker)
    scope_ref = Process.monitor(scope)
    assert {:error, :ownership_scope_unavailable} = Runner.cancel(ctx.runner, :wf)
    refute Process.alive?(worker)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 1_000
    assert_receive {:DOWN, ^scope_ref, :process, ^scope, :normal}, 1_000
  end

  test "a lost task scope cannot confirm cancellation" do
    {:ok, scope} = Runic.TaskScope.start(owner: self())
    ref = Process.monitor(scope)
    Process.exit(scope, :kill)
    assert_receive {:DOWN, ^ref, :process, ^scope, :killed}
    assert {:error, {:ownership_scope_failed, :noproc}} = Runic.TaskScope.confirm_close(scope)
  end

  defp start_blocked(runner, policy \\ [], opts \\ []) do
    workflow = blocked_workflow(self(), policy)
    assert {:ok, worker} = Runner.start_workflow(runner, :wf, workflow, opts)
    assert :ok = Runner.run(runner, :wf, 1)
    assert_receive {:started, task}, 1_000
    on_exit(fn -> if Process.alive?(task), do: Process.exit(task, :kill) end)
    {worker, task}
  end

  defp wait_for_call(scope, tag, deadline \\ System.monotonic_time(:millisecond) + 1_000) do
    {:messages, messages} = Process.info(scope, :messages)

    queued? =
      Enum.any?(messages, fn
        {:"$gen_call", _from, request} when is_tuple(request) -> elem(request, 0) == tag
        {:"$gen_call", _from, ^tag} -> true
        _ -> false
      end)

    unless queued? do
      assert System.monotonic_time(:millisecond) < deadline, "#{tag} call was not queued"
      :erlang.yield()
      wait_for_call(scope, tag, deadline)
    end
  end

  defp blocked_workflow(observer, policy) do
    step = Runic.step(fn input -> block(observer, input) end, name: :blocked)

    Runic.workflow(steps: [step])
    |> Workflow.set_scheduler_policies([{:blocked, Map.new(policy)}])
  end

  defp block(observer, input) do
    Process.flag(:trap_exit, true)
    send(observer, {:started, self()})
    wait(input)
  end

  defp wait(input) do
    receive do
      {:probe, observer, token} ->
        send(observer, {:alive, token})
        wait(input)

      :release ->
        input
    end
  end
end
