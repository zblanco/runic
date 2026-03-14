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
  (already filtered for active tasks and concurrency limits). Returns a
  list of dispatch units and updated scheduler state.

  The Worker iterates over the returned units, routing `{:runnable, r}`
  to individual dispatch and `{:promise, p}` to batched dispatch.
  """
  @callback plan_dispatch(
              workflow :: Runic.Workflow.t(),
              runnables :: [Runnable.t()],
              scheduler_state()
            ) :: {[dispatch_unit()], scheduler_state()}

  @doc """
  Called when a dispatch unit completes.

  Receives the completed dispatch unit, execution duration in milliseconds,
  and the current scheduler state. Returns updated scheduler state.

  Optional — used by adaptive schedulers for profiling.
  """
  @callback on_complete(dispatch_unit(), duration_ms :: non_neg_integer(), scheduler_state()) ::
              scheduler_state()

  @optional_callbacks [on_complete: 3]
end
