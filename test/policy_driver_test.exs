defmodule Runic.Workflow.PolicyDriverTest do
  use ExUnit.Case, async: true

  alias Runic.Workflow.{Step, Fact, CausalContext, Runnable, PolicyDriver, SchedulerPolicy}

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

  describe "happy path" do
    test "execute with default policy succeeds for passing work fn" do
      runnable = make_runnable(fn x -> {:ok, x} end)
      result = PolicyDriver.execute(runnable, SchedulerPolicy.default_policy())

      assert result.status == :completed
    end

    test "execute with default policy fails for raising work fn" do
      runnable = make_runnable(fn _x -> raise "boom" end)
      result = PolicyDriver.execute(runnable, SchedulerPolicy.default_policy())

      assert result.status == :failed
    end
  end

  describe "timeout enforcement" do
    test "work fn that exceeds timeout results in failure" do
      runnable =
        make_runnable(fn _x ->
          Process.sleep(50)
          :ok
        end)

      policy = SchedulerPolicy.new(timeout_ms: 10)
      result = PolicyDriver.execute(runnable, policy)

      assert result.status == :failed
      assert result.error == {:timeout, 10}
    end

    test "work fn that completes within timeout succeeds" do
      runnable =
        make_runnable(fn _x ->
          Process.sleep(5)
          {:ok, :done}
        end)

      policy = SchedulerPolicy.new(timeout_ms: 100)
      result = PolicyDriver.execute(runnable, policy)

      assert result.status == :completed
    end

    test "timeout_ms :infinity uses direct execution" do
      runnable = make_runnable(fn x -> {:ok, x} end)
      policy = SchedulerPolicy.new(timeout_ms: :infinity)
      result = PolicyDriver.execute(runnable, policy)

      assert result.status == :completed
    end
  end

  describe "retry with backoff" do
    test "flaky fn succeeds after retries" do
      {runnable, _counter} = make_flaky_runnable(2)
      policy = SchedulerPolicy.new(max_retries: 3, backoff: :none)
      result = PolicyDriver.execute(runnable, policy)

      assert result.status == :completed
    end

    test "flaky fn fails when retries exhausted" do
      {runnable, _counter} = make_flaky_runnable(4)
      policy = SchedulerPolicy.new(max_retries: 3, backoff: :none)
      result = PolicyDriver.execute(runnable, policy)

      assert result.status == :failed
    end

    test "max_retries 0 means no retry" do
      {runnable, counter} = make_flaky_runnable(1)
      policy = SchedulerPolicy.new(max_retries: 0, backoff: :none)
      result = PolicyDriver.execute(runnable, policy)

      assert result.status == :failed
      assert :counters.get(counter, 1) == 1
    end

    test "exact retry count: initial attempt + max_retries retries" do
      {runnable, counter} = make_flaky_runnable(100)
      policy = SchedulerPolicy.new(max_retries: 3, backoff: :none)
      _result = PolicyDriver.execute(runnable, policy)

      # 1 initial + 3 retries = 4 total
      assert :counters.get(counter, 1) == 4
    end
  end

  describe "fallback — three return shapes" do
    test "fallback returning {:value, term} completes with synthetic fact" do
      runnable = make_runnable(fn _x -> raise "boom" end)

      fallback = fn _runnable, _error -> {:value, :synthetic} end

      policy = SchedulerPolicy.new(max_retries: 0, fallback: fallback)
      result = PolicyDriver.execute(runnable, policy)

      assert result.status == :completed
      assert result.result.value == :synthetic
      assert is_function(result.apply_fn, 1)
    end

    test "fallback returning {:retry_with, overrides} merges into meta_context and executes" do
      counter = :counters.new(1, [:atomics])

      work = fn _input ->
        count = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)

        if count > 0 do
          {:ok, :from_fallback}
        else
          raise "need fallback"
        end
      end

      runnable = make_runnable(work, meta_context: %{})

      fallback = fn _runnable, _error -> {:retry_with, %{use_fallback: true}} end
      policy = SchedulerPolicy.new(max_retries: 0, fallback: fallback)
      result = PolicyDriver.execute(runnable, policy)

      assert result.status == :completed
      # Verify the meta_context was merged (the retry happened via fallback path)
      assert :counters.get(counter, 1) == 2
    end

    test "fallback returning unexpected shape results in failure" do
      runnable = make_runnable(fn _x -> raise "boom" end)
      fallback = fn _runnable, _error -> :unexpected end
      policy = SchedulerPolicy.new(max_retries: 0, fallback: fallback)
      result = PolicyDriver.execute(runnable, policy)

      assert result.status == :failed
      assert result.error == {:invalid_fallback_return, :unexpected}
    end

    test "fallback is only called after all retries exhausted" do
      fallback_counter = :counters.new(1, [:atomics])
      {runnable, invoke_counter} = make_flaky_runnable(100)

      fallback = fn _runnable, _error ->
        :counters.add(fallback_counter, 1, 1)
        {:value, :fell_back}
      end

      policy = SchedulerPolicy.new(max_retries: 2, backoff: :none, fallback: fallback)
      result = PolicyDriver.execute(runnable, policy)

      # 1 initial + 2 retries = 3 invocations, then fallback
      assert :counters.get(invoke_counter, 1) == 3
      assert :counters.get(fallback_counter, 1) == 1
      assert result.status == :completed
      assert result.result.value == :fell_back
    end
  end

  describe "on_failure actions" do
    test ":halt returns the failed runnable" do
      runnable = make_runnable(fn _x -> raise "boom" end)
      policy = SchedulerPolicy.new(on_failure: :halt)
      result = PolicyDriver.execute(runnable, policy)

      assert result.status == :failed
    end

    test ":skip returns a skipped runnable with a valid apply_fn" do
      runnable = make_runnable(fn _x -> raise "boom" end)
      policy = SchedulerPolicy.new(on_failure: :skip)
      result = PolicyDriver.execute(runnable, policy)

      assert result.status == :skipped
      assert is_function(result.apply_fn, 1)
    end
  end

  describe "combinations" do
    test "timeout + retry: first attempt times out, retry succeeds" do
      counter = :counters.new(1, [:atomics])

      work = fn _input ->
        count = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)

        if count == 0 do
          Process.sleep(50)
          {:ok, :slow}
        else
          {:ok, :fast}
        end
      end

      runnable = make_runnable(work)
      policy = SchedulerPolicy.new(timeout_ms: 10, max_retries: 2, backoff: :none)
      result = PolicyDriver.execute(runnable, policy)

      assert result.status == :completed
    end

    test "completed runnable passes through without retry" do
      runnable = make_runnable(fn x -> {:ok, x} end)
      policy = SchedulerPolicy.new(max_retries: 3)
      result = PolicyDriver.execute(runnable, policy)

      assert result.status == :completed
    end
  end
end
