defmodule Runic.Workflow.BatchTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  require Runic
  alias Runic.{Runner, Workflow}
  alias Runic.TestSupport.OrdinaryComponent, as: Custom
  alias Runic.Workflow.Batch
  alias Runic.Workflow.Batch.Result

  for items <- [[], [1], [1, 1, 2]] do
    @tag items: items
    test "custom component completes #{inspect(items)} without consumer coordination", %{
      items: items
    } do
      batch = Runic.batch(Custom.new(:item, :add, 10), name: :batch)

      workflow =
        Workflow.new()
        |> Workflow.add(batch)
        |> Workflow.add(Custom.new(:output, :data), to: :batch)
        |> Workflow.react_until_satisfied(Batch.input(items, %{shared: :parent}), async: true)

      assert [%Result{parent: %{shared: :parent}, outcomes: outcomes}] =
               Workflow.raw_productions(workflow, :output)

      assert Enum.map(outcomes, & &1.value) == Enum.map(items, &(&1 + 10))
      assert Enum.map(outcomes, & &1.index) == Enum.with_index(items) |> Enum.map(&elem(&1, 1))
      assert Enum.all?(outcomes, &(&1.status == :completed))
      refute Workflow.is_runnable?(workflow)
    end
  end

  test "repeated and nested invocations keep different batch and item identities" do
    inner = Runic.batch(Custom.new(:item, :data), name: :inner)
    outer = Runic.batch(inner, name: :outer)

    workflow =
      Workflow.new()
      |> Workflow.add(outer)
      |> Workflow.add(Custom.new(:output, :data), to: :outer)

    {first, _} = Workflow.execute(workflow, Batch.input([[1, 1], []], :parent))
    [result] = Workflow.raw_productions(first, :output)
    [a, b] = result.outcomes
    assert Enum.map(a.value.outcomes, & &1.value) == [1, 1]
    assert b.value.outcomes == []
    refute a.value.id == b.value.id
    refute result.id == a.value.id
    refute hd(a.value.outcomes).id == List.last(a.value.outcomes).id

    {second, _} = Workflow.execute(first, Batch.input([[1, 1], []], :parent))
    results = Workflow.raw_productions(second, :output)
    assert length(results) == 2
    assert length(Enum.uniq_by(results, & &1.id)) == 2
  end

  test "completion order and retries do not change item order" do
    parent = self()
    batch = Runic.batch(Custom.new(:item, :retry, 1), name: :batch)

    workflow =
      Workflow.new()
      |> Workflow.add(batch)
      |> Workflow.add(Custom.new(:output, :data), to: :batch)
      |> Workflow.put_run_context(%{_global: %{observer: parent}})
      |> Workflow.set_scheduler_policies([{:item, %{max_retries: 1, backoff: :none}}])
      |> Workflow.plan_eagerly([10, 20, 30])
      |> Workflow.react()

    {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)
    assert length(runnables) == 3

    completed =
      Enum.map(
        runnables,
        &Workflow.PolicyDriver.execute(&1, %Workflow.SchedulerPolicy{
          max_retries: 1,
          backoff: :none
        })
      )

    workflow =
      Enum.reduce(Enum.reverse(completed), workflow, &Workflow.apply_runnable(&2, &1))
      |> Workflow.react_until_satisfied()

    assert [%{outcomes: outcomes}] = Workflow.raw_productions(workflow, :output)
    assert Enum.map(outcomes, & &1.value) == [10, 20, 30]

    for _ <- 1..3 do
      assert_receive {:work, :item, %{attempt_number: 0}}
      assert_receive {:work, :item, %{attempt_number: 1}}
    end
  end

  test "skip outcomes collect and halt stops new admission" do
    batch = Runic.batch(Custom.new(:item, :failure, :unavailable), name: :batch)

    template =
      Workflow.new()
      |> Workflow.add(batch)
      |> Workflow.add(Custom.new(:output, :data), to: :batch)

    {collected, execution} =
      Workflow.execute(template, [1, 2, 3], scheduler_policies: [{:item, %{on_failure: :skip}}])

    assert execution.admission == :open
    assert [%{outcomes: outcomes}] = Workflow.raw_productions(collected, :output)
    assert Enum.map(outcomes, & &1.status) == [:skipped, :skipped, :skipped]
    assert Enum.all?(outcomes, &(&1.error == :unavailable))
    {failed, execution} = Workflow.execute(template, [1, 2, 3])
    assert execution.admission != :open
    assert Workflow.raw_productions(failed, :output) == []
    assert Enum.count(execution.outcomes, &(&1.kind == :failed)) == 1
    # The same authored graph can be used with another policy.
    assert template.graph ==
             (Workflow.new()
              |> Workflow.add(batch)
              |> Workflow.add(Custom.new(:output, :data), to: :batch)).graph
  end

  test "partial failure observations preserve item order without admitting siblings" do
    batch = Runic.batch(Custom.new(:item, :failure, :stop), name: :batch)
    workflow = Workflow.new() |> Workflow.add(batch)
    {failed, _execution} = Workflow.execute(workflow, [1, 2, 3])
    [id] = Batch.invocations(failed, batch)
    assert {:ok, outcomes} = Batch.outcomes(failed, batch, id)
    assert Enum.map(outcomes, & &1.index) == [0, 1, 2]
    assert Enum.count(outcomes, &(&1.status == :failed)) == 1
    assert Enum.count(outcomes, &(&1.status == :pending)) == 2
    assert {:error, :not_found} = Batch.outcomes(failed, batch, :unknown)
  end

  test "exception failures can be collected as skipped outcomes" do
    workflow =
      Workflow.new()
      |> Workflow.add(Runic.batch(Custom.new(:item, :raise), name: :batch))
      |> Workflow.add(Custom.new(:output, :data), to: :batch)

    {completed, _} =
      Workflow.execute(workflow, [1, 2], scheduler_policies: [{:item, %{on_failure: :skip}}])

    assert [%{outcomes: outcomes}] = Workflow.raw_productions(completed, :output)
    assert Enum.all?(outcomes, &match?(%{status: :skipped, error: %ArgumentError{}}, &1))
  end

  test "batch construction rejects shared member nodes within one graph" do
    item = Custom.new(:item, :data)
    workflow = Workflow.new() |> Workflow.add(Runic.batch(item, name: :first))
    assert_raise ArgumentError, fn -> Workflow.add(workflow, Runic.batch(item, name: :second)) end
  end

  test "build log and accepted event replay restore a custom batch and its parent" do
    batch = Runic.batch(Custom.new(:item, :add, 4), name: :batch)

    workflow =
      Workflow.new()
      |> Workflow.add(batch)
      |> Workflow.add(Custom.new(:output, :data), to: :batch)

    rebuilt = Workflow.from_log(Workflow.build_log(workflow))

    completed =
      rebuilt
      |> Workflow.enable_event_emission()
      |> Workflow.react_until_satisfied(Batch.input([1, 2], :parent))

    replayed =
      Workflow.from_events(
        Workflow.build_log(completed) ++ Enum.reverse(completed.uncommitted_events)
      )

    assert Workflow.raw_productions(replayed, :output) ==
             Workflow.raw_productions(completed, :output)

    refute Workflow.is_runnable?(replayed)
  end

  test "shared parent is absent from stored item Facts and is present in callback context" do
    batch = Runic.batch(Custom.new(:item, :data), name: :batch)
    parent = Enum.into(1..1000, %{}, &{&1, &1})

    workflow =
      Workflow.new()
      |> Workflow.add(batch)
      |> Workflow.plan_eagerly(Batch.input([1, 2, 3], parent))
      |> Workflow.react()

    item_facts = Workflow.facts(workflow) |> Enum.filter(&match?({_, _}, &1.ancestry))
    assert length(item_facts) == 3
    assert Enum.all?(item_facts, &(not Map.has_key?(&1.meta.runic_batch, :parent)))
    {_, runnables} = Workflow.prepare_for_dispatch(workflow)
    assert Enum.all?(runnables, &(&1.context.batch.parent == parent))
    stored_items = :erlang.external_size(item_facts)
    copied_contexts = :erlang.external_size(Enum.map(runnables, & &1.context))
    assert copied_contexts > stored_items + 3 * :erlang.external_size(parent)
  end

  test "invalid batch input and unsupported components fail explicitly" do
    assert_raise ArgumentError, fn -> apply(Batch, :input, [[1 | 2]]) end
    assert_raise ArgumentError, fn -> Runic.batch(Runic.map(fn x -> x end)) end
    workflow = Workflow.new() |> Workflow.add(Runic.batch(Custom.new(:item), name: :batch))
    {_, execution} = Workflow.execute(workflow, :invalid)
    assert [%{kind: :failed, error: %ArgumentError{}}] = execution.outcomes
  end

  for policy <- [:halt, :skip] do
    @tag item_policy: policy
    test "Store recovery keeps the accepted item prefix with #{policy} handling", %{
      item_policy: policy
    } do
      runner = :"batch_replay_#{System.unique_integer([:positive])}"
      start_supervised!({Runner, name: runner})
      operation = if policy == :skip, do: :failure, else: :data
      batch = Runic.batch(Custom.new(:item, operation, :unavailable), name: :batch)

      workflow =
        Workflow.new()
        |> Workflow.add(batch)
        |> Workflow.add(Custom.new(:output, :data), to: :batch)
        |> Workflow.put_run_context(%{_global: %{observer: self()}})
        |> Workflow.set_scheduler_policies([{:item, %{on_failure: policy}}])

      {:ok, worker} =
        Runner.start_workflow(runner, :replay, workflow,
          executor: :inline,
          dispatch_mode: :manual
        )

      :ok = Runner.run(runner, :replay, Batch.input([1, 2, 3], :parent))
      :sys.get_state(worker)
      :ok = Runner.step(runner, :replay)
      :ok = Runner.step(runner, :replay)
      assert_receive {:work, :item, accepted}
      assert :ok = Runner.checkpoint(runner, :replay)

      assert {:ok, %{status: :saved, pending_events: 0}} =
               Runner.persistence_status(runner, :replay)

      assert :ok = Runner.stop(runner, :replay)

      {:ok, _} =
        Runner.resume(runner, :replay,
          scheduler_policies: [{:item, %{on_failure: policy}}],
          executor: :inline,
          run_context: %{_global: %{observer: self()}}
        )

      await_idle(runner, :replay)
      assert_receive {:work, :item, second}
      assert_receive {:work, :item, third}
      refute accepted.activation_id in [second.activation_id, third.activation_id]
      refute_receive {:work, :item, _}, 20
      {:ok, recovered} = Runner.get_workflow(runner, :replay)

      assert [%{parent: :parent, outcomes: outcomes}] =
               Workflow.raw_productions(recovered, :output)

      assert Enum.map(outcomes, & &1.index) == [0, 1, 2]

      assert Enum.map(outcomes, & &1.status) ==
               List.duplicate(if(policy == :skip, do: :skipped, else: :completed), 3)
    end
  end

  test "concurrent native completion preserves input order and Step parent context" do
    runner = :"batch_parallel_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner})

    item =
      Runic.step(
        fn value ->
          batch = context(:batch)
          send(context(:observer), {:started, self(), batch.index})
          receive do: (:release -> :ok)
          value + batch.parent.offset
        end,
        name: :item
      )

    workflow =
      Workflow.new()
      |> Workflow.add(Runic.batch(item, name: :batch))
      |> Workflow.add(Custom.new(:output, :data), to: :batch)
      |> Workflow.put_run_context(%{_global: %{observer: self()}})

    observer = self()

    {:ok, _} =
      Runner.start_workflow(runner, :parallel, workflow,
        max_concurrency: 3,
        hooks: [
          on_complete: fn r, _, _ ->
            if r.node.name == :item,
              do: send(observer, {:accepted, r.input_fact.meta.runic_batch.index})
          end
        ]
      )

    {:ok, id} = Runner.start_execution(runner, :parallel, Batch.input([1, 2, 3], %{offset: 10}))

    tasks =
      for _ <- 1..3 do
        assert_receive {:started, pid, index}, 2000
        {index, pid}
      end

    for {index, pid} <- Enum.sort(tasks, :desc) do
      send(pid, :release)
      assert_receive {:accepted, ^index}, 2000
    end

    assert {:ok, _execution} = Runner.await_execution(runner, :parallel, id)
    {:ok, completed} = Runner.get_workflow(runner, :parallel)
    assert [%{outcomes: outcomes}] = Workflow.raw_productions(completed, :output)
    assert Enum.map(outcomes, & &1.value) == [11, 12, 13]
  end

  test "native executor loss reports one uncertain item and leaves other items pending" do
    runner = :"batch_loss_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner})

    item =
      Runic.step(
        fn value ->
          send(context(:observer), {:blocked, self()})
          receive do: (:release -> value)
        end,
        name: :item
      )

    batch = Runic.batch(item, name: :batch)

    workflow =
      Workflow.new()
      |> Workflow.add(batch)
      |> Workflow.put_run_context(%{_global: %{observer: self()}})

    {:ok, _} = Runner.start_workflow(runner, :loss, workflow, max_concurrency: 1)
    {:ok, id} = Runner.start_execution(runner, :loss, [1, 2, 3])
    assert_receive {:blocked, pid}, 2000
    Process.exit(pid, :kill)
    assert {:ok, execution} = Runner.await_execution(runner, :loss, id)
    assert execution.admission != :open
    {:ok, workflow} = Runner.get_workflow(runner, :loss)
    [batch_id] = Batch.invocations(workflow, batch)
    assert {:ok, outcomes} = Batch.outcomes(workflow, batch, batch_id)
    assert Enum.map(outcomes, & &1.index) == [0, 1, 2]
    assert Enum.count(outcomes, &(&1.status == :uncertain)) == 1
    assert Enum.count(outcomes, &(&1.status == :pending)) == 2
    refute Enum.any?(Workflow.event_log(workflow), &match?(%Workflow.RunnableFailed{}, &1))
    refute_receive {:blocked, _}, 30
  end

  test "Runner cancellation stops admitted native work and prevents more item admission" do
    runner = :"batch_cancel_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner})

    item =
      Runic.step(
        fn value ->
          send(context(:observer), {:item_started, self(), value})
          receive do: (:release -> value)
        end,
        name: :item
      )

    workflow =
      Workflow.new()
      |> Workflow.add(Runic.batch(item, name: :batch))
      |> Workflow.put_run_context(%{_global: %{observer: self()}})

    {:ok, _} = Runner.start_workflow(runner, :cancel, workflow, max_concurrency: 1)
    :ok = Runner.run(runner, :cancel, [1, 2, 3])
    assert_receive {:item_started, pid, _}, 2000
    monitor = Process.monitor(pid)
    assert :ok = Runner.cancel(runner, :cancel)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 2000
    refute_receive {:item_started, _, _}, 50
  end

  defp await_idle(runner, id, attempts \\ 200)
  defp await_idle(_runner, _id, 0), do: flunk("workflow did not become idle")

  defp await_idle(runner, id, attempts) do
    state = :sys.get_state(Runner.lookup(runner, id))

    if state.status == :idle and map_size(state.active_tasks) == 0 do
      :ok
    else
      Process.sleep(10)
      await_idle(runner, id, attempts - 1)
    end
  end
end
