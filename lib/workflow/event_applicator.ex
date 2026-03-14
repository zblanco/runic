defprotocol Runic.Workflow.EventApplicator do
  @moduledoc """
  Protocol for applying custom events to a workflow.

  Built-in events (e.g. `FactProduced`, `ActivationConsumed`, `JoinCompleted`) are
  handled by pattern-matched clauses in `Workflow.apply_event/2` and do **not** need
  to implement this protocol — they are dispatched before the protocol fallback.

  External libraries that define custom `Invokable` node types can introduce their
  own event structs and implement `EventApplicator` so that `apply_event/2` knows
  how to fold them into the workflow.

  ## Example

      defmodule MyApp.Events.CustomStepCompleted do
        defstruct [:node_hash, :result_value]
      end

      defimpl Runic.Workflow.EventApplicator, for: MyApp.Events.CustomStepCompleted do
        def apply(event, workflow) do
          # Use Workflow public API to fold the event into the workflow
          fact = Runic.Workflow.Fact.new(value: event.result_value, ancestry: {event.node_hash, nil})
          Runic.Workflow.log_fact(workflow, fact)
        end
      end

  ## Serialization

  Custom events serialize naturally via ETF (`:erlang.term_to_binary/1`). For
  cross-language interop, implement serialization at the Store adapter level
  using the event struct fields directly.
  """

  @doc """
  Applies this event to the workflow, returning the updated workflow.
  """
  @spec apply(event :: struct(), workflow :: Runic.Workflow.t()) :: Runic.Workflow.t()
  def apply(event, workflow)
end
