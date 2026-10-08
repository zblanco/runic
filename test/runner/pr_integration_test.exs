defmodule Runic.Runner.PRIntegrationTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  require Runic
  alias Runic.Runner
  alias Runic.Workflow
  alias Runic.TestSupport.{AdmissionScheduler, FailingStore, ReleasingExecutor}

  setup do
    store = start_supervised!(FailingStore)
    runner = :"integration_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner, store: FailingStore, store_opts: [agent: store]})
    %{runner: runner, store: store}
  end

  for release_error <- [false, true] do
    test "persistence failure retains results across release failure #{release_error}", ctx do
      {:ok, worker} = start_worker(ctx.runner, single(), release_error: unquote(release_error))
      FailingStore.fail(ctx.store, :append)
      :ok = Runner.run(ctx.runner, :wf, 1)
      assert_receive {:executor_result, ^worker, handle, result}, 1_000
      deliver(worker, handle, result)
      assert_receive {:executor_released, ^handle}, 1_000

      before = :sys.get_state(worker)
      assert before.uncommitted_events != []
      assert before.active_executors == %{}
      assert {:error, {:persistence_failed, :storage_unavailable}} = Runner.stop(ctx.runner, :wf)
      assert Process.alive?(worker)
      assert :sys.get_state(worker).uncommitted_events == before.uncommitted_events
      refute_received {:executor_cleaned, _}

      # A repeated result and its late DOWN cannot release or apply twice.
      deliver(worker, handle, result)
      send(worker, {:DOWN, handle, :process, self(), :late})
      after_duplicate = :sys.get_state(worker)
      assert after_duplicate.uncommitted_events == before.uncommitted_events
      assert after_duplicate.workflow == before.workflow
      refute_received {:executor_released, _}

      FailingStore.recover(ctx.store)
      assert :ok = Runner.checkpoint(ctx.runner, :wf)
      assert :sys.get_state(worker).uncommitted_events == []
      assert :ok = Runner.stop(ctx.runner, :wf)
      assert_receive {:executor_cleaned, :default}, 1_000
      refute_received {:executor_cleaned, _}
      assert {:ok, _} = Runner.resume(ctx.runner, :wf)
      assert {:ok, [2]} = Runner.get_results(ctx.runner, :wf)
    end
  end

  test "failed build persistence cleans the initialized executor once", ctx do
    FailingStore.fail(ctx.store, :append)

    assert {:error, {:persistence_failed, :storage_unavailable}} =
             start_worker(ctx.runner, single())

    assert_receive {:executor_cleaned, :default}, 1_000
    refute_received {:executor_cleaned, _}
    assert Runner.lookup(ctx.runner, :wf) == nil
  end

  test "cleanup failure does not prevent other executor instances from cleaning", ctx do
    workflow =
      single()
      |> Workflow.set_scheduler_policies([
        {:increment,
         %{executor: ReleasingExecutor, executor_opts: [test_pid: self(), label: :override]}}
      ])

    {:ok, worker} = start_worker(ctx.runner, workflow, cleanup_error: true)
    :ok = Runner.run(ctx.runner, :wf, 1)
    assert_receive {:executor_result, ^worker, handle, _result}, 1_000
    assert_receive {:executor_released, ^handle}, 1_000
    :sys.get_state(worker)
    assert :ok = Runner.stop(ctx.runner, :wf)
    assert_receive {:executor_cleaned, :default}
    assert_receive {:executor_cleaned, :override}, 1_000
    refute_received {:executor_cleaned, _}
  end

  test "untracked and mismatched results cannot consume a live handle", ctx do
    owner = self()

    workflow =
      Workflow.attach_after_hook(single(), :increment, fn _, workflow, _ ->
        send(owner, :applied)
        workflow
      end)

    {:ok, worker} = start_worker(ctx.runner, workflow)
    :ok = Runner.run(ctx.runner, :wf, 1)
    assert_receive {:executor_result, ^worker, handle, result}, 1_000
    {runnable, events} = result
    before = :sys.get_state(worker)
    deliver(worker, make_ref(), result)
    deliver(worker, handle, {%{runnable | id: :wrong_activation}, events})
    assert :sys.get_state(worker) == before
    refute_received {:executor_released, _}
    deliver(worker, handle, result)
    assert {:ok, [2]} = Runner.get_results(ctx.runner, :wf)
    assert_received :applied
    deliver(worker, handle, result)
    refute_received :applied
  end

  test "a partial Promise result cannot repeat its completed prefix", ctx do
    workflow =
      Runic.workflow(
        steps: [
          {
            Runic.step(fn n -> n + 1 end, name: :first),
            [Runic.step(fn _ -> raise "second failed" end, name: :second)]
          }
        ]
      )

    {:ok, worker} =
      Runner.start_workflow(ctx.runner, :wf, workflow,
        scheduler: Runic.Runner.Scheduler.ChainBatching,
        executor: ReleasingExecutor,
        executor_opts: [test_pid: self(), outcome: :deferred]
      )

    :ok = Runner.run(ctx.runner, :wf, 1)

    assert_receive {:executor_result, ^worker, handle, {:promise_partial, _, _, _} = result},
                   1_000

    deliver(worker, handle, result)
    assert_receive {:executor_released, ^handle}, 1_000
    before = :sys.get_state(worker)
    deliver(worker, handle, result)
    assert :sys.get_state(worker) == before
    refute_received {:executor_released, _}
    assert {:ok, [2]} = Runner.get_results(ctx.runner, :wf)
  end

  for promise_strategy <- [:sequential, :parallel] do
    test "duplicate #{promise_strategy} Promise result is not applied twice", ctx do
      owner = self()
      first = Runic.step(fn n -> n + 1 end, name: :first)
      second = Runic.step(fn n -> n * 2 end, name: :second)

      workflow =
        if unquote(promise_strategy) == :sequential,
          do: Runic.workflow(steps: [{first, [second]}]),
          else: Runic.workflow(steps: [first, second])

      scheduler =
        if unquote(promise_strategy) == :sequential,
          do: Runic.Runner.Scheduler.ChainBatching,
          else: Runic.Runner.Scheduler.FlowBatch

      {:ok, worker} =
        Runner.start_workflow(ctx.runner, :wf, workflow,
          executor: ReleasingExecutor,
          executor_opts: [test_pid: owner, outcome: :deferred],
          scheduler: scheduler,
          scheduler_opts: [min_batch_size: 2],
          hooks: [on_complete: fn _, _, _ -> send(owner, :completed) end]
        )

      :ok = Runner.run(ctx.runner, :wf, 2)
      assert_receive {:executor_result, ^worker, handle, {:promise_result, _, _} = result}, 5_000
      deliver(worker, handle, result)
      assert_receive {:executor_released, ^handle}
      before = :sys.get_state(worker)
      data = FailingStore.data(ctx.store)
      deliver(worker, handle, result)
      send(worker, {:DOWN, handle, :process, self(), :late})
      assert :sys.get_state(worker) == before
      assert FailingStore.data(ctx.store) == data
      refute_received {:executor_released, _}
    end
  end

  for mode <- [:manual, :automatic] do
    test "#{mode} scheduler sees proposals but tracks only admitted units", ctx do
      workflow =
        Runic.workflow(
          steps: [
            Runic.step(fn n -> n + 1 end, name: :first),
            Runic.step(fn n -> n + 2 end, name: :second)
          ]
        )

      {:ok, worker} =
        Runner.start_workflow(ctx.runner, :wf, workflow,
          dispatch_mode: unquote(mode),
          max_concurrency: 1,
          scheduler: AdmissionScheduler,
          scheduler_opts: [owner: self()],
          executor: ReleasingExecutor,
          executor_opts: [test_pid: self(), outcome: :deferred]
        )

      :ok = Runner.run(ctx.runner, :wf, 1)
      if unquote(mode) == :manual, do: assert(:ok == Runner.step(ctx.runner, :wf))
      assert_receive {:planned, proposed}, 1_000
      assert length(proposed) == 2
      assert_receive {:admitted, first_id}, 1_000
      assert_receive {:executor_result, ^worker, handle, result}
      assert :sys.get_state(worker).scheduler_state.active == MapSet.new([first_id])
      refute_received {:admitted, _}

      # continue with active work must not duplicate its admission.
      assert :ok = Runner.continue(ctx.runner, :wf)
      refute_received {:admitted, _}
      deliver(worker, handle, result)
      assert_receive {:admission_completed, ^first_id, true}, 1_000
      assert_receive {:admitted, second_id}, 1_000
      assert second_id != first_id
      assert_receive {:executor_result, ^worker, second_handle, second_result}, 1_000
      deliver(worker, second_handle, second_result)
      assert_receive {:admission_completed, ^second_id, true}, 1_000
      assert :sys.get_state(worker).scheduler_state.active == MapSet.new()
      assert {:ok, results} = Runner.get_results(ctx.runner, :wf)
      assert Enum.sort(results) == [2, 3]
    end
  end

  test "manual checkpoint and resume keep pending work held with fresh context", ctx do
    workflow =
      Runic.workflow(steps: [Runic.step(fn n -> n + context(:offset) end, name: :increment)])

    {:ok, worker} = Runner.start_workflow(ctx.runner, :wf, workflow, dispatch_mode: :manual)
    :ok = Runner.run(ctx.runner, :wf, 1, run_context: %{increment: %{offset: 2}})
    assert :ok = Runner.checkpoint(ctx.runner, :wf)
    assert :sys.get_state(worker).active_tasks == %{}
    assert :ok = Runner.stop(ctx.runner, :wf)

    assert {:ok, resumed} =
             Runner.resume(ctx.runner, :wf,
               dispatch_mode: :manual,
               run_context: %{increment: %{offset: 10}},
               executor: ReleasingExecutor,
               executor_opts: [test_pid: self(), outcome: :deferred]
             )

    assert :sys.get_state(resumed).active_tasks == %{}
    refute_received {:executor_result, _, _, _}
    assert :ok = Runner.step(ctx.runner, :wf)
    assert_receive {:executor_result, ^resumed, handle, result}, 1_000
    deliver(resumed, handle, result)
    assert {:ok, [11]} = Runner.get_results(ctx.runner, :wf)
  end

  test "manual dynamic construction and fact metadata survive checkpoint and fresh-context resume",
       ctx do
    first = Runic.step(fn n -> n + 1 end, name: :first)
    added = Runic.step(fn n -> n + context(:offset) end, name: :added)

    workflow =
      Workflow.new()
      |> Workflow.add(first)
      |> Workflow.attach_after_hook(:first, fn _, wf, _ -> Workflow.add(wf, added, to: :first) end)

    input = Runic.Workflow.Fact.new(value: 1, meta: %{source: :fixture})

    {:ok, worker} =
      Runner.start_workflow(ctx.runner, :wf, workflow,
        dispatch_mode: :manual,
        executor: ReleasingExecutor,
        executor_opts: [test_pid: self(), outcome: :deferred]
      )

    :ok = Runner.run(ctx.runner, :wf, input, run_context: %{added: %{offset: 1}})
    assert :ok = Runner.step(ctx.runner, :wf)
    assert_receive {:executor_result, ^worker, handle, result}, 1_000
    deliver(worker, handle, result)
    assert :ok = Runner.checkpoint(ctx.runner, :wf)
    assert :ok = Runner.stop(ctx.runner, :wf)

    assert {:ok, resumed} =
             Runner.resume(ctx.runner, :wf,
               dispatch_mode: :manual,
               run_context: %{added: %{offset: 10}},
               executor: ReleasingExecutor,
               executor_opts: [test_pid: self(), outcome: :deferred]
             )

    assert {:ok, restored} = Runner.get_workflow(ctx.runner, :wf)
    assert Workflow.get_component(restored, :added)
    assert Map.fetch!(restored.graph.vertices, input.hash).meta == %{source: :fixture}
    assert :ok = Runner.step(ctx.runner, :wf)
    assert_receive {:executor_result, ^resumed, next_handle, next_result}, 1_000
    deliver(resumed, next_handle, next_result)
    assert {:ok, values} = Runner.get_results(ctx.runner, :wf)
    assert 12 in values
  end

  defp single, do: Runic.workflow(steps: [Runic.step(fn n -> n + 1 end, name: :increment)])

  defp start_worker(runner, workflow, extra \\ []) do
    workflow =
      Workflow.set_scheduler_policies(
        workflow,
        workflow.scheduler_policies ++ [{:default, %{execution_mode: :durable}}]
      )

    Runner.start_workflow(runner, :wf, workflow,
      executor: ReleasingExecutor,
      executor_opts: [test_pid: self(), outcome: :deferred] ++ extra
    )
  end

  defp deliver(worker, handle, result) do
    send(worker, {handle, result})
    GenServer.call(worker, :get_workflow)
  end
end
