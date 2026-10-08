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
           [scheduler: Runic.Runner.Scheduler.FlowBatch, scheduler_opts: [min_batch_size: 2]], 2}
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

  test "an immediate asynchronous work-process crash is contained and consumes its activation" do
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
    assert_receive {:returned, false}, 1_000
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
