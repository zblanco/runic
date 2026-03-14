defmodule Runic.Workflow.FactsTest do
  use ExUnit.Case, async: true

  alias Runic.Workflow.{Fact, FactRef, Facts}
  alias Runic.Workflow.Components

  describe "hash/1" do
    test "returns hash from a Fact" do
      fact = Fact.new(value: 42, ancestry: {1, 2})
      assert Facts.hash(fact) == fact.hash
    end

    test "returns hash from a FactRef" do
      ref = %FactRef{hash: 12345, ancestry: {1, 2}}
      assert Facts.hash(ref) == 12345
    end
  end

  describe "ancestry/1" do
    test "returns ancestry from a Fact" do
      fact = Fact.new(value: "hello", ancestry: {10, 20})
      assert Facts.ancestry(fact) == {10, 20}
    end

    test "returns ancestry from a FactRef" do
      ref = %FactRef{hash: 99, ancestry: {30, 40}}
      assert Facts.ancestry(ref) == {30, 40}
    end

    test "returns nil ancestry" do
      fact = Fact.new(value: "no ancestry", ancestry: nil)
      assert Facts.ancestry(fact) == nil

      ref = %FactRef{hash: 1, ancestry: nil}
      assert Facts.ancestry(ref) == nil
    end
  end

  describe "value?/1" do
    test "returns true for a Fact with a value" do
      fact = Fact.new(value: 42, ancestry: {1, 2})
      assert Facts.value?(fact)
    end

    test "returns false for a Fact with nil value" do
      fact = %Fact{hash: 1, value: nil, ancestry: {1, 2}}
      refute Facts.value?(fact)
    end

    test "returns false for a FactRef" do
      ref = %FactRef{hash: 1, ancestry: {1, 2}}
      refute Facts.value?(ref)
    end
  end

  describe "to_ref/1" do
    test "converts a Fact to a FactRef preserving hash and ancestry" do
      fact = Fact.new(value: "important data", ancestry: {10, 20})
      ref = Facts.to_ref(fact)

      assert %FactRef{} = ref
      assert ref.hash == fact.hash
      assert ref.ancestry == fact.ancestry
    end

    test "FactRef hash matches source Fact hash" do
      for _ <- 1..50 do
        val = :rand.uniform(1_000_000)
        ancestry = {:rand.uniform(1_000_000), :rand.uniform(1_000_000)}
        fact = Fact.new(value: val, ancestry: ancestry)
        ref = Facts.to_ref(fact)

        assert ref.hash == fact.hash
        assert ref.ancestry == fact.ancestry
      end
    end

    test "vertex_id_of matches between Fact and its FactRef" do
      fact = Fact.new(value: :test, ancestry: {1, 2})
      ref = Facts.to_ref(fact)

      assert Components.vertex_id_of(fact) == Components.vertex_id_of(ref)
    end
  end
end
