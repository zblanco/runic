defmodule Runic.Runner.FailureAdmissionTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  require Runic
  alias Runic.Runner
  alias Runic.Workflow
  alias Runic.TestSupport.ReleasingExecutor

  setup do
    runner = :"failure_admission_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner})
    %{runner: runner}
  end

  for executor <- [:inline, Runic.Runner.Executor.Task] do
    test "known failure stops admission with executor #{executor}", %{runner: runner} do
      counter = :atomics.new(1, [])
      owner = self()
      workflow = failing_workflow(counter)

      {:ok, _pid} =
        Runner.start_workflow(runner, :known, workflow,
          executor: unquote(executor),
          max_concurrency: 1,
          on_complete: fn _, _ -> send(owner, :drained) end
        )

      :ok = Runner.run(runner, :known, 1)
      assert_receive :drained, 1_000
      assert :atomics.get(counter, 1) == 1

      assert {:ok, %{status: :stopped, active_units: 0, causes: [%{kind: :failed}]}} =
               Runner.admission_status(runner, :known)

      assert {:ok, wf} = Runner.get_workflow(runner, :known)
      assert Workflow.is_runnable?(wf)

      :ok = Runner.run(runner, :known, 10)
      assert {:ok, %{status: :stopped}} = Runner.admission_status(runner, :known)
      assert :atomics.get(counter, 1) == 1
      :ok = Runner.continue(runner, :known)
      assert_receive :drained, 1_000
      assert {:ok, %{status: :open}} = Runner.admission_status(runner, :known)
      assert :atomics.get(counter, 1) == 6
    end
  end

  test "manual step rejects stopped admission", %{runner: runner} do
    {:ok, _pid} =
      Runner.start_workflow(runner, :manual, failing_workflow(:atomics.new(1, [])),
        dispatch_mode: :manual,
        executor: :inline
      )

    :ok = Runner.run(runner, :manual, 1)
    assert :ok = Runner.step(runner, :manual)
    assert {:error, :admission_stopped} = Runner.step(runner, :manual)
  end

  for executor <- [:inline, Runic.Runner.Executor.Task] do
    test "mixed executor chains use a free slot with default #{executor}", %{runner: runner} do
      owner = self()
      first = Runic.step(fn value -> value + 1 end, name: :first)

      child =
        Runic.step(
          fn value ->
            send(owner, :inline_child)
            value + 1
          end,
          name: :child
        )

      blocked =
        Runic.step(
          fn value ->
            send(owner, {:blocked, self()})

            receive do
              :release -> value
            end
          end,
          name: :blocked
        )

      policies =
        if unquote(executor) == :inline do
          [{:blocked, %{executor: Runic.Runner.Executor.Task}}]
        else
          [{:first, %{executor: :inline}}, {:child, %{executor: :inline}}]
        end

      workflow =
        Runic.workflow(steps: [{first, [child]}, blocked])
        |> Workflow.set_scheduler_policies(policies)

      {:ok, _} =
        Runner.start_workflow(runner, :mixed, workflow,
          executor: unquote(executor),
          max_concurrency: 2,
          on_complete: fn _, _ -> send(owner, :drained) end,
          hooks: [
            transform_runnables: fn units, _ ->
              Enum.sort_by(units, &(&1.node.name != :first))
            end
          ]
        )

      :ok = Runner.run(runner, :mixed, 1)
      assert_receive {:blocked, task}, 1_000

      try do
        assert_receive :inline_child, 1_000
        assert {:ok, %{status: :open, active_units: 1}} = Runner.admission_status(runner, :mixed)
        refute_received :inline_child
      after
        send(task, :release)
      end

      assert_receive :drained, 1_000
      assert {:ok, results} = Runner.get_results(runner, :mixed)
      assert Enum.sort(results) == [1, 2, 3]
    end
  end

  test "outer loss retains prepared work without fabricated node failure", %{runner: runner} do
    owner = self()
    workflow = Runic.workflow(steps: [Runic.step(fn value -> value + 1 end, name: :first)])

    {:ok, _pid} =
      Runner.start_workflow(runner, :uncertain, workflow,
        executor: ReleasingExecutor,
        executor_opts: [test_pid: self(), outcome: :crash],
        on_complete: fn _, _ -> send(owner, :drained) end
      )

    :ok = Runner.run(runner, :uncertain, 1)
    assert_receive :drained, 1_000

    assert {:ok,
            %{
              status: :stopped,
              active_units: 0,
              causes: [%{kind: :uncertain, reason: :test_crash}]
            }} = Runner.admission_status(runner, :uncertain)

    assert {:ok, wf} = Runner.get_workflow(runner, :uncertain)
    assert Workflow.is_runnable?(wf)
    assert wf.runnable_events == []
    assert Workflow.raw_productions(wf) == []
  end

  test "a stopped scope drains results and records later uncertain outcomes", %{runner: runner} do
    {:ok, worker} =
      Runner.start_workflow(runner, :drain, failing_workflow(:atomics.new(1, [])),
        executor: ReleasingExecutor,
        executor_opts: [test_pid: self(), outcome: :deferred],
        max_concurrency: 3
      )

    :ok = Runner.run(runner, :drain, 1)
    assert_receive {:executor_result, ^worker, first, %{status: :failed} = failed}, 1_000
    assert_receive {:executor_result, ^worker, second, _}, 1_000
    assert_receive {:executor_result, ^worker, third, success}, 1_000
    send(worker, {first, failed})
    assert {:ok, %{status: :stopped, active_units: 2}} = Runner.admission_status(runner, :drain)
    assert {:error, :busy} = Runner.continue(runner, :drain)
    send(worker, {:DOWN, second, :process, self(), :lost})
    send(worker, {third, success})

    assert {:ok,
            %{
              status: :stopped,
              active_units: 0,
              causes: [
                %{kind: :failed},
                %{kind: :uncertain, reason: :lost}
              ]
            }} = Runner.admission_status(runner, :drain)

    assert {:ok, [2]} = Runner.get_results(runner, :drain)
    assert {:ok, wf} = Runner.get_workflow(runner, :drain)
    assert length(Workflow.prepared_runnables(wf)) == 1
  end

  test "outer Promise loss retains its prepared entry without fabricated batch history", %{
    runner: runner
  } do
    first = Runic.step(fn value -> value + 1 end, name: :first)
    second = Runic.step(fn value -> value * 2 end, name: :second)
    workflow = Runic.workflow(steps: [{first, [second]}])

    {:ok, worker} =
      Runner.start_workflow(runner, :promise_loss, workflow,
        promise_opts: [min_chain_length: 2],
        executor: ReleasingExecutor,
        executor_opts: [test_pid: self(), outcome: :deferred]
      )

    :ok = Runner.run(runner, :promise_loss, 1)
    assert_receive {:executor_result, ^worker, handle, {:promise_result, promise_id, _}}, 1_000
    send(worker, {:DOWN, handle, :process, self(), :lost_reply})

    assert {:ok,
            %{
              status: :stopped,
              causes: [
                %{kind: :uncertain, unit: {:promise, ^promise_id}, reason: :lost_reply}
              ]
            }} = Runner.admission_status(runner, :promise_loss)

    assert {:ok, wf} = Runner.get_workflow(runner, :promise_loss)
    assert Workflow.is_runnable?(wf)
    assert wf.runnable_events == []
    assert Workflow.raw_productions(wf) == []
  end

  test "inline work is applied once before a new scheduler proposal", %{runner: runner} do
    counter = :atomics.new(1, [])

    steps =
      for name <- [:one, :two, :three] do
        Runic.step(
          fn value ->
            :atomics.add(counter, 1, 1)
            value + 1
          end,
          name: name
        )
      end

    {:ok, _} =
      Runner.start_workflow(runner, :once, Runic.workflow(steps: steps), executor: :inline)

    :ok = Runner.run(runner, :once, 1)
    assert {:ok, _} = Runner.get_workflow(runner, :once)
    assert :atomics.get(counter, 1) == 3
  end

  test "outer loss completes local scheduler admission once", %{runner: runner} do
    workflow = Runic.workflow(steps: [Runic.step(fn value -> value + 1 end, name: :first)])

    {:ok, worker} =
      Runner.start_workflow(runner, :scheduler_loss, workflow,
        scheduler: Runic.TestSupport.AdmissionScheduler,
        scheduler_opts: [owner: self()],
        executor: ReleasingExecutor,
        executor_opts: [test_pid: self(), outcome: :crash]
      )

    :ok = Runner.run(runner, :scheduler_loss, 1)
    assert_receive {:admitted, id}, 1_000
    assert_receive {:executor_released, handle}, 1_000
    assert_receive {:admission_completed, ^id, true}, 1_000
    assert {:ok, %{status: :stopped}} = Runner.admission_status(runner, :scheduler_loss)
    send(worker, {:DOWN, handle, :process, self(), :duplicate})
    assert {:ok, _} = Runner.admission_status(runner, :scheduler_loss)
    refute_received {:admission_completed, _, _}
    assert :ok = Runner.continue(runner, :scheduler_loss)
    assert_receive {:admitted, ^id}, 1_000
    assert_receive {:admission_completed, ^id, true}, 1_000
  end

  test "accepted Promise prefix and consumed failure survive failed persistence and replay" do
    alias Runic.TestSupport.FailingStore
    store = start_supervised!(FailingStore)
    runner = :"failure_store_#{System.unique_integer([:positive])}"

    start_supervised!(
      Supervisor.child_spec(
        {Runner, name: runner, store: FailingStore, store_opts: [agent: store]},
        id: runner
      )
    )

    counts = :atomics.new(3, [])

    first =
      Runic.step(
        fn value ->
          :atomics.add(context(:counts), 1, 1)
          value + 1
        end,
        name: :first
      )

    second =
      Runic.step(
        fn _ ->
          :atomics.add(context(:counts), 2, 1)
          raise "stop"
        end,
        name: :second
      )

    last =
      Runic.step(
        fn value ->
          :atomics.add(context(:counts), 3, 1)
          value * 2
        end,
        name: :last
      )

    workflow =
      Runic.workflow(steps: [{first, [{second, [last]}]}])
      |> Workflow.set_scheduler_policies([{:default, %{execution_mode: :durable}}])

    {:ok, worker} =
      Runner.start_workflow(runner, :prefix, workflow,
        promise_opts: [min_chain_length: 2],
        executor: ReleasingExecutor,
        executor_opts: [test_pid: self(), outcome: :deferred]
      )

    FailingStore.fail(store, :append)
    :ok = Runner.run(runner, :prefix, 1, run_context: %{_global: %{counts: counts}})

    assert_receive {:executor_result, ^worker, handle, {:promise_partial, _, _, _} = result},
                   1_000

    send(worker, {handle, result})
    assert {:ok, %{status: :stopped}} = Runner.admission_status(runner, :prefix)
    assert {:ok, [2]} = Runner.get_results(runner, :prefix)

    assert {:ok, %{status: {:error, _}, pending_events: pending}} =
             Runner.persistence_status(runner, :prefix)

    assert pending > 0
    assert {:error, _} = Runner.stop(runner, :prefix)
    assert Process.alive?(worker)

    assert :ok = Runner.continue(runner, :prefix)

    assert {:ok, %{status: {:error, _}, pending_events: ^pending}} =
             Runner.persistence_status(runner, :prefix)

    send(worker, {handle, result})
    assert {:ok, [2]} = Runner.get_results(runner, :prefix)
    assert {:ok, %{pending_events: ^pending}} = Runner.persistence_status(runner, :prefix)
    assert for(index <- 1..3, do: :atomics.get(counts, index)) == [1, 1, 0]
    FailingStore.recover(store)
    assert :ok = Runner.checkpoint(runner, :prefix)
    assert :ok = Runner.stop(runner, :prefix)

    assert {:ok, _} =
             Runner.resume(runner, :prefix,
               dispatch_mode: :manual,
               run_context: %{_global: %{counts: counts}}
             )

    assert {:ok, [2]} = Runner.get_results(runner, :prefix)
    assert {:error, :not_runnable} = Runner.step(runner, :prefix)
    assert {:ok, %{status: :open}} = Runner.admission_status(runner, :prefix)
    assert for(index <- 1..3, do: :atomics.get(counts, index)) == [1, 1, 0]
  end

  defp failing_workflow(counter) do
    steps =
      for name <- [:one, :two, :three] do
        Runic.step(
          fn value ->
            if :atomics.add_get(counter, 1, 1) == 1, do: raise("stop")
            value + 1
          end,
          name: name
        )
      end

    Runic.workflow(steps: steps)
  end
end
