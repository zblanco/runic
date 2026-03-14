defmodule Runic.Workflow.StateMachine do
  @moduledoc """
  A stateful workflow component that combines an accumulator with reactive rules.

  A StateMachine maintains a piece of state via a reducer function and triggers
  side-effects (reactors) whenever that state changes. Unlike the `FSM` component
  which models discrete named states and transitions, StateMachine manages
  arbitrary state values (counters, maps, lists, etc.) and reacts to them with
  user-defined logic.

  ## How It Works

  At compile time a StateMachine is lowered into standard Runic primitives:

  - An **Accumulator** that holds the current state value and applies the
    `:reducer` function to each incoming fact to produce a new state.
  - One **Rule** per reactor. Each reactor observes the accumulator's current
    value via `state_of()` meta-references and fires whenever new state is
    produced.

  This means a StateMachine participates in the workflow graph like any other
  set of Runic nodes — it is not a special runtime concept.

  ## DSL Syntax

  StateMachines are created with the `Runic.state_machine/1` macro, passing a
  keyword list of options:

      Runic.state_machine(
        name: :my_machine,
        init: initial_value,
        reducer: fn input, acc -> new_acc end,
        reactors: [...]
      )

  ### Options

  - `:name` — atom name for the state machine (required).
  - `:init` — initial state value. Accepts a literal (auto-wrapped into a
    zero-arity function) or an explicit `fn -> value end` thunk.
  - `:reducer` — a 2-arity function `fn input, accumulator -> new_accumulator end`.
    Supports `context/1` expressions for accessing runtime context values.
  - `:reactors` — a list of reactor functions or a keyword list of named
    reactors. Unnamed reactors are auto-named `:"<sm_name>_reactor_<idx>"`.
    Each reactor receives the current state and may return a derived fact.
    Reactors also support `context/1` expressions.

  ## Examples

      require Runic

      # Basic counter with a named reactor
      sm = Runic.state_machine(
        name: :counter,
        init: 0,
        reducer: fn x, acc -> acc + x end,
        reactors: [
          alert: fn count -> if count > 10, do: {:alert, count} end
        ]
      )

      # Literal init value (auto-wrapped to thunk)
      sm = Runic.state_machine(
        name: :collector,
        init: [],
        reducer: fn item, items -> [item | items] end,
        reactors: [fn items -> length(items) end]
      )

      # Using runtime context in reducer and reactors
      sm = Runic.state_machine(
        name: :scaled,
        init: 0,
        reducer: fn x, acc -> acc + x * context(:multiplier) end,
        reactors: [
          log: fn state -> {context(:logger), state} end
        ]
      )

  ## Block DSL with `handle`/`react` (Form 2)

  For state machines with complex state and event-driven transitions, the
  block DSL provides a more expressive form. Each `handle` clause bundles
  an event match, input pattern, state binding, and state transformation
  into a named, addressable sub-component. `react` clauses observe state
  without modifying it.

      Runic.state_machine name: :cart, init: %{items: [], total: 0} do
        handle :add_item, %{item: item}, state do
          %{state | items: [item | state.items], total: state.total + item.price}
        end

        handle :checkout, _, state when state.items != [] do
          %{state | status: :checked_out}
        end

        react :high_value do
          fn %{total: t} when t > 1000 -> {:vip_alert, t} end
        end
      end

  ### `handle` clause semantics

      handle event_pattern, input_match, state_var [when state_guard] do
        body  # must return next state
      end

  - `event_pattern` — atom or pattern matched against the incoming fact's
    event type discriminator.
  - `input_match` — pattern match on the event payload / fact value.
  - `state_var` — binds the current state via `state_of(:sm_name)` meta_ref.
  - `when state_guard` — optional guard on current state.
  - `body` — returns the next state value, fed to the accumulator.

  Each `handle` compiles to a named Rule:
  `:"<sm_name>_<event_pattern>"` (e.g., `:cart_add_item`).

  ### `react` clause semantics

      react name do
        fn state_pattern -> output end
      end

  - Name is explicitly required (the atom after `react`).
  - Compiles to a Rule with a `state_of()` condition and a step that
    produces an output fact.
  - Does **not** modify state — observation only.

  ### Compilation equivalence

  Both the keyword form (Form 1) and the block DSL (Form 2) produce
  identical `%StateMachine{}` structs. The `handle` block is sugar for
  splitting a multi-clause reducer into individually named rules.

  ## Sub-Component Access

  After adding a StateMachine to a workflow, its internal primitives can be
  retrieved via `Workflow.get_component/2` using a `{name, kind}` tuple:

      alias Runic.Workflow

      wrk = Workflow.new() |> Workflow.add(sm)

      # Get the underlying accumulator
      [accumulator] = Workflow.get_component(wrk, {:counter, :accumulator})

      # Get all reactor rules
      reactor_rules = Workflow.get_component(wrk, {:counter, :reactor})
  """

  defstruct [
    :name,
    :init,
    :reducer,
    :reactors,
    :accumulator,
    :reactor_rules,
    :workflow,
    :source,
    :hash,
    :bindings,
    :inputs,
    :outputs
  ]
end
