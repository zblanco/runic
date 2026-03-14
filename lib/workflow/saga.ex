defmodule Runic.Workflow.Saga do
  @moduledoc """
  A sequential transaction pipeline with compensating actions for failure recovery.

  A Saga orchestrates a series of steps that must all succeed or be rolled back.
  Each transaction step has a paired compensation that undoes its effect. If any
  step fails, previously completed steps are compensated in reverse order. Think
  of it as a more powerful `with` statement where each clause has a paired undo.

  Unlike the `Aggregate` component (CQRS/ES semantics) or `ProcessManager`
  (event-driven orchestration), a Saga is an explicit forward-then-compensate
  pipeline with sequential execution semantics.

  ## How It Works

  At compile time a Saga is lowered into standard Runic primitives:

  - An **Accumulator** that tracks the saga's execution state as a map with keys:
    - `:status` — one of `:running`, `:completed`, or `:aborted`
    - `:current_step` — the name of the step currently being executed
    - `:results` — map of step name to result for completed steps
    - `:failure_reason` — the error reason if a step failed
    - `:compensated` — map of compensation results
    - `:step_order` — list of step names in declaration order
  - One **Rule** per transaction step (forward execution). Each rule gates on
    the accumulator's state via `state_of()` meta-references and executes when
    it is the current step's turn.
  - **Rules** for compensation triggers and compensation steps that fire when
    a failure is detected, executing compensations in reverse declaration order.
  - Optional rules for `on_complete` and `on_abort` terminal handlers.

  Compile-time validation ensures every `transaction` has a corresponding
  `compensate` with the same name.

  Each transaction rule is named `:"<saga_name>_<step_name>"`.

  ## DSL Syntax

  Sagas are created with the `Runic.saga/2` macro using a block DSL:

      Runic.saga name: :name do
        transaction :step_name do
          fn input -> {:ok, result} | {:error, reason} end
        end
        compensate :step_name do
          fn results_map -> compensation_result end
        end

        on_complete fn results -> value end       # optional
        on_abort fn reason, compensated -> value end  # optional
      end

  ### Directives

  - `transaction :name do fn -> ... end end` — declares a forward step.
    The function receives the accumulated results map and must return
    `{:ok, result}` on success or `{:error, reason}` on failure.
  - `compensate :name do fn -> ... end end` — declares the compensation for
    a transaction. Receives the results map and returns a compensation result.
    Every transaction must have a matching compensate (validated at compile time).
  - `on_complete fn results -> value end` — optional handler called when all
    steps complete successfully. Receives the final results map.
  - `on_abort fn reason, compensated -> value end` — optional handler called
    when the saga is aborted after compensations. Receives the failure reason
    and a map of compensation results.

  Steps execute in declaration order. On failure, compensations run in reverse
  declaration order for all previously completed steps.

  ## Examples

      require Runic

      # Order fulfillment saga
      saga = Runic.saga name: :fulfillment do
        transaction :reserve_inventory do
          fn input -> {:ok, :reserved} end
        end
        compensate :reserve_inventory do
          fn %{reserve_inventory: _reservation} -> :released end
        end

        transaction :charge_payment do
          fn %{reserve_inventory: _} -> {:ok, :charged} end
        end
        compensate :charge_payment do
          fn %{charge_payment: _charge} -> :refunded end
        end

        on_complete fn results -> {:saga_completed, results} end
        on_abort fn reason, compensated -> {:saga_aborted, reason, compensated} end
      end

      # Add to workflow and execute
      alias Runic.Workflow

      wrk = Workflow.new() |> Workflow.add(saga)
      wrk = Workflow.react(wrk, :start)

  ## Sub-Component Access

  After adding a Saga to a workflow, its internal primitives can be retrieved
  via `Workflow.get_component/2` using a `{name, kind}` tuple:

      alias Runic.Workflow

      wrk = Workflow.new() |> Workflow.add(saga)

      # Get the underlying accumulator (tracks saga execution state)
      [accumulator] = Workflow.get_component(wrk, {:fulfillment, :accumulator})

      # Get all transaction (forward) rules
      transactions = Workflow.get_component(wrk, {:fulfillment, :transaction})
  """

  defstruct [
    :name,
    :steps,
    :on_complete,
    :on_abort,
    :accumulator,
    :forward_rules,
    :compensation_rules,
    :workflow,
    :source,
    :hash,
    :bindings,
    :inputs,
    :outputs
  ]
end
