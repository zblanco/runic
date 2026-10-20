defmodule Runic.Runner.RetryRecoveryTest do
  use ExUnit.Case, async: false

  require Runic

  alias Runic.Runner
  alias Runic.Workflow.{RetryScheduled, RunnableDispatched}
  alias Runic.TestSupport.FailingStore

  defmodule TestClock do
    def now(agent, observer) do
      send(observer, {:retry_clock_read, self()})
      Agent.get(agent, & &1)
    end
  end

  defmodule LostAckStore do
    @behaviour Runic.Runner.Store

    def start_link(_opts) do
      Agent.start_link(fn -> %{events: %{}, logs: %{}, lose_admission?: false} end)
    end

    def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

    def lose_next_admission(agent) do
      Agent.update(agent, &%{&1 | lose_admission?: true})
    end

    @impl true
    def init_store(opts), do: {:ok, Keyword.fetch!(opts, :agent)}

    @impl true
    def append(id, events, agent) do
      Agent.get_and_update(agent, fn state ->
        if state.lose_admission? and Enum.any?(events, &is_struct(&1, RunnableDispatched)) do
          duplicated = events ++ events
          stored = Map.update(state.events, id, duplicated, &(&1 ++ duplicated))
          {{:error, :lost_acknowledgement}, %{state | events: stored, lose_admission?: false}}
        else
          stored = Map.update(state.events, id, events, &(&1 ++ events))
          cursor = length(Map.fetch!(stored, id))
          {{:ok, cursor}, %{state | events: stored}}
        end
      end)
    end

    @impl true
    def stream(id, agent) do
      Agent.get(agent, fn state ->
        case Map.fetch(state.events, id) do
          {:ok, events} -> {:ok, events}
          :error -> {:error, :not_found}
        end
      end)
    end

    @impl true
    def save(id, log, agent) do
      Agent.update(agent, &%{&1 | logs: Map.put(&1.logs, id, log)})
    end

    @impl true
    def load(id, agent) do
      Agent.get(agent, fn state ->
        case Map.fetch(state.logs, id) do
          {:ok, log} -> {:ok, log}
          :error -> {:error, :not_found}
        end
      end)
    end
  end

  setup do
    observer = self()

    counter =
      start_supervised!(Supervisor.child_spec({Agent, fn -> 0 end}, id: make_ref()))

    clock =
      start_supervised!(Supervisor.child_spec({Agent, fn -> 1_000 end}, id: make_ref()))

    %{observer: observer, counter: counter, clock: clock}
  end

  test "a second admitted attempt with an unknown outcome cannot admit attempt three", ctx do
    runner = start_runner()
    workflow = retry_workflow(ctx, :gated_failure)
    policies = durable_policy(max_retries: 1)

    assert {:ok, _worker} =
             Runner.start_workflow(runner, :budget, workflow,
               scheduler_policies: policies,
               retry_time_source: {TestClock, :now, [ctx.clock, ctx.observer]}
             )

    assert :ok =
             Runner.run(runner, :budget, 1,
               scheduler_policies: policies,
               run_context: run_context(ctx, :gated_failure)
             )

    assert_receive {:attempt, 1, first}, 2_000
    send(first, {:release, 1})
    assert_receive {:attempt, 2, second}, 2_000

    assert :ok = Runner.stop(runner, :budget, persist: true)
    refute Process.alive?(second)

    assert {:ok, _worker} =
             Runner.resume(runner, :budget,
               scheduler_policies: policies,
               run_context: run_context(ctx, :gated_failure),
               retry_time_source: {TestClock, :now, [ctx.clock, ctx.observer]}
             )

    assert {:ok, %{status: :stopped, active_units: 0, waiting_retries: 0}} =
             Runner.admission_status(runner, :budget)

    assert Agent.get(ctx.counter, & &1) == 2
    refute_received {:attempt, 3, _pid}

    assert {:ok, restored} = Runner.get_workflow(runner, :budget)

    assert Enum.any?(restored.runnable_events, fn
             %Runic.Workflow.ExecutionUncertain{reason: {:attempt_outcome_unknown, _}} -> true
             _event -> false
           end)
  end

  test "an unknown first attempt consumes budget and permits the saved final attempt", ctx do
    runner = start_runner()
    workflow = retry_workflow(ctx, :gated_then_succeed)
    policies = durable_policy(max_retries: 1)

    opts = [
      scheduler_policies: policies,
      retry_time_source: {TestClock, :now, [ctx.clock, ctx.observer]},
      on_complete: fn _, _ -> send(ctx.observer, :remaining_budget_complete) end
    ]

    assert {:ok, _worker} = Runner.start_workflow(runner, :remaining_budget, workflow, opts)

    assert :ok =
             Runner.run(runner, :remaining_budget, 1,
               scheduler_policies: policies,
               run_context: run_context(ctx, :gated_then_succeed)
             )

    assert_receive {:attempt, 1, first}, 2_000
    assert :ok = Runner.stop(runner, :remaining_budget, persist: true)
    refute Process.alive?(first)

    opts = Keyword.put(opts, :run_context, run_context(ctx, :gated_then_succeed))
    assert {:ok, _worker} = Runner.resume(runner, :remaining_budget, opts)
    assert_receive {:attempt, 2, _second}, 2_000
    assert_receive {:attempt_finished, 2}, 2_000
    assert_receive :remaining_budget_complete, 2_000
    assert {:ok, [2]} = Runner.get_results(runner, :remaining_budget)
    assert Agent.get(ctx.counter, & &1) == 2
    refute_received {:attempt, 3, _pid}
  end

  test "a saved retry deadline releases its task and survives Worker recovery", ctx do
    runner = start_runner()
    workflow = retry_workflow(ctx, :fail_then_succeed)
    policies = durable_policy(max_retries: 1, backoff: :linear, base_delay_ms: 500)

    opts = [
      scheduler_policies: policies,
      retry_time_source: {TestClock, :now, [ctx.clock, ctx.observer]}
    ]

    opts =
      Keyword.put(opts, :on_complete, fn _, _ -> send(ctx.observer, :deadline_complete) end)

    assert {:ok, _worker} = Runner.start_workflow(runner, :deadline, workflow, opts)

    assert :ok =
             Runner.run(runner, :deadline, 1,
               scheduler_policies: policies,
               run_context: run_context(ctx, :fail_then_succeed)
             )

    assert_receive {:attempt, 1, _first}, 2_000
    assert_receive {:retry_clock_read, _worker}, 2_000
    assert_receive {:retry_clock_read, _worker}, 2_000

    assert {:ok, %{active_units: 0, waiting_retries: 1}} =
             Runner.admission_status(runner, :deadline)

    {store, state} = Runner.get_store(runner)
    assert {:ok, stream} = store.stream(:deadline, state)

    assert %RetryScheduled{version: 1, next_attempt: 1, due_at: 1_500} =
             Enum.find(stream, &is_struct(&1, RetryScheduled))

    assert :ok = Runner.stop(runner, :deadline, persist: true)
    Agent.update(ctx.clock, fn _ -> 1_500 end)
    opts = Keyword.put(opts, :run_context, run_context(ctx, :fail_then_succeed))
    assert {:ok, _worker} = Runner.resume(runner, :deadline, opts)
    assert_receive {:attempt, 2, _second}, 2_000
    assert_receive :deadline_complete, 2_000
    assert {:ok, [2]} = Runner.get_results(runner, :deadline)
    assert Agent.get(ctx.counter, & &1) == 2
  end

  test "a Store outage blocks dispatch until the admission is acknowledged", ctx do
    store = start_supervised!(FailingStore)
    runner = start_runner(store: FailingStore, store_opts: [agent: store])
    workflow = retry_workflow(ctx, :succeed)
    policies = durable_policy(max_retries: 0)

    assert {:ok, _worker} =
             Runner.start_workflow(runner, :outage, workflow,
               scheduler_policies: policies,
               hooks: [on_dispatch: fn _, _ -> send(ctx.observer, :outage_dispatched) end],
               on_complete: fn _, _ -> send(ctx.observer, :outage_complete) end
             )

    FailingStore.fail(store, :append)

    assert :ok =
             Runner.run(runner, :outage, 1,
               scheduler_policies: policies,
               run_context: run_context(ctx, :succeed)
             )

    assert {:ok, %{status: {:error, {:persistence_failed, :storage_unavailable}}}} =
             Runner.persistence_status(runner, :outage)

    assert Agent.get(ctx.counter, & &1) == 0
    refute_received :outage_dispatched
    FailingStore.recover(store)
    assert :ok = Runner.checkpoint(runner, :outage)
    assert_receive :outage_dispatched, 2_000
    assert_receive {:attempt, 1, _task}, 2_000
    assert_receive :outage_complete, 2_000
    assert {:ok, [1]} = Runner.get_results(runner, :outage)
  end

  test "a lost admission acknowledgement consumes budget and duplicate replay is idempotent",
       ctx do
    store = start_supervised!(LostAckStore)
    runner = start_runner(store: LostAckStore, store_opts: [agent: store])
    workflow = retry_workflow(ctx, :succeed)
    policies = durable_policy(max_retries: 0)

    assert {:ok, _worker} =
             Runner.start_workflow(runner, :lost_ack, workflow,
               scheduler_policies: policies,
               hooks: [
                 on_persistence_error: fn operation, reason, _state ->
                   send(ctx.observer, {:persistence_error, operation, reason})
                 end
               ]
             )

    LostAckStore.lose_next_admission(store)

    assert :ok =
             Runner.run(runner, :lost_ack, 1,
               scheduler_policies: policies,
               run_context: run_context(ctx, :succeed)
             )

    assert_receive {:persistence_error, :attempt_admission,
                    {:persistence_failed, :lost_acknowledgement}},
                   2_000

    assert Agent.get(ctx.counter, & &1) == 0
    assert :ok = Runner.stop(runner, :lost_ack, persist: false)

    assert {:ok, stored} = LostAckStore.stream(:lost_ack, store)
    stored_admissions = Enum.filter(stored, &is_struct(&1, RunnableDispatched))
    assert length(stored_admissions) == 2
    assert stored_admissions |> Enum.map(& &1.event_id) |> Enum.uniq() |> length() == 1

    assert {:ok, _worker} =
             Runner.resume(runner, :lost_ack,
               scheduler_policies: policies,
               run_context: run_context(ctx, :succeed)
             )

    assert {:ok, %{status: :stopped, active_units: 0}} =
             Runner.admission_status(runner, :lost_ack)

    assert {:ok, restored} = Runner.get_workflow(runner, :lost_ack)
    assert Enum.count(restored.runnable_events, &is_struct(&1, RunnableDispatched)) == 1
    assert Agent.get(ctx.counter, & &1) == 0
    refute_received {:attempt, _, _}
  end

  defp start_runner(opts \\ []) do
    runner = :"retry_recovery_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, Keyword.put(opts, :name, runner)}, id: runner)
    runner
  end

  defp retry_workflow(_ctx, _behavior) do
    step =
      Runic.step(
        fn value ->
          counter = context(:counter)
          observer = context(:observer)
          behavior = context(:behavior)
          attempt = Agent.get_and_update(counter, fn count -> {count + 1, count + 1} end)
          send(observer, {:attempt, attempt, self()})

          case behavior do
            :gated_failure ->
              receive do
                {:release, _released_attempt} -> raise "retry"
              end

            :gated_then_succeed when attempt == 1 ->
              receive do
                :never_released -> :ok
              end

            :fail_then_succeed when attempt == 1 ->
              raise "retry"

            _ ->
              send(observer, {:attempt_finished, attempt})
              attempt * value
          end
        end,
        name: :retry
      )

    Runic.workflow(steps: [step])
  end

  defp run_context(ctx, behavior) do
    %{_global: %{counter: ctx.counter, observer: ctx.observer, behavior: behavior}}
  end

  defp durable_policy(opts) do
    [
      {:default,
       %{
         execution_mode: :durable,
         max_retries: Keyword.fetch!(opts, :max_retries),
         retry_if: fn _error -> true end,
         backoff: Keyword.get(opts, :backoff, :none),
         base_delay_ms: Keyword.get(opts, :base_delay_ms, 0),
         max_delay_ms: Keyword.get(opts, :base_delay_ms, 0)
       }}
    ]
  end
end
