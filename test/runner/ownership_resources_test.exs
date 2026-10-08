defmodule Runic.Runner.OwnershipResourcesTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  require Runic
  alias Runic.{Runner, Workflow}

  setup do
    runner = :"ownership_resources_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner})
    %{runner: runner}
  end

  for terminal <- [:success, :normal_exit, :timeout, :cancel] do
    @tag terminal: terminal
    test "#{terminal} releases native tasks, guards, and private supervisors",
         %{terminal: terminal} = ctx do
      observer = self()

      step =
        Runic.step(
          fn input ->
            Process.flag(:trap_exit, true)
            send(observer, {:started, self()})

            receive do
              :release ->
                if input == :normal_exit do
                  Process.flag(:trap_exit, false)
                  Process.exit(self(), :normal)
                end

                1
            end
          end,
          name: :blocked
        )

      timeout = if terminal == :timeout, do: 150, else: 60_000

      workflow =
        Runic.workflow(steps: [step])
        |> Workflow.set_scheduler_policies([{:blocked, %{timeout_ms: timeout}}])

      assert {:ok, worker} =
               Runner.start_workflow(ctx.runner, :wf, workflow,
                 owner: self(),
                 hooks: [on_idle: fn _ -> send(observer, :idle) end]
               )

      scope = :sys.get_state(worker).task_scope
      {:monitored_by, observers} = Process.info(scope, :monitored_by)
      owner_guards = observers -- [worker]
      assert length(owner_guards) == 1
      supervisor = Process.whereis(Module.concat(ctx.runner, TaskSupervisor))
      roots = [scope, supervisor]
      for pid <- roots, do: :erlang.trace(pid, true, [:procs, :set_on_spawn, {:tracer, self()}])

      on_exit(fn ->
        for pid <- roots, Process.alive?(pid), do: :erlang.trace(pid, false, [:all])
      end)

      assert :ok = Runner.run(ctx.runner, :wf, terminal)
      assert_receive {:started, task}, 1_000
      private_supervisor = :sys.get_state(scope).supervisor
      assert is_pid(private_supervisor)
      task_ref = Process.monitor(task)

      case terminal do
        :cancel ->
          assert :ok = Runner.cancel(ctx.runner, :wf)

        terminal ->
          if terminal in [:success, :normal_exit], do: send(task, :release)
          assert_receive :idle, 2_000
          assert {:ok, result} = Runner.get_workflow(ctx.runner, :wf)
          refute Workflow.is_runnable?(result)
          assert Workflow.raw_productions(result) == if(terminal == :success, do: [1], else: [])
          assert :ok = Runner.stop(ctx.runner, :wf, persist: false)
      end

      assert_receive {:DOWN, ^task_ref, :process, ^task, _}, 1_000
      refute Process.alive?(worker)
      refute Process.alive?(scope)
      :erlang.trace(supervisor, false, [:all])
      marker = :erlang.trace_delivered(:all)
      children = trace_spawns(marker, []) |> Enum.uniq()
      assert task in children
      assert private_supervisor in children

      # The test owner is still alive: task/scope completion must release helpers.
      for pid <- children ++ owner_guards do
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
      end

      await_empty(supervisor)
    end
  end

  test "cancellation does not treat a shared I/O group as ownership", ctx do
    observer = self()

    step =
      Runic.step(
        fn input ->
          Process.flag(:trap_exit, true)

          detached =
            spawn(fn ->
              Process.flag(:trap_exit, true)

              receive do
                {:probe, caller, token} -> send(caller, {:detached_alive, token})
              end
            end)

          send(observer, {:started, self(), detached})
          receive do: (:release -> input)
        end,
        name: :blocked
      )

    assert {:ok, _worker} =
             Runner.start_workflow(ctx.runner, :wf, Runic.workflow(steps: [step]), owner: self())

    assert :ok = Runner.run(ctx.runner, :wf, 1)
    assert_receive {:started, task, detached}, 1_000
    on_exit(fn -> if Process.alive?(detached), do: Process.exit(detached, :kill) end)
    assert Process.info(task, :group_leader) == Process.info(detached, :group_leader)
    detached_ref = Process.monitor(detached)

    assert :ok = Runner.cancel(ctx.runner, :wf)
    refute Process.alive?(task)
    token = make_ref()
    send(detached, {:probe, self(), token})
    assert_receive {:detached_alive, ^token}, 1_000
    assert_receive {:DOWN, ^detached_ref, :process, ^detached, :normal}, 1_000
  end

  defp trace_spawns(marker, children) do
    receive do
      {:trace_delivered, :all, ^marker} -> children
      {:trace, _parent, :spawn, child, _mfa} -> trace_spawns(marker, [child | children])
      {:trace, _pid, _event, _info} -> trace_spawns(marker, children)
      {:trace, _pid, _event, _info, _other} -> trace_spawns(marker, children)
    after
      1_000 -> flunk("trace delivery barrier was not received")
    end
  end

  defp await_empty(supervisor, deadline \\ System.monotonic_time(:millisecond) + 1_000) do
    unless Task.Supervisor.children(supervisor) == [] do
      assert System.monotonic_time(:millisecond) < deadline, "supervisor still owns tasks"
      await_empty(supervisor, deadline)
    end
  end
end
