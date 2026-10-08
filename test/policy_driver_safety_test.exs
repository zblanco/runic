defmodule Runic.Workflow.PolicyDriverSafetyTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  alias Runic.Workflow.{Step, Fact, CausalContext, Runnable, PolicyDriver, SchedulerPolicy}
  alias Runic.Workflow.{RunnableDispatched, RunnableFailed}

  for emit <- [false, true], reason <- [:normal, :shutdown, :kill] do
    test "contains #{reason} timed Task exit with events #{emit}" do
      parent = self()
      work = runnable(fn _ -> Process.exit(self(), unquote(reason)) end)

      {caller, monitor} =
        spawn_monitor(fn ->
          flags = Process.info(self(), :trap_exit)

          result =
            PolicyDriver.execute(work, SchedulerPolicy.new(timeout_ms: 1_000),
              emit_events: unquote(emit)
            )

          send(parent, {:result, result, flags, Process.info(self(), :trap_exit)})
        end)

      assert_receive {:result, result, {:trap_exit, false}, {:trap_exit, false}}, 2_000
      assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
      {failed, events} = unwrap(result)
      assert failed.status == :failed
      expected_reason = if unquote(reason) == :kill, do: :killed, else: unquote(reason)
      assert failed.error == {:task_crashed, expected_reason}
      if unquote(emit), do: assert(match?(%RunnableFailed{}, List.last(events)))
    end
  end

  for emit <- [false, true] do
    test "retry predicate and fallback share the event/non-event decision with events #{emit}" do
      attempts = :counters.new(1, [:atomics])

      work =
        runnable(fn _ ->
          :counters.add(attempts, 1, 1)
          raise "retry me"
        end)

      for predicate <- [fn _ -> false end, {__MODULE__, :classify, [false]}] do
        :counters.put(attempts, 1, 0)

        policy =
          SchedulerPolicy.new(
            max_retries: 3,
            retry_if: predicate,
            fallback: fn _, _ -> {:value, :fallback} end
          )

        {result, _} = PolicyDriver.execute(work, policy, emit_events: unquote(emit)) |> unwrap()
        assert result.status == :completed
        assert result.result.value == :fallback
        assert :counters.get(attempts, 1) == 1
      end

      policy = SchedulerPolicy.new(max_retries: 2, retry_if: {__MODULE__, :classify, [true]})
      :counters.put(attempts, 1, 0)

      {result, events} =
        PolicyDriver.execute(work, policy, emit_events: unquote(emit)) |> unwrap()

      assert result.status == :failed
      assert :counters.get(attempts, 1) == 3

      if unquote(emit) do
        assert Enum.count(events, &match?(%RunnableDispatched{}, &1)) == 3
        assert %RunnableFailed{attempts: 3} = List.last(events)
      end
    end

    test "invalid or crashing predicates fail closed with original error, events #{emit}" do
      owner = self()
      work = runnable(fn _ -> raise "original" end)

      predicates = [
        fn _ -> :truthy end,
        fn _ -> raise "predicate" end,
        fn _ -> throw(:predicate) end,
        fn _ -> exit(:predicate) end
      ]

      for predicate <- predicates do
        policy =
          SchedulerPolicy.new(
            max_retries: 2,
            retry_if: predicate,
            on_failure: :skip,
            fallback: fn _, _ ->
              send(owner, :unexpected_fallback)
              {:value, :bad}
            end
          )

        {failed, events} =
          PolicyDriver.execute(work, policy, emit_events: unquote(emit)) |> unwrap()

        assert failed.status == :failed
        assert {:retry_predicate_failed, _, %RuntimeError{message: "original"}} = failed.error
        refute_received :unexpected_fallback
        if unquote(emit), do: assert(match?(%RunnableFailed{attempts: 1}, List.last(events)))
      end
    end

    test "timed Task crashes honor retry and fallback with events #{emit}" do
      attempts = :counters.new(1, [:atomics])

      work =
        runnable(fn _ ->
          :counters.add(attempts, 1, 1)
          Process.exit(self(), :kill)
        end)

      policy =
        SchedulerPolicy.new(
          timeout_ms: 1_000,
          max_retries: 1,
          retry_if: fn error -> error == {:task_crashed, :killed} end,
          fallback: fn _, _ -> {:value, :recovered} end
        )

      {result, events} =
        PolicyDriver.execute(work, policy, emit_events: unquote(emit)) |> unwrap()

      assert result.result.value == :recovered
      assert :counters.get(attempts, 1) == 2

      if unquote(emit) do
        assert Enum.count(events, &match?(%RunnableDispatched{}, &1)) == 2

        assert Enum.all?(events, fn
                 %RunnableDispatched{policy: policy} -> policy.retry_if == nil
                 _ -> true
               end)
      end
    end

    test "fallback retry cannot escape the inherited deadline with events #{emit}" do
      owner = self()
      work = runnable(fn _ -> raise "original" end)

      fallback_work = fn _ ->
        send(owner, {:fallback_worker, self()})
        receive do: (:finish -> :late)
      end

      fallback = fn failed, _ -> %{failed | node: %{failed.node | work: fallback_work}} end
      policy = SchedulerPolicy.new(timeout_ms: :infinity, fallback: fallback)

      {result, _} =
        PolicyDriver.execute(work, policy,
          emit_events: unquote(emit),
          deadline_at: System.monotonic_time(:millisecond) + 100
        )
        |> unwrap()

      assert result.status == :failed
      assert match?({:timeout, _}, result.error) or match?({:deadline_exceeded, _}, result.error)

      receive do
        {:fallback_worker, worker} -> refute Process.alive?(worker)
      after
        0 -> :ok
      end
    end
  end

  test "predicate is not evaluated after the retry budget is exhausted" do
    work = runnable(fn _ -> raise "original" end)
    policy = SchedulerPolicy.new(max_retries: 0, retry_if: fn _ -> flunk("not called") end)

    assert %Runnable{error: %RuntimeError{message: "original"}} =
             PolicyDriver.execute(work, policy)
  end

  test "a zero timeout starts no user work" do
    owner = self()
    work = runnable(fn _ -> send(owner, :unexpected_work) end)

    assert %Runnable{status: :failed, error: {:timeout, 0}} =
             PolicyDriver.execute(work, SchedulerPolicy.new(timeout_ms: 0))

    refute_received :unexpected_work
  end

  def classify(%RuntimeError{}, accept), do: accept

  defp unwrap({result, events}), do: {result, events}
  defp unwrap(%Runnable{} = result), do: {result, []}

  defp runnable(work) do
    step = Step.new(work: work, name: :policy_safety)
    fact = Fact.new(value: :input)

    context =
      CausalContext.new(
        node_hash: step.hash,
        input_fact: fact,
        ancestry_depth: 0,
        meta_context: %{}
      )

    Runnable.new(step, fact, context)
  end
end
