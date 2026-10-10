defmodule Runic.Runner.ExecutionObservationTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  require Runic

  alias Runic.{Runner, Workflow}
  alias Runic.TestSupport.{FailingStore, ReleasingExecutor}
  alias Runic.Workflow.Execution

  setup do
    runner = :"execution_observation_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner})
    %{runner: runner}
  end

  test "managed success has immediate parity and durable acknowledgement", %{runner: runner} do
    workflow =
      Runic.workflow(
        steps: [
          {Runic.step(&(&1 + 1), name: :add), [Runic.step(&(&1 * 2), name: :double)]}
        ]
      )

    {:ok, _pid} = Runner.start_workflow(runner, :success, workflow, executor: :inline)
    {:ok, execution_id} = Runner.start_execution(runner, :success, 2)
    {:ok, execution} = Runner.await_execution(runner, :success, execution_id)

    assert execution.status == :quiescent
    assert execution.quiescent?
    assert Execution.outputs(execution) == [3, 6]
    assert execution.persistence.status == :saved
    assert execution.persistence.pending_events == 0
  end

  test "managed repeated inputs keep distinct stable observations", %{runner: runner} do
    workflow = Runic.workflow(steps: [Runic.step(& &1, name: :echo)])
    {:ok, _pid} = Runner.start_workflow(runner, :repeated, workflow, executor: :inline)

    {:ok, first_id} = Runner.start_execution(runner, :repeated, :same)
    {:ok, first} = Runner.await_execution(runner, :repeated, first_id)
    {:ok, second_id} = Runner.start_execution(runner, :repeated, :same)
    {:ok, second} = Runner.await_execution(runner, :repeated, second_id)
    {:ok, retained_first} = Runner.execution(runner, :repeated, first_id)

    refute first_id == second_id
    refute first.input_id == second.input_id
    refute first.input_fact_id == second.input_fact_id
    refute hd(first.outcomes).id == hd(second.outcomes).id
    assert retained_first.id == first.id
    assert retained_first.outcomes == first.outcomes
    assert retained_first.persistence == first.persistence
    assert Execution.outputs(first) == [:same]
    assert Execution.outputs(second) == [:same]

    assert :ok = Runner.forget_execution(runner, :repeated, first_id)
    assert {:error, :not_found} = Runner.execution(runner, :repeated, first_id)
  end

  test "managed execution accepts a caller correlation identity once", %{runner: runner} do
    workflow = Runic.workflow(steps: [Runic.step(& &1, name: :echo)])
    {:ok, _pid} = Runner.start_workflow(runner, :correlated, workflow, executor: :inline)
    execution_id = Runic.Identity.derive(:execution, [:customer_request, "request-123"])

    assert {:ok, ^execution_id} =
             Runner.start_execution(runner, :correlated, :value, execution_id: execution_id)

    assert {:ok, %{id: ^execution_id}} =
             Runner.await_execution(runner, :correlated, execution_id)

    assert {:error, :execution_exists} =
             Runner.start_execution(runner, :correlated, :value, execution_id: execution_id)
  end

  test "manual step is admission and ready work remains observable", %{runner: runner} do
    owner = self()

    workflow =
      Runic.workflow(
        steps: [
          Runic.step(
            fn value ->
              send(owner, {:started, self()})
              receive do: (:release -> value + 1)
            end,
            name: :blocked
          )
        ]
      )

    {:ok, _pid} =
      Runner.start_workflow(runner, :manual, workflow,
        dispatch_mode: :manual,
        max_concurrency: 1
      )

    {:ok, execution_id} = Runner.start_execution(runner, :manual, 1)

    assert {:ok, %{status: :ready, active: [], ready: [_], quiescent?: false}} =
             Runner.execution(runner, :manual, execution_id)

    assert :ok = Runner.step(runner, :manual)
    assert_receive {:started, task}, 1_000

    assert {:ok, %{status: :active, active: [_], outcomes: []}} =
             Runner.execution(runner, :manual, execution_id)

    assert {:error, :busy} = Runner.forget_execution(runner, :manual, execution_id)
    assert {:error, :timeout} = Runner.await_execution(runner, :manual, execution_id, 0)
    send(task, :release)
    assert {:ok, execution} = Runner.await_execution(runner, :manual, execution_id)
    assert Execution.outputs(execution) == [2]
  end

  test "actual completion order and stable selection order are both retained", %{runner: runner} do
    owner = self()

    steps =
      for name <- [:one, :two] do
        Runic.step(
          fn value ->
            send(owner, {:started, name, self()})
            receive do: (:release -> value)
          end,
          name: name
        )
      end

    {:ok, _pid} =
      Runner.start_workflow(runner, :order, Runic.workflow(steps: steps), max_concurrency: 2)

    {:ok, execution_id} = Runner.start_execution(runner, :order, 1)
    assert_receive {:started, first_name, first_pid}, 1_000
    assert_receive {:started, second_name, second_pid}, 1_000

    {:ok, active} = Runner.execution(runner, :order, execution_id)
    [first_key, second_key] = Enum.map(active.active, & &1.order_key)
    assert first_key < second_key

    pids = %{first_name => first_pid, second_name => second_pid}
    [stable_first, stable_second] = Enum.map(active.active, &hd(&1.node_names))

    # Release the later stable unit first. The Worker must keep this observed order.
    send(pids[stable_second], :release)

    assert_eventually(fn ->
      {:ok, scope} = Runner.execution(runner, :order, execution_id)
      length(scope.outcomes) == 1
    end)

    send(pids[stable_first], :release)
    {:ok, execution} = Runner.await_execution(runner, :order, execution_id)

    assert Enum.map(execution.outcomes, & &1.node_name) == [stable_second, stable_first]

    assert Enum.map(Execution.ordered_outcomes(execution, order: :stable), & &1.order_key) ==
             Enum.sort(Enum.map(execution.outcomes, & &1.order_key))
  end

  test "failure and outer executor loss are different outcomes", %{runner: runner} do
    failure = Runic.workflow(steps: [Runic.step(fn _ -> raise "failed" end, name: :failed)])
    {:ok, _pid} = Runner.start_workflow(runner, :failure, failure, executor: :inline)
    {:ok, failure_id} = Runner.start_execution(runner, :failure, 1)
    {:ok, failed} = Runner.await_execution(runner, :failure, failure_id)
    assert [%{kind: :failed, node_name: :failed}] = Execution.failures(failed)

    uncertain = Runic.workflow(steps: [Runic.step(& &1, name: :uncertain)])

    {:ok, _pid} =
      Runner.start_workflow(runner, :uncertain, uncertain,
        executor: ReleasingExecutor,
        executor_opts: [test_pid: self(), outcome: :crash]
      )

    {:ok, uncertain_id} = Runner.start_execution(runner, :uncertain, 1)
    {:ok, lost} = Runner.await_execution(runner, :uncertain, uncertain_id)

    assert [%{kind: :uncertain, node_name: :uncertain, error: :test_crash}] =
             Execution.failures(lost)

    assert lost.ready != []
    assert lost.outcomes |> hd() |> Map.get(:result) == nil
  end

  test "computed quiescence is separate from persistence failure and recovery" do
    runner = :"execution_persistence_#{System.unique_integer([:positive])}"

    store =
      start_supervised!(%{
        id: {FailingStore, runner},
        start: {FailingStore, :start_link, [[]]}
      })

    start_supervised!(%{
      id: {Runner, runner},
      start:
        {Runner, :start_link, [[name: runner, store: FailingStore, store_opts: [agent: store]]]}
    })

    workflow = Runic.workflow(steps: [Runic.step(&(&1 + 1), name: :value)])
    {:ok, _pid} = Runner.start_workflow(runner, :stored, workflow, executor: :inline)
    FailingStore.fail(store, :append)

    {:ok, execution_id} = Runner.start_execution(runner, :stored, 1)
    {:ok, execution} = Runner.await_execution(runner, :stored, execution_id)

    assert execution.quiescent?
    assert Execution.outputs(execution) == [2]

    assert match?(
             {:error, {:persistence_failed, :storage_unavailable}},
             execution.persistence.status
           )

    assert execution.persistence.pending_events > 0

    FailingStore.recover(store)
    assert :ok = Runner.checkpoint(runner, :stored)

    assert {:ok, %{persistence: %{status: :saved, pending_events: 0}}} =
             Runner.execution(runner, :stored, execution_id)
  end

  test "accepted Promise prefix is observed before its failure", %{runner: runner} do
    first = Runic.step(&(&1 + 1), name: :first)
    second = Runic.step(fn _ -> raise "stop" end, name: :second)
    third = Runic.step(&(&1 * 2), name: :third)

    workflow =
      Runic.workflow(steps: [{first, [{second, [third]}]}])
      |> Workflow.set_scheduler_policies([{:default, %{execution_mode: :durable}}])

    {:ok, worker} =
      Runner.start_workflow(runner, :promise, workflow,
        promise_opts: [min_chain_length: 2],
        executor: ReleasingExecutor,
        executor_opts: [test_pid: self(), outcome: :deferred]
      )

    {:ok, execution_id} = Runner.start_execution(runner, :promise, 1)

    assert_receive {:executor_result, ^worker, handle,
                    {:promise_partial, _, completed, _failed} = result},
                   1_000

    assert length(completed) == 1
    send(worker, {handle, result})

    {:ok, execution} = Runner.await_execution(runner, :promise, execution_id)
    assert Enum.map(execution.outcomes, & &1.kind) == [:completed, :failed]
    assert Execution.outputs(execution) == [2]
  end

  test "cancellation removes the process-local observation without a fabricated failure", %{
    runner: runner
  } do
    owner = self()

    workflow =
      Runic.workflow(
        steps: [
          Runic.step(
            fn value ->
              send(owner, :started)
              receive do: (:release -> value)
            end,
            name: :blocked
          )
        ]
      )

    {:ok, _pid} = Runner.start_workflow(runner, :cancelled, workflow)
    {:ok, execution_id} = Runner.start_execution(runner, :cancelled, 1)
    assert_receive :started, 1_000

    assert {:ok, %{status: :active, failures: []}} =
             Runner.execution(runner, :cancelled, execution_id)

    assert :ok = Runner.cancel(runner, :cancelled)
    assert {:error, :not_found} = Runner.execution(runner, :cancelled, execution_id)
  end

  defp assert_eventually(fun, attempts \\ 100)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      receive do
      after
        5 -> assert_eventually(fun, attempts - 1)
      end
    end
  end
end
