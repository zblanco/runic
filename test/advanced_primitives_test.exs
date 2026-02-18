defmodule Runic.AdvancedPrimitivesTest do
  @moduledoc """
  Tests for Phase 3: Advanced Primitives.

  Covers deadline enforcement in PolicyDriver, deadline wiring through
  react_until_satisfied, and checkpoint callbacks.
  """

  use ExUnit.Case, async: true

  alias Runic.Workflow
  alias Runic.Workflow.{Step, Fact, CausalContext, Runnable, PolicyDriver, SchedulerPolicy}

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

  # ---------------------------------------------------------------------------
  # A. Deadline enforcement in PolicyDriver
  # ---------------------------------------------------------------------------

  describe "deadline enforcement in PolicyDriver" do
    test "deadline already expired fails immediately" do
      runnable = make_runnable(fn _x -> {:ok, :done} end)
      policy = SchedulerPolicy.default_policy()

      # Deadline in the past
      deadline_at = System.monotonic_time(:millisecond) - 100

      result = PolicyDriver.execute(runnable, policy, deadline_at: deadline_at)

      assert result.status == :failed
      assert {:deadline_exceeded, remaining} = result.error
      assert remaining <= 0
    end

    test "deadline in the future allows execution to complete" do
      runnable = make_runnable(fn _x -> {:ok, :done} end)
      policy = SchedulerPolicy.default_policy()

      deadline_at = System.monotonic_time(:millisecond) + 5_000

      result = PolicyDriver.execute(runnable, policy, deadline_at: deadline_at)

      assert result.status == :completed
    end

    test "deadline checked before each retry — no retry if deadline exceeded" do
      counter = :counters.new(1, [:atomics])

      work = fn _input ->
        count = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)

        if count < 5 do
          Process.sleep(50)
          raise "fail #{count}"
        else
          :success
        end
      end

      runnable = make_runnable(work)

      # Give enough time for 1-2 attempts but not all 5
      policy = SchedulerPolicy.new(max_retries: 5, backoff: :none)
      deadline_at = System.monotonic_time(:millisecond) + 120

      result = PolicyDriver.execute(runnable, policy, deadline_at: deadline_at)

      assert result.status == :failed
      # Should have been stopped by the deadline, not exhausting retries
      total_attempts = :counters.get(counter, 1)
      assert total_attempts < 5
    end

    test "deadline caps effective timeout when timeout_ms is :infinity" do
      runnable =
        make_runnable(fn _x ->
          Process.sleep(500)
          {:ok, :slow}
        end)

      policy = SchedulerPolicy.new(timeout_ms: :infinity)
      # Very short deadline should cause a timeout
      deadline_at = System.monotonic_time(:millisecond) + 30

      result = PolicyDriver.execute(runnable, policy, deadline_at: deadline_at)

      assert result.status == :failed
    end

    test "deadline caps effective timeout when timeout_ms is set" do
      runnable =
        make_runnable(fn _x ->
          Process.sleep(500)
          {:ok, :slow}
        end)

      # Step timeout is long, but deadline is short
      policy = SchedulerPolicy.new(timeout_ms: 10_000)
      deadline_at = System.monotonic_time(:millisecond) + 30

      result = PolicyDriver.execute(runnable, policy, deadline_at: deadline_at)

      assert result.status == :failed
    end

    test "no deadline option means no deadline enforcement" do
      runnable = make_runnable(fn _x -> {:ok, :done} end)
      policy = SchedulerPolicy.default_policy()

      result = PolicyDriver.execute(runnable, policy, [])

      assert result.status == :completed
    end

    test "deadline with emit_events produces failed event on deadline exceeded" do
      runnable = make_runnable(fn _x -> {:ok, :done} end)
      policy = SchedulerPolicy.default_policy()

      deadline_at = System.monotonic_time(:millisecond) - 100

      {result, events} =
        PolicyDriver.execute(runnable, policy, deadline_at: deadline_at, emit_events: true)

      assert result.status == :failed
      assert {:deadline_exceeded, _} = result.error

      failed = Enum.filter(events, &is_struct(&1, Runic.Workflow.RunnableFailed))
      assert length(failed) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # B. Deadline wiring through react_until_satisfied
  # ---------------------------------------------------------------------------

  describe "deadline_ms in react_until_satisfied" do
    test "workflow with short deadline and slow step fails with deadline exceeded" do
      step =
        Runic.step(
          fn _x ->
            Process.sleep(200)
            :done
          end,
          name: :slow
        )

      workflow =
        Runic.workflow(steps: [{step, []}])
        |> Workflow.set_scheduler_policies([{:default, %{max_retries: 0}}])

      result = Workflow.react_until_satisfied(workflow, :input, deadline_ms: 50)

      # The slow step should have been failed by the deadline
      values = Workflow.raw_productions(result)
      refute :done in values
    end

    test "workflow with generous deadline and fast steps completes normally" do
      step = Runic.step(fn x -> x + 1 end, name: :fast)
      downstream = Runic.step(fn x -> x * 2 end, name: :double)

      workflow =
        Runic.workflow(steps: [{step, [downstream]}])
        |> Workflow.set_scheduler_policies([{:default, %{max_retries: 0}}])

      result = Workflow.react_until_satisfied(workflow, 5, deadline_ms: 5_000)

      values = Workflow.raw_productions(result)
      assert 6 in values
      assert 12 in values
    end

    test "deadline prevents retries that would exceed it" do
      counter = :counters.new(1, [:atomics])

      step =
        Step.new(
          work: fn _input ->
            count = :counters.get(counter, 1)
            :counters.add(counter, 1, 1)

            if count < 5 do
              Process.sleep(40)
              raise "fail"
            else
              :success
            end
          end,
          name: :flaky
        )

      workflow =
        Workflow.new()
        |> Workflow.add(step)
        |> Workflow.set_scheduler_policies([{:flaky, %{max_retries: 10, backoff: :none}}])

      result = Workflow.react_until_satisfied(workflow, :input, deadline_ms: 100)

      values = Workflow.raw_productions(result)
      refute :success in values
      # Should have been cut short by deadline
      assert :counters.get(counter, 1) < 5
    end

    test "no deadline_ms behaves normally (backward compat)" do
      step = Runic.step(fn x -> x * 3 end, name: :triple)
      workflow = Runic.workflow(steps: [{step, []}])

      result = Workflow.react_until_satisfied(workflow, 7)

      values = Workflow.raw_productions(result)
      assert 21 in values
    end
  end

  # ---------------------------------------------------------------------------
  # C. Checkpoint callback
  # ---------------------------------------------------------------------------

  describe "checkpoint callback" do
    test "checkpoint fires after each react cycle" do
      agent = start_supervised!({Agent, fn -> [] end})

      step = Runic.step(fn x -> x + 1 end, name: :add)
      downstream = Runic.step(fn x -> x * 2 end, name: :double)

      workflow = Runic.workflow(steps: [{step, [downstream]}])

      _result =
        Workflow.react_until_satisfied(workflow, 5,
          checkpoint: fn wrk ->
            Agent.update(agent, fn states -> [Workflow.raw_productions(wrk) | states] end)
          end
        )

      checkpoints = Agent.get(agent, & &1) |> Enum.reverse()

      # At least one checkpoint should have fired
      assert length(checkpoints) >= 1

      # The last checkpoint should contain the final productions
      last = List.last(checkpoints)
      assert is_list(last)
    end

    test "checkpoint callback receives workflow with applied runnables" do
      agent = start_supervised!({Agent, fn -> [] end})

      step = Runic.step(fn x -> x + 1 end, name: :add)
      downstream = Runic.step(fn x -> x * 2 end, name: :double)
      workflow = Runic.workflow(steps: [{step, [downstream]}])

      _result =
        Workflow.react_until_satisfied(workflow, 5,
          checkpoint: fn wrk ->
            productions = Workflow.raw_productions(wrk)
            Agent.update(agent, fn states -> [productions | states] end)
          end
        )

      checkpoints = Agent.get(agent, & &1) |> Enum.reverse()

      # Pipeline has at least 1 react cycle after root invoke
      assert length(checkpoints) >= 1

      # Last checkpoint should contain final results
      last = List.last(checkpoints)
      assert 12 in last
    end

    test "checkpoint with multi-level pipeline fires multiple times" do
      agent = start_supervised!({Agent, fn -> 0 end})

      step1 = Runic.step(fn x -> x + 1 end, name: :step1)
      step2 = Runic.step(fn x -> x * 2 end, name: :step2)
      step3 = Runic.step(fn x -> x + 100 end, name: :step3)

      workflow = Runic.workflow(steps: [{step1, [{step2, [step3]}]}])

      _result =
        Workflow.react_until_satisfied(workflow, 5,
          checkpoint: fn _wrk ->
            Agent.update(agent, &(&1 + 1))
          end
        )

      count = Agent.get(agent, & &1)
      # 3 react cycles in a 3-step pipeline
      assert count >= 2
    end

    test "no checkpoint option works normally (backward compat)" do
      step = Runic.step(fn x -> x + 1 end, name: :add)
      workflow = Runic.workflow(steps: [{step, []}])

      result = Workflow.react_until_satisfied(workflow, 5)

      values = Workflow.raw_productions(result)
      assert 6 in values
    end

    test "checkpoint combined with deadline_ms" do
      agent = start_supervised!({Agent, fn -> 0 end})

      step = Runic.step(fn x -> x + 1 end, name: :add)
      downstream = Runic.step(fn x -> x * 2 end, name: :double)
      workflow = Runic.workflow(steps: [{step, [downstream]}])

      result =
        Workflow.react_until_satisfied(workflow, 5,
          deadline_ms: 5_000,
          checkpoint: fn _wrk ->
            Agent.update(agent, &(&1 + 1))
          end
        )

      values = Workflow.raw_productions(result)
      assert 6 in values
      assert 12 in values
      assert Agent.get(agent, & &1) >= 1
    end
  end

  # ---------------------------------------------------------------------------
  # D. PolicyDriver deadline + retry + fallback combinations
  # ---------------------------------------------------------------------------

  describe "PolicyDriver deadline combinations" do
    test "deadline + retry: succeeds when deadline allows enough retries" do
      counter = :counters.new(1, [:atomics])

      work = fn _input ->
        count = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)
        if count < 2, do: raise("fail"), else: :success
      end

      runnable = make_runnable(work)
      policy = SchedulerPolicy.new(max_retries: 3, backoff: :none)
      deadline_at = System.monotonic_time(:millisecond) + 5_000

      result = PolicyDriver.execute(runnable, policy, deadline_at: deadline_at)

      assert result.status == :completed
    end

    test "deadline + fallback: deadline exceeded skips fallback" do
      fallback_called = :counters.new(1, [:atomics])

      fallback = fn _r, _e ->
        :counters.add(fallback_called, 1, 1)
        {:value, :from_fallback}
      end

      runnable = make_runnable(fn _x -> {:ok, :done} end)
      policy = SchedulerPolicy.new(max_retries: 0, fallback: fallback)

      # Expired deadline
      deadline_at = System.monotonic_time(:millisecond) - 100
      result = PolicyDriver.execute(runnable, policy, deadline_at: deadline_at)

      assert result.status == :failed
      assert {:deadline_exceeded, _} = result.error
      # Fallback should NOT have been called — deadline check happens before execution
      assert :counters.get(fallback_called, 1) == 0
    end
  end
end
