defmodule Runic.Runner.Scheduler do
  @moduledoc """
  Behaviour for controlling what gets dispatched together and when.

  Schedulers sit between the Worker's prepare phase and the actual dispatch,
  deciding how runnables are grouped and ordered for execution. The Worker
  calls `plan_dispatch/3` with the current workflow and prepared runnables,
  and the scheduler returns a list of dispatch units — either individual
  runnables or batched Promises.

  ## Built-in Schedulers

    * `Runic.Runner.Scheduler.Default` — wraps each runnable individually (zero overhead)
    * `Runic.Runner.Scheduler.ChainBatching` — detects linear chains and batches them into Promises

  ## Dispatch Units

  A dispatch unit is one of:

    * `{:runnable, %Runnable{}}` — dispatch as an individual task
    * `{:promise, %Promise{}}` — dispatch as a batched chain

  ## Contract

  Scheduler implementations must satisfy:

    * Every input runnable appears in exactly one dispatch unit
    * No runnable appears in more than one dispatch unit
    * Promise `node_hashes` do not overlap between dispatch units
    * `plan_dispatch/3` handles empty runnable lists gracefully

  Use `Runic.Runner.Scheduler.ContractTest` to verify implementations.
  """

  alias Runic.Workflow.Runnable
  alias Runic.Runner.Promise

  @type dispatch_unit :: {:runnable, Runnable.t()} | {:promise, Promise.t()}
  @type scheduler_state :: term()

  @doc """
  Initialize the scheduler with configuration.

  Called once when the Worker starts. Returns opaque state passed
  to subsequent `plan_dispatch/3` and `on_complete/3` calls.
  """
  @callback init(opts :: keyword()) :: {:ok, scheduler_state()} | {:error, term()}

  @doc """
  Plan how to dispatch a set of prepared runnables.

  Receives the current workflow and a list of runnables ready for dispatch
  (filtered for active work, but not truncated to the concurrency limit). Returns a
  list of dispatch units and updated scheduler state.

  The Worker iterates over the returned units, routing `{:runnable, r}`
  to individual dispatch and `{:promise, p}` to batched dispatch.

  This is a proposal, not an admission notification. The Worker may dispatch
  only a prefix due to concurrency limits or manual stepping and replan the
  remaining candidates later. Planning state must not assume proposed units
  started. Use optional `on_dispatch/2` to track admitted units.
  """
  @callback plan_dispatch(
              workflow :: Runic.Workflow.t(),
              runnables :: [Runnable.t()],
              scheduler_state()
            ) :: {[dispatch_unit()], scheduler_state()}

  @doc """
  Called for each selected unit immediately before its dispatch is attempted.

  Runs after manual/concurrency filtering and before any inline completion.
  Optional. This is local admission bookkeeping, not backend acceptance or a
  durable acknowledgement. A dispatch failure may terminate the Worker before
  `on_complete/3`; this callback must not be an external ownership authority.
  """
  @callback on_dispatch(dispatch_unit(), scheduler_state()) :: scheduler_state()

  @doc """
  Called when a dispatch unit returns a result or its outer executor ends.

  Receives the completed dispatch unit, execution duration in milliseconds,
  and the current scheduler state. Returns updated scheduler state.

  On outer executor loss, receives the original unit with `status: :pending`.
  This closes local admission bookkeeping; it does not assert node execution or
  success. Profiling code must not treat an unresolved unit as a successful sample.
  A returned Promise has `status: :resolved` or `:failed` for a partial result.

  Optional — used by adaptive schedulers for profiling.
  """
  @callback on_complete(dispatch_unit(), duration_ms :: non_neg_integer(), scheduler_state()) ::
              scheduler_state()

  @optional_callbacks [on_dispatch: 2, on_complete: 3]
end
