# State-Based Components

Runic provides five state-based components that compile down to existing primitives. They are compositional sugar — not new runtime concepts. Every state-based component produces a combination of Accumulators, Rules, Conditions, and Steps that execute through the same `Invokable` protocol as any other workflow node.

---

## Architecture

All state-based components follow the same structural pattern:

1. **A struct** in `lib/workflow/<component>.ex` — data only, no behavior
2. **A macro** in the `Runic` module — construction and compile-time validation
3. **`Runic.Component` protocol** — `connect/3` and `hash/1` for workflow integration
4. **`Runic.Transmutable` protocol** — `to_workflow/1` to expand into a workflow of primitives
5. **No `Invokable` implementation** — they compile to existing `Invokable` nodes

The building blocks are:

- **Accumulator**: holds state, folds incoming values via a reducer function
- **Rule** (Condition + Step): guards that gate reactions, using `state_of()` meta_refs to observe accumulator state
- **`:component_of` edges**: track sub-component ownership in the workflow graph
- **`:meta_ref` edges**: resolve `state_of()` and `context()` references during the prepare phase

---

## When to Use Each Component

| Component | Use When | Key Pattern |
|---|---|---|
| **StateMachine** | Unbounded state with a reducer + reactive conditions | Event sourcing-lite, counters, accumulators with reactions |
| **FSM** | Discrete, enumerable states with named transitions | Protocol states, UI wizards, traffic lights |
| **Aggregate** | CQRS/ES: commands → events → state | Domain aggregates, order lifecycle |
| **Saga** | Sequential steps with compensating rollbacks | Multi-service transactions, booking flows |
| **ProcessManager** | Event-driven coordination across aggregates | Order fulfillment, multi-step business processes |

---

## StateMachine

The `StateMachine` is the most general state-based component. It wraps an Accumulator with optional reactor Rules that fire when the accumulated state matches their guard conditions.

### Construction

`Runic.state_machine/1` takes a keyword list:

```elixir
require Runic
alias Runic.Workflow

counter = Runic.state_machine(
  name: :counter,
  init: 0,
  reducer: fn x, acc -> acc + x end,
  reactors: [
    over_limit: fn state when state > 100 -> :over_limit end
  ]
)

workflow = Workflow.new() |> Workflow.add(counter)
result = workflow |> Workflow.react_until_satisfied(50) |> Workflow.raw_productions()
```

### Key Details

- **`init`** accepts literal values or 0-arity functions. Literals are automatically wrapped in a thunk.
- **`reducer`** is a 2-arity function `(input, state) -> new_state`. Multi-clause pattern matching is supported.
- **Reactors** can be **named** (keyword list) or **unnamed** (plain list, auto-named as `:<name>_reactor_0`, `:<name>_reactor_1`, etc.).
- Compiles to an Accumulator plus reactor Rules with `state_of()` meta_refs that observe the accumulator's current value.

### Multi-Clause Reducer Example

```elixir
lock = Runic.state_machine(
  name: :lock,
  init: %{code: "secret", state: :locked},
  reducer: fn
    :lock, state -> %{state | state: :locked}
    {:unlock, code}, %{code: code, state: :locked} = state -> %{state | state: :unlocked}
    _, state -> state
  end,
  reactors: [
    fn %{state: :unlocked} -> :access_granted end,
    fn %{state: :locked} -> :access_denied end
  ]
)
```

---

## FSM (Finite State Machine)

The `FSM` models discrete, enumerable states with named transitions. It uses a block DSL with compile-time validation.

### Construction

```elixir
require Runic

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
```

### Key Details

- **Compile-time validation**: `initial_state` must exist in declared states, all transition targets must reference declared states, and duplicate `{state, event}` pairs raise an `ArgumentError`.
- Each transition compiles to a named Rule: `:"#{fsm_name}_#{from}_on_#{event}"`. These are individually addressable via `Workflow.get_component/2`.
- **Entry actions** (`on_entry`) fire when the FSM transitions *into* that state. They compile to additional Rules that detect state changes.
- The underlying Accumulator holds the current state as an atom.

