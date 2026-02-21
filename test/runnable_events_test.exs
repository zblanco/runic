defmodule Runic.RunnableEventsTest do
  @moduledoc """
  Tests for Phase 2: Durable Execution Events.

  Covers event emission from PolicyDriver, log integration, round-tripping
  via from_log/1, and pending_runnables/1 for crash recovery.
  """

  use ExUnit.Case, async: true

  alias Runic.Workflow
  alias Runic.Workflow.{Step, Fact, CausalContext, Runnable, PolicyDriver, SchedulerPolicy}
  alias Runic.Workflow.{RunnableDispatched, RunnableCompleted, RunnableFailed}

  require Runic

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp make_runnable(work_fn, opts \\ []) do
    name = Keyword.get(opts, :name, :test_step)
    step = Step.new(work: work_fn, name: name)
    fact = Fact.new(value: Keyword.get(opts, :input, :test))

    context =
      CausalContext.new(
        node_hash: step.hash,
        input_fact: fact,
        ancestry_depth: 0,
        meta_context: Keyword.get(opts, :meta_context, %{})
      )

    Runnable.new(step, fact, context)
  end

  defp make_flaky_runnable(fail_count) do
    counter = :counters.new(1, [:atomics])

    work = fn _input ->
      count = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      if count < fail_count, do: raise("attempt #{count}"), else: :success
    end

    {make_runnable(work), counter}
  end

  # ---------------------------------------------------------------------------
  # A. PolicyDriver emit_events basics
  # ---------------------------------------------------------------------------

  describe "PolicyDriver emit_events" do
    test "successful execution produces RunnableDispatched and RunnableCompleted" do
      runnable = make_runnable(fn x -> {:ok, x} end)
      policy = SchedulerPolicy.default_policy()

      {result, events} = PolicyDriver.execute(runnable, policy, emit_events: true)

      assert result.status == :completed

      dispatched = Enum.filter(events, &is_struct(&1, RunnableDispatched))
      completed = Enum.filter(events, &is_struct(&1, RunnableCompleted))

      assert length(dispatched) == 1
      assert length(completed) == 1

      [d] = dispatched
      assert d.runnable_id == runnable.id
      assert d.node_name == :test_step
      assert d.node_hash == runnable.node.hash
      assert d.input_fact == runnable.input_fact
      assert d.attempt == 0
      assert is_integer(d.dispatched_at)
      assert d.policy.fallback == nil

      [c] = completed
      assert c.runnable_id == runnable.id
      assert c.node_hash == runnable.node.hash
      assert c.attempt == 0
      assert is_integer(c.duration_ms)
      assert c.duration_ms >= 0
      assert is_integer(c.completed_at)
    end

    test "failed execution produces RunnableDispatched and RunnableFailed" do
      runnable = make_runnable(fn _x -> raise "boom" end)
      policy = SchedulerPolicy.default_policy()

      {result, events} = PolicyDriver.execute(runnable, policy, emit_events: true)

      assert result.status == :failed

      dispatched = Enum.filter(events, &is_struct(&1, RunnableDispatched))
      failed = Enum.filter(events, &is_struct(&1, RunnableFailed))

      assert length(dispatched) == 1
      assert length(failed) == 1

      [f] = failed
      assert f.runnable_id == runnable.id
      assert f.attempts == 1
      assert f.failure_action == :halt
      assert is_integer(f.failed_at)
    end

    test "retried execution produces multiple RunnableDispatched events" do
      {runnable, _counter} = make_flaky_runnable(2)
      policy = SchedulerPolicy.new(max_retries: 3, backoff: :none)

      {result, events} = PolicyDriver.execute(runnable, policy, emit_events: true)

      assert result.status == :completed

      dispatched = Enum.filter(events, &is_struct(&1, RunnableDispatched))
      completed = Enum.filter(events, &is_struct(&1, RunnableCompleted))

      # 1 initial + 2 retries = 3 dispatched (fails at 0, 1; succeeds at 2)
      assert length(dispatched) == 3
      assert length(completed) == 1

      attempts = dispatched |> Enum.map(& &1.attempt) |> Enum.sort()
      assert attempts == [0, 1, 2]
    end

    test "all retries exhausted produces RunnableFailed with correct attempts count" do
      {runnable, _counter} = make_flaky_runnable(100)
      policy = SchedulerPolicy.new(max_retries: 2, backoff: :none)

      {result, events} = PolicyDriver.execute(runnable, policy, emit_events: true)

      assert result.status == :failed

      dispatched = Enum.filter(events, &is_struct(&1, RunnableDispatched))
      failed = Enum.filter(events, &is_struct(&1, RunnableFailed))

      # 1 initial + 2 retries = 3 dispatched
      assert length(dispatched) == 3
      assert length(failed) == 1

      [f] = failed
      assert f.attempts == 3
      assert f.failure_action == :halt
    end

    test "on_failure: :skip records :skip failure_action" do
      runnable = make_runnable(fn _x -> raise "boom" end)
      policy = SchedulerPolicy.new(on_failure: :skip)

      {result, events} = PolicyDriver.execute(runnable, policy, emit_events: true)

      assert result.status == :skipped

      [f] = Enum.filter(events, &is_struct(&1, RunnableFailed))
      assert f.failure_action == :skip
    end

    test "emit_events: false returns just the runnable (backward compat)" do
      runnable = make_runnable(fn x -> {:ok, x} end)
      policy = SchedulerPolicy.default_policy()

      result = PolicyDriver.execute(runnable, policy, emit_events: false)

      assert %Runnable{} = result
      assert result.status == :completed
    end

    test "execute/2 still returns just the runnable" do
      runnable = make_runnable(fn x -> {:ok, x} end)
      policy = SchedulerPolicy.default_policy()

      result = PolicyDriver.execute(runnable, policy)

      assert %Runnable{} = result
      assert result.status == :completed
    end

    test "policy in dispatched event has fallback stripped" do
      fallback = fn _r, _e -> {:value, :fb} end
      runnable = make_runnable(fn _x -> raise "boom" end)
      policy = SchedulerPolicy.new(max_retries: 0, fallback: fallback)

      {_result, events} = PolicyDriver.execute(runnable, policy, emit_events: true)

      [d] = Enum.filter(events, &is_struct(&1, RunnableDispatched))
      assert d.policy.fallback == nil
    end

    test "fallback with emit_events produces completed event on success" do
      runnable = make_runnable(fn _x -> raise "boom" end)
      fallback = fn _r, _e -> {:value, :synthetic} end
      policy = SchedulerPolicy.new(max_retries: 0, fallback: fallback)

      {result, events} = PolicyDriver.execute(runnable, policy, emit_events: true)

      assert result.status == :completed

      dispatched = Enum.filter(events, &is_struct(&1, RunnableDispatched))
      completed = Enum.filter(events, &is_struct(&1, RunnableCompleted))

      assert length(dispatched) == 1
      assert length(completed) == 1
    end

    test "fallback failure with emit_events produces failed event" do
      runnable = make_runnable(fn _x -> raise "boom" end)
      fallback = fn _r, _e -> :bad_return end
      policy = SchedulerPolicy.new(max_retries: 0, fallback: fallback)

      {result, events} = PolicyDriver.execute(runnable, policy, emit_events: true)

      assert result.status == :failed

      failed = Enum.filter(events, &is_struct(&1, RunnableFailed))
      assert length(failed) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # B. Workflow.log/1 includes runnable events
  # ---------------------------------------------------------------------------

  describe "Workflow.log/1 includes runnable events" do
    test "log includes runnable events after policy-driven execution" do
      step = Runic.step(fn x -> x * 2 end, name: :double)
      workflow = Runic.workflow(steps: [{step, []}])
      workflow = Workflow.plan(workflow, 5)

      {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

      # Execute with events and accumulate
      {executed, events} =
        Enum.reduce(runnables, {[], []}, fn runnable, {execs, evts} ->
          policy = SchedulerPolicy.resolve(runnable, workflow.scheduler_policies)
          {result, new_events} = PolicyDriver.execute(runnable, policy, emit_events: true)
          {[result | execs], evts ++ new_events}
        end)

      workflow =
        executed
        |> Enum.reduce(workflow, &Workflow.apply_runnable(&2, &1))
        |> Workflow.append_runnable_events(events)

      log = Workflow.log(workflow)

      runnable_events_in_log =
        Enum.filter(log, fn
          %RunnableDispatched{} -> true
          %RunnableCompleted{} -> true
          %RunnableFailed{} -> true
          _ -> false
        end)

      assert length(runnable_events_in_log) > 0
    end
  end

  # ---------------------------------------------------------------------------
  # C. Workflow.from_log/1 round-trips runnable events
  # ---------------------------------------------------------------------------

  describe "Workflow.from_log/1 round-trips runnable events" do
    test "from_log restores runnable events" do
      step = Runic.step(fn x -> x + 1 end, name: :add)
      workflow = Runic.workflow(steps: [{step, []}])
      workflow = Workflow.react_until_satisfied(workflow, 5)

      # Manually add some runnable events to simulate policy-driven execution
      events = [
        %RunnableDispatched{
          runnable_id: 123,
          node_name: :add,
          node_hash: 456,
          input_fact: Fact.new(value: 5),
          dispatched_at: 1000,
          policy: SchedulerPolicy.default_policy(),
          attempt: 0
        },
        %RunnableCompleted{
          runnable_id: 123,
          node_hash: 456,
          result_fact: Fact.new(value: 6),
          completed_at: 1010,
          attempt: 0,
          duration_ms: 10
        }
      ]

      workflow = Workflow.append_runnable_events(workflow, events)

      log = Workflow.log(workflow)
      restored = Workflow.from_log(log)

      assert length(restored.runnable_events) == 2

      [d, c] = restored.runnable_events
      assert %RunnableDispatched{runnable_id: 123, node_name: :add} = d
      assert %RunnableCompleted{runnable_id: 123, duration_ms: 10} = c
    end

    test "from_log handles mixed event types including RunnableFailed" do
      events = [
        %RunnableDispatched{
          runnable_id: 1,
          node_name: :step_a,
          node_hash: 10,
          input_fact: Fact.new(value: :x),
          dispatched_at: 100,
          policy: %SchedulerPolicy{},
          attempt: 0
        },
        %RunnableFailed{
          runnable_id: 1,
          node_hash: 10,
          error: :timeout,
          failed_at: 200,
          attempts: 3,
          failure_action: :halt
        }
      ]

      # from_log with just runnable events (no component events — results in empty workflow)
      restored = Workflow.from_log(events)

      assert length(restored.runnable_events) == 2
      assert [%RunnableDispatched{}, %RunnableFailed{}] = restored.runnable_events
    end
  end

  # ---------------------------------------------------------------------------
  # D. Workflow.pending_runnables/1
  # ---------------------------------------------------------------------------

  describe "Workflow.pending_runnables/1" do
    test "identifies dispatched-but-not-completed runnables" do
      workflow =
        Workflow.new()
        |> Workflow.append_runnable_events([
          %RunnableDispatched{
            runnable_id: 1,
            node_name: :step_a,
            node_hash: 10,
            input_fact: Fact.new(value: :x),
            dispatched_at: 100,
            policy: %SchedulerPolicy{},
            attempt: 0
          },
          %RunnableDispatched{
            runnable_id: 2,
            node_name: :step_b,
            node_hash: 20,
            input_fact: Fact.new(value: :y),
            dispatched_at: 100,
            policy: %SchedulerPolicy{},
            attempt: 0
          },
          %RunnableCompleted{
            runnable_id: 1,
            node_hash: 10,
            result_fact: Fact.new(value: :done),
            completed_at: 200,
            attempt: 0,
            duration_ms: 100
          }
        ])

      pending = Workflow.pending_runnables(workflow)

      assert length(pending) == 1
      [p] = pending
      assert p.runnable_id == 2
      assert p.node_name == :step_b
    end

    test "returns empty list when all runnables are resolved" do
      workflow =
        Workflow.new()
        |> Workflow.append_runnable_events([
          %RunnableDispatched{
            runnable_id: 1,
            node_name: :s,
            node_hash: 10,
            input_fact: Fact.new(value: :x),
            dispatched_at: 100,
            policy: %SchedulerPolicy{},
            attempt: 0
          },
          %RunnableCompleted{
            runnable_id: 1,
            node_hash: 10,
            result_fact: Fact.new(value: :done),
            completed_at: 200,
            attempt: 0,
            duration_ms: 100
          }
        ])

      assert Workflow.pending_runnables(workflow) == []
    end

    test "failed runnables are not pending" do
      workflow =
        Workflow.new()
        |> Workflow.append_runnable_events([
          %RunnableDispatched{
            runnable_id: 1,
            node_name: :s,
            node_hash: 10,
            input_fact: Fact.new(value: :x),
            dispatched_at: 100,
            policy: %SchedulerPolicy{},
            attempt: 0
          },
          %RunnableFailed{
            runnable_id: 1,
            node_hash: 10,
            error: :timeout,
            failed_at: 200,
            attempts: 1,
            failure_action: :halt
          }
        ])

      assert Workflow.pending_runnables(workflow) == []
    end

    test "returns empty list when no events" do
      assert Workflow.pending_runnables(Workflow.new()) == []
    end

    test "multiple dispatches with same id (retries) are resolved by completion" do
      workflow =
        Workflow.new()
        |> Workflow.append_runnable_events([
          %RunnableDispatched{
            runnable_id: 1,
            node_name: :s,
            node_hash: 10,
            input_fact: Fact.new(value: :x),
            dispatched_at: 100,
            policy: %SchedulerPolicy{},
            attempt: 0
          },
          %RunnableDispatched{
            runnable_id: 1,
            node_name: :s,
            node_hash: 10,
            input_fact: Fact.new(value: :x),
            dispatched_at: 200,
            policy: %SchedulerPolicy{},
            attempt: 1
          },
          %RunnableCompleted{
            runnable_id: 1,
            node_hash: 10,
            result_fact: Fact.new(value: :ok),
            completed_at: 300,
            attempt: 1,
            duration_ms: 100
          }
        ])

      assert Workflow.pending_runnables(workflow) == []
    end
  end

  # ---------------------------------------------------------------------------
  # E. append_runnable_events/2
  # ---------------------------------------------------------------------------

  describe "Workflow.append_runnable_events/2" do
    test "appends events to workflow" do
      workflow = Workflow.new()
      assert workflow.runnable_events == []

      event = %RunnableDispatched{
        runnable_id: 1,
        node_name: :s,
        node_hash: 10,
        input_fact: Fact.new(value: :x),
        dispatched_at: 100,
        policy: %SchedulerPolicy{},
        attempt: 0
      }

      workflow = Workflow.append_runnable_events(workflow, [event])
      assert length(workflow.runnable_events) == 1

      workflow = Workflow.append_runnable_events(workflow, [event])
      assert length(workflow.runnable_events) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # F. Full round-trip: workflow + policy execution + log + from_log
  # ---------------------------------------------------------------------------

  describe "full round-trip with policy execution" do
    test "execute with events, append, log, from_log preserves events" do
      step = Runic.step(fn x -> x * 3 end, name: :triple)

      workflow =
        Runic.workflow(steps: [{step, []}])
        |> Workflow.set_scheduler_policies([{:default, %{max_retries: 0}}])
        |> Workflow.plan(7)

      {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

      {workflow, all_events} =
        Enum.reduce(runnables, {workflow, []}, fn runnable, {wrk, evts} ->
          policy = SchedulerPolicy.resolve(runnable, wrk.scheduler_policies)
          {result, new_events} = PolicyDriver.execute(runnable, policy, emit_events: true)
          wrk = Workflow.apply_runnable(wrk, result)
          {wrk, evts ++ new_events}
        end)

      workflow = Workflow.append_runnable_events(workflow, all_events)

      # Verify workflow has events
      assert length(workflow.runnable_events) > 0

      # Round-trip through log
      log = Workflow.log(workflow)
      restored = Workflow.from_log(log)

      assert length(restored.runnable_events) == length(workflow.runnable_events)

      # Verify event types preserved
      dispatched = Enum.filter(restored.runnable_events, &is_struct(&1, RunnableDispatched))
      completed = Enum.filter(restored.runnable_events, &is_struct(&1, RunnableCompleted))

      assert length(dispatched) == 1
      assert length(completed) == 1

      # Verify no pending runnables (all completed)
      assert Workflow.pending_runnables(restored) == []
    end

    test "retried execution events are correctly accumulated" do
      {runnable, _counter} = make_flaky_runnable(2)
      policy = SchedulerPolicy.new(max_retries: 3, backoff: :none)

      {_result, events} = PolicyDriver.execute(runnable, policy, emit_events: true)

      dispatched = Enum.filter(events, &is_struct(&1, RunnableDispatched))
      completed = Enum.filter(events, &is_struct(&1, RunnableCompleted))

      # 2 failed attempts + 1 success = 3 dispatched
      assert length(dispatched) == 3
      assert length(completed) == 1

      # Accumulate into workflow and verify pending_runnables
      workflow = Workflow.append_runnable_events(Workflow.new(), events)
      assert Workflow.pending_runnables(workflow) == []
    end

    test "runnable events round-trip via from_log preserving event data" do
      # Use events directly — no need for a serializable workflow step
      events = [
        %RunnableDispatched{
          runnable_id: 42,
          node_name: :flaky,
          node_hash: 100,
          input_fact: Fact.new(value: :input),
          dispatched_at: 1000,
          policy: %SchedulerPolicy{max_retries: 3},
          attempt: 0
        },
        %RunnableDispatched{
          runnable_id: 42,
          node_name: :flaky,
          node_hash: 100,
          input_fact: Fact.new(value: :input),
          dispatched_at: 1100,
          policy: %SchedulerPolicy{max_retries: 3},
          attempt: 1
        },
        %RunnableCompleted{
          runnable_id: 42,
          node_hash: 100,
          result_fact: Fact.new(value: :recovered),
          completed_at: 1200,
          attempt: 1,
          duration_ms: 50
        }
      ]

      restored = Workflow.from_log(events)
      assert length(restored.runnable_events) == 3
      assert Workflow.pending_runnables(restored) == []
    end
  end
end
