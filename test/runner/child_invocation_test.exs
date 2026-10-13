defmodule Runic.Runner.ChildInvocationTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  require Runic
  alias Runic.{Runner, Workflow}
  alias Runic.Workflow.{Call, ChildInvocation, Execution}
  alias Runic.Workflow.ChildInvocation.Occurrence
  alias Runic.TestSupport.{ChildTargets, FailingStore, OrdinaryComponent, ReleasingExecutor}

  setup do
    runner = :"child_call_#{System.unique_integer([:positive])}"
    store = start_supervised!(FailingStore)
    start_supervised!({Runner, name: runner, store: FailingStore, store_opts: [agent: store]})
    %{runner: runner, store: store}
  end

  defp simple do
    request =
      Runic.step(
        fn x ->
          ChildInvocation.new(target: OrdinaryComponent.new(:target, :add, 1), input: x)
        end,
        name: :request
      )

    Workflow.new() |> Workflow.add(Call.new(request, name: :call))
  end

  test "native cancellation before attachment leaves no child task", %{runner: runner} do
    request =
      Runic.step(
        fn _ ->
          Process.flag(:trap_exit, true)
          send(context(:observer), {:request_started, self()})
          receive do: (:release -> raise "must be cancelled")
        end,
        name: :request
      )

    workflow =
      Workflow.new()
      |> Workflow.add(Call.new(request, name: :call))
      |> Workflow.put_run_context(%{call: %{observer: self()}})

    {:ok, worker} = Runner.start_workflow(runner, :wf, workflow, owner: self())
    :ok = Runner.run(runner, :wf, 3)
    assert_receive {:request_started, task}, 1_000
    ref = Process.monitor(task)
    {:ok, pending} = Runner.get_workflow(runner, :wf)
    refute Enum.any?(Multigraph.vertices(pending.graph), &is_struct(&1, Occurrence))
    assert :ok = Runner.cancel(runner, :wf)
    assert_receive {:DOWN, ^ref, :process, ^task, _}, 1_000
    refute Process.alive?(worker)
    refute Process.alive?(task)
  end

  test "native cancellation during child execution stops a task that traps exits", %{
    runner: runner
  } do
    request =
      Runic.step(fn x -> ChildInvocation.new(target: ChildTargets.blocked(), input: x) end,
        name: :request
      )

    workflow =
      Workflow.new()
      |> Workflow.add(Call.new(request, name: :call))
      |> Workflow.put_run_context(%{target: %{observer: self()}})

    {:ok, worker} = Runner.start_workflow(runner, :wf, workflow, owner: self())
    :ok = Runner.run(runner, :wf, 3)
    assert_receive {:child_started, task}, 1_000
    ref = Process.monitor(task)
    assert :ok = Runner.checkpoint(runner, :wf)
    assert :ok = Runner.cancel(runner, :wf)
    assert_receive {:DOWN, ^ref, :process, ^task, _}, 1_000
    refute Process.alive?(worker)
    refute Process.alive?(task)
    # Replay reconstructs attachment and pending work; it does not promise that
    # the cancelled external attempt had no effects.
    {:ok, worker} =
      Runner.resume(runner, :wf, owner: self(), run_context: %{target: %{observer: self()}})

    assert_receive {:child_started, resumed_task}, 1_000
    refute resumed_task == task
    send(resumed_task, :release)
    assert :ok = Runner.stop(runner, :wf)
    refute Process.alive?(worker)
  end

  test "child output is accepted separately from failed Store acknowledgement", ctx do
    {:ok, worker} =
      Runner.start_workflow(ctx.runner, :wf, simple(),
        executor: ReleasingExecutor,
        executor_opts: [test_pid: self(), outcome: :deferred]
      )

    {:ok, id} = Runner.start_execution(ctx.runner, :wf, 3)
    # Accept the request, initializer, target, and binder. Hold public return.
    for _ <- 1..4, do: accept_next(worker)
    assert_receive {:executor_result, ^worker, handle, result}, 1_000
    FailingStore.fail(ctx.store, :append)
    send(worker, {handle, result})
    assert_receive {:executor_released, ^handle}, 1_000
    :sys.get_state(worker)
    {:ok, snapshot} = Runner.execution(ctx.runner, :wf, id)
    assert snapshot.persistence.status == {:error, {:persistence_failed, :storage_unavailable}}
    assert Execution.outputs(snapshot) != []
    assert {:error, {:persistence_failed, :storage_unavailable}} = Runner.stop(ctx.runner, :wf)
    assert Process.alive?(worker)
    FailingStore.recover(ctx.store)
    # Finish public output and then stop/resume. Accepted child work does not repeat.
    drain(worker, 1)
    assert :ok = Runner.checkpoint(ctx.runner, :wf)
    assert :ok = Runner.stop(ctx.runner, :wf)
    {:ok, _} = Runner.resume(ctx.runner, :wf)
    {:ok, restored} = Runner.get_workflow(ctx.runner, :wf)
    assert Workflow.raw_productions(restored, :call) == [4]
    refute Workflow.is_runnable?(restored)
  end

  test "resume uses fresh target context after an admitted child result was not accepted", ctx do
    request =
      Runic.step(fn x -> ChildInvocation.new(target: ChildTargets.contextual(), input: x) end,
        name: :request
      )

    workflow =
      Workflow.new()
      |> Workflow.add(Call.new(request, name: :call))
      |> Workflow.put_run_context(%{target: %{offset: 1}})

    {:ok, worker} =
      Runner.start_workflow(ctx.runner, :wf, workflow,
        executor: ReleasingExecutor,
        executor_opts: [test_pid: self(), outcome: :deferred]
      )

    :ok = Runner.run(ctx.runner, :wf, 3)
    accept_next(worker)
    accept_next(worker)
    assert_receive {:executor_result, ^worker, _handle, _target_result}, 1_000
    assert :ok = Runner.stop(ctx.runner, :wf)

    {:ok, _} =
      Runner.resume(ctx.runner, :wf, executor: :inline, run_context: %{target: %{offset: 9}})

    {:ok, restored} = Runner.get_workflow(ctx.runner, :wf)
    assert Workflow.raw_productions(restored, :call) == [12]
  end

  test "failure uses parent policy and a new execution can reuse the graph", %{runner: runner} do
    request =
      Runic.step(
        fn x ->
          target =
            if x < 0,
              do: OrdinaryComponent.new(:target, :failure, :bad),
              else: OrdinaryComponent.new(:target, :add, 1)

          ChildInvocation.new(target: target, input: x)
        end,
        name: :request
      )

    workflow = Workflow.new() |> Workflow.add(Call.new(request, name: :call))
    {:ok, _} = Runner.start_workflow(runner, :wf, workflow)
    {:ok, first} = Runner.start_execution(runner, :wf, -1)
    {:ok, failed} = Runner.await_execution(runner, :wf, first)
    assert failed.admission == :stopped
    assert [%{error: :bad}] = failed.failures
    assert :ok = Runner.continue(runner, :wf)
    {:ok, second} = Runner.start_execution(runner, :wf, 3)
    {:ok, completed} = Runner.await_execution(runner, :wf, second)
    assert completed.admission == :open
    {:ok, result} = Runner.get_workflow(runner, :wf)
    assert Workflow.raw_productions(result, :call) == [4]
  end

  test "ChainBatching cannot treat the Call placeholder edge as completed output", %{
    runner: runner
  } do
    {:ok, _} =
      Runner.start_workflow(runner, :wf, simple(),
        scheduler: Runic.Runner.Scheduler.ChainBatching
      )

    {:ok, id} = Runner.start_execution(runner, :wf, 3)
    {:ok, completed} = Runner.await_execution(runner, :wf, id)
    assert completed.quiescent?
    {:ok, result} = Runner.get_workflow(runner, :wf)
    assert Workflow.raw_productions(result, :call) == [4]
  end

  test "target retry policies keep the target name", %{runner: runner} do
    request =
      Runic.step(
        fn x ->
          ChildInvocation.new(target: OrdinaryComponent.new(:target, :retry, 1), input: x)
        end,
        name: :request
      )

    workflow = Workflow.new() |> Workflow.add(Call.new(request, name: :call))
    {:ok, _} = Runner.start_workflow(runner, :wf, workflow)

    {:ok, id} =
      Runner.start_execution(runner, :wf, 3, scheduler_policies: [{:target, %{max_retries: 1}}])

    {:ok, completed} = Runner.await_execution(runner, :wf, id)
    assert completed.quiescent?
    assert Enum.any?(completed.outcomes, &(&1.node_name == :target and &1.kind == :completed))
    {:ok, result} = Runner.get_workflow(runner, :wf)
    assert Workflow.raw_productions(result, :call) == [3]
  end

  test "equal executions have separate child identities and cancel after completion preserves output",
       %{runner: runner} do
    {:ok, _} = Runner.start_workflow(runner, :wf, simple(), owner: self())

    for _ <- 1..2 do
      {:ok, id} = Runner.start_execution(runner, :wf, 3)
      {:ok, completed} = Runner.await_execution(runner, :wf, id)
      assert completed.persistence.status == :saved
    end

    {:ok, result} = Runner.get_workflow(runner, :wf)
    assert Workflow.raw_productions(result, :call) == [4, 4]
    children = Enum.filter(Multigraph.vertices(result.graph), &is_struct(&1, Occurrence))
    assert length(Enum.uniq_by(children, & &1.hash)) == 2
    assert Map.keys(Workflow.results(result)) == [:call]
    assert :ok = Runner.cancel(runner, :wf)
    {:ok, _} = Runner.resume(runner, :wf)
    {:ok, restored} = Runner.get_workflow(runner, :wf)
    assert Workflow.raw_productions(restored, :call) == [4, 4]
    refute Workflow.is_runnable?(restored)
  end

  test "target timeout stops native child work and propagates parent failure", %{runner: runner} do
    request =
      Runic.step(fn x -> ChildInvocation.new(target: ChildTargets.blocked(), input: x) end,
        name: :request
      )

    workflow =
      Workflow.new()
      |> Workflow.add(Call.new(request, name: :call))
      |> Workflow.put_run_context(%{target: %{observer: self()}})

    {:ok, _} = Runner.start_workflow(runner, :wf, workflow)

    {:ok, id} =
      Runner.start_execution(runner, :wf, 3, scheduler_policies: [{:target, %{timeout_ms: 50}}])

    assert_receive {:child_started, task}, 1_000
    ref = Process.monitor(task)
    {:ok, failed} = Runner.await_execution(runner, :wf, id)
    assert failed.admission == :stopped
    assert [%{error: {:timeout, 50}}] = failed.failures
    assert_receive {:DOWN, ^ref, :process, ^task, _}, 1_000
    {:ok, result} = Runner.get_workflow(runner, :wf)
    assert Workflow.raw_productions(result, :call) == []
  end

  test "request fallback data uses the completion port without a child", %{runner: runner} do
    request = Runic.step(fn _ -> raise "request failed" end, name: :request)

    workflow =
      Workflow.new()
      |> Workflow.add(Call.new(request, name: :call))
      |> Workflow.set_scheduler_policies([
        {:call, %{fallback: fn _, _ -> {:value, :replacement} end}}
      ])

    {:ok, _} = Runner.start_workflow(runner, :wf, workflow)
    {:ok, id} = Runner.start_execution(runner, :wf, 3)
    {:ok, completed} = Runner.await_execution(runner, :wf, id)
    assert completed.quiescent?
    {:ok, result} = Runner.get_workflow(runner, :wf)
    assert Workflow.raw_productions(result, :call) == [:replacement]
    refute Enum.any?(Multigraph.vertices(result.graph), &is_struct(&1, Occurrence))
  end

  test "a checkpoint in a child pipeline retains accepted work and replaces runtime context",
       ctx do
    request =
      Runic.step(
        fn input ->
          target =
            Workflow.new(
              name: :pipeline,
              input_ports: [in: []],
              output_ports: [out: [from: :second]]
            )
            |> Workflow.add(OrdinaryComponent.new(:first, :add, 1))
            |> Workflow.add(OrdinaryComponent.new(:second, :add, 1), to: :first)

          ChildInvocation.new(target: target, input: input)
        end,
        name: :request
      )

    workflow =
      Workflow.new()
      |> Workflow.add(Call.new(request, name: :call))
      |> Workflow.put_run_context(%{_global: %{observer: self(), offset: 1}})

    {:ok, worker} =
      Runner.start_workflow(ctx.runner, :wf, workflow,
        executor: ReleasingExecutor,
        executor_opts: [test_pid: self(), outcome: :deferred]
      )

    :ok = Runner.run(ctx.runner, :wf, 3)
    for _ <- 1..3, do: accept_next(worker)
    assert_receive {:work, :first, _}, 1_000
    assert_receive {:work, :second, _}, 1_000
    assert_receive {:executor_result, ^worker, _handle, _result}, 1_000
    assert :ok = Runner.checkpoint(ctx.runner, :wf)
    assert :ok = Runner.stop(ctx.runner, :wf)

    {:ok, _} =
      Runner.resume(ctx.runner, :wf,
        executor: :inline,
        run_context: %{_global: %{observer: self(), offset: 10}}
      )

    assert_receive {:work, :second, _}, 1_000
    refute_received {:work, :first, _}
    {:ok, restored} = Runner.get_workflow(ctx.runner, :wf)
    assert Workflow.raw_productions(restored, :call) == [16]
  end

  test "target skip suppresses return and survives replay", %{runner: runner} do
    request =
      Runic.step(
        fn x ->
          ChildInvocation.new(target: OrdinaryComponent.new(:target, :failure, :bad), input: x)
        end,
        name: :request
      )

    workflow = Workflow.new() |> Workflow.add(Call.new(request, name: :call))
    {:ok, _} = Runner.start_workflow(runner, :wf, workflow)

    {:ok, id} =
      Runner.start_execution(runner, :wf, 3,
        scheduler_policies: [{:target, %{on_failure: :skip}}]
      )

    {:ok, completed} = Runner.await_execution(runner, :wf, id)
    assert completed.admission == :open
    assert [%{kind: :skipped, error: :bad}] = completed.failures
    assert :ok = Runner.stop(runner, :wf)
    {:ok, _} = Runner.resume(runner, :wf)
    {:ok, restored} = Runner.get_workflow(runner, :wf)
    assert Workflow.raw_productions(restored, :call) == []
    refute Workflow.is_runnable?(restored)
  end

  test "request retry creates one occurrence with a stable activation identity", %{runner: runner} do
    request =
      Runic.step(
        fn input ->
          count = :atomics.add_get(context(:attempts), 1, 1)
          send(context(:observer), {:request_attempt, count})
          if count == 1, do: raise("retry request")
          ChildInvocation.new(target: OrdinaryComponent.new(:target, :add, 1), input: input)
        end,
        name: :request
      )

    base =
      Workflow.new()
      |> Workflow.add(Call.new(request, name: :call))
      |> Workflow.put_run_context(%{call: %{observer: self(), attempts: :atomics.new(1, [])}})

    {:ok, _} = Runner.start_workflow(runner, :wf, base)

    {:ok, id} =
      Runner.start_execution(runner, :wf, 3, scheduler_policies: [{:call, %{max_retries: 1}}])

    {:ok, execution} = Runner.await_execution(runner, :wf, id, 10_000)
    assert_receive {:request_attempt, 1}
    assert_receive {:request_attempt, 2}
    {:ok, result} = Runner.get_workflow(runner, :wf)
    assert Workflow.raw_productions(result, :call) == [4]
    [child] = Enum.filter(Multigraph.vertices(result.graph), &is_struct(&1, Occurrence))
    outcome = Enum.find(execution.outcomes, &(&1.node_name == :call))
    assert outcome.attempt_id == Runic.Identity.derive(:attempt, [outcome.activation_id, 1])
    assert child.hash == Runic.Identity.derive(:node_occurrence, [outcome.activation_id, :child])
  end

  test "a ChildInvocation-valued request fallback has the same replayable attachment path", %{
    runner: runner
  } do
    request = Runic.step(fn _ -> raise "request failed" end, name: :request)
    base = Workflow.new() |> Workflow.add(Call.new(request, name: :call))
    {:ok, _} = Runner.start_workflow(runner, :wf, base)

    fallback = fn runnable, _ ->
      {:value,
       ChildInvocation.new(
         target: OrdinaryComponent.new(:target, :add, 1),
         input: runnable.input_fact.value
       )}
    end

    {:ok, id} =
      Runner.start_execution(runner, :wf, 3, scheduler_policies: [{:call, %{fallback: fallback}}])

    {:ok, completed} = Runner.await_execution(runner, :wf, id)
    assert completed.quiescent?
    {:ok, result} = Runner.get_workflow(runner, :wf)
    assert Workflow.raw_productions(result, :call) == [4]
    assert :ok = Runner.stop(runner, :wf)
    {:ok, _} = Runner.resume(runner, :wf)
    {:ok, restored} = Runner.get_workflow(runner, :wf)
    assert Workflow.raw_productions(restored, :call) == [4]
    assert Enum.count(Multigraph.vertices(restored.graph), &is_struct(&1, Occurrence)) == 1
    assert not Workflow.is_runnable?(restored)
  end

  defp accept_next(worker) do
    assert_receive {:executor_result, ^worker, handle, result}, 1_000
    send(worker, {handle, result})
    assert_receive {:executor_released, ^handle}, 1_000
    :sys.get_state(worker)
  end

  defp drain(_, 0), do: :ok

  defp drain(worker, count) do
    accept_next(worker)
    drain(worker, count - 1)
  end
end
