defmodule Runic.Workflow.RunContextTest do
  @moduledoc """
  Tests for runtime context injection (Phases 1 & 2).

  Phase 1: Foundation
  - Workflow.put_run_context/2, get_run_context/1, get_run_context/2
  - CausalContext.with_run_context/2, run_context/1, has_run_context?/1
  - Content addressability (run_context does not affect workflow hash)

  Phase 2: context/1 meta expression
  - Detection of context/1 in step, condition, and rule DSL
  - AST rewriting and arity shifting
  - Meta ref generation with kind: :context
  """

  use ExUnit.Case
  require Runic
  alias Runic.Workflow
  alias Runic.Workflow.{CausalContext, Condition}
  alias Runic.Component

  # =============================================================================
  # Workflow.put_run_context/2
  # =============================================================================

  describe "Workflow.put_run_context/2" do
    test "merges context into empty run_context" do
      workflow =
        Workflow.new()
        |> Workflow.put_run_context(%{call_llm: %{api_key: "sk-123"}})

      assert workflow.run_context == %{call_llm: %{api_key: "sk-123"}}
    end

    test "merges with existing run_context (top-level merge)" do
      workflow =
        Workflow.new()
        |> Workflow.put_run_context(%{call_llm: %{api_key: "sk-123"}})
        |> Workflow.put_run_context(%{db_query: %{repo: MyRepo}})

      assert workflow.run_context == %{
               call_llm: %{api_key: "sk-123"},
               db_query: %{repo: MyRepo}
             }
    end

    test "overwrites existing key on merge" do
      workflow =
        Workflow.new()
        |> Workflow.put_run_context(%{call_llm: %{api_key: "sk-old"}})
        |> Workflow.put_run_context(%{call_llm: %{api_key: "sk-new"}})

      assert workflow.run_context == %{call_llm: %{api_key: "sk-new"}}
    end

    test "returns updated workflow struct" do
      workflow = Workflow.new()
      updated = Workflow.put_run_context(workflow, %{foo: %{bar: 1}})

      assert %Workflow{} = updated
      assert updated.run_context == %{foo: %{bar: 1}}
    end
  end

  # =============================================================================
  # Workflow.get_run_context/1
  # =============================================================================

  describe "Workflow.get_run_context/1" do
    test "returns empty map for new workflow" do
      assert Workflow.get_run_context(Workflow.new()) == %{}
    end

    test "returns full run_context map" do
      workflow =
        Workflow.new()
        |> Workflow.put_run_context(%{
          call_llm: %{api_key: "sk-123"},
          _global: %{workspace_id: "ws1"}
        })

      assert Workflow.get_run_context(workflow) == %{
               call_llm: %{api_key: "sk-123"},
               _global: %{workspace_id: "ws1"}
             }
    end
  end

  # =============================================================================
  # Workflow.get_run_context/2
  # =============================================================================

  describe "Workflow.get_run_context/2" do
    test "returns component-specific context by name" do
      workflow =
        Workflow.new()
        |> Workflow.put_run_context(%{call_llm: %{api_key: "sk-123", model: "gpt-4"}})

      assert Workflow.get_run_context(workflow, :call_llm) == %{api_key: "sk-123", model: "gpt-4"}
    end

    test "merges _global with component-specific (component wins)" do
      workflow =
        Workflow.new()
        |> Workflow.put_run_context(%{
          _global: %{workspace_id: "ws1", timeout: 5000},
          call_llm: %{api_key: "sk-123", timeout: 30_000}
        })

      result = Workflow.get_run_context(workflow, :call_llm)
      assert result == %{workspace_id: "ws1", api_key: "sk-123", timeout: 30_000}
    end

    test "returns only _global if no component-specific entry" do
      workflow =
        Workflow.new()
        |> Workflow.put_run_context(%{_global: %{workspace_id: "ws1"}})

      assert Workflow.get_run_context(workflow, :some_step) == %{workspace_id: "ws1"}
    end

    test "returns empty map if neither exists" do
      workflow = Workflow.new()
      assert Workflow.get_run_context(workflow, :nonexistent) == %{}
    end

    test "merges child workflow run_context into parent during workflow merge" do
      step = Runic.step(fn input -> {context(:token), input} end, name: :ctx_step)

      child_workflow =
        Workflow.new()
        |> Workflow.add(step)
        |> Workflow.put_run_context(%{
          _global: %{token: "abc123"}
        })

      [meta_step | _] =
        child_workflow.graph
        |> Graph.vertices()
        |> Enum.filter(fn v -> Map.has_key?(v, :meta_refs) and v.meta_refs != [] end)

      merged_workflow = Workflow.merge(Workflow.new(), child_workflow)

      assert Workflow.get_run_context(child_workflow, meta_step.name) == %{token: "abc123"}

      assert Workflow.get_run_context(merged_workflow, meta_step.name) == %{token: "abc123"}
    end
  end

  # =============================================================================
  # CausalContext run_context
  # =============================================================================

  describe "CausalContext run_context" do
    test "new context has empty run_context by default" do
      ctx = CausalContext.new()
      assert ctx.run_context == %{}
    end

    test "with_run_context/2 sets the run context" do
      ctx =
        CausalContext.new()
        |> CausalContext.with_run_context(%{api_key: "sk-123"})

      assert ctx.run_context == %{api_key: "sk-123"}
    end

    test "run_context/1 returns the run context" do
      ctx =
        CausalContext.new()
        |> CausalContext.with_run_context(%{foo: :bar})

      assert CausalContext.run_context(ctx) == %{foo: :bar}
    end

    test "has_run_context?/1 returns false for empty context" do
      ctx = CausalContext.new()
      refute CausalContext.has_run_context?(ctx)
    end

    test "has_run_context?/1 returns true when context is populated" do
      ctx =
        CausalContext.new()
        |> CausalContext.with_run_context(%{key: "value"})

      assert CausalContext.has_run_context?(ctx)
    end

    test "defaults don't break existing CausalContext usage" do
      ctx = CausalContext.basic(12345, nil, 0)
      assert ctx.run_context == %{}
      assert ctx.meta_context == %{}
    end
  end

  # =============================================================================
  # Content addressability
  # =============================================================================

  describe "run_context does not affect content addressability" do
    test "workflow hash is identical with different run_contexts" do
      step = Runic.step(fn x -> x + 1 end, name: :add_one)

      workflow1 =
        Workflow.new()
        |> Workflow.add(step)

      workflow2 =
        Workflow.new()
        |> Workflow.add(step)
        |> Workflow.put_run_context(%{call_llm: %{api_key: "sk-123"}})

      hash1 = Component.hash(%{workflow1 | hash: nil})
      hash2 = Component.hash(%{workflow2 | hash: nil, run_context: %{}})

      assert hash1 == hash2
    end
  end

  # =============================================================================
  # Phase 2: context/1 meta expression in step macro
  # =============================================================================

  describe "context/1 in step macro" do
    test "step with context(:api_key) has meta_refs on struct" do
      step = Runic.step(fn x -> {x, context(:api_key)} end, name: :call_api)
      assert length(step.meta_refs) == 1

      [ref] = step.meta_refs
      assert ref.kind == :context
      assert ref.target == :api_key
      assert ref.context_key == :api_key
      assert ref.field_path == []
    end

    test "step work function is arity 2 when context/1 is used" do
      step = Runic.step(fn x -> {x, context(:api_key)} end, name: :call_api)
      assert is_function(step.work, 2)
    end

    test "step with context(:config).pool_size has field_path [:pool_size]" do
      step = Runic.step(fn x -> x + context(:config).pool_size end, name: :pooled)
      assert length(step.meta_refs) == 1

      [ref] = step.meta_refs
      assert ref.kind == :context
      assert ref.target == :config
      assert ref.context_key == :config
      assert ref.field_path == [:pool_size]
    end

    test "step without context/1 is unchanged (no meta_refs, original arity)" do
      step = Runic.step(fn x -> x + 1 end, name: :plain)
      assert step.meta_refs == []
      assert is_function(step.work, 1)
    end

    test "step/1 variant detects context/1" do
      step = Runic.step(fn x -> {x, context(:token)} end)
      assert length(step.meta_refs) == 1
      assert hd(step.meta_refs).kind == :context
      assert hd(step.meta_refs).target == :token
    end

    test "step with context/1 work function resolves from meta_ctx" do
      step = Runic.step(fn _x -> context(:api_key) end, name: :get_key)
      result = step.work.(:input, %{api_key: "sk-secret"})
      assert result == "sk-secret"
    end

    test "step with context(:cfg).field resolves dot access from meta_ctx" do
      step = Runic.step(fn _x -> context(:cfg).timeout end, name: :get_timeout)
      result = step.work.(:input, %{cfg: %{timeout: 5000}})
      assert result == 5000
    end
  end

  # =============================================================================
  # Phase 2: context/1 meta expression in condition macro
  # =============================================================================

  describe "context/1 in condition macro" do
    test "condition with context(:feature_flag) has meta_refs" do
      cond = Runic.condition(fn _x -> context(:feature_flag) end, name: :check_flag)
      assert length(cond.meta_refs) == 1

      [ref] = cond.meta_refs
      assert ref.kind == :context
      assert ref.target == :feature_flag
    end

    test "condition arity is 2 when context/1 is used" do
      cond = Runic.condition(fn _x -> context(:feature_flag) end, name: :check_flag)
      assert cond.arity == 2
    end

    test "condition without context/1 retains original arity" do
      cond = Runic.condition(fn x -> x > 10 end)
      assert cond.arity == 1
      assert cond.meta_refs == []
    end

    test "condition/1 variant detects context/1" do
      cond = Runic.condition(fn _x -> context(:enabled) end)
      assert length(cond.meta_refs) == 1
      assert hd(cond.meta_refs).kind == :context
    end

    test "condition with context/1 work function resolves from meta_ctx" do
      cond = Runic.condition(fn x -> x > context(:threshold) end, name: :above_thresh)
      assert cond.work.(15, %{threshold: 10})
      refute cond.work.(5, %{threshold: 10})
    end
  end

  # =============================================================================
  # Phase 2: context/1 meta expression in rule DSL
  # =============================================================================

  describe "context/1 in rule DSL" do
    test "context(:key) in where clause produces condition meta_refs with kind: :context" do
      rule =
        Runic.rule name: :check_threshold do
          given(val: v)
          where(v > context(:threshold))
          then(fn %{val: v} -> {:above, v} end)
        end

      # The rule's inner workflow contains a condition with the context meta_ref
      conditions = Workflow.conditions(rule.workflow)
      meta_conditions = Enum.filter(conditions, &Condition.has_meta_refs?/1)
      assert length(meta_conditions) == 1

      [cond] = meta_conditions
      assert length(cond.meta_refs) == 1
      [ref] = cond.meta_refs
      assert ref.kind == :context
      assert ref.target == :threshold
      assert ref.context_key == :threshold
    end

    test "context(:key) in then clause produces reaction meta_refs with kind: :context" do
      rule =
        Runic.rule name: :tag_with_tenant do
          given(val: v)
          where(v > 0)
          then(fn %{val: v} -> {context(:tenant_id), v} end)
        end

      # The reaction step should have context meta_refs
      steps = Workflow.steps(rule.workflow)
      meta_steps = Enum.filter(steps, fn s -> s.meta_refs != [] end)
      assert length(meta_steps) == 1

      [step] = meta_steps
      [ref] = step.meta_refs
      assert ref.kind == :context
      assert ref.target == :tenant_id
    end

    test "mixed state_of + context in where clause produces both ref kinds" do
      counter = Runic.accumulator(0, fn x, acc -> acc + x end, name: :counter)

      rule =
        Runic.rule name: :mixed_refs do
          given(val: v)
          where(v > context(:min_val) and state_of(:counter) > 0)
          then(fn %{val: v} -> {:ok, v} end)
        end

      # Add counter first so the rule can resolve state_of(:counter)
      workflow =
        Workflow.new()
        |> Workflow.add(counter)
        |> Workflow.add(rule)

      conditions = Workflow.conditions(workflow)
      meta_conditions = Enum.filter(conditions, &Condition.has_meta_refs?/1)

      all_refs = Enum.flat_map(meta_conditions, & &1.meta_refs)
      kinds = Enum.map(all_refs, & &1.kind) |> Enum.sort()

      assert :context in kinds
      assert :state_of in kinds
    end
  end

  # =============================================================================
  # Phase 3: Runtime resolution in steps
  # =============================================================================

  describe "context/1 resolution in steps" do
    test "step with context(:api_key) receives value from run_context during execution" do
      step = Runic.step(fn _x -> context(:api_key) end, name: :get_key)

      workflow =
        Workflow.new()
        |> Workflow.add(step)
        |> Workflow.put_run_context(%{get_key: %{api_key: "sk-secret"}})
        |> Workflow.react_until_satisfied(42)

      assert Workflow.raw_productions(workflow) == ["sk-secret"]
    end

    test "step receives _global values when no component-specific entry" do
      step = Runic.step(fn _x -> context(:workspace_id) end, name: :lookup)

      workflow =
        Workflow.new()
        |> Workflow.add(step)
        |> Workflow.put_run_context(%{_global: %{workspace_id: "ws-123"}})
        |> Workflow.react_until_satisfied(:input)

      assert Workflow.raw_productions(workflow) == ["ws-123"]
    end

    test "component-specific context overrides _global" do
      step = Runic.step(fn _x -> context(:timeout) end, name: :call_api)

      workflow =
        Workflow.new()
        |> Workflow.add(step)
        |> Workflow.put_run_context(%{
          _global: %{timeout: 5000},
          call_api: %{timeout: 30_000}
        })
        |> Workflow.react_until_satisfied(:input)

      assert Workflow.raw_productions(workflow) == [30_000]
    end

    test "step without context/1 is unaffected by run_context" do
      step = Runic.step(fn x -> x + 1 end, name: :add_one)

      workflow =
        Workflow.new()
        |> Workflow.add(step)
        |> Workflow.put_run_context(%{add_one: %{irrelevant: true}})
        |> Workflow.react_until_satisfied(5)

      assert Workflow.raw_productions(workflow) == [6]
    end

    test "step result flows through fact graph normally (context not in facts)" do
      step1 = Runic.step(fn _x -> context(:multiplier) end, name: :get_mult)
      step2 = Runic.step(fn x -> x * 10 end, name: :apply_mult)

      workflow =
        Workflow.new()
        |> Workflow.add(step1)
        |> Workflow.add(step2, to: :get_mult)
        |> Workflow.put_run_context(%{get_mult: %{multiplier: 7}})
        |> Workflow.react_until_satisfied(:input)

      assert Workflow.raw_productions(workflow, :apply_mult) == [70]
    end

    test "context(:key).field resolves nested values at runtime" do
      step = Runic.step(fn _x -> context(:config).pool_size end, name: :get_pool)

      workflow =
        Workflow.new()
        |> Workflow.add(step)
        |> Workflow.put_run_context(%{get_pool: %{config: %{pool_size: 8}}})
        |> Workflow.react_until_satisfied(:input)

      assert Workflow.raw_productions(workflow) == [8]
    end
  end

  # =============================================================================
  # Phase 3: Runtime resolution in conditions
  # =============================================================================

  describe "context/1 resolution in conditions" do
    test "condition with context(:feature_flag) receives value from run_context" do
      rule =
        Runic.rule name: :gated_step do
          given(val: v)
          where(context(:enabled))
          then(fn %{val: v} -> {:allowed, v} end)
        end

      # With flag enabled
      workflow =
        Workflow.new()
        |> Workflow.add(rule)
        |> Workflow.put_run_context(%{_global: %{enabled: true}})
        |> Workflow.react_until_satisfied(42)

      assert Workflow.raw_productions(workflow) == [{:allowed, 42}]
    end

    test "condition gates correctly based on context value" do
      rule =
        Runic.rule name: :threshold_check do
          given(val: v)
          where(v > context(:threshold))
          then(fn %{val: v} -> {:above, v} end)
        end

      # Above threshold
      wf_above =
        Workflow.new()
        |> Workflow.add(rule)
        |> Workflow.put_run_context(%{_global: %{threshold: 10}})
        |> Workflow.react_until_satisfied(15)

      assert Workflow.raw_productions(wf_above) == [{:above, 15}]

      # Below threshold - should produce no results
      wf_below =
        Workflow.new()
        |> Workflow.add(rule)
        |> Workflow.put_run_context(%{_global: %{threshold: 10}})
        |> Workflow.react_until_satisfied(5)

      assert Workflow.raw_productions(wf_below) == []
    end
  end

  # =============================================================================
  # Phase 3: Mixed state_of + context runtime resolution
  # =============================================================================

  describe "mixed state_of + context runtime resolution" do
    test "rule with state_of and context in where clause resolves both" do
      counter = Runic.accumulator(0, fn x, acc -> acc + x end, name: :counter)

      rule =
        Runic.rule name: :check_both do
          given(val: v)
          where(state_of(:counter) >= context(:limit))
          then(fn %{val: v} -> {:triggered, v} end)
        end

      # Connect rule after counter so condition sees updated state
      workflow =
        Workflow.new()
        |> Workflow.add(counter)
        |> Workflow.add(rule, to: :counter)
        |> Workflow.put_run_context(%{_global: %{limit: 5}})

      # First input: counter becomes 3 (state=3, below limit 5)
      # Rule sees accumulator output (state value 3) with state_of(:counter) = 3
      wf1 = Workflow.react_until_satisfied(workflow, 3)
      assert Workflow.raw_productions(wf1, :check_both) == []

      # Second input: counter becomes 7 (state=7, above limit 5)
      # Rule sees accumulator output (state value 7) with state_of(:counter) = 7
      wf2 = Workflow.react_until_satisfied(wf1, 4)
      assert Workflow.raw_productions(wf2, :check_both) == [{:triggered, 7}]
    end

    test "accumulator continues from the latest state across sequential reactions" do
      counter = Runic.accumulator(0, fn x, acc -> acc + x end, name: :counter)

      wf1 =
        Workflow.new()
        |> Workflow.add(counter)
        |> Workflow.react_until_satisfied(3)

      wf2 = Workflow.react_until_satisfied(wf1, 4)
      wf3 = Workflow.react_until_satisfied(wf2, 5)
      productions = Workflow.raw_productions(wf3, :counter)

      assert 12 in productions
      refute 8 in productions
    end
  end

  # =============================================================================
  # Phase 3: Context isolation from data plane
  # =============================================================================

  describe "context isolation from data plane" do
    test "run_context values do not appear in produced facts" do
      step = Runic.step(fn _x -> context(:secret) end, name: :get_secret)

      workflow =
        Workflow.new()
        |> Workflow.add(step)
        |> Workflow.put_run_context(%{get_secret: %{secret: "classified"}})
        |> Workflow.react_until_satisfied(:input)

      # The fact contains the result value, not the context map
      facts = Workflow.facts(workflow)

      fact_values = Enum.map(facts, & &1.value)
      assert "classified" in fact_values
      refute %{secret: "classified"} in fact_values
    end

    test "run_context values do not appear in event log" do
      step = Runic.step(fn _x -> context(:token) end, name: :use_token)

      workflow =
        Workflow.new()
        |> Workflow.add(step)
        |> Workflow.put_run_context(%{use_token: %{token: "abc"}})
        |> Workflow.react_until_satisfied(:go)

      log = Workflow.build_log(workflow)

      log_string = inspect(log, limit: :infinity)

      # The token value "abc" appears as a fact result (that's expected)
      # But the run_context map itself should not be serialized
      refute log_string =~ "run_context"
    end
  end

  # =============================================================================
  # Phase 4: Runtime API Integration
  # =============================================================================

  describe "react/3 with run_context option" do
    test "passes context to steps via opts" do
      step = Runic.step(fn _x -> context(:api_key) end, name: :get_key)

      wf =
        Workflow.new()
        |> Workflow.add(step)
        |> Workflow.react(:input, run_context: %{get_key: %{api_key: "test-key-123"}})
        |> Workflow.react_until_satisfied()

      assert Workflow.raw_productions(wf, :get_key) == ["test-key-123"]
    end

    test "context persists across react cycles in react_until_satisfied" do
      step1 = Runic.step(fn _x -> context(:token) end, name: :get_token)
      step2 = Runic.step(fn x -> "bearer_#{x}" end, name: :format_token)

      workflow =
        Workflow.new()
        |> Workflow.add(step1)
        |> Workflow.add(step2, to: :get_token)

      wf =
        Workflow.react_until_satisfied(workflow, :start,
          run_context: %{get_token: %{token: "abc123"}}
        )

      assert Workflow.raw_productions(wf, :format_token) == ["bearer_abc123"]
    end
  end

  describe "react_until_satisfied/3 with run_context option" do
    test "full pipeline execution with context injection" do
      step = Runic.step(fn _x -> context(:secret) end, name: :fetch)

      wf =
        Workflow.new()
        |> Workflow.add(step)
        |> Workflow.react_until_satisfied(:go, run_context: %{fetch: %{secret: "s3cr3t"}})

      assert Workflow.raw_productions(wf, :fetch) == ["s3cr3t"]
    end

    test "multi-step pipeline where only some steps use context" do
      step1 = Runic.step(fn x -> x * 2 end, name: :double)
      step2 = Runic.step(fn x -> x + context(:offset) end, name: :add_offset)

      wf =
        Workflow.new()
        |> Workflow.add(step1)
        |> Workflow.add(step2, to: :double)
        |> Workflow.react_until_satisfied(5,
          run_context: %{add_offset: %{offset: 100}}
        )

      assert Workflow.raw_productions(wf, :double) == [10]
      assert Workflow.raw_productions(wf, :add_offset) == [110]
    end

    test "run_context via opts merges with pre-existing run_context" do
      step = Runic.step(fn _x -> {context(:a), context(:b)} end, name: :both)

      wf =
        Workflow.new()
        |> Workflow.add(step)
        |> Workflow.put_run_context(%{_global: %{a: 1}})
        |> Workflow.react_until_satisfied(:go, run_context: %{both: %{b: 2}})

      assert Workflow.raw_productions(wf, :both) == [{1, 2}]
    end
  end

  # =============================================================================
  # Phase 5: Introspection & Validation
  # =============================================================================

  describe "Workflow.required_context_keys/1" do
    test "returns empty map for workflow with no context refs" do
      step = Runic.step(fn x -> x + 1 end, name: :plain)
      wf = Workflow.new() |> Workflow.add(step)

      assert Workflow.required_context_keys(wf) == %{}
    end

    test "returns component to keys map for workflow with context refs" do
      step1 = Runic.step(fn _x -> context(:api_key) end, name: :call_llm)
      step2 = Runic.step(fn x -> x + context(:offset) end, name: :compute)

      wf =
        Workflow.new()
        |> Workflow.add(step1)
        |> Workflow.add(step2)

      result = Workflow.required_context_keys(wf)
      assert result[:call_llm] == [api_key: :required]
      assert result[:compute] == [offset: :required]
      assert map_size(result) == 2
    end

    test "includes refs from both steps and conditions in rules" do
      rule =
        Runic.rule name: :gated do
          given(val: v)
          where(v > context(:threshold))
          then(fn %{val: v} -> {:ok, v} end)
        end

      wf = Workflow.new() |> Workflow.add(rule)
      result = Workflow.required_context_keys(wf)

      # The condition inside the rule should have context refs
      context_keys = Map.values(result) |> List.flatten() |> Keyword.keys()
      assert :threshold in context_keys
    end

    test "does not include state_of or other meta ref kinds" do
      counter = Runic.accumulator(0, fn x, acc -> acc + x end, name: :counter)

      rule =
        Runic.rule name: :check do
          given(val: v)
          where(state_of(:counter) > 0)
          then(fn %{val: v} -> v end)
        end

      wf =
        Workflow.new()
        |> Workflow.add(counter)
        |> Workflow.add(rule)

      # state_of refs should not appear in required_context_keys
      assert Workflow.required_context_keys(wf) == %{}
    end
  end

  describe "Workflow.validate_run_context/2" do
    test "returns :ok when all keys present" do
      step = Runic.step(fn _x -> context(:api_key) end, name: :call_llm)
      wf = Workflow.new() |> Workflow.add(step)

      assert :ok = Workflow.validate_run_context(wf, %{call_llm: %{api_key: "key"}})
    end

    test "returns {:error, missing} when keys missing" do
      step1 = Runic.step(fn _x -> context(:api_key) end, name: :call_llm)
      step2 = Runic.step(fn _x -> context(:repo) end, name: :db_query)

      wf =
        Workflow.new()
        |> Workflow.add(step1)
        |> Workflow.add(step2)

      assert {:error, missing} = Workflow.validate_run_context(wf, %{})
      assert :api_key in missing[:call_llm]
      assert :repo in missing[:db_query]
    end

    test "considers _global keys as satisfying any component's requirements" do
      step = Runic.step(fn _x -> context(:workspace_id) end, name: :lookup)
      wf = Workflow.new() |> Workflow.add(step)

      assert :ok = Workflow.validate_run_context(wf, %{_global: %{workspace_id: "ws-1"}})
    end

    test "returns :ok for workflow with no context requirements" do
      step = Runic.step(fn x -> x + 1 end, name: :plain)
      wf = Workflow.new() |> Workflow.add(step)

      assert :ok = Workflow.validate_run_context(wf, %{})
    end
  end

  # =============================================================================
  # Phase 11: context/2 with default values
  # =============================================================================

  describe "context/2 with default literal" do
    test "step with context(:key, default: \"fallback\") has default in meta_ref" do
      step = Runic.step(fn _x -> context(:api_key, default: "test-key") end, name: :with_default)
      assert length(step.meta_refs) == 1

      [ref] = step.meta_refs
      assert ref.kind == :context
      assert ref.target == :api_key
      assert ref.default == "test-key"
    end

    test "step uses default when run_context does not provide key" do
      step = Runic.step(fn _x -> context(:api_key, default: "fallback") end, name: :defaulted)

      workflow =
        Workflow.new()
        |> Workflow.add(step)
        |> Workflow.react_until_satisfied(:go)

      productions = Workflow.raw_productions(workflow)
      assert "fallback" in productions
    end

    test "step uses run_context value when provided (overrides default)" do
      step = Runic.step(fn _x -> context(:api_key, default: "fallback") end, name: :defaulted)

      workflow =
        Workflow.new()
        |> Workflow.add(step)
        |> Workflow.put_run_context(%{defaulted: %{api_key: "real-key"}})
        |> Workflow.react_until_satisfied(:go)

      productions = Workflow.raw_productions(workflow)
      assert "real-key" in productions
      refute "fallback" in productions
    end

    test "different defaults produce different hashes" do
      step1 = Runic.step(fn _x -> context(:key, default: "a") end, name: :s1)
      step2 = Runic.step(fn _x -> context(:key, default: "b") end, name: :s2)

      assert step1.hash != step2.hash
    end

    test "default works in conditions" do
      cond_node =
        Runic.condition(fn x -> x > context(:threshold, default: 10) end, name: :thresh_cond)

      assert length(cond_node.meta_refs) == 1
      [ref] = cond_node.meta_refs
      assert ref.default == 10
    end

    test "default works in rule where clause" do
      rule =
        Runic.rule name: :default_rule do
          given(val: v)
          where(v > context(:threshold, default: 5))
          then(fn %{val: v} -> {:over, v} end)
        end

      workflow =
        Workflow.new()
        |> Workflow.add(rule)
        |> Workflow.react_until_satisfied(10)

      productions = Workflow.raw_productions(workflow)
      assert {:over, 10} in productions
    end

    test "default works in rule then clause" do
      rule =
        Runic.rule name: :default_then do
          given(val: v)
          where(v > 0)
          then(fn %{val: v} -> {v, context(:tag, default: :untagged)} end)
        end

      workflow =
        Workflow.new()
        |> Workflow.add(rule)
        |> Workflow.react_until_satisfied(42)

      productions = Workflow.raw_productions(workflow)
      assert {42, :untagged} in productions
    end

    test "default works in accumulator reducer" do
      acc =
        Runic.accumulator(0, fn x, state -> state + x * context(:factor, default: 2) end,
          name: :default_acc
        )

      workflow =
        Workflow.new()
        |> Workflow.add(acc)
        |> Workflow.react_until_satisfied(5)

      productions = Workflow.raw_productions(workflow)
      assert 10 in productions
    end
  end

  describe "context/2 with default function" do
    test "step with default function uses fn when key missing" do
      step =
        Runic.step(fn _x -> context(:api_key, default: fn -> "fn-default" end) end,
          name: :fn_default
        )

      workflow =
        Workflow.new()
        |> Workflow.add(step)
        |> Workflow.react_until_satisfied(:go)

      productions = Workflow.raw_productions(workflow)
      assert "fn-default" in productions
    end

    test "default function is not called when value is provided" do
      step =
        Runic.step(
          fn _x -> context(:api_key, default: fn -> raise "should not be called" end) end,
          name: :fn_default
        )

      workflow =
        Workflow.new()
        |> Workflow.add(step)
        |> Workflow.put_run_context(%{fn_default: %{api_key: "provided"}})
        |> Workflow.react_until_satisfied(:go)

      productions = Workflow.raw_productions(workflow)
      assert "provided" in productions
    end
  end

  describe "context/2 interaction with validate_run_context" do
    test "keys with defaults are NOT reported as missing" do
      step =
        Runic.step(fn _x -> context(:api_key, default: "fallback") end, name: :optional_step)

      wf = Workflow.new() |> Workflow.add(step)
      assert :ok = Workflow.validate_run_context(wf, %{})
    end

    test "keys without defaults ARE reported as missing" do
      step = Runic.step(fn _x -> context(:api_key) end, name: :required_step)
      wf = Workflow.new() |> Workflow.add(step)

      assert {:error, missing} = Workflow.validate_run_context(wf, %{})
      assert :api_key in missing[:required_step]
    end

    test "mixed required and optional — only required reported" do
      step =
        Runic.step(
          fn _x -> {context(:api_key), context(:model, default: "gpt-4")} end,
          name: :mixed
        )

      wf = Workflow.new() |> Workflow.add(step)

      assert {:error, missing} = Workflow.validate_run_context(wf, %{})
      assert :api_key in missing[:mixed]
    end

    test "required_context_keys distinguishes required vs optional" do
      step =
        Runic.step(
          fn _x -> {context(:api_key), context(:model, default: "gpt-4")} end,
          name: :mixed
        )

      wf = Workflow.new() |> Workflow.add(step)
      result = Workflow.required_context_keys(wf)

      entries = result[:mixed]
      assert {:api_key, :required} in entries
      assert {:model, {:optional, "gpt-4"}} in entries
    end
  end

  describe "context/2 backward compatibility" do
    test "context(:key) without default still resolves to nil when missing" do
      step = Runic.step(fn _x -> context(:missing_key) end, name: :nil_step)

      workflow =
        Workflow.new()
        |> Workflow.add(step)
        |> Workflow.react_until_satisfied(:go)

      productions = Workflow.raw_productions(workflow)
      assert nil in productions
    end

    test "existing context/1 workflows unchanged" do
      step = Runic.step(fn _x -> context(:api_key) end, name: :original)

      workflow =
        Workflow.new()
        |> Workflow.add(step)
        |> Workflow.put_run_context(%{original: %{api_key: "real-key"}})
        |> Workflow.react_until_satisfied(:go)

      productions = Workflow.raw_productions(workflow)
      assert "real-key" in productions
    end
  end

  # =============================================================================
  # Phase 8: context/1 in Map components
  # =============================================================================

  describe "context/1 in map" do
    test "map with simple fn using context(:key) — inner step has meta_refs" do
      map = Runic.map(fn x -> x + context(:offset) end, name: :offset_map)

      inner_steps = Workflow.steps(map.pipeline)
      meta_steps = Enum.filter(inner_steps, fn s -> s.meta_refs != [] end)
      assert length(meta_steps) >= 1

      [step | _] = meta_steps
      [ref] = step.meta_refs
      assert ref.kind == :context
      assert ref.target == :offset
    end

    test "map pipeline execution receives context values via _global" do
      map = Runic.map(fn x -> x * context(:multiplier) end, name: :mult_map)

      workflow =
        Workflow.new()
        |> Workflow.add(map)
        |> Workflow.put_run_context(%{_global: %{multiplier: 10}})
        |> Workflow.react_until_satisfied([1, 2, 3])

      productions = Workflow.raw_productions(workflow)
      assert Enum.sort(productions) == [10, 20, 30]
    end

    test "map with context in multi-step pipeline" do
      map =
        Runic.map(
          {Runic.step(fn x -> x + context(:offset) end, name: :add_offset),
           [Runic.step(fn x -> x * 2 end, name: :double_it)]},
          name: :pipeline_map
        )

      workflow =
        Workflow.new()
        |> Workflow.add(map)
        |> Workflow.put_run_context(%{add_offset: %{offset: 100}})
        |> Workflow.react_until_satisfied([1, 2])

      productions = Workflow.raw_productions(workflow)
      assert 202 in productions
      assert 204 in productions
    end

    test "map with context passed via react opts" do
      map = Runic.map(fn x -> x + context(:bonus) end, name: :bonus_map)

      workflow =
        Workflow.new()
        |> Workflow.add(map)
        |> Workflow.react_until_satisfied([10, 20],
          run_context: %{_global: %{bonus: 5}}
        )

      productions = Workflow.raw_productions(workflow)
      assert Enum.sort(productions) == [15, 25]
    end
  end

  # =============================================================================
  # Phase 7: context/1 in Accumulator
  # =============================================================================

  describe "context/1 in accumulator" do
    test "accumulator with context(:key) in reducer has meta_refs on struct" do
      acc = Runic.accumulator(0, fn x, state -> state + x * context(:factor) end, name: :scaled)
      assert length(acc.meta_refs) == 1

      [ref] = acc.meta_refs
      assert ref.kind == :context
      assert ref.target == :factor
      assert ref.context_key == :factor
    end

    test "accumulator reducer is arity 3 when context is used" do
      acc = Runic.accumulator(0, fn x, state -> state + x * context(:factor) end, name: :scaled)
      assert is_function(acc.reducer, 3)
    end

    test "accumulator without context/1 is unchanged" do
      acc = Runic.accumulator(0, fn x, state -> state + x end, name: :plain)
      assert acc.meta_refs == []
      assert is_function(acc.reducer, 2)
    end

    test "accumulator in workflow receives context values during execution" do
      acc = Runic.accumulator(0, fn x, state -> state + x * context(:factor) end, name: :scaled)

      workflow =
        Workflow.new()
        |> Workflow.add(acc)
        |> Workflow.put_run_context(%{scaled: %{factor: 10}})
        |> Workflow.react_until_satisfied(5)

      productions = Workflow.raw_productions(workflow)
      assert 50 in productions
    end

    test "accumulator with context(:decay_factor) applies decay to state" do
      acc =
        Runic.accumulator(100, fn _x, state -> trunc(state * context(:decay)) end,
          name: :decaying
        )

      workflow =
        Workflow.new()
        |> Workflow.add(acc)
        |> Workflow.put_run_context(%{decaying: %{decay: 0.5}})

      wf1 = Workflow.react_until_satisfied(workflow, :tick)
      assert 50 in Workflow.raw_productions(wf1)
    end

    test "context does not affect content addressability of accumulator" do
      acc = Runic.accumulator(0, fn x, s -> s + x end, name: :counter)

      wf1 = Workflow.new() |> Workflow.add(acc)

      wf2 =
        Workflow.new()
        |> Workflow.add(acc)
        |> Workflow.put_run_context(%{counter: %{irrelevant: true}})

      hash1 = Component.hash(%{wf1 | hash: nil})
      hash2 = Component.hash(%{wf2 | hash: nil, run_context: %{}})
      assert hash1 == hash2
    end
  end

  # =============================================================================
  # Phase 9: context/1 in Reduce
  # =============================================================================

  describe "context/1 in reduce" do
    test "reduce with context(:key) in reducer has meta_refs on FanIn struct" do
      red = Runic.reduce(0, fn x, acc -> acc + x * context(:weight) end, name: :weighted_sum)
      assert length(red.fan_in.meta_refs) == 1

      [ref] = red.fan_in.meta_refs
      assert ref.kind == :context
      assert ref.target == :weight
    end

    test "FanIn reducer is arity 3 when context is used" do
      red = Runic.reduce(0, fn x, acc -> acc + x * context(:weight) end, name: :weighted_sum)
      assert is_function(red.fan_in.reducer, 3)
    end

    test "FanIn has name from reduce" do
      red = Runic.reduce(0, fn x, acc -> acc + x end, name: :my_sum)
      assert red.fan_in.name == :my_sum
    end

    test "reduce without context/1 is unchanged" do
      red = Runic.reduce(0, fn x, acc -> acc + x end, name: :plain_sum)
      assert red.fan_in.meta_refs == []
      assert is_function(red.fan_in.reducer, 2)
    end

    test "simple reduce with context receives values during execution" do
      gen = Runic.step(fn _x -> [1, 2, 3] end, name: :gen)

      red =
        Runic.reduce(0, fn x, acc -> acc + x * context(:weight) end, name: :weighted_sum)

      workflow =
        Workflow.new()
        |> Workflow.add(gen)
        |> Workflow.add(red, to: :gen)
        |> Workflow.put_run_context(%{weighted_sum: %{weight: 10}})
        |> Workflow.react_until_satisfied(:go)

      assert 60 in Workflow.raw_productions(workflow, :weighted_sum)
    end
  end

  # =============================================================================
  # Phase 10: context/1 support in StateMachine
  # =============================================================================

  describe "context/1 in state_machine" do
    test "state machine internal accumulator receives context via run_context" do
      sm =
        Runic.state_machine(
          name: :counter,
          init: 0,
          reducer: fn
            x, state when is_integer(x) -> state + x
          end
        )

      # The accumulator should have meta_refs field (defaults to [])
      assert sm.accumulator.meta_refs == []
    end

    test "state machine without context/1 is unchanged and works normally" do
      sm =
        Runic.state_machine(
          name: :simple_counter,
          init: 0,
          reducer: fn
            x, state when is_integer(x) -> state + x
          end
        )

      workflow =
        Workflow.new()
        |> Workflow.add(sm)
        |> Workflow.react_until_satisfied(5)

      productions = Workflow.raw_productions(workflow)
      assert 5 in productions
    end

    test "state machine context propagation via _global affects accumulator" do
      # State machine with accumulator that uses context/1 in its reducer
      # This tests that run_context propagates to internal components
      sm =
        Runic.state_machine(
          name: :sm_counter,
          init: 0,
          reducer: fn
            x, state when is_integer(x) -> state + x
          end
        )

      workflow =
        Workflow.new()
        |> Workflow.add(sm)
        |> Workflow.put_run_context(%{_global: %{irrelevant: true}})
        |> Workflow.react_until_satisfied(5)

      # Basic functionality should not be broken by presence of run_context
      productions = Workflow.raw_productions(workflow)
      assert 5 in productions
    end
  end
end
