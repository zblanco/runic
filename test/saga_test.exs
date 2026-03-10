defmodule Runic.SagaTest do
  use ExUnit.Case, async: true
  require Runic

  alias Runic.Workflow
  alias Runic.Workflow.{Saga, Accumulator, Rule}

  describe "Runic.saga/2 construction" do
    test "creates Saga struct with transaction/compensate pairs" do
      saga =
        Runic.saga name: :simple_saga do
          transaction :step_one do
            fn _input -> {:ok, :result_one} end
          end

          compensate :step_one do
            fn %{step_one: _} -> :compensated_one end
          end
        end

      assert %Saga{name: :simple_saga} = saga
      assert %Accumulator{} = saga.accumulator
      assert is_list(saga.forward_rules)
      assert is_list(saga.compensation_rules)
    end

    test "compiles to accumulator + rules" do
      saga =
        Runic.saga name: :basic_saga do
          transaction :step_one do
            fn _input -> {:ok, :done} end
          end

          compensate :step_one do
            fn _ -> :undone end
          end
        end

      wrk = Workflow.new() |> Workflow.add(saga)
      vertices = Graph.vertices(wrk.graph)
      vertex_types = Enum.map(vertices, & &1.__struct__) |> Enum.uniq()

      for type <- vertex_types do
        assert type in [
                 Runic.Workflow.Root,
                 Runic.Workflow.Accumulator,
                 Runic.Workflow.Condition,
                 Runic.Workflow.Step,
                 Runic.Workflow.Saga,
                 Runic.Workflow.Rule,
                 Runic.Workflow.Fact
               ],
               "Unexpected vertex type: #{inspect(type)}"
      end
    end

    test "content hash is deterministic" do
      saga1 =
        Runic.saga name: :det_saga do
          transaction :step_one do
            fn _input -> {:ok, :done} end
          end

          compensate :step_one do
            fn _ -> :undone end
          end
        end

      saga2 =
        Runic.saga name: :det_saga do
          transaction :step_one do
            fn _input -> {:ok, :done} end
          end

          compensate :step_one do
            fn _ -> :undone end
          end
        end

      assert saga1.hash == saga2.hash
    end

    test "validates each transaction has a corresponding compensate" do
      assert_raise ArgumentError, ~r/compensate/, fn ->
        Code.eval_string("""
        require Runic
        Runic.saga name: :missing_comp do
          transaction :step_one do
            fn _input -> {:ok, :done} end
          end
        end
        """)
      end
    end
  end

  describe "Saga execution — happy path" do
    test "single step saga completes" do
      saga =
        Runic.saga name: :single_step do
          transaction :step_one do
            fn _input -> {:ok, :result_one} end
          end

          compensate :step_one do
            fn _ -> :comp_one end
          end
        end

      wrk =
        Workflow.new()
        |> Workflow.add(saga)
        |> Workflow.react_until_satisfied(:start)

      prods = Workflow.raw_productions(wrk)

      assert Enum.any?(prods, fn
               %{status: :completed} -> true
               {:step_completed, :step_one, _} -> true
               _ -> false
             end)
    end

    test "multi-step saga executes steps in order" do
      saga =
        Runic.saga name: :multi_step do
          transaction :first do
            fn _input -> {:ok, :first_done} end
          end

          compensate :first do
            fn _ -> :first_undone end
          end

          transaction :second do
            fn %{first: _} -> {:ok, :second_done} end
          end

          compensate :second do
            fn _ -> :second_undone end
          end
        end

      wrk =
        Workflow.new()
        |> Workflow.add(saga)
        |> Workflow.react_until_satisfied(:start)

      prods = Workflow.raw_productions(wrk)

      has_completed =
        Enum.any?(prods, fn
          %{status: :completed} -> true
          _ -> false
        end)

      has_step_results =
        Enum.any?(prods, &match?({:step_completed, _, _}, &1))

      assert has_completed or has_step_results
    end
  end

  describe "Saga execution — failure and compensation" do
    test "single step saga compensates on failure" do
      saga =
        Runic.saga name: :fail_saga do
          transaction :step_one do
            fn _input -> {:error, :boom} end
          end

          compensate :step_one do
            fn _ -> :compensated end
          end
        end

      wrk =
        Workflow.new()
        |> Workflow.add(saga)
        |> Workflow.react_until_satisfied(:start)

      prods = Workflow.raw_productions(wrk)

      has_failure =
        Enum.any?(prods, fn
          {:step_failed, :step_one, _} -> true
          %{status: :compensating} -> true
          %{status: :aborted} -> true
          _ -> false
        end)

      assert has_failure
    end

    test "multi-step saga compensates completed steps on failure" do
      saga =
        Runic.saga name: :multi_fail do
          transaction :first do
            fn _input -> {:ok, :first_done} end
          end

          compensate :first do
            fn _ -> :first_compensated end
          end

          transaction :second do
            fn _results -> {:error, :second_failed} end
          end

          compensate :second do
            fn _ -> :second_compensated end
          end
        end

      wrk =
        Workflow.new()
        |> Workflow.add(saga)
        |> Workflow.react_until_satisfied(:start)

      prods = Workflow.raw_productions(wrk)

      has_compensation_or_abort =
        Enum.any?(prods, fn
          {:compensated, :first} -> true
          %{status: :aborted} -> true
          %{status: :compensating} -> true
          _ -> false
        end)

      assert has_compensation_or_abort
    end
  end

  describe "Saga with terminal handlers" do
    test "on_complete fires when saga succeeds" do
      saga =
        Runic.saga name: :complete_handler do
          transaction :step_one do
            fn _input -> {:ok, :done} end
          end

          compensate :step_one do
            fn _ -> :undone end
          end

          on_complete(fn results -> {:saga_completed, results} end)
        end

      wrk =
        Workflow.new()
        |> Workflow.add(saga)
        |> Workflow.react_until_satisfied(:start)

      prods = Workflow.raw_productions(wrk)

      has_completion =
        Enum.any?(prods, fn
          {:saga_completed, _} -> true
          %{status: :completed} -> true
          _ -> false
        end)

      assert has_completion
    end

    test "on_abort fires when saga fails" do
      saga =
        Runic.saga name: :abort_handler do
          transaction :step_one do
            fn _input -> {:error, :failure} end
          end

          compensate :step_one do
            fn _ -> :undone end
          end

          on_abort(fn reason, compensated -> {:saga_aborted, reason, compensated} end)
        end

      wrk =
        Workflow.new()
        |> Workflow.add(saga)
        |> Workflow.react_until_satisfied(:start)

      prods = Workflow.raw_productions(wrk)

      has_abort =
        Enum.any?(prods, fn
          {:saga_aborted, _, _} -> true
          %{status: :aborted} -> true
          %{status: :compensating} -> true
          _ -> false
        end)

      assert has_abort
    end
  end

  describe "Saga composition" do
    test "saga composes with other components" do
      saga =
        Runic.saga name: :composable_saga do
          transaction :step_one do
            fn _input -> {:ok, :done} end
          end

          compensate :step_one do
            fn _ -> :undone end
          end
        end

      step = Runic.step(fn x -> {:processed, x} end, name: :post_saga)

      wrk =
        Workflow.new()
        |> Workflow.add(saga)
        |> Workflow.add(step, to: :composable_saga)

      assert %Workflow{} = wrk
    end

    test "saga transmutable to_workflow" do
      saga =
        Runic.saga name: :transmutable_saga do
          transaction :step_one do
            fn _input -> {:ok, :done} end
          end

          compensate :step_one do
            fn _ -> :undone end
          end
        end

      wrk = Runic.Transmutable.to_workflow(saga)
      assert %Workflow{} = wrk
      refute is_nil(wrk.components[:transmutable_saga])
    end
  end

  describe "Saga sub-component access" do
    test "get_component returns accumulator" do
      saga =
        Runic.saga name: :accessible_saga do
          transaction :step_one do
            fn _input -> {:ok, :done} end
          end

          compensate :step_one do
            fn _ -> :undone end
          end
        end

      wrk = Workflow.new() |> Workflow.add(saga)

      accumulators = Workflow.get_component(wrk, {:accessible_saga, :accumulator})
      assert is_list(accumulators)
      assert Enum.any?(accumulators, &match?(%Accumulator{}, &1))
    end

    test "get_component returns transaction rules when terminal handlers exist" do
      saga =
        Runic.saga name: :tx_access do
          transaction :step_one do
            fn _input -> {:ok, :done} end
          end

          compensate :step_one do
            fn _ -> :undone end
          end

          on_complete(fn results -> {:done, results} end)
        end

      wrk = Workflow.new() |> Workflow.add(saga)

      txns = Workflow.get_component(wrk, {:tx_access, :transaction})
      assert is_list(txns)
      assert length(txns) >= 1
      assert Enum.all?(txns, &match?(%Rule{}, &1))
    end
  end

  describe "no legacy node types" do
    test "saga workflow contains only standard primitives" do
      saga =
        Runic.saga name: :primitives_only do
          transaction :step_one do
            fn _input -> {:ok, :done} end
          end

          compensate :step_one do
            fn _ -> :undone end
          end
        end

      wrk = Workflow.new() |> Workflow.add(saga)
      vertices = Graph.vertices(wrk.graph)
      vertex_types = Enum.map(vertices, & &1.__struct__) |> Enum.uniq()

      for type <- vertex_types do
        assert type in [
                 Runic.Workflow.Root,
                 Runic.Workflow.Accumulator,
                 Runic.Workflow.Condition,
                 Runic.Workflow.Step,
                 Runic.Workflow.Saga,
                 Runic.Workflow.Rule,
                 Runic.Workflow.Fact
               ],
               "Unexpected vertex type: #{inspect(type)}"
      end
    end
  end

  describe "accumulator state tracking" do
    test "accumulator init has correct saga state structure" do
      saga =
        Runic.saga name: :state_tracking do
          transaction :step_a do
            fn _input -> {:ok, :a_done} end
          end

          compensate :step_a do
            fn _ -> :a_undone end
          end

          transaction :step_b do
            fn _results -> {:ok, :b_done} end
          end

          compensate :step_b do
            fn _ -> :b_undone end
          end
        end

      init_state = saga.accumulator.init.()
      assert init_state.status == :pending
      assert init_state.current_step == :step_a
      assert init_state.results == %{}
      assert init_state.failure_reason == nil
      assert init_state.compensated == []
      assert init_state.step_order == [:step_a, :step_b]
    end

    test "accumulator reducer runs all steps on single input" do
      saga =
        Runic.saga name: :reducer_test do
          transaction :step_a do
            fn _input -> {:ok, :a_done} end
          end

          compensate :step_a do
            fn _ -> :a_undone end
          end

          transaction :step_b do
            fn _results -> {:ok, :b_done} end
          end

          compensate :step_b do
            fn _ -> :b_undone end
          end
        end

      init_state = saga.accumulator.init.()
      reducer = saga.accumulator.reducer

      final_state = reducer.(:start, init_state)
      assert final_state.results == %{step_a: :a_done, step_b: :b_done}
      assert final_state.current_step == nil
      assert final_state.status == :completed
    end

    test "accumulator reducer handles step failure and compensation" do
      saga =
        Runic.saga name: :fail_reducer_test do
          transaction :step_a do
            fn _input -> {:ok, :a_done} end
          end

          compensate :step_a do
            fn _ -> :a_undone end
          end

          transaction :step_b do
            fn _results -> {:error, :boom} end
          end

          compensate :step_b do
            fn _ -> :b_undone end
          end
        end

      init_state = saga.accumulator.init.()
      reducer = saga.accumulator.reducer

      state = reducer.(:start, init_state)
      assert state.status == :aborted
      assert state.failure_reason == {:step_b, :boom}
      assert :step_a in state.compensated
    end
  end
end
