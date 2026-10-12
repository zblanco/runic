defmodule Runic.Runner.FailureAdmissionEdgesTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  require Runic
  alias Runic.{Runner, Workflow}

  alias Runic.TestSupport.{
    AdmissionScheduler,
    FailureBatchScheduler,
    FailingStore,
    ReleasingExecutor
  }

  setup do
    runner = :"failure_edges_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner})
    %{runner: runner}
  end

  test "old replies after continuation cannot consume the new handle for the same activation",
       ctx do
    observer = self()
    counts = :atomics.new(1, [])

    step =
      Runic.step(
        fn n ->
          :atomics.add(counts, 1, 1)
          n + 1
        end,
        name: :first
      )

    workflow = Runic.workflow(steps: [step])

    assert {:ok, worker} =
             Runner.start_workflow(ctx.runner, :stale, workflow,
               scheduler: AdmissionScheduler,
               scheduler_opts: [owner: observer],
               executor: ReleasingExecutor,
               executor_opts: [test_pid: observer, outcome: :deferred],
               hooks: [on_complete: fn _, _, _ -> send(observer, :applied) end]
             )

    assert :ok = Runner.run(ctx.runner, :stale, 1)
    assert_receive {:admitted, activation}, 2_000
    assert_receive {:executor_result, ^worker, old_handle, old_result}, 2_000
    send(worker, {:DOWN, old_handle, :process, self(), :lost})

    assert {:ok, %{status: :stopped, active_units: 0}} =
             Runner.admission_status(ctx.runner, :stale)

    assert_receive {:executor_released, ^old_handle}, 2_000
    assert_receive {:admission_completed, ^activation, true}, 2_000

    assert :ok = Runner.continue(ctx.runner, :stale)
    assert_receive {:admitted, ^activation}, 2_000
    assert_receive {:executor_result, ^worker, new_handle, new_result}, 2_000
    assert old_handle != new_handle

    assert {:ok, %{status: :open, active_units: 1, causes: []}} =
             Runner.admission_status(ctx.runner, :stale)

    before = :sys.get_state(worker)
    send(worker, {old_handle, old_result})
    send(worker, {:DOWN, old_handle, :process, self(), :late})
    assert :sys.get_state(worker) == before
    refute_received :applied
    refute_received {:executor_released, _}
    refute_received {:admission_completed, _, _}

    send(worker, {new_handle, new_result})
    assert {:ok, [2]} = Runner.get_results(ctx.runner, :stale)
    assert {:ok, %{status: :open, active_units: 0}} = Runner.admission_status(ctx.runner, :stale)
    assert_receive :applied, 2_000
    assert_receive {:executor_released, ^new_handle}, 2_000
    assert_receive {:admission_completed, ^activation, true}, 2_000
    assert :atomics.get(counts, 1) == 2
  end

  for cut <- [:before_a, :during_b, :after_computation] do
    test "native Promise loss #{cut} exposes uncertainty and explicit repetition", ctx do
      observer = self()
      counts = :atomics.new(3, [])
      a = gated_step(1, :a)
      b = gated_step(2, :b)
      c = gated_step(3, :c)

      workflow =
        Runic.workflow(steps: [{a, [{b, [c]}]}])
        |> Workflow.set_scheduler_policies([{:default, %{execution_mode: :durable}}])
        |> Workflow.attach_after_hook(:c, fn _, wf, _ ->
          # The Promise applies locally before the Worker applies its reply.
          # Hold only the native executor, not the later accepted application.
          if self() != Runner.lookup(ctx.runner, :live) do
            send(observer, {:computed_before_reply, self()})
            receive do: (:reply -> :ok)
          end

          wf
        end)

      assert {:ok, worker} =
               Runner.start_workflow(ctx.runner, :live, workflow,
                 owner: observer,
                 promise_opts: [min_chain_length: 2],
                 on_complete: fn _, _ -> send(observer, :drained) end
               )

      scope = :sys.get_state(worker).task_scope
      if unquote(cut) == :before_a, do: :sys.suspend(scope)
      on_exit(fn -> if Process.alive?(scope), do: :sys.resume(scope) end)

      assert :ok =
               Runner.run(ctx.runner, :live, 1,
                 run_context: %{_global: %{counts: counts, observer: observer}}
               )

      {lost, expected} =
        case unquote(cut) do
          :before_a ->
            {_, _, {:admit, pid, _}} = wait_for_admission(scope)
            {pid, [0, 0, 0]}

          :during_b ->
            assert_receive {:stage, :a, pid}, 2_000
            send(pid, :release)
            assert_receive {:stage, :b, ^pid}, 2_000
            {pid, [1, 1, 0]}

          :after_computation ->
            for name <- [:a, :b, :c] do
              assert_receive {:stage, ^name, pid}, 2_000
              send(pid, :release)
            end

            assert_receive {:computed_before_reply, pid}, 2_000
            {pid, [1, 1, 1]}
        end

      lost_ref = Process.monitor(lost)
      Process.exit(lost, :kill)
      assert_receive {:DOWN, ^lost_ref, :process, ^lost, :killed}, 2_000
      if unquote(cut) == :before_a, do: :sys.resume(scope)
      assert_receive :drained, 2_000

      assert {:ok,
              %{
                status: :stopped,
                active_units: 0,
                causes: [%{kind: :uncertain, unit: {:promise, _}}]
              }} =
               Runner.admission_status(ctx.runner, :live)

      assert read_counts(counts, 3) == expected
      assert {:ok, wf} = Runner.get_workflow(ctx.runner, :live)
      assert Workflow.is_runnable?(wf)
      refute Enum.any?(wf.runnable_events, &is_struct(&1, Workflow.RunnableFailed))
      assert Workflow.raw_productions(wf) == []
      refute_received {:stage, _, _}

      assert :ok = Runner.continue(ctx.runner, :live)

      for name <- [:a, :b, :c] do
        assert_receive {:stage, ^name, pid}, 2_000
        refute pid == lost
        send(pid, :release)
      end

      assert_receive {:computed_before_reply, pid}, 2_000
      send(pid, :reply)
      assert_receive :drained, 2_000
      assert read_counts(counts, 3) == Enum.map(expected, &(&1 + 1))
      assert {:ok, results} = Runner.get_results(ctx.runner, :live)
      assert Enum.sort(results) == [2, 4, 7]
      assert :ok = Runner.checkpoint(ctx.runner, :live)
      assert {:ok, %{status: :saved}} = Runner.persistence_status(ctx.runner, :live)
      assert :ok = Runner.stop(ctx.runner, :live)

      assert {:ok, _} =
               Runner.resume(ctx.runner, :live,
                 owner: observer,
                 run_context: %{_global: %{counts: counts, observer: observer}}
               )

      assert {:ok, restored} = Runner.get_workflow(ctx.runner, :live)
      refute Workflow.is_runnable?(restored)
      assert {:ok, %{status: :open, active_units: 0}} = Runner.admission_status(ctx.runner, :live)
      assert read_counts(counts, 3) == Enum.map(expected, &(&1 + 1))
      refute_received {:stage, _, _}
    end
  end

  for order <- [
        [:one, :two, :loss],
        [:one, :loss, :two],
        [:two, :one, :loss],
        [:two, :loss, :one],
        [:loss, :one, :two],
        [:loss, :two, :one]
      ] do
    test "draining preserves every cause in arrival order #{inspect(order)}", ctx do
      observer = self()
      counts = :atomics.new(4, [])

      steps =
        for {name, index} <- Enum.with_index([:one, :two, :loss, :later], 1) do
          Runic.step(
            fn value ->
              :atomics.add(counts, index, 1)
              if name in [:one, :two], do: raise(Atom.to_string(name)), else: value + index
            end,
            name: name
          )
        end

      positions = %{one: 0, two: 1, loss: 2, later: 3}

      assert {:ok, worker} =
               Runner.start_workflow(ctx.runner, :causes, Runic.workflow(steps: steps),
                 max_concurrency: 3,
                 executor: ReleasingExecutor,
                 executor_opts: [test_pid: observer, outcome: :deferred],
                 on_complete: fn _, _ -> send(observer, :drained) end,
                 hooks: [
                   transform_runnables: fn units, _ ->
                     Enum.sort_by(units, &positions[&1.node.name])
                   end
                 ]
               )

      assert :ok = Runner.run(ctx.runner, :causes, 1)

      replies =
        Map.new(
          for _ <- 1..3 do
            assert_receive {:executor_result, ^worker, handle, result}, 2_000
            {result.node.name, {handle, result}}
          end
        )

      expected_causes =
        for {name, index} <- Enum.with_index(unquote(order), 1) do
          {handle, result} = Map.fetch!(replies, name)

          if name == :loss,
            do: send(worker, {:DOWN, handle, :process, self(), :lost}),
            else: send(worker, {handle, result})

          assert {:ok, %{status: :stopped, active_units: active, causes: causes}} =
                   Runner.admission_status(ctx.runner, :causes)

          assert active == 3 - index
          assert length(causes) == index
          if active > 0, do: assert({:error, :busy} == Runner.continue(ctx.runner, :causes))
          {if(name == :loss, do: :uncertain, else: :failed), {:runnable, result.id}}
        end

      assert_receive :drained, 2_000
      assert {:ok, %{causes: causes}} = Runner.admission_status(ctx.runner, :causes)
      assert Enum.map(causes, &{&1.kind, &1.unit}) == expected_causes
      assert read_counts(counts, 4) == [1, 1, 1, 0]
      assert {:ok, []} = Runner.get_results(ctx.runner, :causes)
      assert {:ok, wf} = Runner.get_workflow(ctx.runner, :causes)
      assert length(Workflow.prepared_runnables(wf)) == 2

      for {_name, {handle, result}} <- replies do
        send(worker, {handle, result})
        send(worker, {:DOWN, handle, :process, self(), :duplicate})
      end

      assert {:ok, %{active_units: 0, causes: ^causes}} =
               Runner.admission_status(ctx.runner, :causes)

      assert {:ok, []} = Runner.get_results(ctx.runner, :causes)
      refute_received :drained
    end
  end

  test "a parallel Promise drains its members after another unit fails without admitting later work",
       ctx do
    observer = self()
    counts = :atomics.new(4, [])
    pa = gated_step(1, :pa)
    pb = gated_step(2, :pb)

    fail =
      Runic.step(
        fn _ ->
          :atomics.add(counts, 3, 1)
          send(observer, {:stage, :fail, self()})
          receive do: (:fail -> raise("stop"))
        end,
        name: :fail
      )

    later =
      Runic.step(
        fn value ->
          :atomics.add(counts, 4, 1)
          value + 4
        end,
        name: :later
      )

    assert {:ok, _} =
             Runner.start_workflow(
               ctx.runner,
               :parallel,
               Runic.workflow(steps: [pa, pb, fail, later]),
               scheduler: FailureBatchScheduler,
               max_concurrency: 2,
               on_complete: fn _, _ -> send(observer, :drained) end,
               hooks: [on_failed: fn _, _, _ -> send(observer, :failure_applied) end]
             )

    assert :ok =
             Runner.run(ctx.runner, :parallel, 1,
               run_context: %{_global: %{counts: counts, observer: observer}}
             )

    assert_receive {:stage, :pa, pa_pid}, 2_000
    assert_receive {:stage, :pb, pb_pid}, 2_000
    assert_receive {:stage, :fail, failed_pid}, 2_000
    send(failed_pid, :fail)
    assert_receive :failure_applied, 2_000

    assert {:ok, %{status: :stopped, active_units: 1}} =
             Runner.admission_status(ctx.runner, :parallel)

    assert {:error, :busy} = Runner.continue(ctx.runner, :parallel)
    send(pa_pid, :release)
    assert {:ok, %{active_units: 1}} = Runner.admission_status(ctx.runner, :parallel)
    send(pb_pid, :release)
    assert_receive :drained, 2_000
    assert {:ok, results} = Runner.get_results(ctx.runner, :parallel)
    assert Enum.sort(results) == [2, 3]
    assert read_counts(counts, 4) == [1, 1, 1, 0]

    assert {:ok, %{status: :stopped, active_units: 0, causes: [%{kind: :failed}]}} =
             Runner.admission_status(ctx.runner, :parallel)

    assert {:ok, wf} = Runner.get_workflow(ctx.runner, :parallel)
    assert Enum.map(Workflow.prepared_runnables(wf), & &1.node.name) == [:later]
  end

  for recovery <- [:retry, :fallback, :skip] do
    test "#{recovery} keeps admission open while another native unit remains active", ctx do
      observer = self()
      counts = :atomics.new(3, [])

      recovering =
        Runic.step(
          fn value ->
            attempt = :atomics.add_get(counts, 1, 1)

            if attempt == 1 do
              send(observer, {:first_attempt, self()})
              receive do: (:attempt -> :ok)
              raise "recoverable"
            end

            value + 1
          end,
          name: :recovering
        )

      slow = gated_step(2, :slow)

      later =
        Runic.step(
          fn value ->
            :atomics.add(counts, 3, 1)
            value + 3
          end,
          name: :later
        )

      policy =
        case unquote(recovery) do
          :retry -> %{max_retries: 1, retry_if: fn _ -> true end}
          :fallback -> %{fallback: fn _, _ -> {:value, 2} end}
          :skip -> %{on_failure: :skip}
        end

      workflow =
        Runic.workflow(steps: [recovering, slow, later])
        |> Workflow.set_scheduler_policies([
          {:recovering, policy},
          {:default, %{execution_mode: :durable}}
        ])

      positions = %{recovering: 0, slow: 1, later: 2}

      assert {:ok, _} =
               Runner.start_workflow(ctx.runner, :recover, workflow,
                 max_concurrency: 2,
                 on_complete: fn _, _ -> send(observer, :drained) end,
                 hooks: [
                   transform_runnables: fn units, _ ->
                     Enum.sort_by(units, &positions[&1.node.name])
                   end,
                   on_complete: fn runnable, _, _ ->
                     if runnable.node.name == :later, do: send(observer, :later_applied)
                   end
                 ]
               )

      assert :ok =
               Runner.run(ctx.runner, :recover, 1,
                 run_context: %{_global: %{counts: counts, observer: observer}}
               )

      assert_receive {:first_attempt, first}, 2_000
      assert_receive {:stage, :slow, held}, 2_000
      send(first, :attempt)
      assert_receive :later_applied, 2_000

      assert {:ok, %{status: :open, active_units: 1, causes: []}} =
               Runner.admission_status(ctx.runner, :recover)

      send(held, :release)
      assert_receive :drained, 2_000
      assert {:ok, results} = Runner.get_results(ctx.runner, :recover)
      assert Enum.sort(results) == if(unquote(recovery) == :skip, do: [3, 4], else: [2, 3, 4])
      assert read_counts(counts, 3) == [if(unquote(recovery) == :retry, do: 2, else: 1), 1, 1]

      assert {:ok, %{status: :open, active_units: 0, causes: []}} =
               Runner.admission_status(ctx.runner, :recover)
    end
  end

  test "a real active success survives stopped admission and failed storage without repeating acknowledged work" do
    observer = self()
    counts = :atomics.new(2, [])
    store = start_supervised!(FailingStore)
    runner = :"failure_storage_edge_#{System.unique_integer([:positive])}"

    start_supervised!(
      Supervisor.child_spec(
        {Runner, name: runner, store: FailingStore, store_opts: [agent: store]},
        id: runner
      )
    )

    failing =
      Runic.step(
        fn _ ->
          :atomics.add(context(:counts), 1, 1)
          send(context(:observer), {:stage, :fail, self()})
          receive do: (:fail -> raise("stop"))
        end,
        name: :fail
      )

    success = gated_step(2, :success)

    workflow =
      Runic.workflow(steps: [failing, success])
      |> Workflow.set_scheduler_policies([{:default, %{execution_mode: :durable}}])

    assert {:ok, _} =
             Runner.start_workflow(runner, :stored, workflow,
               max_concurrency: 2,
               on_complete: fn _, _ -> send(observer, :drained) end,
               hooks: [on_failed: fn _, _, _ -> send(observer, :failure_applied) end]
             )

    assert :ok =
             Runner.run(runner, :stored, 1,
               run_context: %{_global: %{counts: counts, observer: observer}}
             )

    assert_receive {:stage, :fail, first}, 2_000
    assert_receive {:stage, :success, second}, 2_000
    FailingStore.fail(store, :append)
    send(first, :fail)
    assert_receive :failure_applied, 2_000
    assert {:ok, %{status: :stopped, active_units: 1}} = Runner.admission_status(runner, :stored)

    assert {:ok, %{status: {:error, _}, pending_events: failed_pending}} =
             Runner.persistence_status(runner, :stored)

    assert failed_pending > 0
    send(second, :release)
    assert_receive :drained, 2_000
    assert {:ok, [3]} = Runner.get_results(runner, :stored)

    assert {:ok, %{status: error, pending_events: all_pending}} =
             Runner.persistence_status(runner, :stored)

    assert all_pending > failed_pending
    assert :ok = Runner.continue(runner, :stored)

    assert {:ok, %{status: ^error, pending_events: ^all_pending}} =
             Runner.persistence_status(runner, :stored)

    assert read_counts(counts, 2) == [1, 1]

    FailingStore.recover(store)
    assert :ok = Runner.checkpoint(runner, :stored)

    assert {:ok, %{status: :saved, pending_events: 0}} =
             Runner.persistence_status(runner, :stored)

    assert :ok = Runner.stop(runner, :stored)

    assert {:ok, _} =
             Runner.resume(runner, :stored,
               run_context: %{_global: %{counts: counts, observer: observer}}
             )

    assert {:ok, restored} = Runner.get_workflow(runner, :stored)
    refute Workflow.is_runnable?(restored)
    assert {:ok, %{status: :open, active_units: 0}} = Runner.admission_status(runner, :stored)
    assert Workflow.raw_productions(restored) == [3]
    assert read_counts(counts, 2) == [1, 1]
    refute_received {:stage, _, _}
  end

  defp gated_step(index, name) do
    definition = %{offset: index, stage: name}

    Runic.step(
      fn value ->
        definition = ^definition
        :atomics.add(context(:counts), definition.offset, 1)
        send(context(:observer), {:stage, definition.stage, self()})
        receive do: (:release -> value + definition.offset)
      end,
      name: name
    )
  end

  defp read_counts(counts, size), do: for(index <- 1..size, do: :atomics.get(counts, index))

  defp wait_for_admission(scope, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    {:messages, messages} = Process.info(scope, :messages)

    case Enum.find(messages, &match?({:"$gen_call", _, {:admit, _, _}}, &1)) do
      nil ->
        assert System.monotonic_time(:millisecond) < deadline, "admission was not queued"
        :erlang.yield()
        wait_for_admission(scope, deadline)

      message ->
        message
    end
  end
end
