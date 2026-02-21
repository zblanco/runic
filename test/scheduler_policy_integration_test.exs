defmodule Runic.SchedulerPolicyIntegrationTest do
  @moduledoc """
  Integration tests for scheduler policies with real workflows.
  Tests end-to-end behavior of policy resolution, retry, timeout, fallback,
  and backward compatibility.
  """

  use ExUnit.Case, async: true

  alias Runic.Workflow
  alias Runic.Workflow.{Step, Condition, Fact, Runnable, SchedulerPolicy}
  require Runic

  # --- A. Workflow struct — policy storage ---

  describe "workflow policy storage" do
    test "Workflow.new with scheduler_policies stores policies" do
      policies = [{:default, %{max_retries: 1}}]
      workflow = Workflow.new(scheduler_policies: policies)
      assert workflow.scheduler_policies == policies
    end

    test "Workflow.new without scheduler_policies defaults to empty list" do
      workflow = Workflow.new()
      assert workflow.scheduler_policies == []
    end

    test "set_scheduler_policies/2 replaces policies" do
      workflow = Workflow.new(scheduler_policies: [{:default, %{max_retries: 1}}])
      new_policies = [{:default, %{max_retries: 5}}]
      workflow = Workflow.set_scheduler_policies(workflow, new_policies)
      assert workflow.scheduler_policies == new_policies
    end

    test "add_scheduler_policy/3 prepends to the front" do
      workflow =
        Workflow.new()
        |> Workflow.set_scheduler_policies([{:default, %{max_retries: 0}}])
        |> Workflow.add_scheduler_policy(:my_step, %{max_retries: 3})

      assert [{:my_step, %{max_retries: 3}}, {:default, %{max_retries: 0}}] =
               workflow.scheduler_policies
    end

    test "append_scheduler_policy/3 appends to the end" do
      workflow =
        Workflow.new()
        |> Workflow.set_scheduler_policies([{:my_step, %{max_retries: 3}}])
        |> Workflow.append_scheduler_policy(:default, %{max_retries: 0})

      assert [{:my_step, %{max_retries: 3}}, {:default, %{max_retries: 0}}] =
               workflow.scheduler_policies
    end
  end

  # --- B. Runtime override semantics ---

  describe "runtime override semantics" do
    test "runtime scheduler_policies override takes priority via prepend" do
      counter = :counters.new(1, [:atomics])

      work = fn _input ->
        count = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)
        if count < 2, do: raise("fail"), else: :ok
      end

      step = Runic.step(work, name: :flaky)
      workflow = Runic.workflow(steps: [{step, []}])

      # Workflow base has no retries
      workflow = Workflow.set_scheduler_policies(workflow, [{:default, %{max_retries: 0}}])

      # Runtime override adds retries for the flaky step
      result =
        Workflow.react_until_satisfied(workflow, :input,
          scheduler_policies: [{:flaky, %{max_retries: 3}}]
        )

      values = Workflow.raw_productions(result)
      assert :ok in values
    end

    test "scheduler_policies_mode: :replace ignores workflow base" do
      step = Runic.step(fn x -> x + 1 end, name: :add)
      workflow = Runic.workflow(steps: [{step, []}])

      # Workflow base would cause timeout (very short)
      workflow =
        Workflow.set_scheduler_policies(workflow, [{:default, %{timeout_ms: 1}}])

      # Replace entirely with no timeout
      result =
        Workflow.react_until_satisfied(workflow, 5,
          scheduler_policies: [{:default, %{timeout_ms: :infinity}}],
          scheduler_policies_mode: :replace
        )

      values = Workflow.raw_productions(result)
      assert 6 in values
    end

    test "no runtime override uses workflow base" do
      counter = :counters.new(1, [:atomics])

      work = fn _input ->
        count = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)
        if count < 2, do: raise("fail"), else: :recovered
      end

      step = Runic.step(work, name: :flaky)
      workflow = Runic.workflow(steps: [{step, []}])

      workflow =
        Workflow.set_scheduler_policies(workflow, [{:default, %{max_retries: 3}}])

      result = Workflow.react_until_satisfied(workflow, :input)
      values = Workflow.raw_productions(result)
      assert :recovered in values
    end

    test "no workflow base and no runtime results in vanilla execution" do
      step = Runic.step(fn x -> x * 2 end, name: :double)
      workflow = Runic.workflow(steps: [{step, []}])

      result = Workflow.react_until_satisfied(workflow, 5)
      values = Workflow.raw_productions(result)
      assert 10 in values
    end
  end

  # --- C. End-to-end with real workflows ---

  describe "end-to-end with real workflows" do
    test "pipeline with max_retries and flaky step completes after retry" do
      counter = :counters.new(1, [:atomics])

      work = fn _input ->
        count = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)
        if count < 3, do: raise("fail #{count}"), else: :success
      end

      step = Runic.step(work, name: :flaky)
      downstream = Runic.step(fn x -> {:processed, x} end, name: :process)

      workflow =
        Runic.workflow(steps: [{step, [downstream]}])
        |> Workflow.set_scheduler_policies([{:flaky, %{max_retries: 3}}])

      result = Workflow.react_until_satisfied(workflow, :input)
      values = Workflow.raw_productions(result)
      assert :success in values
      assert {:processed, :success} in values
    end

    test "pipeline with timeout and on_failure: :skip skips failed step" do
      slow_step = Runic.step(fn _x -> Process.sleep(100) end, name: :slow)
      downstream = Runic.step(fn x -> {:after_slow, x} end, name: :after_slow)

      workflow =
        Runic.workflow(steps: [{slow_step, [downstream]}])
        |> Workflow.set_scheduler_policies([
          {:slow, %{timeout_ms: 10, on_failure: :skip}}
        ])

      result = Workflow.react_until_satisfied(workflow, :input)
      values = Workflow.raw_productions(result)
      # The slow step was skipped, downstream should NOT have fired
      refute Enum.any?(values, fn v -> match?({:after_slow, _}, v) end)
    end

    test "pipeline with fallback providing synthetic value" do
      failing_step = Runic.step(fn _x -> raise "always fails" end, name: :failing)
      downstream = Runic.step(fn x -> {:got, x} end, name: :consumer)

      workflow =
        Runic.workflow(steps: [{failing_step, [downstream]}])
        |> Workflow.set_scheduler_policies([
          {:failing,
           %{
             max_retries: 0,
             fallback: fn _runnable, _error -> {:value, :fallback_data} end
           }}
        ])

      result = Workflow.react_until_satisfied(workflow, :input)
      values = Workflow.raw_productions(result)
      assert :fallback_data in values
      assert {:got, :fallback_data} in values
    end

    test "rule workflow with policies on the reaction step" do
      counter = :counters.new(1, [:atomics])

      work = fn x ->
        count = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)
        if count < 2, do: raise("fail"), else: x * 10
      end

      rule = Runic.rule(fn x when is_integer(x) and x > 5 -> x end, name: :gt_5)
      reaction = Runic.step(work, name: :react_step)

      workflow =
        Runic.workflow(name: "rule_test")
        |> Workflow.add(rule)
        |> Workflow.add(reaction, to: :gt_5)
        |> Workflow.set_scheduler_policies([{:react_step, %{max_retries: 3}}])

      result = Workflow.react_until_satisfied(workflow, 10)
      values = Workflow.raw_productions(result)
      assert 100 in values
    end

    test "async: true with policies resolves per-runnable" do
      counter_a = :counters.new(1, [:atomics])
      counter_b = :counters.new(1, [:atomics])

      work_a = fn _input ->
        count = :counters.get(counter_a, 1)
        :counters.add(counter_a, 1, 1)
        if count < 2, do: raise("fail a"), else: :a_done
      end

      work_b = fn _input ->
        count = :counters.get(counter_b, 1)
        :counters.add(counter_b, 1, 1)
        if count < 2, do: raise("fail b"), else: :b_done
      end

      step_a = Runic.step(work_a, name: :step_a)
      step_b = Runic.step(work_b, name: :step_b)

      workflow =
        Runic.workflow(steps: [{step_a, []}, {step_b, []}])
        |> Workflow.set_scheduler_policies([{:default, %{max_retries: 3}}])

      result =
        Workflow.react_until_satisfied(workflow, :input, async: true, max_concurrency: 4)

      values = Workflow.raw_productions(result)
      assert :a_done in values
      assert :b_done in values
    end
  end

  # --- D. Backward compatibility ---

  describe "backward compatibility" do
    test "workflow with no policies behaves identically" do
      workflow =
        Runic.workflow(
          steps: [
            {Runic.step(fn x -> x * 2 end, name: :double),
             [Runic.step(fn x -> x + 1 end, name: :inc)]}
          ]
        )

      result =
        workflow
        |> Workflow.react_until_satisfied(5)
        |> Workflow.reactions()
        |> Enum.map(& &1.value)
        |> Enum.sort()

      assert 10 in result
      assert 11 in result
    end

    test "react/2 with no opts behaves identically" do
      workflow =
        Runic.workflow(steps: [Runic.step(fn x -> x + 10 end)])

      result =
        workflow
        |> Workflow.react(5)
        |> Workflow.reactions()
        |> Enum.map(& &1.value)

      assert 15 in result
    end

    test "prepare_for_dispatch -> manual execute -> apply_runnable still works" do
      workflow =
        Runic.workflow(
          steps: [
            {Runic.step(fn x -> x * 2 end, name: :double),
             [Runic.step(fn x -> x + 1 end, name: :inc)]}
          ]
        )
        |> Workflow.plan(10)

      {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

      executed =
        Enum.map(runnables, fn runnable ->
          Runic.Workflow.Invokable.execute(runnable.node, runnable)
        end)

      workflow =
        Enum.reduce(executed, workflow, fn r, wrk ->
          Workflow.apply_runnable(wrk, r)
        end)

      values = Workflow.reactions(workflow) |> Enum.map(& &1.value)
      assert 20 in values
    end
  end

  # --- E. Policy resolution across component types ---

  describe "policy resolution across component types" do
    test "type matcher differentiates Steps from Conditions" do
      rule = Runic.rule(fn x when x > 0 -> x * 10 end, name: :pos)

      workflow =
        Runic.workflow(rules: [rule])
        |> Workflow.set_scheduler_policies([
          {{:type, Step}, %{max_retries: 2}},
          {{:type, Condition}, %{max_retries: 0}},
          {:default, %{max_retries: 5}}
        ])

      # Resolve for a Step node
      step = Step.new(work: fn x -> x end, name: :test)
      fact = Fact.new(value: :test)

      step_runnable =
        Runnable.new(
          step,
          fact,
          Runic.Workflow.CausalContext.new(
            node_hash: step.hash,
            input_fact: fact,
            ancestry_depth: 0
          )
        )

      step_policy = SchedulerPolicy.resolve(step_runnable, workflow.scheduler_policies)
      assert step_policy.max_retries == 2
    end
  end

  # --- F. execute_with_policies public API ---

  describe "execute_with_policies/2" do
    test "resolves and executes each runnable with policies" do
      step = Runic.step(fn x -> x * 3 end, name: :triple)

      workflow =
        Runic.workflow(steps: [{step, []}])
        |> Workflow.set_scheduler_policies([{:default, %{max_retries: 0}}])
        |> Workflow.plan(7)

      {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

      executed = Workflow.execute_with_policies(runnables, workflow.scheduler_policies)

      assert length(executed) == 1
      [result] = executed
      assert result.status == :completed
      assert result.result.value == 21

      workflow = Enum.reduce(executed, workflow, &Workflow.apply_runnable(&2, &1))
      values = Workflow.raw_productions(workflow)
      assert 21 in values
    end
  end
end
