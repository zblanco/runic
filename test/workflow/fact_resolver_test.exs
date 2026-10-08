defmodule Runic.Workflow.FactResolverTest do
  use ExUnit.Case, async: true

  alias Runic.Workflow
  alias Runic.Workflow.{Fact, FactRef, FactResolver, Facts}
  alias Runic.Workflow.Events.FactProduced
  alias Runic.Runner.Store.ETS

  setup do
    runner_name = :"test_resolver_#{System.unique_integer([:positive])}"
    start_supervised!({ETS, runner_name: runner_name})
    {:ok, store_state} = ETS.init_store(runner_name: runner_name)
    store = {ETS, store_state}
    resolver = FactResolver.new(store)
    %{store: store, store_state: store_state, resolver: resolver}
  end

  describe "new/1" do
    test "creates a resolver with empty cache", %{store: store} do
      resolver = FactResolver.new(store)
      assert resolver.store == store
      assert resolver.cache == %{}
    end
  end

  describe "resolve/2" do
    test "hydrates a pre-metadata FactRef decoded from ETF", %{
      resolver: resolver,
      store_state: store_state
    } do
      fact = Fact.new(value: "old value", ancestry: {10, 20})
      :ok = ETS.save_fact(fact.hash, fact.value, store_state)

      old_ref =
        fact
        |> Facts.to_ref()
        |> Map.delete(:meta)
        |> :erlang.term_to_binary()
        |> :erlang.binary_to_term()

      for resolver <- [resolver, FactResolver.preload(resolver, [fact.hash])] do
        assert {:ok, restored} = FactResolver.resolve(old_ref, resolver)
        assert restored.value == fact.value
        assert restored.hash == fact.hash
        assert restored.meta == %{}
      end
    end

    test "passes through a full Fact unchanged", %{resolver: resolver} do
      fact = Fact.new(value: 42, ancestry: {1, 2})
      assert {:ok, ^fact} = FactResolver.resolve(fact, resolver)
    end

    test "keeps metadata when a FactRef is hydrated", %{
      resolver: resolver,
      store_state: store_state
    } do
      fact = Fact.new(value: "hello", ancestry: {10, 20}, meta: %{owner: :component})
      :ok = ETS.save_fact(fact.hash, fact.value, store_state)

      ref = Facts.to_ref(fact)
      assert ref.meta == %{owner: :component}
      assert {:ok, %Fact{meta: %{owner: :component}}} = FactResolver.resolve(ref, resolver)
    end

    test "keeps metadata when a lean event is replayed" do
      fact = Fact.new(value: "hello", meta: %{owner: :component})

      event =
        fact
        |> FactProduced.new(producer_label: :input, weight: 0)
        |> Map.put(:value, nil)

      workflow = Workflow.from_events([event], Workflow.new(), fact_mode: :ref)

      assert %FactRef{meta: %{owner: :component}} =
               Map.fetch!(workflow.graph.vertices, fact.hash)
    end

    test "resolves a FactRef from the store", %{resolver: resolver, store_state: store_state} do
      fact = Fact.new(value: "hello", ancestry: {10, 20})
      :ok = ETS.save_fact(fact.hash, fact.value, store_state)

      ref = %FactRef{hash: fact.hash, ancestry: fact.ancestry}
      assert {:ok, resolved} = FactResolver.resolve(ref, resolver)

      assert %Fact{} = resolved
      assert resolved.hash == fact.hash
      assert resolved.value == "hello"
      assert resolved.ancestry == {10, 20}
    end

    test "returns error when FactRef is not in store", %{resolver: resolver} do
      ref = %FactRef{hash: 999_999, ancestry: {1, 2}}
      assert {:error, :not_found} = FactResolver.resolve(ref, resolver)
    end

    test "rejects a stored value that does not match the payload digest", %{
      resolver: resolver,
      store_state: store_state
    } do
      fact = Fact.new(value: "expected", ancestry: {1, 2})
      :ok = ETS.save_fact(fact.hash, "corrupt", store_state)

      assert {:error, %Runic.Identity.IntegrityError{}} =
               fact |> Facts.to_ref() |> FactResolver.resolve(resolver)
    end

    test "resolves a FactRef from the cache without hitting the store", %{store: store} do
      resolver = %FactResolver{store: store, cache: %{42 => "cached_value"}}
      ref = %FactRef{hash: 42, ancestry: {5, 6}}

      assert {:ok, resolved} = FactResolver.resolve(ref, resolver)
      assert resolved.value == "cached_value"
      assert resolved.hash == 42
      assert resolved.ancestry == {5, 6}
    end
  end

  describe "resolve!/2" do
    test "returns the fact on success", %{resolver: resolver} do
      fact = Fact.new(value: 99, ancestry: {1, 2})
      assert ^fact = FactResolver.resolve!(fact, resolver)
    end

    test "raises on error", %{resolver: resolver} do
      ref = %FactRef{hash: 999_999, ancestry: {1, 2}}

      assert_raise MatchError, fn ->
        FactResolver.resolve!(ref, resolver)
      end
    end
  end

  describe "preload/2" do
    test "loads hashes into the cache", %{resolver: resolver, store_state: store_state} do
      fact_a = Fact.new(value: "a", ancestry: {1, 2})
      fact_b = Fact.new(value: "b", ancestry: {3, 4})
      :ok = ETS.save_fact(fact_a.hash, fact_a.value, store_state)
      :ok = ETS.save_fact(fact_b.hash, fact_b.value, store_state)

      resolver = FactResolver.preload(resolver, [fact_a.hash, fact_b.hash])

      assert Map.has_key?(resolver.cache, fact_a.hash)
      assert Map.has_key?(resolver.cache, fact_b.hash)
      assert resolver.cache[fact_a.hash] == "a"
      assert resolver.cache[fact_b.hash] == "b"
    end

    test "skips hashes already in cache", %{resolver: resolver, store_state: store_state} do
      fact = Fact.new(value: "original", ancestry: {1, 2})
      :ok = ETS.save_fact(fact.hash, "overwritten", store_state)

      resolver = %{resolver | cache: %{fact.hash => "original"}}
      resolver = FactResolver.preload(resolver, [fact.hash])

      assert resolver.cache[fact.hash] == "original"
    end

    test "skips hashes not found in store", %{resolver: resolver} do
      resolver = FactResolver.preload(resolver, [123_456_789])
      refute Map.has_key?(resolver.cache, 123_456_789)
    end

    test "resolve uses preloaded cache", %{resolver: resolver, store_state: store_state} do
      fact = Fact.new(value: "preloaded", ancestry: {7, 8})
      :ok = ETS.save_fact(fact.hash, fact.value, store_state)

      resolver = FactResolver.preload(resolver, [fact.hash])

      ref = %FactRef{hash: fact.hash, ancestry: fact.ancestry}
      assert {:ok, resolved} = FactResolver.resolve(ref, resolver)
      assert resolved.value == "preloaded"
    end
  end
end
