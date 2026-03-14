defmodule Runic.FSMTest do
  use ExUnit.Case, async: true
  require Runic

  alias Runic.Workflow
  alias Runic.Workflow.{FSM, Accumulator, Rule}

  describe "Runic.fsm/2 construction" do
    test "creates FSM struct with correct fields" do
      fsm =
        Runic.fsm name: :simple do
          initial_state(:idle)

          state :idle do
            on(:start, to: :running)
          end

          state :running do
            on(:stop, to: :idle)
          end
        end

      assert %FSM{name: :simple} = fsm
      assert fsm.initial_state == :idle
      assert %Accumulator{} = fsm.accumulator
      assert length(fsm.transition_rules) == 2
    end

    test "compiles to accumulator + rules (no legacy node types)" do
      fsm =
        Runic.fsm name: :basic do
          initial_state(:off)

          state :off do
            on(:toggle, to: :on)
          end

          state :on do
            on(:toggle, to: :off)
          end
        end

      wrk = Workflow.new() |> Workflow.add(fsm)
      vertices = Graph.vertices(wrk.graph)
      vertex_types = Enum.map(vertices, & &1.__struct__) |> Enum.uniq()

      for type <- vertex_types do
        assert type in [
                 Runic.Workflow.Root,
                 Runic.Workflow.Accumulator,
                 Runic.Workflow.Condition,
                 Runic.Workflow.Step,
                 Runic.Workflow.FSM,
                 Runic.Workflow.Rule,
                 Runic.Workflow.Fact
               ],
               "Unexpected vertex type: #{inspect(type)}"
      end
    end

    test "validates initial_state exists in declared states" do
      assert_raise ArgumentError, ~r/initial_state.*not.*declared/, fn ->
        Code.eval_string("""
        require Runic
        Runic.fsm name: :bad do
          initial_state :nonexistent
          state :idle do
            on :go, to: :idle
          end
        end
        """)
      end
    end

    test "validates transition targets reference declared states" do
      assert_raise ArgumentError, ~r/target.*not.*declared/, fn ->
        Code.eval_string("""
        require Runic
        Runic.fsm name: :bad_target do
          initial_state :idle
          state :idle do
            on :go, to: :nonexistent
          end
        end
        """)
      end
    end

    test "raises on duplicate {state, event} transitions" do
      assert_raise ArgumentError, ~r/[Dd]uplicate/, fn ->
        Code.eval_string("""
        require Runic
        Runic.fsm name: :dup do
          initial_state :idle
          state :idle do
            on :go, to: :running
            on :go, to: :stopped
          end
          state :running do
            on :stop, to: :idle
          end
          state :stopped do
            on :go, to: :idle
          end
        end
        """)
      end
    end

    test "content hash is deterministic" do
      fsm1 =
        Runic.fsm name: :det do
          initial_state(:a)

          state :a do
            on(:go, to: :b)
          end

          state :b do
            on(:back, to: :a)
          end
        end

      fsm2 =
        Runic.fsm name: :det do
          initial_state(:a)

          state :a do
            on(:go, to: :b)
          end

          state :b do
            on(:back, to: :a)
          end
        end

      assert fsm1.hash == fsm2.hash
    end
  end

  describe "FSM execution" do
    test "basic state transitions via react" do
      fsm =
        Runic.fsm name: :toggle do
          initial_state(:off)

          state :off do
            on(:toggle, to: :on)
          end

          state :on do
            on(:toggle, to: :off)
          end
        end

      wrk =
        Workflow.new()
        |> Workflow.add(fsm)
        |> Workflow.react_until_satisfied(:toggle)

      prods = Workflow.raw_productions(wrk)
      assert :on in prods
    end

    test "self-loop transition" do
      fsm =
        Runic.fsm name: :looper do
          initial_state(:idle)

          state :idle do
            on(:ping, to: :idle)
            on(:start, to: :running)
          end

          state :running do
            on(:stop, to: :idle)
          end
        end

      wrk =
        Workflow.new()
        |> Workflow.add(fsm)
        |> Workflow.react_until_satisfied(:ping)

      prods = Workflow.raw_productions(wrk)
      assert :idle in prods
    end

    test "invalid event for current state (no transition)" do
      fsm =
        Runic.fsm name: :strict do
          initial_state(:locked)

          state :locked do
            on(:unlock, to: :unlocked)
          end

          state :unlocked do
            on(:lock, to: :locked)
          end
        end

      wrk =
        Workflow.new()
        |> Workflow.add(fsm)
        |> Workflow.react_until_satisfied(:lock)

      # :lock event when in :locked state should not transition
      prods = Workflow.raw_productions(wrk)
      refute :unlocked in prods
    end

    test "on_entry fires when state changes" do
      fsm =
        Runic.fsm name: :with_entry do
          initial_state(:idle)

          state :idle do
            on(:start, to: :running)
          end

          state :running do
            on(:stop, to: :idle)
            on_entry(fn -> :entered_running end)
          end
        end

      wrk =
        Workflow.new()
        |> Workflow.add(fsm)
        |> Workflow.react_until_satisfied(:start)

      prods = Workflow.raw_productions(wrk)
      assert :entered_running in prods
    end

    test "works with react_until_satisfied" do
      fsm =
        Runic.fsm name: :traffic do
          initial_state(:red)

          state :red do
            on(:timer, to: :green)
          end

          state :green do
            on(:timer, to: :yellow)
          end

          state :yellow do
            on(:timer, to: :red)
          end
        end

      wrk =
        Workflow.new()
        |> Workflow.add(fsm)
        |> Workflow.react_until_satisfied(:timer)

      prods = Workflow.raw_productions(wrk)
      assert :green in prods
    end
  end

  describe "FSM composition" do
    test "FSM composes with other components via Workflow.add" do
      fsm =
        Runic.fsm name: :composable_fsm do
          initial_state(:idle)

          state :idle do
            on(:start, to: :running)
          end

          state :running do
            on(:stop, to: :idle)
          end
        end

      step = Runic.step(fn x -> {:processed, x} end, name: :processor)

      _wrk =
        Workflow.new()
        |> Workflow.add(step)
        |> Workflow.add(fsm, to: :processor)
    end

    test "FSM transmutable to_workflow" do
      fsm =
        Runic.fsm name: :transmutable_fsm do
          initial_state(:a)

          state :a do
            on(:go, to: :b)
          end

          state :b do
            on(:back, to: :a)
          end
        end

      wrk = Runic.Transmutable.to_workflow(fsm)
      assert %Workflow{} = wrk
      refute is_nil(wrk.components[:transmutable_fsm])
    end
  end

  describe "FSM sub-component access" do
    test "get_component returns accumulator" do
      fsm =
        Runic.fsm name: :accessible_fsm do
          initial_state(:idle)

          state :idle do
            on(:go, to: :running)
          end

          state :running do
            on(:stop, to: :idle)
          end
        end

      wrk = Workflow.new() |> Workflow.add(fsm)

      accumulators = Workflow.get_component(wrk, {:accessible_fsm, :accumulator})
      assert is_list(accumulators)
      assert Enum.any?(accumulators, &match?(%Accumulator{}, &1))
    end

    test "get_component returns transition rules" do
      fsm =
        Runic.fsm name: :transition_access do
          initial_state(:idle)

          state :idle do
            on(:go, to: :running)
          end

          state :running do
            on(:stop, to: :idle)
          end
        end

      wrk = Workflow.new() |> Workflow.add(fsm)

      transitions = Workflow.get_component(wrk, {:transition_access, :transition})
      assert is_list(transitions)
      assert length(transitions) == 2
      assert Enum.all?(transitions, &match?(%Rule{}, &1))
    end
  end
end
