defmodule Runic.Workflow.BatchContractRegressionTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  require Runic
  alias Runic.{Runner, Workflow}
  alias Runic.Workflow.Batch
  alias Runic.TestSupport.OrdinaryComponent, as: Custom

  for items <- [[], [1]], match? <- [true, false] do
    @tag items: items, match?: match?
    test "Rule completion after #{inspect(items)} has correct match admission #{match?}", ctx do
      match? = ctx.match?

      authored_rule =
        if match? do
          Runic.rule(fn value when is_map(value) -> :matched end, name: :rule)
        else
          Runic.rule(fn value when is_integer(value) -> :matched end, name: :rule)
        end

      workflow =
        Workflow.new()
        |> Workflow.add(Runic.batch(Custom.new(:item, :data), name: :batch))
        |> Workflow.add(authored_rule, to: :batch)
        |> Workflow.add(Runic.step(fn value -> value end, name: :output), to: :rule)
        |> Workflow.enable_event_emission()

      {completed, _} = Workflow.execute(workflow, ctx.items)
      assert Workflow.raw_productions(completed, :output) == if(match?, do: [:matched], else: [])
      refute Workflow.is_runnable?(completed)
      events = Workflow.build_log(completed) ++ Enum.reverse(completed.uncommitted_events)

      assert Enum.any?(
               events,
               &match?(%Workflow.Events.RunnableActivated{activation_kind: :matchable}, &1)
             )

      replayed = Workflow.from_events(events)

      assert Workflow.raw_productions(replayed, :output) ==
               Workflow.raw_productions(completed, :output)

      refute Workflow.is_runnable?(replayed)
    end
  end

  test "a skipped inner item does not suppress a successful sibling collector in controlled order" do
    {workflow, outer} = nested_workflow()

    workflow =
      workflow |> Workflow.enable_event_emission() |> Workflow.plan_eagerly([[:bad], [2]])

    workflow = apply_ready(workflow)
    workflow = apply_ready(workflow)
    {workflow, members} = Workflow.prepare_for_dispatch(workflow)
    good = Enum.find(members, &(&1.input_fact.value == 2))
    bad = Enum.find(members, &(&1.input_fact.value == :bad))
    workflow = Workflow.apply_runnable(workflow, Workflow.execute_runnable(good))
    {workflow, before} = Workflow.prepare_for_dispatch(workflow)
    assert Enum.any?(before, &(&1.node.name == "inner.fan_in"))
    skipped = Workflow.PolicyDriver.execute(bad, %Workflow.SchedulerPolicy{on_failure: :skip})
    workflow = Workflow.apply_runnable(workflow, skipped)
    {workflow, after_skip} = Workflow.prepare_for_dispatch(workflow)
    assert Enum.any?(after_skip, &(&1.node.name == "inner.fan_in"))
    # Persist the interrupted state and complete from replay, too.
    replayed = replay(workflow)

    for base <- [workflow, replayed] do
      completed = Workflow.react_until_satisfied(base)
      assert_nested_result(completed, outer)
    end
  end

  test "concurrent inner skip keeps the successful sibling collection and replay" do
    runner = runner()

    item =
      Runic.step(
        fn value ->
          send(context(:observer), {:member, self(), value})
          receive do: (:release -> :ok)
          if value == :bad, do: raise("bad item"), else: value
        end,
        name: :item
      )

    inner = Runic.batch(item, name: :inner)
    outer = Runic.batch(inner, name: :outer)

    workflow =
      Workflow.new()
      |> Workflow.add(outer)
      |> Workflow.add(Custom.new(:output, :data), to: :outer)
      |> Workflow.put_run_context(%{_global: %{observer: self()}})

    observer = self()
    gate = :atomics.new(1, [])

    {:ok, worker} =
      Runner.start_workflow(runner, :concurrent, workflow,
        max_concurrency: 2,
        hooks: [
          transform_runnables: fn runnables, _ ->
            Enum.reject(runnables, fn r ->
              is_struct(r.node, Workflow.FanIn) and :atomics.get(gate, 1) == 0
            end)
          end,
          on_complete: fn r, _, _ ->
            if r.node.name == :item, do: send(observer, {:accepted, r.input_fact.value})
          end
        ]
      )

    :ok =
      Runner.run(runner, :concurrent, [[:bad], [2]],
        scheduler_policies: [{:item, %{on_failure: :skip}}]
      )

    tasks =
      for _ <- 1..2 do
        assert_receive {:member, pid, value}, 2000
        {value, pid}
      end

    good_pid = Map.fetch!(Map.new(tasks), 2)
    send(good_pid, :release)
    assert_receive {:accepted, 2}, 2000
    bad_pid = Map.fetch!(Map.new(tasks), :bad)
    :atomics.put(gate, 1, 1)
    send(bad_pid, :release)
    wait_idle(worker)
    {:ok, completed} = Runner.get_workflow(runner, :concurrent)
    assert_nested_result(completed, outer)
    :ok = Runner.stop(runner, :concurrent)
    {:ok, _} = Runner.resume(runner, :concurrent)
    {:ok, restored} = Runner.get_workflow(runner, :concurrent)
    assert_nested_result(restored, outer)
  end

  for timing <- [:before, :after] do
    @tag timing: timing
    test "wrapped #{timing} hook failures collect and replay", ctx do
      item = Custom.new(:item, :data)

      workflow =
        Workflow.new()
        |> Workflow.add(Runic.batch(item, name: :batch))
        |> Workflow.add(Custom.new(:output, :data), to: :batch)
        |> Workflow.enable_event_emission()

      field = if ctx.timing == :before, do: :before_hooks, else: :after_hooks
      workflow = Map.put(workflow, field, %{item.hash => [fn _, _ -> raise "hook failed" end]})

      {completed, execution} =
        Workflow.execute(workflow, [1], scheduler_policies: [{:item, %{on_failure: :skip}}])

      assert execution.admission == :open

      assert [
               %{
                 outcomes: [
                   %{
                     status: :skipped,
                     error: {:hook_error, {:hook_exception, %RuntimeError{}, _}}
                   }
                 ]
               }
             ] = Workflow.raw_productions(completed, :output)

      assert Workflow.raw_productions(replay(completed), :output) ==
               Workflow.raw_productions(completed, :output)
    end
  end

  test "nested exceptions project strictly and opaque or live fields remain rejected" do
    alias Runic.Workflow.Batch.Outcome
    id = Runic.Identity.derive(:fact_occurrence, [:item])
    base = %Outcome{id: id, batch_id: id, index: 0, status: :skipped}

    error =
      {:hook_error,
       {:hook_exception, %RuntimeError{message: "nested"},
        [extra: %{error: %ArgumentError{message: "inner"}}]}}

    digest = Runic.Identity.project(:payload, %{base | error: error})
    assert digest == Runic.Identity.project(:payload, %{base | error: error})

    for unsupported <- [
          self(),
          make_ref(),
          fn -> :ok end,
          Custom.new(:opaque),
          %{__exception__: true, module: :fake, field: self()}
        ] do
      assert_raise Runic.Identity.CanonicalError, fn ->
        Runic.Identity.project(:payload, %{base | error: {:hook_error, unsupported}})
      end
    end
  end

  test "ownership checks reject reverse additions, links and workflow merge" do
    member = Custom.new(:item, :data)
    one = Runic.batch(member, name: :one)
    two = Runic.batch(member, name: :two)
    first = Workflow.new() |> Workflow.add(one)
    assert_raise ArgumentError, fn -> Workflow.add(first, member) end

    assert_raise ArgumentError, fn ->
      Workflow.add(Workflow.new() |> Workflow.add(member), one)
    end

    assert_raise ArgumentError, fn ->
      Workflow.add(first, Custom.new(:outside, :data), to: :item)
    end

    assert_raise ArgumentError, ~r/batch member nodes/, fn ->
      Workflow.add(first, Runic.step(fn value -> value end, name: :outside),
        connections: [[from: {:item, :out}, to: :in]]
      )
    end

    second = Workflow.new() |> Workflow.add(two)
    assert_raise ArgumentError, fn -> Workflow.merge(first, second) end
    assert_raise ArgumentError, fn -> Workflow.add(first, second) end
    invalid = Workflow.add_step(first, Workflow.root(), member)
    assert_raise ArgumentError, fn -> Workflow.execute(invalid, [1, 2]) end
    linked = Workflow.draw_connection(first, member, Custom.new(:outside), :flow)
    assert_raise ArgumentError, fn -> Workflow.prepare_for_dispatch(linked) end
  end

  for policy <- [:skip, :halt] do
    @tag policy: policy
    test "a terminal nested boundary has an outer #{policy} outcome and replay", ctx do
      inner = Runic.batch(Custom.new(:item, :data), name: :inner)
      outer = Runic.batch(inner, name: :outer)

      workflow =
        Workflow.new()
        |> Workflow.add(outer)
        |> Workflow.add(Custom.new(:output, :data), to: :outer)
        |> Workflow.enable_event_emission()

      workflow = workflow |> Workflow.plan_eagerly([[1], :invalid, [2]]) |> apply_ready()
      {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)
      invalid = Enum.find(runnables, &(&1.input_fact.value == :invalid))

      terminal =
        Workflow.PolicyDriver.execute(invalid, %Workflow.SchedulerPolicy{on_failure: ctx.policy})

      workflow = Workflow.apply_runnable(workflow, terminal)
      [id] = Batch.invocations(workflow, outer)
      assert {:ok, outcomes} = Batch.outcomes(workflow, outer, id)
      assert Enum.at(outcomes, 1).status == if(ctx.policy == :skip, do: :skipped, else: :failed)
      assert Enum.at(outcomes, 1).error.__struct__ == ArgumentError
      assert {:ok, restored} = Batch.outcomes(replay(workflow), outer, id)
      assert Enum.at(restored, 1) == Enum.at(outcomes, 1)

      if ctx.policy == :skip do
        completed =
          Workflow.react_until_satisfied(workflow, nil,
            scheduler_policies: [{:default, %{on_failure: :skip}}]
          )

        assert [%{outcomes: results}] = Workflow.raw_productions(completed, :output)
        assert Enum.map(results, & &1.status) == [:completed, :skipped, :completed]
      end

      {_, observed} =
        Workflow.execute(Workflow.new() |> Workflow.add(outer), [[1], :invalid, [2]],
          scheduler_policies: [{:default, %{on_failure: ctx.policy}}]
        )

      assert observed.admission == if(ctx.policy == :skip, do: :open, else: :stopped)
    end
  end

  test "fallback values collect as completed batch outcomes" do
    batch = Runic.batch(Custom.new(:item, :failure, :unavailable), name: :batch)

    workflow =
      Workflow.new()
      |> Workflow.add(batch)
      |> Workflow.add(Custom.new(:output, :data), to: :batch)

    {completed, _} =
      Workflow.execute(workflow, [1, 2],
        scheduler_policies: [{:item, %{fallback: fn _, _ -> {:value, {:error, :data}} end}}]
      )

    assert [%{outcomes: outcomes}] = Workflow.raw_productions(completed, :output)
    assert Enum.map(outcomes, & &1.status) == [:completed, :completed]
    assert Enum.map(outcomes, & &1.value) == [{:error, :data}, {:error, :data}]
  end

  test "outer observation is uncertain when an inner native Task is lost" do
    runner = runner()

    item =
      Runic.step(
        fn value ->
          send(context(:observer), {:item_ran, value})

          if value == 2 and context(:block) do
            send(context(:observer), {:blocked, self()})
            receive do: (:release -> :ok)
          end

          value
        end,
        name: :item
      )

    inner = Runic.batch(item, name: :inner)
    outer = Runic.batch(inner, name: :outer)

    workflow =
      Workflow.new()
      |> Workflow.add(outer)
      |> Workflow.put_run_context(%{_global: %{observer: self(), block: true}})

    observer = self()

    {:ok, _} =
      Runner.start_workflow(runner, :loss, workflow,
        max_concurrency: 1,
        hooks: [
          transform_runnables: fn runnables, _ ->
            Enum.sort_by(runnables, fn r ->
              cond do
                is_struct(r.node, Workflow.FanOut) -> 0
                r.node.name == :item -> r.input_fact.value
                true -> 10
              end
            end)
          end,
          on_complete: fn r, _, _ ->
            if r.node.name == :item, do: send(observer, {:item_accepted, r.input_fact.value})
          end
        ]
      )

    {:ok, id} = Runner.start_execution(runner, :loss, [[1, 2], [3]])
    assert_receive {:item_ran, 1}, 2000
    assert_receive {:item_accepted, 1}, 2000
    assert_receive {:blocked, pid}, 2000
    assert_receive {:item_ran, 2}, 2000
    Process.exit(pid, :kill)
    assert {:ok, execution} = Runner.await_execution(runner, :loss, id)
    assert execution.admission == :stopped
    {:ok, completed} = Runner.get_workflow(runner, :loss)
    assert Workflow.raw_productions(completed, :item) == [1]
    [batch_id] = Batch.invocations(completed, outer)
    assert {:ok, outcomes} = Batch.outcomes(completed, outer, batch_id)
    assert Enum.map(outcomes, & &1.status) == [:uncertain, :pending]

    inner_observations =
      for inner_id <- Batch.invocations(completed, inner) do
        {:ok, observations} = Batch.outcomes(completed, inner, inner_id)
        observations
      end

    assert Enum.any?(inner_observations, fn items ->
             Enum.map(items, & &1.status) == [:completed, :uncertain]
           end)

    refute Enum.any?(Workflow.event_log(completed), &match?(%Workflow.RunnableFailed{}, &1))
    {:ok, replayed} = completed |> Runner.encode_snapshot() |> Runner.decode_snapshot()
    assert {:ok, replay_outcomes} = Batch.outcomes(replayed, outer, batch_id)
    assert Enum.map(replay_outcomes, & &1.status) == [:uncertain, :pending]
    :ok = Runner.stop(runner, :loss)

    {:ok, worker} =
      Runner.resume(runner, :loss, run_context: %{_global: %{observer: self(), block: false}})

    wait_idle(worker)
    {:ok, recovered} = Runner.get_workflow(runner, :loss)
    assert Enum.sort(Workflow.raw_productions(recovered, :item)) == [1, 2, 3]
    {:ok, recovered_outcomes} = Batch.outcomes(recovered, outer, batch_id)
    assert Enum.map(recovered_outcomes, & &1.status) == [:completed, :completed]
    assert_received {:item_ran, 2}
    assert_received {:item_ran, 3}
    refute_received {:item_ran, 1}
  end

  for store <- [Runic.Runner.Store.ETS, Runic.TestSupport.SnapshotTailStore] do
    @tag store: store
    test "nested Batch.Terminal recovery retains the accepted skipped outer item with #{store}",
         ctx do
      runner = runner(ctx.store)
      _ = Runner.get_store(runner)
      inner = Runic.batch(Custom.new(:item, :data), name: :inner)
      outer = Runic.batch(inner, name: :outer)

      workflow =
        Workflow.new()
        |> Workflow.add(outer)
        |> Workflow.add(Custom.new(:output, :data), to: :outer)
        |> Workflow.put_run_context(%{_global: %{observer: self()}})

      {:ok, worker} =
        Runner.start_workflow(runner, :recovery, workflow,
          executor: :inline,
          dispatch_mode: :manual
        )

      :ok =
        Runner.run(runner, :recovery, [:invalid, [2]],
          scheduler_policies: [{:default, %{on_failure: :skip}}]
        )

      :sys.get_state(worker)
      :ok = Runner.step(runner, :recovery)
      :ok = Runner.checkpoint(runner, :recovery)
      {store_mod, store_state} = Runner.get_store(runner)

      if ctx.store == Runic.TestSupport.SnapshotTailStore do
        {:ok, snapshot_base} = Runner.get_workflow(runner, :recovery)
        {:ok, %{event_cursor: cursor}} = Runner.persistence_status(runner, :recovery)

        :ok =
          store_mod.save_snapshot(
            :recovery,
            cursor,
            Runner.encode_snapshot(snapshot_base),
            store_state
          )
      end

      {:ok, current} = Runner.get_workflow(runner, :recovery)
      [batch_id] = Batch.invocations(current, outer)

      step_until(runner, :recovery, fn workflow ->
        {:ok, outcomes} = Batch.outcomes(workflow, outer, batch_id)
        Enum.at(outcomes, 0).status == :skipped
      end)

      :ok = Runner.checkpoint(runner, :recovery)
      {:ok, events} = store_mod.stream(:recovery, store_state)
      assert Enum.count(events, &match?(%Batch.Terminal{}, &1)) == 1
      :ok = Runner.stop(runner, :recovery)

      {:ok, worker} =
        Runner.resume(runner, :recovery,
          executor: :inline,
          run_context: %{_global: %{observer: self()}},
          scheduler_policies: [{:default, %{on_failure: :skip}}]
        )

      wait_idle(worker)
      {:ok, completed} = Runner.get_workflow(runner, :recovery)
      assert [%{outcomes: results}] = Workflow.raw_productions(completed, :output)
      assert Enum.map(results, & &1.status) == [:skipped, :completed]
      assert {:ok, ^results} = Batch.outcomes(completed, outer, batch_id)
      {:ok, final_events} = store_mod.stream(:recovery, store_state)
      assert Enum.count(final_events, &match?(%Batch.Terminal{}, &1)) == 1

      if ctx.store == Runic.TestSupport.SnapshotTailStore do
        assert Runic.TestSupport.SnapshotTailStore.call_count(
                 store_state,
                 {:stream, :recovery, :after_cursor}
               ) == 1
      end
    end
  end

  defp runner(store \\ Runic.Runner.Store.ETS) do
    name = :"batch_contract_#{System.unique_integer([:positive])}"

    if store == Runic.Runner.Store.ETS do
      start_supervised!({Runner, name: name})
    else
      start_supervised!({Runner, name: name, store: store})
    end

    name
  end

  defp nested_workflow do
    item =
      Runic.step(fn value -> if value == :bad, do: raise("bad item"), else: value end,
        name: :item
      )

    outer = Runic.batch(Runic.batch(item, name: :inner), name: :outer)

    {Workflow.new()
     |> Workflow.add(outer)
     |> Workflow.add(Custom.new(:output, :data), to: :outer), outer}
  end

  defp apply_ready(workflow) do
    {workflow, ready} = Workflow.prepare_for_dispatch(workflow)

    Enum.reduce(ready, workflow, fn runnable, wf ->
      Workflow.apply_runnable(wf, Workflow.execute_runnable(runnable))
    end)
  end

  defp replay(workflow),
    do:
      Workflow.from_events(
        Workflow.build_log(workflow) ++ Enum.reverse(workflow.uncommitted_events)
      )

  defp assert_nested_result(workflow, _outer) do
    assert [%{outcomes: [%{value: bad}, %{value: good}]}] =
             Workflow.raw_productions(workflow, :output)

    assert Enum.map(bad.outcomes, & &1.status) == [:skipped]
    assert Enum.map(good.outcomes, & &1.value) == [2]
  end

  defp step_until(runner, id, predicate, tries \\ 8)
  defp step_until(_runner, _id, _predicate, 0), do: flunk("terminal outcome was not accepted")

  defp step_until(runner, id, predicate, tries) do
    {:ok, workflow} = Runner.get_workflow(runner, id)

    unless predicate.(workflow) do
      assert :ok = Runner.step(runner, id)
      step_until(runner, id, predicate, tries - 1)
    end
  end

  defp wait_idle(worker, tries \\ 200)
  defp wait_idle(_worker, 0), do: flunk("worker did not become idle")

  defp wait_idle(worker, tries) do
    if :sys.get_state(worker).status == :idle,
      do: :ok,
      else:
        (
          Process.sleep(5)
          wait_idle(worker, tries - 1)
        )
  end
end
