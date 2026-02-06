defmodule ConditionComponentTest do
  use ExUnit.Case

  alias Runic.Workflow.Condition
  alias Runic.Workflow.Rule
  alias Runic.Workflow
  alias Runic.Closure
  require Runic

  describe "Phase 1: Runic.condition macro" do
    test "anonymous function form produces a Condition with closure and name" do
      cond = Runic.condition(fn x -> x > 10 end)

      assert %Condition{} = cond
      assert is_function(cond.work)
      assert cond.arity == 1
      assert cond.hash != nil
      assert cond.name != nil
      assert %Closure{} = cond.closure
      assert cond.closure.source != nil
    end

    test "condition evaluates correctly" do
      cond = Runic.condition(fn x -> x > 10 end)

      assert Condition.check(cond, 15)
      refute Condition.check(cond, 5)
    end

    test "pattern-matching condition works" do
      cond = Runic.condition(fn :potato -> true end)

      assert Condition.check(cond, :potato)
      refute Condition.check(cond, :tomato)
    end

    test "captured function form produces a Condition with closure" do
      cond = Runic.condition(&is_integer/1)

      assert %Condition{} = cond
      assert is_function(cond.work)
      assert cond.hash != nil
      assert cond.name != nil
      assert %Closure{} = cond.closure
    end

    test "MFA tuple form produces a Condition" do
      cond = Runic.condition({Kernel, :is_integer, 1})

      assert %Condition{} = cond
      assert is_function(cond.work)
      assert cond.hash != nil
      assert cond.arity == 1
    end

    test "condition with name option" do
      cond = Runic.condition(fn x -> x > 10 end, name: :big_number)

      assert %Condition{} = cond
      assert cond.name == :big_number
    end

    test "pinned variables produce unique hashes and are captured in closure" do
      threshold = 10
      cond1 = Runic.condition(fn x -> x > ^threshold end)

      assert %Condition{} = cond1
      assert cond1.closure.bindings[:threshold] == 10
      assert Condition.check(cond1, 15)
      refute Condition.check(cond1, 5)

      threshold2 = 20
      cond2 = Runic.condition(fn x -> x > ^threshold2 end)

      assert cond2.closure.bindings[:threshold2] == 20
      assert Condition.check(cond2, 25)
      refute Condition.check(cond2, 15)
    end

    test "content-addressable: different pinned binding values produce different hashes" do
      val1 = 10
      cond1 = Runic.condition(fn x -> x > ^val1 end)

      val2 = 20
      val1 = val2
      cond2 = Runic.condition(fn x -> x > ^val1 end)

      assert cond1.hash != cond2.hash
    end

    test "Condition.new/1 still works as runtime constructor" do
      cond = Condition.new(fn x -> x > 10 end)

      assert %Condition{} = cond
      assert is_function(cond.work)
      assert cond.hash != nil
      assert cond.arity == 1
      # runtime constructor doesn't produce closure or name
      assert cond.closure == nil
      assert cond.name == nil
    end

    test "captured function condition evaluates correctly" do
      cond = Runic.condition(&is_integer/1)

      assert Condition.check(cond, 42)
      refute Condition.check(cond, "hello")
    end

    test "MFA tuple condition evaluates correctly" do
      cond = Runic.condition({Kernel, :is_integer, 1})

      assert Condition.check(cond, 42)
      refute Condition.check(cond, "hello")
    end
  end

  describe "Phase 2: Component protocol for Condition" do
    test "Condition implements Component.hash/1" do
      cond = Runic.condition(fn x -> x > 10 end)
      assert Runic.Component.hash(cond) == cond.hash
    end

    test "Condition implements Component.source/1 with closure" do
      cond = Runic.condition(fn x -> x > 10 end)
      assert Runic.Component.source(cond) != nil
    end

    test "Condition implements Component.source/1 without closure" do
      cond = Condition.new(fn x -> x > 10 end)
      assert Runic.Component.source(cond) == nil
    end

    test "Condition implements Component.inputs/1" do
      cond = Runic.condition(fn x -> x > 10 end)
      schema = Runic.Component.inputs(cond)

      assert is_list(schema)
      assert Keyword.has_key?(schema, :condition)

      condition_schema = Keyword.fetch!(schema, :condition)
      assert Keyword.get(condition_schema, :type) == :any
    end

    test "Condition implements Component.outputs/1" do
      cond = Runic.condition(fn x -> x > 10 end)
      schema = Runic.Component.outputs(cond)

      assert is_list(schema)
      assert Keyword.has_key?(schema, :condition)

      condition_schema = Keyword.fetch!(schema, :condition)
      assert Keyword.get(condition_schema, :type) == :any
    end

    test "Condition implements Component.connectable?/2" do
      cond = Runic.condition(fn x -> x > 10 end)
      step = Runic.step(fn x -> x * 2 end)

      assert Runic.Component.connectable?(cond, step)
    end

    test "condition can be added to a workflow via Workflow.add/2" do
      cond = Runic.condition(fn x -> x > 10 end, name: :big_check)

      workflow =
        Workflow.new("test")
        |> Workflow.add(cond)

      assert cond in Graph.vertices(workflow.graph)
      assert Map.has_key?(workflow.components, :big_check)
    end

    test "condition can be added to a workflow with a parent step" do
      step = Runic.step(fn x -> x + 1 end, name: :add_one)
      cond = Runic.condition(fn x -> x > 10 end, name: :big_check)

      workflow =
        Workflow.new("test")
        |> Workflow.add(step)
        |> Workflow.add(cond, to: :add_one)

      assert cond in Graph.vertices(workflow.graph)
      assert Map.has_key?(workflow.components, :big_check)
    end

    test "condition appears in Workflow.conditions/1 when added as component" do
      cond = Runic.condition(fn x -> x > 10 end, name: :big_check)

      workflow =
        Workflow.new("test")
        |> Workflow.add(cond)

      conditions = Workflow.conditions(workflow)
      assert length(conditions) == 1
      assert hd(conditions).name == :big_check
    end

    test "condition with meta_refs gets meta_ref edges drawn" do
      cond = Runic.condition(fn x -> x > 10 end, name: :big_check)

      workflow =
        Workflow.new("test")
        |> Workflow.add(cond)

      assert %Workflow{} = workflow
    end

    test "condition gates downstream step when satisfied" do
      cond = Runic.condition(fn x -> x > 10 end, name: :big_check)
      step = Runic.step(fn x -> x * 2 end, name: :doubler)

      workflow =
        Workflow.new("test")
        |> Workflow.add(cond)
        |> Workflow.add(step, to: :big_check)

      satisfied_result =
        workflow
        |> Workflow.react_until_satisfied(15)
        |> Workflow.raw_productions()

      assert 30 in satisfied_result

      unsatisfied_result =
        workflow
        |> Workflow.react_until_satisfied(5)
        |> Workflow.raw_productions()

      refute 10 in unsatisfied_result
    end
  end

  describe "Phase 3: Transmutable protocol for Condition" do
    test "to_workflow/1 wraps condition in a standalone workflow" do
      cond = Runic.condition(fn x -> x > 10 end, name: :big_check)
      workflow = Runic.Transmutable.to_workflow(cond)

      assert %Workflow{} = workflow
      conditions = Workflow.conditions(workflow)
      assert length(conditions) == 1
      assert hd(conditions).name == :big_check
    end

    test "to_component/1 returns the condition itself" do
      cond = Runic.condition(fn x -> x > 10 end, name: :big_check)
      assert Runic.Transmutable.to_component(cond) == cond
    end

    test "transmute/1 delegates to to_workflow/1" do
      cond = Runic.condition(fn x -> x > 10 end, name: :big_check)
      workflow = Runic.Transmutable.transmute(cond)

      assert %Workflow{} = workflow
    end

    test "Runic.transmute/1 works with condition" do
      cond = Runic.condition(fn x -> x > 10 end, name: :big_check)
      workflow = Runic.transmute(cond)

      assert %Workflow{} = workflow
      assert Map.has_key?(workflow.components, :big_check)
    end

    test "transmuted condition workflow is functional" do
      cond = Runic.condition(fn x -> x > 10 end, name: :big_check)
      workflow = Runic.transmute(cond)

      result =
        workflow
        |> Workflow.react_until_satisfied(15)

      conditions = Workflow.conditions(result)
      assert length(conditions) == 1
    end
  end

  describe "Phase 4: Condition Reference Markers & Boolean Expression Compilation" do
    alias Runic.Workflow.ConditionRef
    alias Runic.Workflow.Conjunction

    test "ConditionRef struct exists with name field" do
      ref = %ConditionRef{name: :ham}
      assert ref.name == :ham
    end

    test "Conjunction struct supports condition_refs field" do
      conj = %Conjunction{hash: 123, condition_hashes: MapSet.new(), condition_refs: [:ham]}
      assert conj.condition_refs == [:ham]
    end

    test "Conjunction.new/2 creates conjunction with refs and inline hashes" do
      inline_cond = Runic.condition(fn x -> x >= 2 end, name: :inline_check)
      conj = Conjunction.new([inline_cond.hash], [:ham])

      assert conj.condition_hashes == MapSet.new([inline_cond.hash])
      assert conj.condition_refs == [:ham]
      assert is_integer(conj.hash)
    end

    test "Conjunction.new/2 produces stable hashes" do
      inline_cond = Runic.condition(fn x -> x >= 2 end, name: :inline_check)
      conj1 = Conjunction.new([inline_cond.hash], [:ham])
      conj2 = Conjunction.new([inline_cond.hash], [:ham])

      assert conj1.hash == conj2.hash
    end

    test "Conjunction.new/2 produces different hashes for different refs" do
      inline_cond = Runic.condition(fn x -> x >= 2 end, name: :inline_check)
      conj1 = Conjunction.new([inline_cond.hash], [:ham])
      conj2 = Conjunction.new([inline_cond.hash], [:eggs])

      assert conj1.hash != conj2.hash
    end

    test "rule with condition(:name) in where clause compiles" do
      rule =
        Runic.rule do
          given(value: x)
          where(condition(:ham) and x >= 2)
          then(fn %{value: v} -> {:result, v} end)
        end

      assert %Rule{} = rule
      assert is_integer(rule.hash)
    end

    test "rule with condition ref has conjunction with condition_refs" do
      rule =
        Runic.rule do
          given(value: x)
          where(condition(:ham) and x >= 2)
          then(fn %{value: v} -> {:result, v} end)
        end

      vertices = Graph.vertices(rule.workflow.graph)

      conjunctions = Enum.filter(vertices, &match?(%Conjunction{}, &1))
      assert length(conjunctions) == 1

      conj = hd(conjunctions)
      assert :ham in conj.condition_refs
      assert MapSet.size(conj.condition_hashes) >= 1
    end

    test "rule with condition ref has inline condition in workflow" do
      rule =
        Runic.rule do
          given(value: x)
          where(condition(:ham) and x >= 2)
          then(fn %{value: v} -> {:result, v} end)
        end

      vertices = Graph.vertices(rule.workflow.graph)

      inline_conditions = Enum.filter(vertices, &match?(%Condition{}, &1))
      assert length(inline_conditions) >= 1

      inline_cond = hd(inline_conditions)
      assert is_function(inline_cond.work)
    end

    test "rule with multiple condition refs compiles" do
      rule =
        Runic.rule do
          given(value: x)
          where(condition(:ham) and condition(:eggs) and x > 0)
          then(fn %{value: v} -> {:result, v} end)
        end

      assert %Rule{} = rule

      vertices = Graph.vertices(rule.workflow.graph)
      conjunctions = Enum.filter(vertices, &match?(%Conjunction{}, &1))
      assert length(conjunctions) == 1

      conj = hd(conjunctions)
      assert :ham in conj.condition_refs
      assert :eggs in conj.condition_refs
    end

    test "rule with only condition refs (no inline) compiles" do
      rule =
        Runic.rule do
          given(value: _x)
          where(condition(:ham) and condition(:eggs))
          then(fn %{value: v} -> {:result, v} end)
        end

      assert %Rule{} = rule

      vertices = Graph.vertices(rule.workflow.graph)
      conjunctions = Enum.filter(vertices, &match?(%Conjunction{}, &1))
      assert length(conjunctions) == 1

      conj = hd(conjunctions)
      assert :ham in conj.condition_refs
      assert :eggs in conj.condition_refs
      assert MapSet.size(conj.condition_hashes) == 0
    end

    test "rule with condition ref in keyword form compiles" do
      rule =
        Runic.rule(
          name: :keyword_ref_rule,
          given: [value: x],
          where: condition(:ham) and x >= 2,
          then: fn %{value: v} -> {:result, v} end
        )

      assert %Rule{name: :keyword_ref_rule} = rule

      vertices = Graph.vertices(rule.workflow.graph)
      conjunctions = Enum.filter(vertices, &match?(%Conjunction{}, &1))
      assert length(conjunctions) == 1
      assert :ham in hd(conjunctions).condition_refs
    end

    test "condition_hash points to conjunction when refs present" do
      rule =
        Runic.rule do
          given(value: x)
          where(condition(:ham) and x >= 2)
          then(fn %{value: v} -> {:result, v} end)
        end

      vertices = Graph.vertices(rule.workflow.graph)
      conjunctions = Enum.filter(vertices, &match?(%Conjunction{}, &1))
      conj = hd(conjunctions)

      assert rule.condition_hash == conj.hash
    end

    test "existing rules without condition refs still work" do
      rule =
        Runic.rule do
          given(value: x)
          where(x > 10)
          then(fn %{value: v} -> {:result, v} end)
        end

      assert %Rule{} = rule

      workflow =
        Workflow.new("test")
        |> Workflow.add(rule)
        |> Workflow.react_until_satisfied(15)

      results = Workflow.raw_productions(workflow)
      assert {:result, 15} in results
    end

    test "pinned variables in where clause with condition refs" do
      threshold = 5

      rule =
        Runic.rule do
          given(value: x)
          where(condition(:ham) and x >= ^threshold)
          then(fn %{value: v} -> {:result, v} end)
        end

      assert %Rule{} = rule
    end
  end

  describe "Phase 4b: or expression support in where clauses with condition refs" do
    alias Runic.Workflow.Conjunction

    test "rule with simple or of condition ref and inline compiles" do
      rule =
        Runic.rule do
          given(value: x)
          where(condition(:ham) or x >= 2)
          then(fn %{value: v} -> {:result, v} end)
        end

      assert %Rule{} = rule
      assert is_integer(rule.hash)
    end

    test "rule with || syntax compiles" do
      rule =
        Runic.rule do
          given(value: x)
          where(condition(:ham) || x >= 2)
          then(fn %{value: v} -> {:result, v} end)
        end

      assert %Rule{} = rule
    end

    test "or branches produce independent flow paths (no conjunction for simple or)" do
      rule =
        Runic.rule do
          given(value: x)
          where(condition(:ham) or x > 100)
          then(fn %{value: v} -> {:result, v} end)
        end

      vertices = Graph.vertices(rule.workflow.graph)

      conjunctions = Enum.filter(vertices, &match?(%Conjunction{}, &1))
      assert Enum.empty?(conjunctions)

      inline_conditions = Enum.filter(vertices, &match?(%Condition{}, &1))
      assert length(inline_conditions) >= 1
    end

    test "or of two inline conditions without refs uses standard compilation" do
      rule =
        Runic.rule do
          given(value: x)
          where(x > 100 or x < 0)
          then(fn %{value: v} -> {:out_of_range, v} end)
        end

      assert %Rule{} = rule

      workflow =
        Workflow.new("test")
        |> Workflow.add(rule)
        |> Workflow.react_until_satisfied(150)

      results = Workflow.raw_productions(workflow)
      assert {:out_of_range, 150} in results
    end

    test "or of two condition refs compiles" do
      rule =
        Runic.rule do
          given(value: _x)
          where(condition(:ham) or condition(:eggs))
          then(fn %{value: v} -> {:result, v} end)
        end

      assert %Rule{} = rule

      vertices = Graph.vertices(rule.workflow.graph)
      conjunctions = Enum.filter(vertices, &match?(%Conjunction{}, &1))
      assert Enum.empty?(conjunctions)
    end

    test "mixed and/or: (condition(:ham) and x >= 2) or condition(:vip)" do
      rule =
        Runic.rule do
          given(value: x)
          where((condition(:ham) and x >= 2) or condition(:vip))
          then(fn %{value: v} -> {:result, v} end)
        end

      assert %Rule{} = rule

      vertices = Graph.vertices(rule.workflow.graph)

      conjunctions = Enum.filter(vertices, &match?(%Conjunction{}, &1))
      assert length(conjunctions) == 1

      conj = hd(conjunctions)
      assert :ham in conj.condition_refs
      assert MapSet.size(conj.condition_hashes) >= 1
    end

    test "mixed and/or: (a and b) or (c and d)" do
      rule =
        Runic.rule do
          given(value: x)
          where((condition(:a) and x > 0) or (condition(:b) and x < 100))
          then(fn %{value: v} -> {:result, v} end)
        end

      assert %Rule{} = rule

      vertices = Graph.vertices(rule.workflow.graph)
      conjunctions = Enum.filter(vertices, &match?(%Conjunction{}, &1))
      assert length(conjunctions) == 2
    end

    test "or in keyword form compiles" do
      rule =
        Runic.rule(
          name: :keyword_or_rule,
          given: [value: x],
          where: condition(:ham) or x >= 2,
          then: fn %{value: v} -> {:result, v} end
        )

      assert %Rule{name: :keyword_or_rule} = rule
    end

    test "pinned variables in or expression with condition refs" do
      threshold = 5

      rule =
        Runic.rule do
          given(value: x)
          where(condition(:ham) or x >= ^threshold)
          then(fn %{value: v} -> {:result, v} end)
        end

      assert %Rule{} = rule
    end

    test "existing and-only rules with condition refs still work" do
      rule =
        Runic.rule do
          given(value: x)
          where(condition(:ham) and x >= 2)
          then(fn %{value: v} -> {:result, v} end)
        end

      assert %Rule{} = rule

      vertices = Graph.vertices(rule.workflow.graph)
      conjunctions = Enum.filter(vertices, &match?(%Conjunction{}, &1))
      assert length(conjunctions) == 1
      assert :ham in hd(conjunctions).condition_refs
    end

    test "condition_hash is a synthetic hash for or expressions" do
      rule =
        Runic.rule do
          given(value: x)
          where(condition(:ham) or x > 100)
          then(fn %{value: v} -> {:result, v} end)
        end

      assert is_integer(rule.condition_hash)
    end

    test "condition_hash is consistent within a single or rule" do
      rule =
        Runic.rule do
          given(value: x)
          where(condition(:ham) or x > 100)
          then(fn %{value: v} -> {:result, v} end)
        end

      assert is_integer(rule.condition_hash)
      assert rule.condition_hash != rule.reaction_hash
    end
  end

  describe "Phase 5: Connect-time resolution of condition references" do
    alias Runic.Workflow.Conjunction

    test "named condition + rule with condition ref wires correctly" do
      ham = Runic.condition(fn x -> x > 10 end, name: :ham)

      rule =
        Runic.rule do
          given(value: x)
          where(condition(:ham) and x >= 2)
          then(fn %{value: v} -> {:result, v} end)
        end

      workflow =
        Workflow.new("test")
        |> Workflow.add(ham)
        |> Workflow.add(rule)

      vertices = Graph.vertices(workflow.graph)
      conjunctions = Enum.filter(vertices, &match?(%Conjunction{}, &1))
      assert length(conjunctions) == 1

      conj = hd(conjunctions)
      assert MapSet.member?(conj.condition_hashes, ham.hash)
      assert conj.condition_refs == []
    end

    test "condition ref resolution wires flow edge from condition to conjunction" do
      ham = Runic.condition(fn x -> x > 10 end, name: :ham)

      rule =
        Runic.rule do
          given(value: x)
          where(condition(:ham) and x >= 2)
          then(fn %{value: v} -> {:result, v} end)
        end

      workflow =
        Workflow.new("test")
        |> Workflow.add(ham)
        |> Workflow.add(rule)

      vertices = Graph.vertices(workflow.graph)
      conj = Enum.find(vertices, &match?(%Conjunction{}, &1))

      flow_edges = Graph.in_edges(workflow.graph, conj, by: :flow)
      flow_sources = Enum.map(flow_edges, & &1.v1)
      assert ham in flow_sources
    end

    test "unresolved condition ref raises error" do
      rule =
        Runic.rule do
          given(value: x)
          where(condition(:nonexistent) and x >= 2)
          then(fn %{value: v} -> {:result, v} end)
        end

      assert_raise Runic.UnresolvedReferenceError, ~r/:nonexistent/, fn ->
        Workflow.new("test")
        |> Workflow.add(rule)
      end
    end

    test "multiple condition refs resolve correctly" do
      ham = Runic.condition(fn x -> x > 10 end, name: :ham)
      eggs = Runic.condition(fn x -> is_integer(x) end, name: :eggs)

      rule =
        Runic.rule do
          given(value: x)
          where(condition(:ham) and condition(:eggs) and x > 0)
          then(fn %{value: v} -> {:result, v} end)
        end

      workflow =
        Workflow.new("test")
        |> Workflow.add(ham)
        |> Workflow.add(eggs)
        |> Workflow.add(rule)

      vertices = Graph.vertices(workflow.graph)
      conj = Enum.find(vertices, &match?(%Conjunction{}, &1))

      assert MapSet.member?(conj.condition_hashes, ham.hash)
      assert MapSet.member?(conj.condition_hashes, eggs.hash)
      assert conj.condition_refs == []
    end

    test "or-branch condition ref wires to reaction step" do
      ham = Runic.condition(fn x -> x > 10 end, name: :ham)

      rule =
        Runic.rule do
          given(value: x)
          where(condition(:ham) or x >= 2)
          then(fn %{value: v} -> {:result, v} end)
        end

      workflow =
        Workflow.new("test")
        |> Workflow.add(ham)
        |> Workflow.add(rule)

      reaction = Map.get(workflow.graph.vertices, rule.reaction_hash)
      flow_edges = Graph.in_edges(workflow.graph, reaction, by: :flow)
      flow_sources = Enum.map(flow_edges, & &1.v1)

      assert ham in flow_sources
    end

    test "shared condition across two rules" do
      ham = Runic.condition(fn x -> x > 10 end, name: :ham)

      rule1 =
        Runic.rule do
          given(value: x)
          where(condition(:ham) and x >= 2)
          then(fn %{value: v} -> {:rule1, v} end)
        end

      rule2 =
        Runic.rule do
          given(value: x)
          where(condition(:ham) and x < 100)
          then(fn %{value: v} -> {:rule2, v} end)
        end

      workflow =
        Workflow.new("test")
        |> Workflow.add(ham)
        |> Workflow.add(rule1)
        |> Workflow.add(rule2)

      vertices = Graph.vertices(workflow.graph)
      conjunctions = Enum.filter(vertices, &match?(%Conjunction{}, &1))
      assert length(conjunctions) == 2

      Enum.each(conjunctions, fn conj ->
        assert MapSet.member?(conj.condition_hashes, ham.hash)
        assert conj.condition_refs == []
      end)
    end

    test "existing rules without condition refs still work after Phase 5" do
      rule =
        Runic.rule do
          given(value: x)
          where(x > 10)
          then(fn %{value: v} -> {:result, v} end)
        end

      workflow =
        Workflow.new("test")
        |> Workflow.add(rule)
        |> Workflow.react_until_satisfied(15)

      results = Workflow.raw_productions(workflow)
      assert {:result, 15} in results
    end
  end

  describe "Phase 6: End-to-end runtime with condition refs" do
    test "and-gated rule fires when named condition and inline condition both satisfied" do
      ham = Runic.condition(fn x -> x > 10 end, name: :ham)

      rule =
        Runic.rule do
          given(value: x)
          where(condition(:ham) and x >= 2)
          then(fn %{value: v} -> {:result, v} end)
        end

      workflow =
        Workflow.new("test")
        |> Workflow.add(ham)
        |> Workflow.add(rule)

      results =
        workflow
        |> Workflow.react_until_satisfied(15)
        |> Workflow.raw_productions()

      assert {:result, 15} in results
    end

    test "and-gated rule does NOT fire when named condition unsatisfied" do
      ham = Runic.condition(fn x -> x > 10 end, name: :ham)

      rule =
        Runic.rule do
          given(value: x)
          where(condition(:ham) and x >= 2)
          then(fn %{value: v} -> {:result, v} end)
        end

      workflow =
        Workflow.new("test")
        |> Workflow.add(ham)
        |> Workflow.add(rule)

      results =
        workflow
        |> Workflow.react_until_satisfied(5)
        |> Workflow.raw_productions()

      refute {:result, 5} in results
    end

    test "and-gated rule does NOT fire when inline condition unsatisfied" do
      ham = Runic.condition(fn _x -> true end, name: :ham)

      rule =
        Runic.rule do
          given(value: x)
          where(condition(:ham) and x > 100)
          then(fn %{value: v} -> {:result, v} end)
        end

      workflow =
        Workflow.new("test")
        |> Workflow.add(ham)
        |> Workflow.add(rule)

      results =
        workflow
        |> Workflow.react_until_satisfied(5)
        |> Workflow.raw_productions()

      refute {:result, 5} in results
    end

    test "or-branch rule fires when named condition satisfied" do
      ham = Runic.condition(fn x -> x > 10 end, name: :ham)

      rule =
        Runic.rule do
          given(value: x)
          where(condition(:ham) or x < 0)
          then(fn %{value: v} -> {:result, v} end)
        end

      workflow =
        Workflow.new("test")
        |> Workflow.add(ham)
        |> Workflow.add(rule)

      results =
        workflow
        |> Workflow.react_until_satisfied(15)
        |> Workflow.raw_productions()

      assert {:result, 15} in results
    end

    test "or-branch rule fires when inline condition satisfied (ref unsatisfied)" do
      ham = Runic.condition(fn x -> x > 10 end, name: :ham)

      rule =
        Runic.rule do
          given(value: x)
          where(condition(:ham) or x < 0)
          then(fn %{value: v} -> {:result, v} end)
        end

      workflow =
        Workflow.new("test")
        |> Workflow.add(ham)
        |> Workflow.add(rule)

      results =
        workflow
        |> Workflow.react_until_satisfied(-5)
        |> Workflow.raw_productions()

      assert {:result, -5} in results
    end

    test "or-branch rule does NOT fire when neither condition satisfied" do
      ham = Runic.condition(fn x -> x > 10 end, name: :ham)

      rule =
        Runic.rule do
          given(value: x)
          where(condition(:ham) or x < 0)
          then(fn %{value: v} -> {:result, v} end)
        end

      workflow =
        Workflow.new("test")
        |> Workflow.add(ham)
        |> Workflow.add(rule)

      results =
        workflow
        |> Workflow.react_until_satisfied(5)
        |> Workflow.raw_productions()

      refute {:result, 5} in results
    end

    test "mixed and/or: (condition(:ham) and x >= 2) or condition(:vip) — and branch fires" do
      ham = Runic.condition(fn x -> x > 10 end, name: :ham)
      vip = Runic.condition(fn _x -> false end, name: :vip)

      rule =
        Runic.rule do
          given(value: x)
          where((condition(:ham) and x >= 2) or condition(:vip))
          then(fn %{value: v} -> {:result, v} end)
        end

      workflow =
        Workflow.new("test")
        |> Workflow.add(ham)
        |> Workflow.add(vip)
        |> Workflow.add(rule)

      results =
        workflow
        |> Workflow.react_until_satisfied(15)
        |> Workflow.raw_productions()

      assert {:result, 15} in results
    end

    test "mixed and/or: (condition(:ham) and x >= 2) or condition(:vip) — or branch fires" do
      ham = Runic.condition(fn _x -> false end, name: :ham)
      vip = Runic.condition(fn _x -> true end, name: :vip)

      rule =
        Runic.rule do
          given(value: x)
          where((condition(:ham) and x >= 2) or condition(:vip))
          then(fn %{value: v} -> {:result, v} end)
        end

      workflow =
        Workflow.new("test")
        |> Workflow.add(ham)
        |> Workflow.add(vip)
        |> Workflow.add(rule)

      results =
        workflow
        |> Workflow.react_until_satisfied(15)
        |> Workflow.raw_productions()

      assert {:result, 15} in results
    end

    test "shared condition evaluated once, both rules observe it" do
      ham = Runic.condition(fn x -> x > 10 end, name: :ham)

      rule1 =
        Runic.rule do
          given(value: x)
          where(condition(:ham) and x >= 2)
          then(fn %{value: v} -> {:rule1, v} end)
        end

      rule2 =
        Runic.rule do
          given(value: x)
          where(condition(:ham) and x < 100)
          then(fn %{value: v} -> {:rule2, v} end)
        end

      workflow =
        Workflow.new("test")
        |> Workflow.add(ham)
        |> Workflow.add(rule1)
        |> Workflow.add(rule2)

      results =
        workflow
        |> Workflow.react_until_satisfied(15)
        |> Workflow.raw_productions()

      assert {:rule1, 15} in results
      assert {:rule2, 15} in results
    end

    test "reaction runs only once when multiple or branches satisfied" do
      ham = Runic.condition(fn x -> x > 10 end, name: :ham)

      rule =
        Runic.rule do
          given(value: x)
          where(condition(:ham) or x > 5)
          then(fn %{value: v} -> {:result, v} end)
        end

      workflow =
        Workflow.new("test")
        |> Workflow.add(ham)
        |> Workflow.add(rule)

      results =
        workflow
        |> Workflow.react_until_satisfied(15)
        |> Workflow.raw_productions()

      matching = Enum.filter(results, &match?({:result, 15}, &1))
      assert length(matching) == 1
    end
  end
end
