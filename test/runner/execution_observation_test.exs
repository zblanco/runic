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

    assert {:ok, %{quiescent?: true}} =
             Runner.await_execution(runner, :success, execution_id, 0)
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

  for mode <- [:halt, :skip, :custom_skip] do
    @tag terminal_handling: mode
    test "managed #{mode} outcomes match immediate terminal handling", %{
      runner: runner,
      terminal_handling: mode
    } do
      workflow =
        if mode == :custom_skip do
          node = %Runic.Test.SkippedNode{
            name: :custom_skip,
            hash: Runic.Identity.derive(:component_definition, [:custom_skip])
          }

          Workflow.new() |> Workflow.add_step(node)
        else
          Runic.workflow(steps: [Runic.step(fn _ -> raise "failure" end, name: :failed)])
          |> Workflow.set_scheduler_policies([{:default, %{on_failure: mode}}])
        end

      {_, immediate} = Workflow.execute(workflow, :input)
      {:ok, _} = Runner.start_workflow(runner, :terminal_handling, workflow)
      {:ok, id} = Runner.start_execution(runner, :terminal_handling, :input)
      {:ok, managed} = Runner.await_execution(runner, :terminal_handling, id)
      [immediate_outcome] = immediate.outcomes
      [managed_outcome] = managed.outcomes
      fields = [:kind, :node_name, :result, :failure_action]

      assert Map.take(managed_outcome, fields) == Map.take(immediate_outcome, fields)
      assert managed_outcome.kind == if(mode == :halt, do: :failed, else: :skipped)
      assert managed_outcome.failure_action == if(mode == :halt, do: :halt, else: :skip)
      assert is_nil(managed_outcome.error) == (mode == :custom_skip)
      assert managed.admission == immediate.admission
      assert managed.quiescent?
      assert Execution.outputs(managed) == []
    end
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

  test "invalid execution identities leave the Worker available", %{runner: runner} do
    workflow = Runic.workflow(steps: [Runic.step(& &1, name: :echo)])
    {:ok, worker} = Runner.start_workflow(runner, :invalid_identity, workflow, executor: :inline)

    for id <- [:invalid, Runic.Identity.derive(:input_command, [:invalid])] do
      assert {:error, %ArgumentError{}} =
               Runner.start_execution(runner, :invalid_identity, :value, execution_id: id)

      assert Runner.lookup(runner, :invalid_identity) == worker
      assert {:ok, []} = Runner.get_results(runner, :invalid_identity)
    end

    assert {:ok, id} = Runner.start_execution(runner, :invalid_identity, :value)
    assert {:ok, execution} = Runner.await_execution(runner, :invalid_identity, id)
    assert Execution.outputs(execution) == [:value]
  end

  test "invalid payloads preserve the Worker and retained executions", %{runner: runner} do
    workflow = Runic.workflow(steps: [Runic.step(& &1, name: :echo)])
    {:ok, worker} = Runner.start_workflow(runner, :invalid_payload, workflow, executor: :inline)
    {:ok, first_id} = Runner.start_execution(runner, :invalid_payload, :first)
    {:ok, _} = Runner.await_execution(runner, :invalid_payload, first_id)
    {:ok, second_id} = Runner.start_execution(runner, :invalid_payload, :second)
    {:ok, _} = Runner.await_execution(runner, :invalid_payload, second_id)
    {:ok, retained} = Runner.execution(runner, :invalid_payload, first_id)
    deep_input = Enum.reduce(1..65, :value, fn _, value -> [value] end)

    for input <- [
          %{reply_to: self()},
          make_ref(),
          fn -> :value end,
          deep_input,
          %Runic.Workflow.Fact{value: :value}
        ] do
      assert {:error, %Runic.Identity.CanonicalError{}} =
               Runner.start_execution(runner, :invalid_payload, input)

      assert Runner.lookup(runner, :invalid_payload) == worker
      assert {:ok, ^retained} = Runner.execution(runner, :invalid_payload, first_id)
      assert {:ok, current} = Runner.execution(runner, :invalid_payload, second_id)
      assert Execution.outputs(current) == [:second]
    end

    assert {:ok, id} = Runner.start_execution(runner, :invalid_payload, :third)
    assert {:ok, execution} = Runner.await_execution(runner, :invalid_payload, id)
    assert Execution.outputs(execution) == [:third]
  end

  for mode <- [:default, :override] do
    @tag inline_mode: mode
    test "start returns its generated ID before #{mode} inline work ends", %{
      runner: runner,
      inline_mode: mode
    } do
      observer = self()

      workflow =
        Runic.workflow(
          steps: [
            Runic.step(
              fn value ->
                send(observer, {:inline_started, self()})
                receive do: (:release -> value + 1)
              end,
              name: :blocked
            )
          ]
        )

      {workflow, opts} =
        if mode == :default,
          do: {workflow, [executor: :inline]},
          else:
            {Workflow.set_scheduler_policies(workflow, [{:blocked, %{executor: :inline}}]), []}

      {:ok, worker} = Runner.start_workflow(runner, :inline_admission, workflow, opts)
      caller = Task.async(fn -> Runner.start_execution(runner, :inline_admission, 1) end)
      assert_receive {:inline_started, ^worker}, 1_000

      try do
        assert {:ok, id} = Task.await(caller, 1_000)
        assert %Runic.Identity{domain: :execution} = id
        assert {:error, :timeout} = Runner.await_execution(runner, :inline_admission, id, 20)
        send(worker, :release)
        assert {:ok, execution} = Runner.await_execution(runner, :inline_admission, id)
        assert Execution.outputs(execution) == [2]
      after
        send(worker, :release)
      end
    end
  end

  test "start returns before a blocked Store write and completion callback" do
    runner = :"admission_persistence_#{System.unique_integer([:positive])}"
    store = start_supervised!(FailingStore)

    start_supervised!(%{
      id: {Runner, runner},
      start:
        {Runner, :start_link, [[name: runner, store: FailingStore, store_opts: [agent: store]]]}
    })

    observer = self()
    workflow = Runic.workflow(steps: [Runic.step(&(&1 + 1), name: :increment)])

    {:ok, worker} =
      Runner.start_workflow(runner, :blocked_store, workflow,
        executor: :inline,
        on_complete: fn _, _ -> send(observer, :completed) end
      )

    :ok = :sys.suspend(store)
    on_exit(fn -> if Process.alive?(store), do: :sys.resume(store) end)
    caller = Task.async(fn -> Runner.start_execution(runner, :blocked_store, 1) end)

    try do
      assert {:ok, id} = Task.await(caller, 1_000)

      assert_eventually(fn ->
        {:messages, messages} = Process.info(store, :messages)
        Enum.any?(messages, &match?({:"$gen_call", {^worker, _}, _}, &1))
      end)

      refute_received :completed
      :ok = :sys.resume(store)
      assert_receive :completed, 1_000
      assert {:ok, execution} = Runner.await_execution(runner, :blocked_store, id)
      assert execution.persistence.status == :saved
      assert Execution.outputs(execution) == [2]
    after
      if Process.alive?(store), do: :sys.resume(store)
    end
  end

  test "completion callback faults do not restore state from before admission", %{runner: runner} do
    observer = self()
    workflow = Runic.workflow(steps: [Runic.step(&(&1 + 1), name: :increment)])

    {:ok, worker} =
      Runner.start_workflow(runner, :callback_fault, workflow,
        executor: :inline,
        owner: self(),
        on_complete: fn _, completed ->
          send(observer, {:completed, Workflow.raw_productions(completed)})
          raise ArgumentError, "completion callback failed"
        end
      )

    monitor = Process.monitor(worker)
    assert {:ok, id} = Runner.start_execution(runner, :callback_fault, 1)
    assert_receive {:completed, [2]}
    assert_receive {:DOWN, ^monitor, :process, ^worker, {%ArgumentError{}, _}}, 1_000
    assert Runner.lookup(runner, :callback_fault) == nil
    assert {:error, :not_found} = Runner.execution(runner, :callback_fault, id)

    assert {:ok, _} = Runner.resume(runner, :callback_fault, owner: self())
    assert {:ok, [2]} = Runner.get_results(runner, :callback_fault)
    refute_receive {:completed, _}
  end

  for timeout <- [0, 20] do
    test "a #{timeout} ms wait returns while the Worker is suspended", %{runner: runner} do
      workflow = Runic.workflow(steps: [Runic.step(&(&1 + 1), name: :increment)])

      {:ok, worker} =
        Runner.start_workflow(runner, :wait_timeout, workflow, dispatch_mode: :manual)

      {:ok, id} = Runner.start_execution(runner, :wait_timeout, 1)
      :ok = :sys.suspend(worker)
      on_exit(fn -> if Process.alive?(worker), do: :sys.resume(worker) end)

      waiter =
        Task.async(fn -> Runner.await_execution(runner, :wait_timeout, id, unquote(timeout)) end)

      assert {:error, :timeout} = Task.await(waiter, 1_000)
      assert Process.alive?(worker)
      :ok = :sys.resume(worker)
      assert :ok = Runner.step(runner, :wait_timeout)
      assert {:ok, execution} = Runner.await_execution(runner, :wait_timeout, id)
      assert Execution.outputs(execution) == [2]
    end
  end

  test "an infinite wait has no default GenServer call deadline", %{runner: runner} do
    workflow = Runic.workflow(steps: [Runic.step(& &1, name: :echo)])

    {:ok, worker} =
      Runner.start_workflow(runner, :infinite_wait, workflow, dispatch_mode: :manual)

    {:ok, id} = Runner.start_execution(runner, :infinite_wait, :value)
    :ok = :sys.suspend(worker)
    on_exit(fn -> if Process.alive?(worker), do: :sys.resume(worker) end)
    waiter = Task.async(fn -> Runner.await_execution(runner, :infinite_wait, id, :infinity) end)
    ref = waiter.ref

    refute_receive {^ref, _}, 5_100
    assert Process.alive?(waiter.pid)
    :ok = :sys.resume(worker)
    assert :ok = Runner.step(runner, :infinite_wait)
    assert {:ok, execution} = Task.await(waiter, 1_000)
    assert Execution.outputs(execution) == [:value]
  end

  test "Worker death during a snapshot query returns not found", %{runner: runner} do
    workflow = Runic.workflow(steps: [Runic.step(& &1, name: :echo)])

    {:ok, worker} =
      Runner.start_workflow(runner, :lost_worker, workflow,
        dispatch_mode: :manual,
        owner: self()
      )

    {:ok, id} = Runner.start_execution(runner, :lost_worker, :value)
    :ok = :sys.suspend(worker)
    on_exit(fn -> if Process.alive?(worker), do: :sys.resume(worker) end)
    waiter = Task.async(fn -> Runner.await_execution(runner, :lost_worker, id, :infinity) end)

    assert_eventually(fn ->
      {:messages, messages} = Process.info(worker, :messages)
      Enum.any?(messages, &match?({:"$gen_call", _, {:execution, ^id}}, &1))
    end)

    Process.exit(worker, :kill)
    assert {:error, :not_found} = Task.await(waiter, 1_000)
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
