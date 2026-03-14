defmodule Runic.Workflow.Aggregate do
  @moduledoc """
  A CQRS/Event Sourcing aggregate component that validates commands, emits domain events, and folds events into state.

  An Aggregate separates write operations (commands) from state projection
  (event handlers). Commands are validated against the current state via
  optional guards, produce domain events on success, and those events are
  folded back into the aggregate's state by event handlers. This mirrors
  the Aggregate pattern from Domain-Driven Design.

  Note that the "events" here are domain-level facts flowing through the
  workflow graph — they are distinct from Runic's internal workflow events
  used for replay and event sourcing at the engine layer.

  ## How It Works

  At compile time an Aggregate is lowered into standard Runic primitives:

  - An **Accumulator** that holds the aggregate's state. Its reducer is built
    from the declared `event` handlers — each event pattern is matched and
    folded into the current state.
  - One **Rule** per command handler. Each rule uses `state_of()` meta-references
    to access the current state, applies the optional `where` guard as a
    condition, and produces a domain event via the `emit` function as its
    reaction. The emitted event then feeds back into the accumulator's reducer.

  Each command rule is named `:"<aggregate_name>_<command_name>"`.

  ## DSL Syntax

  Aggregates are created with the `Runic.aggregate/2` macro using a block DSL:

      Runic.aggregate name: :name do
        state initial_value

        command :command_name do
          where fn state -> boolean end    # optional guard
          emit fn state -> event_value end # event producer
        end

        event pattern, state do
          new_state_expression
        end
      end

  ### Directives

  - `state value` — declares the initial aggregate state (required).
  - `command :name do ... end` — declares a command handler with:
    - `where fn state -> bool end` — optional guard that must return true
      for the command to execute. Receives the current state.
    - `emit fn state -> event end` — produces a domain event from the
      current state (required).
  - `event pattern, state do ... end` — declares an event handler that
    pattern-matches on the event value and folds it into the current state.

  ## Examples

      require Runic

      # Counter aggregate with guarded decrement
      agg = Runic.aggregate name: :counter do
        state 0

        command :increment do
          emit fn _state -> {:incremented, 1} end
        end

        command :decrement do
          where fn state -> state > 0 end
          emit fn _state -> {:decremented, 1} end
        end

        event {:incremented, n}, state do
          state + n
        end

        event {:decremented, n}, state do
          state - n
        end
      end

      # Add to workflow and process commands
      alias Runic.Workflow

      wrk = Workflow.new() |> Workflow.add(agg)
      wrk = Workflow.react(wrk, :increment)
      # State is now 1, event {:incremented, 1} was produced

  ## Sub-Component Access

  After adding an Aggregate to a workflow, its internal primitives can be
  retrieved via `Workflow.get_component/2` using a `{name, kind}` tuple:

      alias Runic.Workflow

      wrk = Workflow.new() |> Workflow.add(agg)

      # Get the underlying accumulator (holds aggregate state)
      [accumulator] = Workflow.get_component(wrk, {:counter, :accumulator})

      # Get all command handler rules
      handlers = Workflow.get_component(wrk, {:counter, :command_handler})
  """

  defstruct [
    :name,
    :initial_state,
    :command_handlers,
    :event_handlers,
    :accumulator,
    :command_rules,
    :workflow,
    :source,
    :hash,
    :bindings,
    :inputs,
    :outputs
  ]
end
