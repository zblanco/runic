defmodule Runic.FailureAdmissionTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  require Runic
  alias Runic.Workflow

  for outcome <- [:success, :failure] do
    test "async cleanup preserves a trapping caller's mailbox after #{outcome}" do
      observer = self()
      marker = make_ref()

      first =
        Runic.step(
          fn value ->
            if unquote(outcome) == :failure, do: raise("stop"), else: value + 1
          end,
          name: :first
        )

      child = Runic.step(fn value -> value + 1 end, name: :child)
      workflow = Runic.workflow(steps: [{first, [child]}])

      {caller, monitor} =
        spawn_monitor(fn ->
          Process.flag(:trap_exit, true)
          send(self(), {:keep, marker})
          send(self(), {:EXIT, observer, :normal})
          Workflow.react_until_satisfied(workflow, 1, async: true)

          send(
            observer,
            {:mailbox, self(), Process.info(self(), :messages), Process.info(self(), :trap_exit)}
          )
        end)

      assert_receive {:mailbox, ^caller, {:messages, messages}, {:trap_exit, true}}, 1_000
      assert Enum.sort(messages) == Enum.sort([{:keep, marker}, {:EXIT, observer, :normal}])
      assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 1_000
    end
  end

  test "an invalid custom task result is retained as uncertain without a mailbox leak" do
    observer = self()
    node = %Runic.Test.DispatchProbe{hash: 987_321, owner: observer, mode: :invalid_result}
    fact = Runic.Workflow.Fact.new(value: :input)
    workflow = Workflow.new()

    workflow = %{
      workflow
      | graph: Multigraph.add_edge(workflow.graph, fact, node, label: :runnable)
    }

    {caller, monitor} =
      spawn_monitor(fn ->
        result = Workflow.react(workflow, async: true)
        send(observer, {:invalid_result, self(), result, Process.info(self(), :messages)})
      end)

    assert_receive {:invalid_result, ^caller, result, {:messages, []}}, 1_000
    assert Workflow.is_runnable?(result)
    refute Enum.any?(result.runnable_events, &is_struct(&1, Workflow.RunnableFailed))
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 1_000
  end

  for async <- [false, true] do
    test "halt stops this evaluation and a later call can continue, async #{async}" do
      counter = :atomics.new(1, [])

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

      workflow = Runic.workflow(steps: steps)

      stopped =
        Workflow.react_until_satisfied(workflow, 1, async: unquote(async), max_concurrency: 1)

      assert :atomics.get(counter, 1) == 1
      assert Workflow.is_runnable?(stopped)

      resumed =
        Workflow.react_until_satisfied(stopped, nil, async: unquote(async), max_concurrency: 1)

      assert :atomics.get(counter, 1) == 3
      refute Workflow.is_runnable?(resumed)

      reused = Workflow.react_until_satisfied(resumed, 10)
      assert 11 in Workflow.raw_productions(reused)
    end
  end

  test "async failure stops new admission and retains active successful results" do
    owner = self()

    task =
      Task.async(fn ->
        Workflow.react_until_satisfied(blocking_workflow(owner), 1,
          async: true,
          max_concurrency: 2
        )
      end)

    assert_receive {:started, first}, 1_000
    assert_receive {:started, second}, 1_000
    monitor = Process.monitor(first)
    send(first, :fail)
    assert_receive {:DOWN, ^monitor, :process, ^first, :normal}, 1_000
    send(second, :complete)
    result = Task.await(task)
    assert 2 in Workflow.raw_productions(result)
    assert Workflow.is_runnable?(result)
    # Returning confirms that the admitted tasks and their scope have closed.
    refute_received {:started, _}
  end

  test "async admission follows each completion without waiting for the whole group" do
    owner = self()

    task =
      Task.async(fn ->
        Workflow.react_until_satisfied(blocking_workflow(owner), 1,
          async: true,
          max_concurrency: 2
        )
      end)

    assert_receive {:started, first}, 1_000
    assert_receive {:started, second}, 1_000
    send(first, :complete)
    assert_receive {:started, third}, 1_000
    send(third, :complete)
    send(second, :complete)
    refute Workflow.is_runnable?(Task.await(task))
  end

  test "replay retains a consumed failure without making the graph permanently halted" do
    counter = :atomics.new(1, [])

    step =
      Runic.step(
        fn value ->
          if :atomics.add_get(counter, 1, 1) == 1, do: raise("stop")
          value + 1
        end,
        name: :first
      )

    original = Runic.workflow(steps: [step]) |> Workflow.enable_event_emission()
    stopped = Workflow.react_until_satisfied(original, 1)
    restored = Workflow.from_events(Enum.reverse(stopped.uncommitted_events), original)
    refute Workflow.is_runnable?(restored)
    reused = Workflow.react_until_satisfied(restored, 10)
    assert :atomics.get(counter, 1) == 2
    assert Workflow.raw_productions(reused) == [11]
  end

  test "async outer loss returns retained work without fabricated node events" do
    step = Runic.step(fn _ -> Process.exit(self(), :kill) end, name: :killed)
    workflow = Runic.workflow(steps: [step]) |> Workflow.enable_event_emission()
    result = Workflow.react_until_satisfied(workflow, 1, async: true)
    assert Workflow.is_runnable?(result)
    refute Enum.any?(result.runnable_events, &is_struct(&1, Workflow.RunnableFailed))
    assert Workflow.raw_productions(result) == []
  end

  test "async outer timeout retains the activation for an explicit later call" do
    step =
      Runic.step(
        fn _ ->
          receive do
            :release -> :done
          end
        end,
        name: :blocked
      )

    workflow = Runic.workflow(steps: [step]) |> Workflow.enable_event_emission()
    result = Workflow.react_until_satisfied(workflow, 1, async: true, timeout: 10)
    assert Workflow.is_runnable?(result)
    refute Enum.any?(result.runnable_events, &is_struct(&1, Workflow.RunnableFailed))
    assert Workflow.raw_productions(result) == []
  end

  test "async outer timeout confirms trapped work is dead before returning uncertain state" do
    observer = self()

    step =
      Runic.step(
        fn _ ->
          Process.flag(:trap_exit, true)
          send(observer, {:held_for_timeout, self()})
          receive do: (:release -> :done)
        end,
        name: :held
      )

    workflow = Runic.workflow(steps: [step]) |> Workflow.enable_event_emission()

    caller =
      Task.async(fn -> Workflow.react_until_satisfied(workflow, 1, async: true, timeout: 100) end)

    assert_receive {:held_for_timeout, work}, 1_000
    ref = Process.monitor(work)
    on_exit(fn -> if Process.alive?(work), do: Process.exit(work, :kill) end)

    result = Task.await(caller)
    refute Process.alive?(work)
    assert_receive {:DOWN, ^ref, :process, ^work, _}, 1_000
    assert Workflow.is_runnable?(result)
    refute Enum.any?(result.runnable_events, &is_struct(&1, Workflow.RunnableFailed))
    assert Workflow.raw_productions(result) == []
  end

  defp blocking_workflow(owner) do
    steps =
      for name <- [:one, :two, :three] do
        Runic.step(
          fn value ->
            send(owner, {:started, self()})

            receive do
              :complete -> value + 1
              :fail -> raise "stop"
            end
          end,
          name: name
        )
      end

    Runic.workflow(steps: steps)
  end
end
