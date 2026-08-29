defmodule Runic.Workflow.IdentityTest do
  use ExUnit.Case, async: false

  require Runic

  alias Runic.Workflow
  alias Runic.Workflow.{Components, Fact, FactRef, IdentityConflictError, Step}

  @max_phash 4_294_967_296

  describe "phash2_64_v1" do
    test "combines the primary hash with a domain-separated secondary hash" do
      term = {%{answer: 42}, {:producer, :parent}}
      primary = :erlang.phash2(term, @max_phash)
      secondary = :erlang.phash2({:phash2_64_v1, :secondary, term}, @max_phash)

      assert Components.hash_scheme() == :phash2_64_v1
      assert Components.fact_hash(term) == primary * @max_phash + secondary
      assert Components.fact_hash(term) in 0..(Integer.pow(2, 64) - 1)
    end

    test "separates the issue 16 Step.new collision and preserves both results" do
      left =
        Step.new(
          name: "left",
          hash: "probe-step-11396",
          work: fn _input -> %{value: 11_396} end
        )

      right =
        Step.new(
          name: "right",
          hash: "probe-step-19508",
          work: fn _input -> %{value: 19_508} end
        )

      run = run_parallel(left, right, %{})
      left_basis = {run.left.result.value, run.left.result.ancestry}
      right_basis = {run.right.result.value, run.right.result.ancestry}

      assert :erlang.phash2(left_basis, @max_phash) ==
               :erlang.phash2(right_basis, @max_phash)

      refute run.left.result.hash == run.right.result.hash

      assert result_values(run.workflow, ["left", "right"]) == %{
               "left" => %{value: 11_396},
               "right" => %{value: 19_508}
             }
    end

    @tag timeout: 30_000
    test "separates a primary collision produced by macro-built steps" do
      left = Runic.step(fn _input -> %{value: context(:value)} end, name: :left)
      right = Runic.step(fn _input -> %{value: context(:value)} end, name: :right)
      root_hash = Fact.new(value: %{}).hash
      {left_value, right_value, primary_hash} = find_primary_collision(left, right, root_hash)

      run =
        run_parallel(left, right, %{
          left: %{value: left_value},
          right: %{value: right_value}
        })

      assert div(run.left.result.hash, @max_phash) == primary_hash
      assert div(run.right.result.hash, @max_phash) == primary_hash
      refute run.left.result.hash == run.right.result.hash

      assert result_values(run.workflow, [:left, :right]) == %{
               left: %{value: left_value},
               right: %{value: right_value}
             }
    end
  end

  describe "guarded fact insertion" do
    test "keeps an equivalent Fact insertion idempotent" do
      original = Fact.new(hash: 101, value: :same, ancestry: {:producer, :parent}, meta: %{a: 1})
      duplicate = %{original | meta: %{a: 2}}

      workflow = Workflow.new() |> Workflow.log_fact(original) |> Workflow.log_fact(duplicate)

      assert workflow.graph.vertices[101] == original
    end

    test "keeps an equivalent FactRef insertion idempotent" do
      ref = %FactRef{hash: 102, ancestry: {:producer, :parent}}

      workflow = Workflow.new() |> Workflow.log_fact(ref) |> Workflow.log_fact(ref)

      assert workflow.graph.vertices[102] == ref
    end

    test "raises before replacing a distinct Fact at the same identity" do
      original = Fact.new(hash: 103, value: :first, ancestry: {:producer, :parent})
      conflicting = Fact.new(hash: 103, value: :second, ancestry: {:producer, :parent})
      workflow = Workflow.new() |> Workflow.log_fact(original)

      error =
        assert_raise IdentityConflictError, fn ->
          Workflow.log_fact(workflow, conflicting)
        end

      assert error.identity == 103
      assert error.context == :log_fact
      assert error.existing.value_type == :atom
      assert error.incoming.value_type == :atom
      assert workflow.graph.vertices[103] == original
    end

    test "fails closed when a Fact and FactRef claim the same identity" do
      fact = Fact.new(hash: 104, value: :full, ancestry: {:producer, :parent})
      ref = %FactRef{hash: 104, ancestry: fact.ancestry}

      assert_raise IdentityConflictError, fn ->
        Workflow.new() |> Workflow.log_fact(fact) |> Workflow.log_fact(ref)
      end

      assert_raise IdentityConflictError, fn ->
        Workflow.new() |> Workflow.log_fact(ref) |> Workflow.log_fact(fact)
      end
    end

    test "rejects a Fact identity already occupied by a component" do
      step = Step.new(name: :occupied, hash: 105, work: &Function.identity/1)
      fact = Fact.new(hash: 105, value: :fact, ancestry: nil)
      workflow = Workflow.new() |> Workflow.add(step)

      error =
        assert_raise IdentityConflictError, fn ->
          Workflow.log_fact(workflow, fact)
        end

      assert error.existing == %{type: Step, hash: 105}
      assert error.incoming.type == Fact
    end
  end

  defp find_primary_collision(left, right, root_hash) do
    search_range = 0..250_000

    left_hashes =
      Map.new(search_range, fn value ->
        basis = {%{value: value}, {left.hash, root_hash}}
        {:erlang.phash2(basis, @max_phash), value}
      end)

    Enum.find_value(search_range, fn right_value ->
      basis = {%{value: right_value}, {right.hash, root_hash}}
      hash = :erlang.phash2(basis, @max_phash)

      case Map.fetch(left_hashes, hash) do
        {:ok, left_value} when left_value != right_value ->
          {left_value, right_value, hash}

        _other ->
          nil
      end
    end) || flunk("expected a primary phash2 collision in the search range")
  end

  defp run_parallel(left, right, context) do
    workflow =
      Workflow.new("identity_collision")
      |> Workflow.add(left)
      |> Workflow.add(right)
      |> Workflow.put_run_context(context)
      |> Workflow.plan_eagerly(%{})

    {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)
    left_runnable = Enum.find(runnables, &(&1.node.name == left.name))
    right_runnable = Enum.find(runnables, &(&1.node.name == right.name))
    executed_left = Workflow.execute_runnable(left_runnable)
    executed_right = Workflow.execute_runnable(right_runnable)

    workflow =
      workflow
      |> Workflow.apply_runnable(executed_left)
      |> Workflow.apply_runnable(executed_right)

    %{workflow: workflow, left: executed_left, right: executed_right}
  end

  defp result_values(workflow, names) do
    workflow
    |> Workflow.results(names, facts: true, all: true)
    |> Map.new(fn {name, facts} -> {name, facts |> List.first() |> Map.fetch!(:value)} end)
  end
end
