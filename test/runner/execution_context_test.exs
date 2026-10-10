defmodule Runic.Runner.ExecutionContextTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  require Runic
  alias Runic.{Runner, Workflow}

  setup do
    runner = :"execution_context_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner})
    # StringIO monitors the test process and closes when it exits.
    {:ok, first_io} = StringIO.open("")
    {:ok, second_io} = StringIO.open("")
    %{runner: runner, first_io: first_io, second_io: second_io}
  end

  for mode <- [:sync, :timed, :async, :async_timed] do
    test "immediate #{mode} work keeps caller I/O, caller chain, and Logger metadata", ctx do
      observer = self()
      token = make_ref()
      workflow = Runic.workflow(steps: [probe_step(observer, token)])

      {caller, ref} =
        spawn_monitor(fn ->
          install_context(ctx.first_io, observer, token)
          before = context()
          result = Workflow.react_until_satisfied(workflow, 1, options(unquote(mode)))
          send(observer, {token, :returned, Workflow.raw_productions(result), before, context()})
        end)

      on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
      assert_receive {^token, :work, 1, work_context}, 1_000
      assert_receive {^token, :returned, [1], before, after_context}, 1_000
      assert_receive {:DOWN, ^ref, :process, ^caller, :normal}, 1_000

      assert_context(work_context, ctx.first_io, observer, token)

      if unquote(mode) != :sync do
        assert caller in work_context.callers
        assert work_context.private == nil
      end

      assert after_context == before
      assert elem(StringIO.contents(ctx.first_io), 1) == "1\n"
      assert elem(StringIO.contents(ctx.second_io), 1) == ""
    end
  end

  for mode <- [:timed, :async, :async_timed] do
    test "nested #{mode} work uses current context while reusing a managed scope", ctx do
      observer = self()
      token = make_ref()
      inner = Runic.workflow(steps: [probe_step(observer, token)])

      outer =
        Runic.step(
          fn input ->
            send(observer, {token, :outer, self(), Runic.TaskScope.current()})

            for {device, index} <- [{ctx.first_io, 1}, {ctx.second_io, 2}] do
              install_context(device, observer, {token, index})
              Workflow.react_until_satisfied(inner, index, options(unquote(mode)))
            end

            input
          end,
          name: :outer
        )

      assert {:ok, worker} = start_workflow(ctx.runner, :nested, [outer], observer, token)
      assert :ok = Runner.run(ctx.runner, :nested, 42)
      assert_receive {^token, :outer, outer_pid, scope}, 1_000
      assert_receive {^token, :work, 1, first}, 1_000
      assert_receive {^token, :work, 2, second}, 1_000
      assert_receive {^token, :idle}, 1_000

      for {work_context, device, index} <- [{first, ctx.first_io, 1}, {second, ctx.second_io, 2}] do
        assert_context(work_context, device, observer, {token, index})
        assert outer_pid in work_context.callers
        assert work_context.scope == scope
        assert work_context.private == nil
      end

      assert {:ok, [42]} = Runner.get_results(ctx.runner, :nested)
      assert elem(StringIO.contents(ctx.first_io), 1) == "1\n"
      assert elem(StringIO.contents(ctx.second_io), 1) == "2\n"
      supervisor = :sys.get_state(scope).supervisor
      assert Process.info(supervisor, :group_leader) == Process.info(scope, :group_leader)
      assert :ok = Runner.stop(ctx.runner, :nested, persist: false)
      refute Process.alive?(worker)
    end
  end

  test "concurrent Workers route I/O separately through a shared Task Supervisor", ctx do
    observer = self()
    token = make_ref()
    supervisor = Module.concat(ctx.runner, TaskSupervisor)
    original_group = Process.info(Process.whereis(supervisor), :group_leader)

    workers =
      for {id, device} <- [{:first, ctx.first_io}, {:second, ctx.second_io}] do
        step =
          Runic.step(
            fn input ->
              send(observer, {token, :held, id, self()})
              receive do: (:release -> :ok)
              IO.puts(Atom.to_string(id))
              send(observer, {token, :context, id, context()})
              input
            end,
            name: :probe
          )

        assert {:ok, worker} =
                 start_workflow(ctx.runner, id, [step], observer, {token, id},
                   on_dispatch: fn _, _ -> install_context(device, observer, {token, id}) end
                 )

        assert :ok = Runner.run(ctx.runner, id, 1)
        assert_receive {^token, :held, ^id, task}, 1_000
        {id, worker, task, device}
      end

    for {_id, _worker, task, _device} <- workers, do: send(task, :release)

    for {id, worker, _task, device} <- workers do
      assert_receive {^token, :context, ^id, work_context}, 1_000
      assert_receive {{^token, ^id}, :idle}, 1_000
      assert_context(work_context, device, observer, {token, id})
      assert worker in work_context.callers
      assert work_context.private == nil
      assert elem(StringIO.contents(device), 1) == "#{id}\n"
      assert :ok = Runner.stop(ctx.runner, id, persist: false)
    end

    assert Process.info(Process.whereis(supervisor), :group_leader) == original_group
  end

  test "a Task executor override keeps the inline Worker's dispatch context", ctx do
    observer = self()
    token = make_ref()

    workflow =
      Runic.workflow(steps: [probe_step(observer, token)])
      |> Workflow.set_scheduler_policies([{:probe, %{executor: Runic.Runner.Executor.Task}}])

    assert {:ok, worker} =
             Runner.start_workflow(ctx.runner, :override, workflow,
               executor: :inline,
               owner: self(),
               hooks: [
                 on_dispatch: fn _, _ -> install_context(ctx.first_io, observer, token) end,
                 on_idle: fn _ -> send(observer, {token, :idle}) end
               ]
             )

    assert :ok = Runner.run(ctx.runner, :override, 1)
    assert_receive {^token, :work, 1, work_context}, 1_000
    assert_receive {^token, :idle}, 1_000
    assert_context(work_context, ctx.first_io, observer, token)
    assert worker in work_context.callers
    assert elem(StringIO.contents(ctx.first_io), 1) == "1\n"
  end

  for executor <- [:inline, Runic.Runner.Executor.Task], timeout <- [:infinity, 60_000] do
    test "parallel Promise preserves and resets context with #{executor}, timeout #{timeout}",
         ctx do
      observer = self()
      token = make_ref()

      steps =
        for index <- 1..3 do
          Runic.step(
            fn input ->
              value = ^index
              IO.puts(Integer.to_string(value))
              send(observer, {token, :stage, value, context()})
              # Flow reuses a stage: one runnable must not alter the next one's context.
              Process.group_leader(self(), ctx.second_io)
              Process.put(:"$callers", [self()])
              Logger.reset_metadata(leaked: true)
              input + value
            end,
            name: Enum.at([:first, :second, :third], index - 1)
          )
        end

      workflow =
        Runic.workflow(steps: steps)
        |> Workflow.set_scheduler_policies([{:default, %{timeout_ms: unquote(timeout)}}])

      assert {:ok, worker} =
               Runner.start_workflow(ctx.runner, :parallel, workflow,
                 owner: self(),
                 executor: unquote(executor),
                 scheduler: Runic.Runner.Scheduler.FlowBatch,
                 scheduler_opts: [min_batch_size: 2, flow_stages: 1, flow_max_demand: 1],
                 hooks: [
                   on_dispatch: fn _, _ -> install_context(ctx.first_io, observer, token) end,
                   on_failed: fn _, reason, _ -> send(observer, {token, :failed, reason}) end,
                   on_idle: fn _ -> send(observer, {token, :idle}) end
                 ]
               )

      assert :ok = Runner.run(ctx.runner, :parallel, 10)

      # Stage messages are sent before the Promise reply and Worker completion.
      # Inspect them after that barrier instead of timing each stage separately.
      assert_receive {^token, :idle}, 5_000
      refute_received {^token, :failed, _}

      stages =
        for _ <- 1..3 do
          assert_received {^token, :stage, index, work_context}
          {index, work_context}
        end

      assert Enum.sort(Enum.map(stages, &elem(&1, 0))) == [1, 2, 3]
      refute_received {^token, :stage, _, _}
      contexts = Enum.map(stages, &elem(&1, 1))

      for work_context <- contexts do
        assert_context(work_context, ctx.first_io, observer, token)
        assert worker in work_context.callers
        assert work_context.private == nil
      end

      if unquote(timeout) == :infinity, do: assert(length(Enum.uniq_by(contexts, & &1.pid)) == 1)
      assert {:ok, results} = Runner.get_results(ctx.runner, :parallel)
      assert Enum.sort(results) == [11, 12, 13]

      assert String.split(elem(StringIO.contents(ctx.first_io), 1)) |> Enum.sort() == [
               "1",
               "2",
               "3"
             ]

      assert elem(StringIO.contents(ctx.second_io), 1) == ""
    end
  end

  for kind <- [:error, :throw, :exit] do
    @tag failure_kind: kind
    test "a reused process restores execution context after #{kind}",
         %{failure_kind: kind} = ctx do
      before = context()
      flags = Process.info(self(), :trap_exit)
      captured = Runic.TaskScope.capture_context()

      captured = %{
        captured
        | group_leader: ctx.first_io,
          logger_metadata: [request_id: :temporary]
      }

      failure =
        try do
          Runic.TaskScope.within_context(captured, fn ->
            IO.puts("captured")
            assert Process.group_leader() == ctx.first_io
            assert Logger.metadata() == [request_id: :temporary]
            Process.group_leader(self(), ctx.second_io)
            Process.put(:"$callers", [:changed])
            Logger.reset_metadata(changed: true)
            :erlang.raise(kind, :expected_failure, [])
          end)
        catch
          failure_kind, reason -> {failure_kind, reason}
        end

      assert failure == {kind, :expected_failure}
      assert context() == before
      assert Process.info(self(), :trap_exit) == flags
      assert elem(StringIO.contents(ctx.first_io), 1) == "captured\n"
      assert elem(StringIO.contents(ctx.second_io), 1) == ""
    end
  end

  defp probe_step(observer, token) do
    Runic.step(
      fn input ->
        IO.puts(Integer.to_string(input))
        send(observer, {token, :work, input, context()})
        input
      end,
      name: :probe
    )
  end

  defp start_workflow(runner, id, steps, observer, token, hooks \\ []) do
    Runner.start_workflow(runner, id, Runic.workflow(steps: steps),
      owner: self(),
      hooks: Keyword.put(hooks, :on_idle, fn _ -> send(observer, {token, :idle}) end)
    )
  end

  defp install_context(device, caller, request) do
    Process.group_leader(self(), device)
    Process.put(:"$callers", [caller])
    Process.put(:private_execution_context_test, request)
    Logger.reset_metadata(request_id: request)
  end

  defp context do
    %{
      pid: self(),
      group_leader: Process.group_leader(),
      callers: Process.get(:"$callers", []),
      metadata: Logger.metadata(),
      private: Process.get(:private_execution_context_test),
      scope: Runic.TaskScope.current()
    }
  end

  defp assert_context(context, device, caller, request) do
    assert context.group_leader == device
    assert caller in context.callers
    assert context.metadata == [request_id: request]
  end

  defp options(:sync), do: []
  defp options(:timed), do: [scheduler_policies: [{:probe, %{timeout_ms: 60_000}}]]
  defp options(:async), do: [async: true]
  defp options(:async_timed), do: [async: true] ++ options(:timed)
end
