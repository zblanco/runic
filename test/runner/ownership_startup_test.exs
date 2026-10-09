defmodule Runic.Runner.OwnershipStartupTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  require Runic
  alias Runic.{Runner, Workflow}
  alias Runic.TestSupport.TerminationGate

  setup do
    runner = :"ownership_startup_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner})
    %{runner: runner}
  end

  for supervisor_kind <- [:shared, :private],
      terminal <- [:worker_death, :owner_death, :cancel] do
    @tag supervisor_kind: supervisor_kind, terminal: terminal
    test "#{terminal} closes native work while the #{supervisor_kind} supervisor blocks startup",
         ctx do
      observer = self()
      owner = spawn(fn -> receive do: (:finish -> :ok) end)
      on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
      first = Runic.step(fn n -> block(observer, n) + 1 end, name: :first)
      second = Runic.step(fn n -> block(observer, n) + 2 end, name: :second)
      workflow = Runic.workflow(steps: [first, second])

      workflow =
        if ctx.supervisor_kind == :private,
          do: Workflow.set_scheduler_policies(workflow, [{:default, %{timeout_ms: 60_000}}]),
          else: workflow

      hook = fn _, _ ->
        count = Process.get(:startup_test_dispatches, 0)
        Process.put(:startup_test_dispatches, count + 1)

        if count == 1 do
          send(observer, {:admission_held, self()})
          receive do: (:continue -> :ok)
        end
      end

      assert {:ok, worker} =
               Runner.start_workflow(ctx.runner, :wf, workflow,
                 owner: owner,
                 max_concurrency: 2,
                 hooks: [on_dispatch: hook]
               )

      scope = :sys.get_state(worker).task_scope
      worker_ref = Process.monitor(worker)
      scope_ref = Process.monitor(scope)
      assert :ok = Runner.run(ctx.runner, :wf, 1)
      assert_receive {:started, task}, 1_000
      assert_receive {:admission_held, ^worker}, 1_000
      task_ref = Process.monitor(task)

      supervisor =
        if ctx.supervisor_kind == :shared,
          do: Process.whereis(Module.concat(ctx.runner, TaskSupervisor)),
          else: :sys.get_state(scope).supervisor

      supervisor_ref = Process.monitor(supervisor)
      :ok = :sys.suspend(supervisor)

      on_exit(fn ->
        if Process.alive?(supervisor), do: :sys.resume(supervisor)
        if Process.alive?(worker), do: Process.exit(worker, :kill)
      end)

      send(worker, :continue)
      wait_for_start(supervisor)

      case ctx.terminal do
        :worker_death ->
          Process.exit(worker, :kill)

        :owner_death ->
          send(owner, :finish)

        :cancel ->
          canceler = spawn(fn -> send(observer, {:cancelled, Runner.cancel(ctx.runner, :wf)}) end)
          on_exit(fn -> if Process.alive?(canceler), do: Process.exit(canceler, :kill) end)
      end

      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 1_000
      assert_receive {:DOWN, ^task_ref, :process, ^task, _}, 1_000
      assert_receive {:DOWN, ^scope_ref, :process, ^scope, :normal}, 1_000
      if ctx.terminal == :cancel, do: assert_receive({:cancelled, :ok}, 1_000)
      assert Runner.lookup(ctx.runner, :wf) == nil

      if ctx.supervisor_kind == :shared do
        assert Process.alive?(supervisor)
        :ok = :sys.resume(supervisor)
        # Drain the queued startup and confirm that its child cannot run user code.
        for {_id, child, _type, _modules} <- DynamicSupervisor.which_children(supervisor) do
          ref = Process.monitor(child)
          assert_receive {:DOWN, ^ref, :process, ^child, _}, 1_000
        end
      else
        assert_receive {:DOWN, ^supervisor_ref, :process, ^supervisor, _}, 1_000
      end

      refute_received {:started, _late_child}
    end
  end

  test "cancel reports a replacement Worker after losing the original child", ctx do
    workflow = Runic.workflow(steps: [Runic.step(fn n -> n + 1 end, name: :increment)])
    assert {:ok, original} = Runner.start_workflow(ctx.runner, :wf, workflow)
    name = Module.concat(ctx.runner, WorkerSupervisor)
    supervisor = Process.whereis(name)
    true = Process.unregister(name)

    gate =
      start_supervised!({TerminationGate, name: name, supervisor: supervisor, observer: self()})

    on_exit(fn ->
      if Process.whereis(name) == gate, do: Process.unregister(name)

      if Process.alive?(supervisor) and Process.whereis(name) == nil,
        do: Process.register(supervisor, name)
    end)

    :ok = :sys.suspend(original)
    on_exit(fn -> if Process.alive?(original), do: :sys.resume(original) end)
    canceler = Task.async(fn -> Runner.cancel(ctx.runner, :wf) end)
    assert_receive {:termination_held, from, ^original}, 1_000
    ref = Process.monitor(original)
    Process.exit(original, :kill)
    assert_receive {:DOWN, ^ref, :process, ^original, :killed}, 1_000
    replacement = wait_for_replacement(ctx.runner, original)
    # Check initialized state, not only its early Registry registration.
    assert :sys.get_state(replacement).id == :wf
    assert {:error, :not_found} = result = DynamicSupervisor.terminate_child(supervisor, original)
    GenServer.reply(from, result)

    assert {:error, :worker_replaced} = Task.await(canceler)
    assert Runner.lookup(ctx.runner, :wf) == replacement
    assert Process.alive?(replacement)
    assert :ok = Runner.cancel(ctx.runner, :wf)
    assert Runner.lookup(ctx.runner, :wf) == nil
  end

  test "a child waiting for admission exits when its requester dies" do
    supervisor = start_supervised!(Task.Supervisor)
    {:ok, scope} = Runic.TaskScope.start(owner: self())
    observer = self()
    :ok = :sys.suspend(scope)
    on_exit(fn -> if Process.alive?(scope), do: :sys.resume(scope) end)

    requester =
      spawn(fn ->
        Runic.TaskScope.dispatch(scope, fn -> send(observer, :unexpected_work) end, supervisor)
      end)

    on_exit(fn -> if Process.alive?(requester), do: Process.exit(requester, :kill) end)
    child = wait_for_admission(scope, requester)
    child_ref = Process.monitor(child)
    requester_ref = Process.monitor(requester)
    Process.exit(requester, :kill)

    assert_receive {:DOWN, ^requester_ref, :process, ^requester, :killed}, 1_000
    assert_receive {:DOWN, ^child_ref, :process, ^child, _}, 1_000
    :ok = :sys.resume(scope)
    assert :sys.get_state(scope).tasks == %{}
    refute_received :unexpected_work
    assert :ok = Runic.TaskScope.confirm_close(scope)
  end

  test "queued admission cannot start a child after parent cancellation" do
    supervisor = start_supervised!(Task.Supervisor)
    {:ok, scope} = Runic.TaskScope.start(owner: self())
    observer = self()

    {handle, parent} =
      Runic.TaskScope.dispatch(
        scope,
        fn ->
          send(observer, :parent_ready)
          receive do: (:nested -> :ok)
          Runic.TaskScope.dispatch(scope, fn -> send(observer, :unexpected_work) end, supervisor)
        end,
        supervisor
      )

    assert_receive :parent_ready, 1_000
    parent_ref = Process.monitor(parent)
    :ok = :sys.suspend(scope)
    on_exit(fn -> if Process.alive?(scope), do: :sys.resume(scope) end)

    canceler =
      spawn(fn ->
        send(observer, {:parent_cancelled, GenServer.call(scope, {:cancel, handle}, :infinity)})
      end)

    on_exit(fn -> if Process.alive?(canceler), do: Process.exit(canceler, :kill) end)
    wait_for_request(scope, :cancel)
    send(parent, :nested)
    child = wait_for_admission(scope, parent)
    child_ref = Process.monitor(child)
    :ok = :sys.resume(scope)

    assert_receive {:parent_cancelled, :ok}, 1_000
    assert_receive {:DOWN, ^parent_ref, :process, ^parent, :killed}, 1_000
    assert_receive {:DOWN, ^child_ref, :process, ^child, _}, 1_000
    assert :sys.get_state(scope).tasks == %{}
    refute_received :unexpected_work
    assert :ok = Runic.TaskScope.confirm_close(scope)
  end

  defp block(observer, n) do
    Process.flag(:trap_exit, true)
    send(observer, {:started, self()})
    receive do: (:release -> n)
  end

  defp wait_for_start(supervisor, deadline \\ System.monotonic_time(:millisecond) + 1_000) do
    {:messages, messages} = Process.info(supervisor, :messages)

    if Enum.any?(messages, fn
         {:"$gen_call", _from, {:start_task, _args, _restart, _shutdown}} -> true
         _ -> false
       end) do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline, "no startup request was queued"
      :erlang.yield()
      wait_for_start(supervisor, deadline)
    end
  end

  defp wait_for_replacement(
         runner,
         original,
         deadline \\ System.monotonic_time(:millisecond) + 1_000
       ) do
    case Runner.lookup(runner, :wf) do
      pid when is_pid(pid) and pid != original ->
        pid

      _ ->
        assert System.monotonic_time(:millisecond) < deadline, "Worker did not restart"
        :erlang.yield()
        wait_for_replacement(runner, original, deadline)
    end
  end

  defp wait_for_admission(
         scope,
         requester,
         deadline \\ System.monotonic_time(:millisecond) + 1_000
       ) do
    {:messages, messages} = Process.info(scope, :messages)

    case Enum.find(messages, fn
           {:"$gen_call", {^requester, _ref}, {:admit, _pid, _handle}} -> true
           _ -> false
         end) do
      {:"$gen_call", _from, {:admit, pid, _handle}} ->
        pid

      nil ->
        assert System.monotonic_time(:millisecond) < deadline, "no admission was queued"
        :erlang.yield()
        wait_for_admission(scope, requester, deadline)
    end
  end

  defp wait_for_request(scope, tag, deadline \\ System.monotonic_time(:millisecond) + 1_000) do
    {:messages, messages} = Process.info(scope, :messages)

    unless Enum.any?(messages, fn
             {:"$gen_call", _from, request} when is_tuple(request) -> elem(request, 0) == tag
             _ -> false
           end) do
      assert System.monotonic_time(:millisecond) < deadline, "#{tag} was not queued"
      :erlang.yield()
      wait_for_request(scope, tag, deadline)
    end
  end
end
