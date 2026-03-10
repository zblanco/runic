defmodule Runic.Workflow.FSM do
  @moduledoc """
  A finite state machine component with discrete named states and event-driven transitions.

  An FSM models a system that is always in exactly one of a finite set of states.
  Transitions between states are triggered by named events and may have entry
  actions that fire when a state is entered.

  ## How It Works

  At compile time an FSM is lowered into standard Runic primitives:

  - An **Accumulator** that holds the current state as an atom value, initialized
    to the declared `initial_state`.
  - One **Rule** per transition. Each rule uses `state_of()` meta-references to
    gate on the current state and matches against the incoming event. The rule's
    reaction produces the target state atom which feeds back into the accumulator.
  - One **Rule** per `on_entry` action. Entry rules fire when the accumulator
    transitions into the associated state.

  Each transition rule is named `:"<fsm_name>_<from_state>_on_<event>"`, making
  individual transitions addressable by name.

  Compile-time validation ensures:
  - The `initial_state` refers to a declared state
  - All transition `:to` targets refer to declared states
  - No duplicate `{state, event}` transition pairs exist

  The content hash is deterministic — identical FSM definitions produce the
  same hash regardless of compilation order.

  ## DSL Syntax

  FSMs are created with the `Runic.fsm/2` macro using a block DSL:

      Runic.fsm name: :name do
        initial_state :state_name

        state :state_name do
          on :event_name, to: :target_state
          on_entry fn -> side_effect_value end
        end
      end

  ### Directives

  - `initial_state :atom` — declares the starting state (required, must match
    a declared state).
  - `state :name do ... end` — declares a state with its transitions and
    optional entry action.
  - `on :event, to: :target` — declares a transition from the enclosing state
    to `:target` when `:event` is received.
  - `on_entry fn -> value end` — declares a side-effect function that fires
    when this state is entered.

  ## Examples

      require Runic

      # Traffic light FSM
      fsm = Runic.fsm name: :traffic_light do
        initial_state :red

        state :red do
          on :timer, to: :green
          on :emergency, to: :red
          on_entry fn -> {:notify, :traffic_stopped} end
        end

        state :green do
          on :timer, to: :yellow
          on :emergency, to: :red
        end

        state :yellow do
          on :timer, to: :red
          on :emergency, to: :red
        end
      end

      # Add to workflow and run
      alias Runic.Workflow

      wrk = Workflow.new() |> Workflow.add(fsm)
      wrk = Workflow.react(wrk, :timer)
      # Current state transitions from :red -> :green

  ## Sub-Component Access

  After adding an FSM to a workflow, its internal primitives can be retrieved
  via `Workflow.get_component/2` using a `{name, kind}` tuple:

      alias Runic.Workflow

      wrk = Workflow.new() |> Workflow.add(fsm)

      # Get the underlying accumulator (holds current state atom)
      [accumulator] = Workflow.get_component(wrk, {:traffic_light, :accumulator})

      # Get all transition rules
      transitions = Workflow.get_component(wrk, {:traffic_light, :transition})
  """

  defstruct [
    :name,
    :initial_state,
    :states,
    :accumulator,
    :transition_rules,
    :entry_rules,
    :workflow,
    :source,
    :hash,
    :bindings,
    :inputs,
    :outputs
  ]
end
