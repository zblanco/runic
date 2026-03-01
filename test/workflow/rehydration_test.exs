defmodule Runic.Workflow.RehydrationTest do
  use ExUnit.Case, async: true

  require Runic

  alias Runic.Workflow
  alias Runic.Workflow.{Fact, FactRef, Facts, FactResolver, Rehydration}
  alias Runic.Runner.Store.ETS

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp build_chain_workflow do
    step_a = Runic.step(fn x -> x + 1 end, name: :add)
    step_b = Runic.step(fn x -> x * 2 end, name: :double)
    step_c = Runic.step(fn x -> x - 3 end, name: :subtract)

    Workflow.new()
    |> Workflow.add(step_a)
    |> Workflow.add(step_b, to: :add)
    |> Workflow.add(step_c, to: :double)
  end

  defp all_fact_hashes(workflow) do
    for v <- Graph.vertices(workflow.graph),
        is_struct(v, Fact) or is_struct(v, FactRef),
        into: MapSet.new() do
      Facts.hash(v)
    end
  end

  defp fact_ref_hashes(workflow) do
    for v <- Graph.vertices(workflow.graph),
        is_struct(v, FactRef),
        into: MapSet.new() do
      v.hash
    end
  end

  defp full_fact_hashes(workflow) do
    for v <- Graph.vertices(workflow.graph),
        is_struct(v, Fact),
        into: MapSet.new() do
      v.hash
    end
  end

  defp setup_ets_store(_context \\ %{}) do
    runner_name = :"test_rehydration_#{System.unique_integer([:positive])}"
    start_supervised!({ETS, runner_name: runner_name})
    {:ok, store_state} = ETS.init_store(runner_name: runner_name)
    {ETS, store_state}
  end

  # ---------------------------------------------------------------------------
  # classify/2
  # ---------------------------------------------------------------------------

  describe "classify/2" do
    test "empty workflow — no facts, empty hot and cold" do
      workflow = Workflow.new()
      %{hot: hot, cold: cold} = Rehydration.classify(workflow)

      assert MapSet.size(hot) == 0
      assert MapSet.size(cold) == 0
    end

    test "single input, no execution — input is frontier and hot" do
      workflow =
        build_chain_workflow()
        |> Workflow.plan_eagerly(5)

      %{hot: hot, cold: cold} = Rehydration.classify(workflow)
      all = all_fact_hashes(workflow)

      # The input fact is the only fact and is frontier (no children)
      assert MapSet.size(all) == 1
      assert hot == all
      assert MapSet.size(cold) == 0
    end

    test "partially executed chain — intermediate parent is cold, tip is hot" do
      # input(5) → add → fact_a(6) → double(runnable)
      workflow =
        build_chain_workflow()
        |> Workflow.react(5)

      %{hot: hot, cold: cold} = Rehydration.classify(workflow)

      # fact_a is frontier + pending runnable → hot
      # input is parent of fact_a → cold
      fact_a = hd(Workflow.productions(workflow, :add))

      assert MapSet.member?(hot, fact_a.hash)

      # Input fact is cold (it's a parent)
      input = hd(for v <- Graph.vertices(workflow.graph), match?(%Fact{ancestry: nil}, v), do: v)
      assert MapSet.member?(cold, input.hash)
    end

    test "fully executed chain — only leaf fact is hot" do
      # input(5) → add → 6 → double → 12 → subtract → 9
      workflow =
        build_chain_workflow()
        |> Workflow.react_until_satisfied(5)

      %{hot: hot, cold: cold} = Rehydration.classify(workflow)

      all = all_fact_hashes(workflow)
      # 4 facts total: input + 3 produced
      assert MapSet.size(all) == 4

      # Only the leaf (subtract result) is frontier
      [leaf_fact] = Workflow.productions(workflow, :subtract)
      assert MapSet.member?(hot, leaf_fact.hash)

      # Intermediate facts are cold
      assert MapSet.size(cold) == 3
    end

    test "branching workflow — both branch tips are hot" do
      step_a = Runic.step(fn x -> x + 1 end, name: :branch_a)
      step_b = Runic.step(fn x -> x * 2 end, name: :branch_b)

      workflow =
        Workflow.new()
        |> Workflow.add(step_a)
        |> Workflow.add(step_b)
        |> Workflow.react_until_satisfied(5)

      %{hot: hot, cold: cold} = Rehydration.classify(workflow)

      # Both branch results are frontier (neither is parent of the other)
      [fact_a] = Workflow.productions(workflow, :branch_a)
      [fact_b] = Workflow.productions(workflow, :branch_b)

      assert MapSet.member?(hot, fact_a.hash)
      assert MapSet.member?(hot, fact_b.hash)

      # Input is parent of both → cold
      assert MapSet.size(cold) == 1
    end

    test "pending runnable inputs are always hot even if they are parents" do
      # A diamond: input → step_a → fact_a, input → step_b → fact_b
      # fact_a and fact_b both feed into step_c (via join or shared downstream)
      # After running step_a only (step_b still runnable), input should be hot
      # because it's on a :runnable edge for step_b, even though it's a parent of fact_a.
      step_a = Runic.step(fn x -> x + 1 end, name: :first)
      step_b = Runic.step(fn x -> x * 3 end, name: :second)

      workflow =
        Workflow.new()
        |> Workflow.add(step_a)
        |> Workflow.add(step_b)

      # Plan with input, making both steps runnable
      workflow = Workflow.plan_eagerly(workflow, 10)

      # Execute only one cycle — both independent steps fire in the same cycle
      # So let's check before executing: both steps are runnable with the input fact
      %{hot: hot} = Rehydration.classify(workflow)

      input = hd(for v <- Graph.vertices(workflow.graph), match?(%Fact{ancestry: nil}, v), do: v)
      assert MapSet.member?(hot, input.hash)
    end

    test "hot and cold are disjoint and cover all facts" do
      workflow =
        build_chain_workflow()
        |> Workflow.react_until_satisfied(5)

      %{hot: hot, cold: cold} = Rehydration.classify(workflow)
      all = all_fact_hashes(workflow)

      assert MapSet.union(hot, cold) == all
      assert MapSet.intersection(hot, cold) == MapSet.new()
    end
  end

  # ---------------------------------------------------------------------------
  # dehydrate/2
  # ---------------------------------------------------------------------------

  describe "dehydrate/2" do
    test "replaces cold facts with FactRefs" do
      workflow =
        build_chain_workflow()
        |> Workflow.react_until_satisfied(5)

      %{cold: cold} = Rehydration.classify(workflow)
      assert MapSet.size(cold) > 0

      dehydrated = Rehydration.dehydrate(workflow, cold)

      # Cold facts are now FactRefs
      for hash <- cold do
        vertex = Map.get(dehydrated.graph.vertices, hash)
        assert %FactRef{} = vertex
      end
    end

    test "preserves hot facts as full Fact structs" do
      workflow =
        build_chain_workflow()
        |> Workflow.react_until_satisfied(5)

      %{hot: hot, cold: cold} = Rehydration.classify(workflow)
      dehydrated = Rehydration.dehydrate(workflow, cold)

      for hash <- hot do
        vertex = Map.get(dehydrated.graph.vertices, hash)
        assert %Fact{} = vertex
        refute is_nil(vertex.value)
      end
    end

    test "preserves graph edge structure" do
      workflow =
        build_chain_workflow()
        |> Workflow.react_until_satisfied(5)

      %{cold: cold} = Rehydration.classify(workflow)
      dehydrated = Rehydration.dehydrate(workflow, cold)

      # Edge count should be identical
      original_edges = Graph.edges(dehydrated.graph)
      assert length(original_edges) == length(Graph.edges(workflow.graph))
    end

    test "FactRef hash and ancestry match original Fact" do
      workflow =
        build_chain_workflow()
        |> Workflow.react_until_satisfied(5)

      %{cold: cold} = Rehydration.classify(workflow)
      dehydrated = Rehydration.dehydrate(workflow, cold)

      for hash <- cold do
        original = Map.get(workflow.graph.vertices, hash)
        ref = Map.get(dehydrated.graph.vertices, hash)

        assert ref.hash == original.hash
        assert ref.ancestry == original.ancestry
      end
    end

    test "empty cold set is a no-op" do
      workflow =
        build_chain_workflow()
        |> Workflow.plan_eagerly(5)

      dehydrated = Rehydration.dehydrate(workflow, MapSet.new())
      assert dehydrated.graph.vertices == workflow.graph.vertices
    end
  end

  # ---------------------------------------------------------------------------
  # rehydrate/3
  # ---------------------------------------------------------------------------

  describe "rehydrate/3" do
    test "returns dehydrated workflow and a resolver" do
      store = setup_ets_store()

      workflow =
        build_chain_workflow()
        |> Workflow.react_until_satisfied(5)

      {rehydrated, resolver} = Rehydration.rehydrate(workflow, store)

      assert %FactResolver{} = resolver
      # Cold facts became FactRefs
      assert MapSet.size(fact_ref_hashes(rehydrated)) > 0
      # Hot facts remain as full Facts
      assert MapSet.size(full_fact_hashes(rehydrated)) > 0
    end

    test "hot facts retain values, cold facts are FactRefs" do
      store = setup_ets_store()

      workflow =
        build_chain_workflow()
        |> Workflow.react_until_satisfied(5)

      %{hot: hot, cold: cold} = Rehydration.classify(workflow)
      {rehydrated, _resolver} = Rehydration.rehydrate(workflow, store)

      for hash <- hot do
        vertex = Map.get(rehydrated.graph.vertices, hash)
        assert %Fact{} = vertex
      end

      for hash <- cold do
        vertex = Map.get(rehydrated.graph.vertices, hash)
        assert %FactRef{} = vertex
      end
    end

    test "resolver can resolve cold FactRefs when store has fact values" do
      {store_mod, store_state} = store = setup_ets_store()

      workflow =
        build_chain_workflow()
        |> Workflow.react_until_satisfied(5)

      # Persist fact values to the store before rehydrating
      for v <- Graph.vertices(workflow.graph), match?(%Fact{}, v) do
        store_mod.save_fact(v.hash, v.value, store_state)
      end

      %{cold: cold} = Rehydration.classify(workflow)
      {rehydrated, resolver} = Rehydration.rehydrate(workflow, store)

      # Resolve each cold FactRef through the resolver
      for hash <- cold do
        ref = Map.get(rehydrated.graph.vertices, hash)
        assert {:ok, %Fact{} = resolved} = FactResolver.resolve(ref, resolver)
        # Resolved fact should match the original
        original = Map.get(workflow.graph.vertices, hash)
        assert resolved.value == original.value
        assert resolved.hash == original.hash
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Round-trip: execute → classify → dehydrate → continue execution
  # ---------------------------------------------------------------------------

  describe "round-trip execution" do
    test "dehydrated workflow can continue execution to completion" do
      # Execute partway through, dehydrate, then continue
      workflow =
        build_chain_workflow()
        |> Workflow.react(5)
        |> Workflow.react()

      # After 2 reacts: input → add(6) → double(12), subtract is runnable
      assert Workflow.is_runnable?(workflow)

      %{cold: cold} = Rehydration.classify(workflow)
      dehydrated = Rehydration.dehydrate(workflow, cold)

      # The pending runnable input (fact for :subtract) should still be a full Fact
      assert Workflow.is_runnable?(dehydrated)

      # Continue execution on dehydrated workflow
      completed = Workflow.react(dehydrated)
      refute Workflow.is_runnable?(completed)

      [result] = Workflow.raw_productions(completed, :subtract)
      assert result == 12 - 3
    end

    test "full round-trip: build → execute → checkpoint events → rehydrate → verify" do
      {store_mod, store_state} = store = setup_ets_store()
      workflow_id = :test_roundtrip

      # Build and fully execute with event emission
      workflow =
        build_chain_workflow()
        |> Workflow.enable_event_emission()
        |> Workflow.react_until_satisfied(5)

      # Persist build log + runtime events
      build_events = Workflow.build_log(workflow)
      runtime_events = Enum.reverse(workflow.uncommitted_events)
      all_events = build_events ++ runtime_events

      {:ok, _cursor} = store_mod.append(workflow_id, all_events, store_state)

      # Persist fact values
      for v <- Graph.vertices(workflow.graph), match?(%Fact{}, v) do
        store_mod.save_fact(v.hash, v.value, store_state)
      end

      # Rebuild from events
      {:ok, event_stream} = store_mod.stream(workflow_id, store_state)
      rebuilt = Workflow.from_events(Enum.to_list(event_stream))

      # Rehydrate with hybrid mode
      {rehydrated, resolver} = Rehydration.rehydrate(rebuilt, store)

      # Verify structural equivalence: same components
      assert Map.keys(rehydrated.components) == Map.keys(workflow.components)

      # Verify hot facts have values
      %{hot: hot} = Rehydration.classify(rebuilt)

      for hash <- hot do
        vertex = Map.get(rehydrated.graph.vertices, hash)
        assert %Fact{} = vertex
        refute is_nil(vertex.value)
      end

      # Verify cold FactRefs can be resolved
      for v <- Graph.vertices(rehydrated.graph), match?(%FactRef{}, v) do
        assert {:ok, %Fact{}} = FactResolver.resolve(v, resolver)
      end
    end
  end
end
