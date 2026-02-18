defmodule Runic.Workflow.SchedulerPolicyTest do
  use ExUnit.Case, async: true

  alias Runic.Workflow.SchedulerPolicy
  alias Runic.Workflow.{Step, Condition, Fact, CausalContext, Runnable}

  defp make_runnable(name, struct_mod \\ Step) do
    node =
      case struct_mod do
        Step -> Step.new(work: fn x -> x end, name: name)
        Condition -> Condition.new(work: fn _ -> true end, name: name, arity: 1)
      end

    fact = Fact.new(value: :test)
    context = CausalContext.new(node_hash: node.hash, input_fact: fact, ancestry_depth: 0)
    Runnable.new(node, fact, context)
  end

  # A. Struct construction & validation

  describe "new/1" do
    test "creates valid struct from map" do
      policy = SchedulerPolicy.new(%{max_retries: 3, backoff: :exponential})
      assert %SchedulerPolicy{max_retries: 3, backoff: :exponential} = policy
    end

    test "creates valid struct from keyword list" do
      policy = SchedulerPolicy.new(max_retries: 5, timeout_ms: 10_000)
      assert %SchedulerPolicy{max_retries: 5, timeout_ms: 10_000} = policy
    end

    test "raises on unknown keys" do
      assert_raise ArgumentError, ~r/unknown keys/, fn ->
        SchedulerPolicy.new(%{bogus_key: true})
      end

      assert_raise ArgumentError, ~r/unknown keys/, fn ->
        SchedulerPolicy.new(bogus_key: true)
      end
    end

    test "applies defaults for omitted fields" do
      policy = SchedulerPolicy.new(%{max_retries: 2})
      assert policy.backoff == :none
      assert policy.base_delay_ms == 500
      assert policy.max_delay_ms == 30_000
      assert policy.timeout_ms == :infinity
      assert policy.on_failure == :halt
      assert policy.fallback == nil
      assert policy.execution_mode == :sync
      assert policy.priority == :normal
      assert policy.idempotency_key == nil
      assert policy.deadline_ms == nil
      assert policy.circuit_breaker == nil
    end
  end

  describe "default_policy/0" do
    test "returns expected default values" do
      policy = SchedulerPolicy.default_policy()
      assert %SchedulerPolicy{} = policy
      assert policy.max_retries == 0
      assert policy.backoff == :none
      assert policy.base_delay_ms == 500
      assert policy.max_delay_ms == 30_000
      assert policy.timeout_ms == :infinity
      assert policy.on_failure == :halt
      assert policy.fallback == nil
      assert policy.execution_mode == :sync
      assert policy.priority == :normal
      assert policy.idempotency_key == nil
      assert policy.deadline_ms == nil
      assert policy.circuit_breaker == nil
    end
  end

  # B. Matcher evaluation

  describe "matchers via resolve/2" do
    test "exact atom name match" do
      runnable = make_runnable(:generate_narrative)
      policies = [{:generate_narrative, %{max_retries: 3}}]
      result = SchedulerPolicy.resolve(runnable, policies)
      assert result.max_retries == 3
    end

    test "exact atom name does NOT match different name" do
      runnable = make_runnable(:generate_narrative)
      policies = [{:other_name, %{max_retries: 3}}]
      result = SchedulerPolicy.resolve(runnable, policies)
      assert result == SchedulerPolicy.default_policy()
    end

    test "regex name match on atom name" do
      runnable = make_runnable(:llm_classify)
      policies = [{{:name, ~r/^llm_/}, %{max_retries: 5}}]
      result = SchedulerPolicy.resolve(runnable, policies)
      assert result.max_retries == 5
    end

    test "regex name does NOT match non-matching name" do
      runnable = make_runnable(:classify)
      policies = [{{:name, ~r/^llm_/}, %{max_retries: 5}}]
      result = SchedulerPolicy.resolve(runnable, policies)
      assert result == SchedulerPolicy.default_policy()
    end

    test "regex name match against string node names" do
      step = %Step{
        name: "llm_summarize",
        work: fn x -> x end,
        hash: :erlang.phash2(fn x -> x end)
      }

      fact = Fact.new(value: :test)
      context = CausalContext.new(node_hash: step.hash, input_fact: fact, ancestry_depth: 0)
      runnable = Runnable.new(step, fact, context)

      policies = [{{:name, ~r/^llm_/}, %{max_retries: 2}}]
      result = SchedulerPolicy.resolve(runnable, policies)
      assert result.max_retries == 2
    end

    test "type match — single module" do
      step_runnable = make_runnable(:my_step, Step)
      cond_runnable = make_runnable(:my_cond, Condition)

      policies = [{{:type, Step}, %{timeout_ms: 5000}}]

      assert SchedulerPolicy.resolve(step_runnable, policies).timeout_ms == 5000
      assert SchedulerPolicy.resolve(cond_runnable, policies) == SchedulerPolicy.default_policy()
    end

    test "type match — list of modules" do
      step_runnable = make_runnable(:my_step, Step)
      cond_runnable = make_runnable(:my_cond, Condition)

      policies = [{{:type, [Step, Condition]}, %{execution_mode: :async}}]

      assert SchedulerPolicy.resolve(step_runnable, policies).execution_mode == :async
      assert SchedulerPolicy.resolve(cond_runnable, policies).execution_mode == :async
    end

    test "custom predicate function — matches when true" do
      runnable = make_runnable(:heavy_step)
      matcher = fn node -> node.name == :heavy_step end
      policies = [{matcher, %{priority: :high}}]
      result = SchedulerPolicy.resolve(runnable, policies)
      assert result.priority == :high
    end

    test "custom predicate function — skips when false" do
      runnable = make_runnable(:light_step)
      matcher = fn node -> node.name == :heavy_step end
      policies = [{matcher, %{priority: :high}}]
      result = SchedulerPolicy.resolve(runnable, policies)
      assert result == SchedulerPolicy.default_policy()
    end

    test ":default catches everything" do
      runnable = make_runnable(:anything)
      policies = [{:default, %{max_retries: 1}}]
      result = SchedulerPolicy.resolve(runnable, policies)
      assert result.max_retries == 1
    end

    test "nil name on node doesn't crash any matcher" do
      step = %Step{name: nil, work: fn x -> x end, hash: :erlang.phash2(fn x -> x end)}
      fact = Fact.new(value: :test)
      context = CausalContext.new(node_hash: step.hash, input_fact: fact, ancestry_depth: 0)
      runnable = Runnable.new(step, fact, context)

      policies = [
        {:some_name, %{max_retries: 1}},
        {{:name, ~r/^test/}, %{max_retries: 2}},
        {:default, %{max_retries: 99}}
      ]

      result = SchedulerPolicy.resolve(runnable, policies)
      assert result.max_retries == 99
    end
  end

  # C. Resolution — policy list ordering and semantics

  describe "resolve/2 ordering and semantics" do
    test "first match wins" do
      runnable = make_runnable(:my_step)

      policies = [
        {:my_step, %{max_retries: 10}},
        {:my_step, %{max_retries: 20}}
      ]

      result = SchedulerPolicy.resolve(runnable, policies)
      assert result.max_retries == 10
    end

    test "runtime overrides prepended take priority over workflow base" do
      runnable = make_runnable(:my_step)

      workflow_base = [{:my_step, %{max_retries: 1}}]
      runtime_overrides = [{:my_step, %{max_retries: 5}}]

      merged = SchedulerPolicy.merge_policies(runtime_overrides, workflow_base)
      result = SchedulerPolicy.resolve(runnable, merged)
      assert result.max_retries == 5
    end

    test ":default acts as catch-all at end of list" do
      runnable = make_runnable(:unknown_step)

      policies = [
        {:specific_step, %{max_retries: 3}},
        {:default, %{max_retries: 1, on_failure: :skip}}
      ]

      result = SchedulerPolicy.resolve(runnable, policies)
      assert result.max_retries == 1
      assert result.on_failure == :skip
    end

    test "no matching rules returns default_policy" do
      runnable = make_runnable(:my_step)
      policies = [{:other_step, %{max_retries: 5}}]
      assert SchedulerPolicy.resolve(runnable, policies) == SchedulerPolicy.default_policy()
    end

    test "empty policy list returns default_policy" do
      runnable = make_runnable(:my_step)
      assert SchedulerPolicy.resolve(runnable, []) == SchedulerPolicy.default_policy()
    end

    test "nil policies returns default_policy" do
      runnable = make_runnable(:my_step)
      assert SchedulerPolicy.resolve(runnable, nil) == SchedulerPolicy.default_policy()
    end

    test "partial policy map is merged over defaults" do
      runnable = make_runnable(:my_step)
      policies = [{:my_step, %{max_retries: 3}}]
      result = SchedulerPolicy.resolve(runnable, policies)

      assert result.max_retries == 3
      assert result.backoff == :none
      assert result.timeout_ms == :infinity
      assert result.on_failure == :halt
    end
  end

  # D. merge_policies/2

  describe "merge_policies/2" do
    test "prepends overrides to base" do
      base = [{:default, %{max_retries: 1}}]
      overrides = [{:special, %{max_retries: 5}}]

      result = SchedulerPolicy.merge_policies(overrides, base)
      assert result == [{:special, %{max_retries: 5}}, {:default, %{max_retries: 1}}]
    end

    test "nil overrides returns base unchanged" do
      base = [{:default, %{max_retries: 1}}]
      assert SchedulerPolicy.merge_policies(nil, base) == base
    end

    test "empty overrides returns base unchanged" do
      base = [{:default, %{max_retries: 1}}]
      assert SchedulerPolicy.merge_policies([], base) == base
    end

    test "replace mode returns only overrides" do
      base = [{:default, %{max_retries: 1}}]
      overrides = [{:special, %{max_retries: 5}}]

      result = SchedulerPolicy.merge_policies(overrides, base, :replace)
      assert result == [{:special, %{max_retries: 5}}]
    end
  end

  # --- Presets ---

  describe "llm_policy/1" do
    test "returns expected defaults" do
      policy = SchedulerPolicy.llm_policy()

      assert %SchedulerPolicy{} = policy
      assert policy.max_retries == 3
      assert policy.backoff == :exponential
      assert policy.base_delay_ms == 1_000
      assert policy.max_delay_ms == 30_000
      assert policy.timeout_ms == 30_000
      assert policy.on_failure == :halt
    end

    test "accepts overrides" do
      policy = SchedulerPolicy.llm_policy(max_retries: 5, timeout_ms: 60_000)

      assert policy.max_retries == 5
      assert policy.timeout_ms == 60_000
      assert policy.backoff == :exponential
    end
  end

  describe "io_policy/1" do
    test "returns expected defaults" do
      policy = SchedulerPolicy.io_policy()

      assert %SchedulerPolicy{} = policy
      assert policy.max_retries == 2
      assert policy.backoff == :linear
      assert policy.base_delay_ms == 500
      assert policy.timeout_ms == 10_000
      assert policy.on_failure == :skip
    end

    test "accepts overrides" do
      policy = SchedulerPolicy.io_policy(max_retries: 0, timeout_ms: 1_000)

      assert policy.max_retries == 0
      assert policy.timeout_ms == 1_000
      assert policy.backoff == :linear
    end
  end

  describe "fast_fail/0" do
    test "returns expected values" do
      policy = SchedulerPolicy.fast_fail()

      assert %SchedulerPolicy{} = policy
      assert policy.max_retries == 0
      assert policy.timeout_ms == 5_000
      assert policy.on_failure == :halt
    end
  end

  describe "merge/2" do
    test "overrides take precedence" do
      base = %{max_retries: 1, timeout_ms: 5_000, backoff: :none}
      overrides = %{max_retries: 3}

      result = SchedulerPolicy.merge(base, overrides)

      assert result.max_retries == 3
      assert result.timeout_ms == 5_000
      assert result.backoff == :none
    end

    test "merges disjoint keys" do
      base = %{max_retries: 1}
      overrides = %{timeout_ms: 10_000}

      result = SchedulerPolicy.merge(base, overrides)

      assert result.max_retries == 1
      assert result.timeout_ms == 10_000
    end
  end
end
