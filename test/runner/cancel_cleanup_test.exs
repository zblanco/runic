defmodule Runic.Runner.CancelCleanupTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  require Runic
  alias Runic.{Runner, Workflow}
  alias Runic.TestSupport.{FailingStore, ResourceExecutor}

  setup do
    store = start_supervised!(FailingStore)
    pools = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    runner = :"cancel_cleanup_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner, store: FailingStore, store_opts: [agent: store]})
    %{runner: runner, store: store, pools: pools}
  end

  for mode <- [:default, :override, :mixed], ownership <- [:owned, :background] do
    @tag mode: mode, ownership: ownership
    test "cancel cleans #{mode} #{ownership} custom resources exactly once without persistence",
         ctx do
      owner = if ctx.ownership == :owned, do: self(), else: :background
      {worker, labels} = start_execution(ctx, ctx.mode, :ok, owner)
      resources = collect_pools(labels)
      assert_receive :idle, 1_000
      assert {:ok, [2]} = Runner.get_results(ctx.runner, :wf)
      assert Process.info(worker, :trap_exit) == {:trap_exit, false}
      FailingStore.fail(ctx.store, :append)
      calls = FailingStore.data(ctx.store).calls
      worker_ref = Process.monitor(worker)

      assert :ok = Runner.cancel(ctx.runner, :wf)
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 1_000

      for {label, pool, ref} <- resources do
        assert_receive {:cleanup_started, ^label, ^worker}, 1_000
        assert_receive {:cleanup_finished, ^label}, 1_000
        assert_receive {:DOWN, ^ref, :process, ^pool, _}, 1_000
        refute Process.alive?(pool)
      end

      # Callback notifications precede the Worker DOWN from the same sender.
      refute_received {:cleanup_started, _, _}
      refute_received {:cleanup_finished, _}
      assert FailingStore.data(ctx.store).calls == calls
      assert Runner.lookup(ctx.runner, :wf) == nil
    end
  end

  test "custom cleanup stops active pool work that traps exits", ctx do
    observer = self()

    step =
      Runic.step(
        fn input ->
          Process.flag(:trap_exit, true)
          send(observer, {:pool_work_started, self()})
          receive do: (:release -> input)
        end,
        name: :blocked
      )

    assert {:ok, worker} =
             Runner.start_workflow(ctx.runner, :wf, Runic.workflow(steps: [step]),
               owner: self(),
               executor: ResourceExecutor,
               executor_opts: resource_opts(ctx, :active)
             )

    [{:active, pool, pool_ref}] = collect_pools([:active])
    assert :ok = Runner.run(ctx.runner, :wf, 1)
    assert_receive {:pool_work_started, ^pool}, 1_000
    [task] = Map.values(:sys.get_state(worker).executor_state.tasks)
    task_ref = Process.monitor(task)
    worker_ref = Process.monitor(worker)

    assert :ok = Runner.cancel(ctx.runner, :wf)
    assert_receive {:cleanup_started, :active, ^worker}, 1_000
    assert_receive {:cleanup_finished, :active}, 1_000
    assert_receive {:DOWN, ^pool_ref, :process, ^pool, _}, 1_000
    assert_receive {:DOWN, ^task_ref, :process, ^task, _}, 1_000
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 1_000
    refute_received {:cleanup_started, _, _}
  end

  for failure <- [:raise, :throw] do
    @tag cleanup_failure: failure
    test "cancel contains cleanup #{failure} and still cleans overrides", ctx do
      {worker, labels} = start_execution(ctx, :mixed, ctx.cleanup_failure, self())
      resources = collect_pools(labels)
      assert_receive :idle, 1_000
      worker_ref = Process.monitor(worker)

      assert :ok = Runner.cancel(ctx.runner, :wf)
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 1_000

      for {label, pool, ref} <- resources do
        assert_receive {:cleanup_started, ^label, ^worker}, 1_000
        assert_receive {:DOWN, ^ref, :process, ^pool, _}, 1_000
      end

      assert_receive {:cleanup_finished, :override}, 1_000
      refute_received {:cleanup_finished, :default}
      refute_received {:cleanup_started, _, _}
    end
  end

  test "blocked cleanup cannot prevent native shutdown and forced Worker cancellation", ctx do
    observer = self()

    step =
      Runic.step(
        fn input ->
          Process.flag(:trap_exit, true)
          send(observer, {:native_started, self()})
          receive do: (:release -> input)
        end,
        name: :blocked
      )

    workflow =
      Runic.workflow(steps: [step])
      |> Workflow.set_scheduler_policies([{:blocked, %{executor: Runic.Runner.Executor.Task}}])

    assert {:ok, worker} =
             Runner.start_workflow(ctx.runner, :wf, workflow,
               owner: self(),
               executor: ResourceExecutor,
               executor_opts: resource_opts(ctx, :default, :block)
             )

    [{:default, pool, _pool_ref}] = collect_pools([:default])
    scope = :sys.get_state(worker).task_scope
    scope_ref = Process.monitor(scope)
    worker_ref = Process.monitor(worker)
    assert :ok = Runner.run(ctx.runner, :wf, 1)
    assert_receive {:native_started, task}, 1_000
    task_ref = Process.monitor(task)
    calls = FailingStore.data(ctx.store).calls

    canceler = Task.async(fn -> Runner.cancel(ctx.runner, :wf) end)
    assert_receive {:cleanup_started, :default, ^worker}, 1_000
    assert_receive {:DOWN, ^task_ref, :process, ^task, _}, 1_000
    assert_receive {:DOWN, ^scope_ref, :process, ^scope, :normal}, 1_000
    assert :ok = Task.await(canceler, 2_000)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :shutdown}, 1_000
    refute_received {:cleanup_finished, :default}
    refute_received {:cleanup_started, _, _}
    assert Process.alive?(pool)
    assert FailingStore.data(ctx.store).calls == calls
    assert Runner.lookup(ctx.runner, :wf) == nil
  end

  test "cancellation does not initialize an unused executor override", ctx do
    workflow =
      single()
      |> Workflow.set_scheduler_policies([
        {:increment, %{executor: ResourceExecutor, executor_opts: resource_opts(ctx, :unused)}}
      ])

    assert {:ok, worker} = Runner.start_workflow(ctx.runner, :wf, workflow, owner: self())
    ref = Process.monitor(worker)
    assert :ok = Runner.cancel(ctx.runner, :wf)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 1_000
    refute_received {:pool_started, _, _}
    refute_received {:cleanup_started, _, _}
  end

  defp start_execution(ctx, mode, cleanup, owner) do
    workflow = single()

    workflow =
      if mode in [:override, :mixed] do
        Workflow.set_scheduler_policies(workflow, [
          {:increment,
           %{executor: ResourceExecutor, executor_opts: resource_opts(ctx, :override)}}
        ])
      else
        workflow
      end

    opts =
      if mode in [:default, :mixed],
        do: [executor: ResourceExecutor, executor_opts: resource_opts(ctx, :default, cleanup)],
        else: [executor: :inline]

    observer = self()

    assert {:ok, worker} =
             Runner.start_workflow(
               ctx.runner,
               :wf,
               workflow,
               [owner: owner, hooks: [on_idle: fn _ -> send(observer, :idle) end]] ++ opts
             )

    assert :ok = Runner.run(ctx.runner, :wf, 1)

    labels =
      case mode do
        :default -> [:default]
        :override -> [:override]
        :mixed -> [:default, :override]
      end

    {worker, labels}
  end

  defp collect_pools(labels) do
    for label <- labels do
      assert_receive {:pool_started, ^label, pool}, 1_000
      {label, pool, Process.monitor(pool)}
    end
  end

  defp resource_opts(ctx, label, cleanup \\ :ok),
    do: [observer: self(), pool_supervisor: ctx.pools, label: label, cleanup: cleanup]

  defp single, do: Runic.workflow(steps: [Runic.step(fn n -> n + 1 end, name: :increment)])
end
