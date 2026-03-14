defmodule Runic.Workflow.ProcessManager do
  @moduledoc """
  An event-driven process orchestrator that coordinates across multiple aggregates.

  A ProcessManager reacts to events from various sources, maintains its own
  coordination state, and issues commands to drive a business process forward.
  Unlike the `Saga` component (sequential forward-then-compensate pipeline),
  a ProcessManager is reactive and event-driven — it subscribes to event
  patterns and decides what to do based on its accumulated state.

  ## How It Works

  At compile time a ProcessManager is lowered into standard Runic primitives:

  - An **Accumulator** that holds the coordination state (typically a map).
    The reducer merges state updates from event handlers into the current state.
  - One **Rule** per `on` event handler. Each rule pattern-matches on incoming
    events and produces both a state update (fed back into the accumulator) and
    an optional command emission. Handlers without `emit` produce no output
    event rules — they only update state.
  - An optional **Rule** for the `complete?` check. This rule observes the
    accumulator's state via `state_of()` and fires when the completion predicate
    returns true.

  Each event handler rule is named `:"<pm_name>_on_<idx>"` based on declaration
  order.

  Timeouts are declared but scheduled externally by the Runner. Timeout blocks
  compile to rules that match `{:timeout, :name}` events with `state_of()` guards.

  ## DSL Syntax

  ProcessManagers are created with the `Runic.process_manager/2` macro using a
  block DSL:

      Runic.process_manager name: :name do
        state %{initial: :state}

        on pattern do
          update %{field: value}
          emit command_value       # optional
        end

        complete? fn state -> boolean end   # optional
      end

  ### Directives

  - `state value` — declares the initial coordination state, typically a map
    (required).
  - `on pattern do ... end` — declares an event handler that pattern-matches
    on incoming events. The body may contain:
    - `update %{key: value}` — a map that is merged into the current state.
    - `emit value` — an optional command to emit as an output fact.
  - `complete? fn state -> bool end` — optional completion predicate. When it
    returns true, the process manager signals that the business process is
    finished.

  ## Examples

      require Runic

      # Order fulfillment process manager
      pm = Runic.process_manager name: :fulfillment do
        state %{order_id: nil, paid: false, shipped: false}

        on {:order_submitted, order_id} do
          update %{order_id: order_id}
          emit {:charge_payment, order_id}
        end

        on {:payment_received, _} do
          update %{paid: true}
          emit {:ship_order, state.order_id}
        end

        on {:shipment_created, _} do
          update %{shipped: true}
        end

        complete? fn state -> state.shipped end
      end

      # Add to workflow and react to events
      alias Runic.Workflow

      wrk = Workflow.new() |> Workflow.add(pm)
      wrk = Workflow.react(wrk, {:order_submitted, "order-123"})
      # State updated, {:charge_payment, "order-123"} command emitted

  ## Sub-Component Access

  After adding a ProcessManager to a workflow, its internal primitives can be
  retrieved via `Workflow.get_component/2` using a `{name, kind}` tuple:

      alias Runic.Workflow

      wrk = Workflow.new() |> Workflow.add(pm)

      # Get the underlying accumulator (holds coordination state)
      [accumulator] = Workflow.get_component(wrk, {:fulfillment, :accumulator})

      # Get all event handler rules
      handlers = Workflow.get_component(wrk, {:fulfillment, :event_handler})

      # Get the completion rule (if declared)
      [completion] = Workflow.get_component(wrk, {:fulfillment, :completion})
  """

  defstruct [
    :name,
    :initial_state,
    :event_handlers,
    :timeout_handlers,
    :completion_check,
    :accumulator,
    :event_rules,
    :completion_rule,
    :workflow,
    :source,
    :hash,
    :bindings,
    :inputs,
    :outputs
  ]
end
