defmodule Runic.Workflow.MergeableTest do
  use ExUnit.Case, async: true

  require Runic

  alias Runic.Workflow
  alias Runic.Workflow.{Accumulator, FanIn, StateReaction, CausalContext, Fact, Invokable}

  describe "Accumulator.mergeable" do
    test "defaults to false" do
      acc = %Accumulator{
        reducer: fn v, acc -> acc + v end,
        init: fn -> 0 end,
        hash: 123
      }

      assert acc.mergeable == false
    end

    test "can be set to true" do
      acc = %Accumulator{
        reducer: fn v, acc -> acc + v end,
        init: fn -> 0 end,
        hash: 123,
        mergeable: true
      }

      assert acc.mergeable == true
    end

    test "mergeable flag is copied to CausalContext during prepare" do
      wrk =
        Runic.workflow(
          name: "test",
          steps: [
            Runic.step(fn x -> x end, name: :source)
          ]
        )

      acc = %Accumulator{
        reducer: fn v, acc -> acc + v end,
        init: fn -> 0 end,
        hash: 999,
        mergeable: true
      }

      wrk = Workflow.add(wrk, acc, to: :source)

      fact = Fact.new(value: 10, ancestry: {123, 456})

      {:ok, runnable} = Invokable.prepare(acc, wrk, fact)

      assert runnable.context.mergeable == true
    end
  end

  describe "FanIn.mergeable" do
    test "defaults to false" do
      fan_in = %FanIn{
        hash: 123,
        init: fn -> 0 end,
        reducer: fn v, acc -> acc + v end
      }

      assert fan_in.mergeable == false
    end

    test "can be set to true" do
      fan_in = %FanIn{
        hash: 123,
        init: fn -> 0 end,
        reducer: fn v, acc -> acc + v end,
        mergeable: true
      }

      assert fan_in.mergeable == true
    end
  end

  describe "StateReaction.mergeable" do
    test "defaults to false" do
      sr = StateReaction.new(hash: 123, state_hash: 456, work: fn x -> x end, arity: 1)

      assert sr.mergeable == false
    end

    test "can be set to true" do
      sr =
        StateReaction.new(
          hash: 123,
          state_hash: 456,
          work: fn x -> x end,
          arity: 1,
          mergeable: true
        )

      assert sr.mergeable == true
    end
  end

  describe "CausalContext.mergeable?" do
    test "returns false by default" do
      ctx = CausalContext.new()
      assert CausalContext.mergeable?(ctx) == false
    end

    test "returns true when set" do
      ctx = CausalContext.new(mergeable: true)
      assert CausalContext.mergeable?(ctx) == true
    end

    test "with_mergeable/2 sets the flag" do
      ctx = CausalContext.new()
      updated = CausalContext.with_mergeable(ctx, true)

      assert CausalContext.mergeable?(updated) == true
    end
  end
end
