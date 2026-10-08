defmodule Runic.Runner.PersistenceFailureTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  require Runic
  alias Runic.Runner
  alias Runic.Workflow
  alias Runic.Workflow.Events.FactProduced
  alias Runic.Workflow.{FactRef, FactResolver}
  alias Runic.TestSupport.FailingStore
  alias Runic.TestSupport.{FailingEventOnlyStore, FailingLegacyStore, FailingSaveOnlyStore}

  setup do
    store = start_supervised!(FailingStore)
    %{store: store}
  end

  test "failed checkpoint retains events and successful retry acknowledges the Store cursor",
       ctx do
    runner = start_runner(ctx.store)
    {worker, barrier} = start_blocked_workflow(runner)
    before = :sys.get_state(worker)
    assert before.uncommitted_events != []
    FailingStore.fail(ctx.store, :append)

    assert {:error, {:persistence_failed, :storage_unavailable}} = Runner.checkpoint(runner, :wf)
    after_failure = :sys.get_state(worker)
    assert after_failure.uncommitted_events == before.uncommitted_events
    assert after_failure.event_cursor == before.event_cursor

    assert {:error, {:persistence_failed, :storage_unavailable}} = Runner.checkpoint(runner, :wf)
    assert :sys.get_state(worker).uncommitted_events == before.uncommitted_events

    FailingStore.recover(ctx.store)
    assert :ok = Runner.checkpoint(runner, :wf)
    after_retry = :sys.get_state(worker)
    assert after_retry.uncommitted_events == []
    assert after_retry.event_cursor == FailingStore.data(ctx.store).cursors.wf
    append_count = call_count(ctx.store, :append)
    assert :ok = Runner.checkpoint(runner, :wf)
    assert call_count(ctx.store, :append) == append_count
    send(barrier, :release)
    assert_receive {:idle, :saved}, 5_000
    assert :sys.get_state(worker).uncommitted_events == []
    assert :ok = Runner.stop(runner, :wf)
    assert {:ok, _} = Runner.resume(runner, :wf)
    assert {:ok, results} = Runner.get_results(runner, :wf)
    assert Enum.sort(results) == [2, 4]
  end

  for {label, module, operation} <- [
        {"checkpoint callback", FailingLegacyStore, :checkpoint},
        {"save fallback", FailingSaveOnlyStore, :save}
      ] do
    test "legacy #{label} returns failure and can retry", ctx do
      runner = start_runner(ctx.store, unquote(module))
      {worker, barrier} = start_blocked_workflow(runner)
      before = :sys.get_state(worker).workflow
      FailingStore.fail(ctx.store, unquote(operation))

      assert {:error, {:persistence_failed, :storage_unavailable}} =
               Runner.checkpoint(runner, :wf)

      assert :sys.get_state(worker).workflow == before
      assert {:error, :not_found} = FailingStore.load(:wf, ctx.store)
      FailingStore.recover(ctx.store)
      assert :ok = Runner.checkpoint(runner, :wf)
      assert {:ok, log} = FailingStore.load(:wf, ctx.store)
      assert log == Workflow.event_log(before)
      send(barrier, :release)
      assert_receive {:idle, :saved}, 5_000
    end
  end

  for operation <- [:save_fact, :save_payload] do
    test "#{operation} failure retains full values without committing references", ctx do
      runner = start_runner(ctx.store)
      {worker, barrier} = start_blocked_workflow(runner)
      pending = :sys.get_state(worker).uncommitted_events
      assert Enum.any?(pending, &match?(%FactProduced{value: 2}, &1))
      append_count = call_count(ctx.store, :append)
      FailingStore.fail(ctx.store, unquote(operation))

      assert {:error, {:persistence_failed, :storage_unavailable}} =
               Runner.checkpoint(runner, :wf)

      assert call_count(ctx.store, :append) == append_count
      assert :sys.get_state(worker).uncommitted_events == pending
      FailingStore.recover(ctx.store)
      assert :ok = Runner.checkpoint(runner, :wf)
      assert_resolvable_stream(ctx.store)
      send(barrier, :release)
      assert_receive {:idle, :saved}, 5_000
    end
  end

  test "failed append after value saves retries original values rather than nil", ctx do
    runner = start_runner(ctx.store)
    {worker, barrier} = start_blocked_workflow(runner)
    pending = :sys.get_state(worker).uncommitted_events
    FailingStore.fail(ctx.store, :append)
    assert {:error, _} = Runner.checkpoint(runner, :wf)
    facts_before = FailingStore.data(ctx.store).facts
    assert map_size(facts_before) > 0
    assert :sys.get_state(worker).uncommitted_events == pending
    FailingStore.recover(ctx.store)
    assert :ok = Runner.checkpoint(runner, :wf)
    assert FailingStore.data(ctx.store).facts == facts_before
    assert_resolvable_stream(ctx.store)
    send(barrier, :release)
    assert_receive {:idle, :saved}, 5_000
  end

  test "stores without value storage keep inline values and replay after retry", ctx do
    runner = start_runner(ctx.store, FailingEventOnlyStore)
    {_worker, barrier} = start_blocked_workflow(runner)
    FailingStore.fail(ctx.store, :append)
    assert {:error, _} = Runner.checkpoint(runner, :wf)
    FailingStore.recover(ctx.store)
    assert :ok = Runner.checkpoint(runner, :wf)
    assert Enum.any?(FailingStore.data(ctx.store).events.wf, &match?(%FactProduced{value: 2}, &1))
    send(barrier, :release)
    assert_receive {:idle, :saved}, 5_000
    assert :ok = Runner.stop(runner, :wf)
    assert {:ok, _} = Runner.resume(runner, :wf)
    assert {:ok, results} = Runner.get_results(runner, :wf)
    assert Enum.sort(results) == [2, 4]
  end

  for module <- [FailingStore, FailingLegacyStore] do
    test "#{inspect(module)} stop failure leaves worker alive for retry", ctx do
      runner = start_runner(ctx.store, unquote(module))
      {worker, _barrier} = start_blocked_workflow(runner)
      monitor = Process.monitor(worker)
      operation = if unquote(module) == FailingStore, do: :append, else: :save
      FailingStore.fail(ctx.store, operation)

      assert {:error, {:persistence_failed, :storage_unavailable}} = Runner.stop(runner, :wf)
      assert Process.alive?(worker)
      assert Runner.lookup(runner, :wf) == worker

      assert {:ok, %{status: {:error, {:persistence_failed, :storage_unavailable}}}} =
               Runner.persistence_status(runner, :wf)

      FailingStore.recover(ctx.store)
      assert :ok = Runner.stop(runner, :wf)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
    end
  end

  test "persist false explicitly stops without attempting a failed write", ctx do
    runner = start_runner(ctx.store)
    {worker, _barrier} = start_blocked_workflow(runner)
    FailingStore.fail(ctx.store, :append)
    calls_before = FailingStore.data(ctx.store).calls
    monitor = Process.monitor(worker)
    assert :ok = Runner.stop(runner, :wf, persist: false)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
    assert FailingStore.data(ctx.store).calls == calls_before
  end

  test "initial build failure is structured and does not register or dispatch a Worker", ctx do
    runner = start_runner(ctx.store)
    FailingStore.fail(ctx.store, :append)
    workflow = Runic.workflow(steps: [Runic.step(fn n -> n + 1 end, name: :increment)])

    assert {:error, {:persistence_failed, :storage_unavailable}} =
             Runner.start_workflow(runner, :wf, workflow)

    assert Runner.lookup(runner, :wf) == nil
    assert FailingStore.data(ctx.store).events == %{}
    assert call_count(ctx.store, :append) == 1
    FailingStore.recover(ctx.store)
    assert {:ok, _} = Runner.start_workflow(runner, :wf, workflow)
    assert Runner.list_workflows(runner) == [:wf]
  end

  for strategy <- [:manual, :on_complete, :every_cycle, {:every_n, 2}] do
    test "#{inspect(strategy)} exposes computed completion and retained final-save failure",
         ctx do
      runner = start_runner(ctx.store)
      parent = self()

      {worker, barrier} =
        start_blocked_workflow(runner,
          checkpoint_strategy: unquote(Macro.escape(strategy)),
          on_complete: fn id, wf ->
            send(parent, {:computed, id, Workflow.raw_productions(wf)})
          end,
          hooks: [
            on_persistence_error: fn operation, reason, state ->
              send(parent, {:persistence_error, operation, reason, state.persistence})
            end
          ]
        )

      FailingStore.fail(ctx.store, :append)
      send(barrier, :release)
      error = {:persistence_failed, :storage_unavailable}
      assert_receive {:persistence_error, :save, ^error, {:error, ^error}}, 5_000
      assert_receive {:computed, :wf, results}, 5_000
      assert Enum.sort(results) == [2, 4]
      assert_receive {:idle, {:error, ^error}}, 5_000
      assert Process.alive?(worker)

      assert {:ok, %{status: {:error, ^error}, pending_events: count}} =
               Runner.persistence_status(runner, :wf)

      assert count > 0
      FailingStore.recover(ctx.store)
      assert :ok = Runner.checkpoint(runner, :wf)
      assert {:ok, %{status: :saved, pending_events: 0}} = Runner.persistence_status(runner, :wf)
      refute_received {:computed, :wf, _}
      assert :ok = Runner.stop(runner, :wf)
      assert {:ok, _} = Runner.resume(runner, :wf)
      assert {:ok, restored} = Runner.get_results(runner, :wf)
      assert Enum.sort(restored) == [2, 4]
    end
  end

  test "legacy final save reports failure while preserving computed completion", ctx do
    runner = start_runner(ctx.store, FailingLegacyStore)
    parent = self()

    {_worker, barrier} =
      start_blocked_workflow(runner,
        on_complete: fn id, wf -> send(parent, {:computed, id, Workflow.raw_productions(wf)}) end
      )

    FailingStore.fail(ctx.store, :save)
    send(barrier, :release)
    assert_receive {:idle, {:error, {:persistence_failed, :storage_unavailable}}}, 5_000
    assert_receive {:computed, :wf, results}
    assert Enum.sort(results) == [2, 4]
    assert {:error, :not_found} = FailingStore.load(:wf, ctx.store)
    FailingStore.recover(ctx.store)
    assert :ok = Runner.checkpoint(runner, :wf)
    assert :ok = Runner.stop(runner, :wf)
    assert {:ok, _} = Runner.resume(runner, :wf)
    assert {:ok, results} = Runner.get_results(runner, :wf)
    assert Enum.sort(results) == [2, 4]
  end

  test "nil output values survive a failed append and replay", ctx do
    runner = start_runner(ctx.store)
    parent = self()
    workflow = Runic.workflow(steps: [Runic.step(fn _ -> nil end, name: :nothing)])

    assert {:ok, _} =
             Runner.start_workflow(runner, :wf, workflow,
               executor: :inline,
               checkpoint_strategy: :manual,
               hooks: [on_idle: fn state -> send(parent, {:idle, state.persistence}) end]
             )

    FailingStore.fail(ctx.store, :append)
    assert :ok = Runner.run(runner, :wf, 1)
    assert_receive {:idle, {:error, {:persistence_failed, :storage_unavailable}}}, 5_000
    FailingStore.recover(ctx.store)
    assert :ok = Runner.checkpoint(runner, :wf)
    assert_resolvable_stream(ctx.store)
    assert :ok = Runner.stop(runner, :wf)
    assert {:ok, _} = Runner.resume(runner, :wf)
    assert {:ok, [nil]} = Runner.get_results(runner, :wf)
  end

  test "an error hook exception does not discard data or crash the Worker", ctx do
    runner = start_runner(ctx.store)

    {worker, barrier} =
      start_blocked_workflow(runner,
        hooks: [on_persistence_error: fn _, _, _ -> raise "hook failure" end]
      )

    pending = :sys.get_state(worker).uncommitted_events
    FailingStore.fail(ctx.store, :append)
    assert {:error, {:persistence_failed, :storage_unavailable}} = Runner.checkpoint(runner, :wf)
    assert Process.alive?(worker)
    assert :sys.get_state(worker).uncommitted_events == pending
    FailingStore.recover(ctx.store)
    assert :ok = Runner.checkpoint(runner, :wf)
    send(barrier, :release)
    assert_receive {:idle, :saved}, 5_000
  end

  for {label, opts} <- [
        {"inline", [executor: :inline]},
        {"chain promise", [scheduler: Runic.Runner.Scheduler.ChainBatching]},
        {"parallel promise", [scheduler: TestParallelScheduler]}
      ] do
    test "#{label} retains value-save failures for checkpoint retry", ctx do
      runner = start_runner(ctx.store)
      parent = self()
      first = Runic.step(fn n -> n + 1 end, name: :first)
      second = Runic.step(fn n -> n * 2 end, name: :second)
      third = Runic.step(fn n -> n + 10 end, name: :third)

      {workflow, expected} =
        if unquote(label) == "parallel promise" do
          {Runic.workflow(steps: [{first, [second, third]}]), [2, 4, 12]}
        else
          {Runic.workflow(steps: [{first, [{second, [third]}]}]), [2, 4, 14]}
        end

      opts =
        Keyword.merge(unquote(Macro.escape(opts)),
          checkpoint_strategy: :manual,
          hooks: [on_idle: fn state -> send(parent, {:idle, state.persistence}) end]
        )

      assert {:ok, worker} = Runner.start_workflow(runner, :wf, workflow, opts)
      FailingStore.fail(ctx.store, :save_fact)
      assert :ok = Runner.run(runner, :wf, 1)
      assert_receive {:idle, {:error, {:persistence_failed, :storage_unavailable}}}, 5_000

      assert Enum.any?(:sys.get_state(worker).uncommitted_events, fn
               %FactProduced{value: value} -> value == List.last(expected)
               _ -> false
             end)

      FailingStore.recover(ctx.store)
      assert :ok = Runner.checkpoint(runner, :wf)
      assert_resolvable_stream(ctx.store)
      assert :ok = Runner.stop(runner, :wf)
      assert {:ok, _} = Runner.resume(runner, :wf)
      assert {:ok, results} = Runner.get_results(runner, :wf)
      assert Enum.sort(results) == expected
    end
  end

  test "parallel map/reduce retains coordination and lifecycle events for runtime replay after retry",
       ctx do
    runner = start_runner(ctx.store)
    parent = self()

    workflow =
      Runic.workflow(
        steps: [
          {Runic.map(fn n -> n * 2 end, name: :double),
           [Runic.reduce(0, fn n, acc -> n + acc end, name: :sum, map: :double)]}
        ]
      )
      |> Workflow.set_scheduler_policies([{:default, %{execution_mode: :durable}}])

    assert {:ok, worker} =
             Runner.start_workflow(runner, :wf, workflow,
               scheduler: Runic.Runner.Scheduler.FlowBatch,
               scheduler_opts: [min_batch_size: 2],
               checkpoint_strategy: :manual,
               hooks: [on_idle: fn state -> send(parent, {:idle, state.persistence}) end]
             )

    FailingStore.fail(ctx.store, :append)
    assert :ok = Runner.run(runner, :wf, [1, 2, 3])
    assert_receive {:idle, {:error, {:persistence_failed, :storage_unavailable}}}, 5_000
    assert {:ok, original} = Runner.get_results(runner, :wf)
    assert 12 in original
    pending = :sys.get_state(worker).uncommitted_events
    assert Enum.any?(pending, &match?(%Runic.Workflow.Events.FanInCompleted{}, &1))
    assert Enum.any?(pending, &match?(%Runic.Workflow.RunnableCompleted{}, &1))
    FailingStore.recover(ctx.store)
    assert :ok = Runner.checkpoint(runner, :wf)
    assert_resolvable_stream(ctx.store)
    data = FailingStore.data(ctx.store)

    full_events =
      Enum.map(data.events.wf, fn
        %FactProduced{} = event -> %{event | value: Map.fetch!(data.facts, event.hash)}
        event -> event
      end)

    # Preserve the authored topology to exercise runtime journal replay. Full
    # Map/Reduce build-log reconstruction has a separate upstream limitation.
    replayed = Workflow.from_events(full_events, workflow)
    assert Enum.sort(Workflow.raw_productions(replayed)) == Enum.sort(original)
    assert :ok = Runner.stop(runner, :wf)
  end

  test "successful final persistence clears the actual Worker buffer and avoids duplicate appends",
       ctx do
    runner = start_runner(ctx.store)
    {worker, barrier} = start_blocked_workflow(runner)
    send(barrier, :release)
    assert_receive {:idle, :saved}, 5_000
    assert :sys.get_state(worker).uncommitted_events == []
    calls = FailingStore.data(ctx.store).calls
    assert :ok = Runner.checkpoint(runner, :wf)
    assert :ok = Runner.stop(runner, :wf)
    assert FailingStore.data(ctx.store).calls == calls
  end

  test "persistence status is pending before checkpoint and missing for unknown workflows", ctx do
    runner = start_runner(ctx.store)
    {_worker, barrier} = start_blocked_workflow(runner)

    assert {:ok, %{status: :pending, pending_events: count}} =
             Runner.persistence_status(runner, :wf)

    assert count > 0
    assert {:error, :not_found} = Runner.persistence_status(runner, :missing)
    send(barrier, :release)
    assert_receive {:idle, :saved}, 5_000
  end

  test "an already evaluated Workflow retains its runtime buffer after initial build acknowledgement",
       ctx do
    runner = start_runner(ctx.store)

    workflow =
      Runic.workflow(steps: [Runic.step(fn n -> n + 1 end, name: :increment)])
      |> Workflow.enable_event_emission()
      |> Workflow.react_until_satisfied(1)

    assert workflow.uncommitted_events != []
    assert {:ok, worker} = Runner.start_workflow(runner, :wf, workflow)

    assert {:ok, %{status: :pending, pending_events: count}} =
             Runner.persistence_status(runner, :wf)

    assert count == length(workflow.uncommitted_events)
    assert :sys.get_state(worker).uncommitted_events == Enum.reverse(workflow.uncommitted_events)
    FailingStore.fail(ctx.store, :append)
    assert {:error, _} = Runner.checkpoint(runner, :wf)
    FailingStore.recover(ctx.store)
    assert :ok = Runner.checkpoint(runner, :wf)
    assert :ok = Runner.stop(runner, :wf)
    assert {:ok, _} = Runner.resume(runner, :wf)
    assert {:ok, [2]} = Runner.get_results(runner, :wf)
  end

  test "store telemetry distinguishes returned errors from acknowledged writes", ctx do
    runner = start_runner(ctx.store)
    {worker, barrier} = start_blocked_workflow(runner)
    handler_id = "persistence-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:runic, :runner, :store, :stop],
        &__MODULE__.handle_store_event/4,
        %{test_pid: self(), worker: worker}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    FailingStore.fail(ctx.store, :append)
    assert {:error, _} = Runner.checkpoint(runner, :wf)

    assert_receive {:telemetry, [:runic, :runner, :store, :stop], %{duration: _},
                    %{
                      workflow_id: :wf,
                      operation: :checkpoint,
                      result: {:error, :storage_unavailable}
                    }}

    FailingStore.recover(ctx.store)
    assert :ok = Runner.checkpoint(runner, :wf)

    assert_receive {:telemetry, [:runic, :runner, :store, :stop], %{duration: _},
                    %{workflow_id: :wf, operation: :checkpoint, result: {:ok, cursor}}}

    assert cursor == FailingStore.data(ctx.store).cursors.wf
    send(barrier, :release)
    assert_receive {:idle, :saved}, 5_000
  end

  def handle_store_event(event, measurements, metadata, %{test_pid: test_pid, worker: worker}) do
    if self() == worker, do: send(test_pid, {:telemetry, event, measurements, metadata})
  end

  defp call_count(store, operation) do
    Enum.count(FailingStore.data(store).calls, fn {op, _} -> op == operation end)
  end

  defp assert_resolvable_stream(store) do
    data = FailingStore.data(store)
    events = Enum.filter(data.events.wf, &match?(%FactProduced{}, &1))
    assert events != []
    resolver = FactResolver.new({FailingStore, store})

    for event <- events do
      assert event.value == nil
      ref = struct(FactRef, Map.from_struct(event))
      assert {:ok, fact} = FactResolver.resolve(ref, resolver)
      assert fact.value == Map.fetch!(data.facts, event.hash)
      assert {:ok, encoded} = FailingStore.load_payload(event.payload_digest, store)
      assert :erlang.binary_to_term(encoded) == fact.value
    end
  end

  defp start_runner(store, module \\ FailingStore) do
    name = :"persistence_runner_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: name, store: module, store_opts: [agent: store]})
    name
  end

  defp start_blocked_workflow(runner, opts \\ []) do
    parent = self()
    observer = Module.concat(runner, Observer)
    Process.register(parent, observer)
    increment = Runic.step(fn n -> n + 1 end, name: :increment)

    barrier =
      Runic.step(
        fn n ->
          send(Process.whereis(^observer), {:blocked, self()})

          receive do
            :release -> n * 2
          end
        end,
        name: :barrier
      )

    workflow = Runic.workflow(steps: [{increment, [barrier]}])

    hooks =
      Keyword.merge(
        [on_idle: fn state -> send(parent, {:idle, state.persistence}) end],
        Keyword.get(opts, :hooks, [])
      )

    opts = Keyword.put(opts, :hooks, hooks)

    {:ok, worker} =
      Runner.start_workflow(
        runner,
        :wf,
        workflow,
        Keyword.merge([checkpoint_strategy: :manual, max_concurrency: 1], opts)
      )

    assert :ok = Runner.run(runner, :wf, 1)
    assert_receive {:blocked, barrier_pid}, 5_000
    {worker, barrier_pid}
  end
end