### Execution

```elixir
alias Runic.Workflow

wrk =
  Workflow.new()
  |> Workflow.add(fsm)
  |> Workflow.react_until_satisfied(:timer)

prods = Workflow.raw_productions(wrk)
# => [:green, ...] — transitioned from :red to :green
```

Events that don't match any transition for the current state are silently ignored — the FSM stays in its current state.

---

## Aggregate

The `Aggregate` implements a CQRS/Event Sourcing pattern: commands validate against current state, produce domain events, and events fold into state via the accumulator.

> **Note**: This is a *domain-level* abstraction. Runic's internal event sourcing (workflow events, replay) operates at a different layer — the aggregate's "events" are domain facts flowing through the workflow graph.

### Construction

```elixir
require Runic

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
```

### Key Details

- **Commands** validate against current state via `where` guards. If the guard returns falsy, the command is rejected (no event produced).
- **`emit`** produces domain events — the output of a command handler.
- **`event` handlers** fold events into state via the accumulator. Command handler output feeds back to the accumulator.
- Each command handler compiles to a named Rule: `:"<agg_name>_<command_name>"`.

### Execution

```elixir
wrk =
  Workflow.new()
  |> Workflow.add(agg)
  |> Workflow.react_until_satisfied(:increment)

prods = Workflow.raw_productions(wrk)
# => [{:incremented, 1}, 1, ...] — event produced, state folded to 1
```

When a command's `where` guard fails, no event is emitted and the state remains unchanged:

```elixir
# With state 0, :decrement's guard `state > 0` fails
wrk = Workflow.new() |> Workflow.add(agg) |> Workflow.react_until_satisfied(:decrement)
prods = Workflow.raw_productions(wrk)
# No {:decremented, _} in productions
```

---

## Saga

The `Saga` models a sequence of transaction steps with compensating rollback actions. Think of it as a more powerful `with` statement where each step has a paired undo.

### Construction

```elixir
require Runic

saga = Runic.saga name: :fulfillment do
  transaction :reserve_inventory do
    fn input -> {:ok, :reserved} end
  end
  compensate :reserve_inventory do
    fn %{reserve_inventory: reservation} -> :released end
  end

  transaction :charge_payment do
    fn %{reserve_inventory: _} -> {:ok, :charged} end
  end
  compensate :charge_payment do
    fn %{charge_payment: charge} -> :refunded end
  end

  on_complete fn results -> {:saga_completed, results} end
  on_abort fn reason, compensated -> {:saga_aborted, reason, compensated} end
end
```

### Key Details

- **Transactions** execute in declaration order. Each returns `{:ok, result}` for success or `{:error, reason}` for failure.
- **On failure**, all previously completed steps are compensated in reverse order.
- **Every transaction must have a corresponding `compensate` block** — this is validated at compile time.
- **`on_complete`** and **`on_abort`** are optional terminal handlers that fire when the saga finishes.
- Each transaction compiles to a named Rule: `:"<saga_name>_<step_name>"`.

### Saga State

The accumulator tracks a structured state map:

```elixir
%{
  status: :pending | :running | :completed | :compensating | :aborted,
  current_step: atom() | nil,
  results: %{step_name => result},
  failure_reason: nil | {step_name, reason},
  compensated: [step_name],
  step_order: [step_name]
}
```

### Execution

```elixir
# Happy path
wrk =
  Workflow.new()
  |> Workflow.add(saga)
  |> Workflow.react_until_satisfied(:start)

prods = Workflow.raw_productions(wrk)
# => [%{status: :completed, results: %{reserve_inventory: :reserved, charge_payment: :charged}, ...}, ...]

# Failure path — second step fails, first step compensated
saga = Runic.saga name: :failing do
  transaction :first do
    fn _input -> {:ok, :first_done} end
  end
  compensate :first do
    fn _ -> :first_compensated end
  end

  transaction :second do
    fn _results -> {:error, :boom} end
  end
  compensate :second do
    fn _ -> :second_compensated end
  end
end

wrk = Workflow.new() |> Workflow.add(saga) |> Workflow.react_until_satisfied(:start)
# => status: :aborted, failure_reason: {:second, :boom}, compensated: [:first]
```

