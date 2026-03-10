defmodule Runic.ProcessManagerTest do
  use ExUnit.Case, async: true
  require Runic

  alias Runic.Workflow
  alias Runic.Workflow.{ProcessManager, Accumulator, Rule}

  describe "Runic.process_manager/2 construction" do
    test "creates ProcessManager struct with correct fields" do
      pm =
        Runic.process_manager name: :simple_pm do
          state(%{count: 0})

          on :increment do
            update(%{count: 1})
          end
        end

      assert %ProcessManager{name: :simple_pm} = pm
      assert %Accumulator{} = pm.accumulator
      assert pm.event_handlers == 1
    end

    test "compiles to accumulator + event handler rules" do
      pm =
        Runic.process_manager name: :with_emit do
          state(%{started: false})

          on :start do
            update(%{started: true})
            emit({:command, :do_work})
          end
        end

      assert %ProcessManager{} = pm
      assert %Accumulator{} = pm.accumulator
      assert length(pm.event_rules) == 1
    end

    test "compiles to standard primitives only" do
      pm =
        Runic.process_manager name: :primitives_pm do
          state(%{value: 0})

          on :tick do
            update(%{value: 1})
            emit(:tock)
          end
        end

      wrk = Workflow.new() |> Workflow.add(pm)
      vertices = Graph.vertices(wrk.graph)
      vertex_types = Enum.map(vertices, & &1.__struct__) |> Enum.uniq()

      for type <- vertex_types do
        assert type in [
                 Runic.Workflow.Root,
                 Runic.Workflow.Accumulator,
                 Runic.Workflow.Condition,
                 Runic.Workflow.Step,
                 Runic.Workflow.ProcessManager,
                 Runic.Workflow.Rule,
                 Runic.Workflow.Fact
               ],
               "Unexpected vertex type: #{inspect(type)}"
      end
    end

    test "content hash is deterministic" do
      pm1 =
        Runic.process_manager name: :det_pm do
          state(%{x: 0})

          on :go do
            update(%{x: 1})
          end
        end

      pm2 =
        Runic.process_manager name: :det_pm do
          state(%{x: 0})

          on :go do
            update(%{x: 1})
          end
        end

      assert pm1.hash == pm2.hash
    end

    test "handlers without emit produce no event rules" do
      pm =
        Runic.process_manager name: :no_emit do
          state(%{done: false})

          on :finish do
            update(%{done: true})
          end
        end

      assert pm.event_rules == []
    end

    test "completion check is tracked" do
      pm =
        Runic.process_manager name: :with_complete do
          state(%{done: false})

          on :finish do
            update(%{done: true})
          end

          complete?(fn state -> state.done end)
        end

      assert pm.completion_check == true
      assert %Rule{} = pm.completion_rule
    end
  end

  describe "ProcessManager execution" do
    test "event triggers state update" do
      pm =
        Runic.process_manager name: :state_update do
          state(%{count: 0})

          on :increment do
            update(%{count: 1})
          end
        end

      wrk =
        Workflow.new()
        |> Workflow.add(pm)
        |> Workflow.react_until_satisfied(:increment)

      prods = Workflow.raw_productions(wrk)
      assert Enum.any?(prods, &match?(%{count: 1}, &1))
    end

    test "event triggers command emission" do
      pm =
        Runic.process_manager name: :emit_cmd do
          state(%{started: false})

          on :start do
            update(%{started: true})
            emit({:command, :do_work})
          end
        end

      wrk =
        Workflow.new()
        |> Workflow.add(pm)
        |> Workflow.react_until_satisfied(:start)

      prods = Workflow.raw_productions(wrk)
      assert Enum.any?(prods, &match?({:command, :do_work}, &1))
    end

    test "completion check fires at correct state" do
      pm =
        Runic.process_manager name: :complete_check do
          state(%{done: false})

          on :finish do
            update(%{done: true})
          end

          complete?(fn state -> state.done end)
        end

      wrk =
        Workflow.new()
        |> Workflow.add(pm)
        |> Workflow.react_until_satisfied(:finish)

      prods = Workflow.raw_productions(wrk)
      assert Enum.any?(prods, &match?({:process_completed, :complete_check}, &1))
    end

    test "completion check does not fire when predicate not satisfied" do
      pm =
        Runic.process_manager name: :no_complete do
          state(%{step1: false, step2: false})

          on :step_one do
            update(%{step1: true})
          end

          complete?(fn state -> state.step1 and state.step2 end)
        end

      wrk =
        Workflow.new()
        |> Workflow.add(pm)
        |> Workflow.react_until_satisfied(:step_one)

      prods = Workflow.raw_productions(wrk)
      refute Enum.any?(prods, &match?({:process_completed, _}, &1))
    end

    test "unmatched event does not change state" do
      pm =
        Runic.process_manager name: :unmatched do
          state(%{count: 0})

          on :increment do
            update(%{count: 1})
          end
        end

      wrk =
        Workflow.new()
        |> Workflow.add(pm)
        |> Workflow.react_until_satisfied(:decrement)

      prods = Workflow.raw_productions(wrk)
      assert Enum.any?(prods, &match?(%{count: 0}, &1))
    end

    test "multiple event handlers work independently" do
      pm =
        Runic.process_manager name: :multi_handler do
          state(%{a: false, b: false})

          on :event_a do
            update(%{a: true})
            emit({:got, :a})
          end

          on :event_b do
            update(%{b: true})
            emit({:got, :b})
          end
        end

      wrk =
        Workflow.new()
        |> Workflow.add(pm)
        |> Workflow.react_until_satisfied(:event_a)

      prods = Workflow.raw_productions(wrk)
      assert Enum.any?(prods, &match?({:got, :a}, &1))
      refute Enum.any?(prods, &match?({:got, :b}, &1))
    end
  end

  describe "ProcessManager composition" do
    test "composes with other components via Workflow.add" do
      pm =
        Runic.process_manager name: :composable_pm do
          state(%{active: false})

          on :activate do
            update(%{active: true})
            emit(:activated)
          end
        end

      step = Runic.step(fn x -> {:logged, x} end, name: :logger)

      wrk =
        Workflow.new()
        |> Workflow.add(step)
        |> Workflow.add(pm, to: :logger)

      assert %Workflow{} = wrk
    end

    test "transmutable to_workflow" do
      pm =
        Runic.process_manager name: :transmutable_pm do
          state(%{x: 0})

          on :go do
            update(%{x: 1})
          end
        end

      wrk = Runic.Transmutable.to_workflow(pm)
      assert %Workflow{} = wrk
      refute is_nil(wrk.components[:transmutable_pm])
    end
  end

  describe "ProcessManager sub-component access" do
    test "get_component returns accumulator" do
      pm =
        Runic.process_manager name: :accessible_pm do
          state(%{count: 0})

          on :increment do
            update(%{count: 1})
            emit(:incremented)
          end
        end

      wrk = Workflow.new() |> Workflow.add(pm)

      accumulators = Workflow.get_component(wrk, {:accessible_pm, :accumulator})
      assert is_list(accumulators)
      assert Enum.any?(accumulators, &match?(%Accumulator{}, &1))
    end

    test "get_component returns event handler rules" do
      pm =
        Runic.process_manager name: :handler_access do
          state(%{count: 0})

          on :increment do
            update(%{count: 1})
            emit(:incremented)
          end
        end

      wrk = Workflow.new() |> Workflow.add(pm)

      handlers = Workflow.get_component(wrk, {:handler_access, :event_handler})
      assert is_list(handlers)
      assert length(handlers) == 1
      assert Enum.all?(handlers, &match?(%Rule{}, &1))
    end

    test "get_component returns completion rule" do
      pm =
        Runic.process_manager name: :comp_access do
          state(%{done: false})

          on :finish do
            update(%{done: true})
          end

          complete?(fn state -> state.done end)
        end

      wrk = Workflow.new() |> Workflow.add(pm)

      completion = Workflow.get_component(wrk, {:comp_access, :completion})
      assert is_list(completion)
      assert length(completion) == 1
      assert Enum.all?(completion, &match?(%Rule{}, &1))
    end
  end
end
