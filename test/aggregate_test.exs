defmodule Runic.AggregateTest do
  use ExUnit.Case, async: true
  require Runic

  alias Runic.Workflow
  alias Runic.Workflow.{Aggregate, Accumulator, Rule}

  describe "Runic.aggregate/2 construction" do
    test "creates Aggregate struct with correct fields" do
      agg =
        Runic.aggregate name: :counter do
          state(0)

          command :increment do
            emit(fn _state -> {:incremented, 1} end)
          end

          event {:incremented, n}, state do
            state + n
          end
        end

      assert %Aggregate{name: :counter} = agg
      assert agg.initial_state == 0
      assert %Accumulator{} = agg.accumulator
      assert length(agg.command_rules) >= 1
    end

    test "compiles to accumulator + rules" do
      agg =
        Runic.aggregate name: :basic_agg do
          state(0)

          command :increment do
            emit(fn _state -> {:incremented, 1} end)
          end

          event {:incremented, n}, state do
            state + n
          end
        end

      wrk = Workflow.new() |> Workflow.add(agg)
      vertices = Graph.vertices(wrk.graph)
      vertex_types = Enum.map(vertices, & &1.__struct__) |> Enum.uniq()

      for type <- vertex_types do
        assert type in [
                 Runic.Workflow.Root,
                 Runic.Workflow.Accumulator,
                 Runic.Workflow.Condition,
                 Runic.Workflow.Step,
                 Runic.Workflow.Aggregate,
                 Runic.Workflow.Rule,
                 Runic.Workflow.Fact
               ],
               "Unexpected vertex type: #{inspect(type)}"
      end
    end

    test "content hash is deterministic" do
      agg1 =
        Runic.aggregate name: :det_agg do
          state(0)

          command :inc do
            emit(fn _state -> {:incremented, 1} end)
          end

          event {:incremented, n}, state do
            state + n
          end
        end

      agg2 =
        Runic.aggregate name: :det_agg do
          state(0)

          command :inc do
            emit(fn _state -> {:incremented, 1} end)
          end

          event {:incremented, n}, state do
            state + n
          end
        end

      assert agg1.hash == agg2.hash
    end
  end

  describe "Aggregate execution" do
    test "command accepted when state satisfies guard" do
      agg =
        Runic.aggregate name: :guarded do
          state(5)

          command :decrement do
            where(fn state -> state > 0 end)
            emit(fn _state -> {:decremented, 1} end)
          end

          event {:decremented, n}, state do
            state - n
          end
        end

      wrk =
        Workflow.new()
        |> Workflow.add(agg)
        |> Workflow.react_until_satisfied(:decrement)

      prods = Workflow.raw_productions(wrk)

      assert Enum.any?(prods, fn
               {:decremented, 1} -> true
               4 -> true
               _ -> false
             end)
    end

    test "command rejected when state doesn't satisfy guard" do
      agg =
        Runic.aggregate name: :reject_test do
          state(0)

          command :decrement do
            where(fn state -> state > 0 end)
            emit(fn _state -> {:decremented, 1} end)
          end

          event {:decremented, n}, state do
            state - n
          end
        end

      wrk =
        Workflow.new()
        |> Workflow.add(agg)
        |> Workflow.react_until_satisfied(:decrement)

      prods = Workflow.raw_productions(wrk)
      refute Enum.any?(prods, &match?({:decremented, _}, &1))
    end

    test "event folds into state correctly" do
      agg =
        Runic.aggregate name: :fold_test do
          state(0)

          command :increment do
            emit(fn _state -> {:incremented, 1} end)
          end

          event {:incremented, n}, state do
            state + n
          end
        end

      wrk =
        Workflow.new()
        |> Workflow.add(agg)
        |> Workflow.react_until_satisfied(:increment)

      prods = Workflow.raw_productions(wrk)
      # The reaction produces {:incremented, 1}, which the accumulator folds to state 1.
      assert {:incremented, 1} in prods or 1 in prods,
             "Expected {:incremented, 1} or 1 in productions, got: #{inspect(prods)}"
    end
  end

  describe "Aggregate composition" do
    test "aggregate composes with downstream steps" do
      agg =
        Runic.aggregate name: :composable_agg do
          state(0)

          command :increment do
            emit(fn _state -> {:incremented, 1} end)
          end

          event {:incremented, n}, state do
            state + n
          end
        end

      step = Runic.step(fn x -> {:logged, x} end, name: :logger)

      _wrk =
        Workflow.new()
        |> Workflow.add(agg)
        |> Workflow.add(step, to: :composable_agg)
    end

    test "aggregate transmutable to_workflow" do
      agg =
        Runic.aggregate name: :transmutable_agg do
          state(0)

          command :increment do
            emit(fn _state -> {:incremented, 1} end)
          end

          event {:incremented, n}, state do
            state + n
          end
        end

      wrk = Runic.Transmutable.to_workflow(agg)
      assert %Workflow{} = wrk
      refute is_nil(wrk.components[:transmutable_agg])
    end
  end

  describe "Aggregate sub-component access" do
    test "get_component returns accumulator" do
      agg =
        Runic.aggregate name: :accessible_agg do
          state(0)

          command :increment do
            emit(fn _state -> {:incremented, 1} end)
          end

          event {:incremented, n}, state do
            state + n
          end
        end

      wrk = Workflow.new() |> Workflow.add(agg)

      accumulators = Workflow.get_component(wrk, {:accessible_agg, :accumulator})
      assert is_list(accumulators)
      assert Enum.any?(accumulators, &match?(%Accumulator{}, &1))
    end

    test "get_component returns command handler rules" do
      agg =
        Runic.aggregate name: :cmd_access do
          state(0)

          command :increment do
            emit(fn _state -> {:incremented, 1} end)
          end

          event {:incremented, n}, state do
            state + n
          end
        end

      wrk = Workflow.new() |> Workflow.add(agg)

      handlers = Workflow.get_component(wrk, {:cmd_access, :command_handler})
      assert is_list(handlers)
      assert length(handlers) >= 1
      assert Enum.all?(handlers, &match?(%Rule{}, &1))
    end
  end
end