---

## ProcessManager

The `ProcessManager` is an event-driven coordination component. Unlike Sagas (which are sequential), ProcessManagers react to events from multiple sources and decide what commands to issue based on accumulated state.

### Construction

```elixir
require Runic

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
```

### Key Details

- **Event-driven and reactive**: each `on` block matches an event pattern, applies a state update (merge), and optionally emits commands.
- **`update`** merges the given map into the current state.
- **`emit`** produces a command fact that flows downstream. Handlers without `emit` produce no event rules.
- **`complete?`** fires a `{:process_completed, name}` fact when the predicate is satisfied. It compiles to a Rule that checks state via `state_of()`.
- Each event handler compiles to a named Rule: `:"<pm_name>_on_<idx>"`.
- Timeouts are declared but scheduled externally by the Runner. Timeout blocks compile to rules that match `{:timeout, :name}` events with `state_of()` guards.

### Execution

```elixir
alias Runic.Workflow

pm = Runic.process_manager name: :simple do
  state %{done: false}

  on :finish do
    update %{done: true}
  end

  complete? fn state -> state.done end
end

wrk =
  Workflow.new()
  |> Workflow.add(pm)
  |> Workflow.react_until_satisfied(:finish)

prods = Workflow.raw_productions(wrk)
# => [%{done: true}, {:process_completed, :simple}, ...]
```

Unmatched events leave the state unchanged — only handlers whose event pattern matches will fire.

---

## Composition Patterns

All state-based components are first-class workflow citizens. They compose with each other and with plain Steps, Rules, and other components.

### Adding to a Workflow

```elixir
alias Runic.Workflow

wrk = Workflow.new() |> Workflow.add(fsm)
```

### Connecting Downstream Steps

```elixir
logger_step = Runic.step(fn x -> {:logged, x} end, name: :logger)

wrk =
  Workflow.new()
  |> Workflow.add(fsm)
  |> Workflow.add(logger_step, to: :traffic_light)
```

### Connecting a Component After a Step

```elixir
step = Runic.step(fn x -> {:processed, x} end, name: :processor)

wrk =
  Workflow.new()
  |> Workflow.add(step)
  |> Workflow.add(fsm, to: :processor)
```

### Sub-Component Access

Each component registers its sub-components with `:component_of` edges. Access them via `Workflow.get_component/2` with a `{component_name, kind}` tuple:

```elixir
# Accumulator (available on all state-based components)
Workflow.get_component(wrk, {:traffic_light, :accumulator})

# FSM transition rules
Workflow.get_component(wrk, {:traffic_light, :transition})

# Aggregate command handler rules
Workflow.get_component(wrk, {:counter, :command_handler})

# Saga transaction rules
Workflow.get_component(wrk, {:fulfillment, :transaction})

# ProcessManager event handler rules
Workflow.get_component(wrk, {:fulfillment, :event_handler})

# ProcessManager completion rule
Workflow.get_component(wrk, {:fulfillment, :completion})

# StateMachine reactor rules
Workflow.get_component(wrk, {:counter, :reactor})
```

### Transmutable: Standalone Workflow Conversion

Any component can be converted to a standalone workflow via `Runic.Transmutable.to_workflow/1`:

```elixir
wrk = Runic.Transmutable.to_workflow(fsm)
# => %Workflow{} with the FSM's sub-components wired up
```

---

## Interaction with Runner

All state-based components work with the Runner for durable execution, checkpointing, and crash recovery. Because they compile to standard Accumulator + Rule primitives, the Runner treats them identically to any other workflow node — no special-casing required.

For details on durable execution patterns, see [Durable Execution](durable-execution.md).
