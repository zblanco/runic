defmodule Runic.Runner.Executor do
  @moduledoc """
  Behaviour for controlling how runnables are dispatched to compute.

  Executors abstract the process/task/worker mechanism used to execute
  runnables. The Runner's Worker calls `dispatch/3` for each runnable
  (or Promise) and receives a handle for tracking completion.

  Completion is signaled asynchronously to the calling process via
  standard Erlang messages: `{ref, result}` and `{:DOWN, ref, ...}`.

  ## Message Contract

  The executor MUST arrange for the calling process to receive:

    - `{handle, result}` on successful completion
    - `{:DOWN, handle, :process, pid, reason}` on crash

  This message contract also supports scoped supervised tasks. Handles are
  completion identifiers; an executor may forward notifications from its own
  monitors rather than creating a monitor in the Worker.

  ## Built-in Executors

    - `Runic.Runner.Executor.Task` — default, owns supervised native tasks
    - `:inline` — special value indicating synchronous execution in the Worker process
  """

  @type handle :: reference()
  @type dispatch_opts :: keyword()
  @type executor_state :: term()

  @doc """
  Initialize the executor with configuration.

  Called once when the Worker starts. Returns opaque state passed
  to subsequent `dispatch/3` and `cleanup/1` calls.
  """
  @callback init(opts :: keyword()) :: {:ok, executor_state()} | {:error, term()}

  @doc """
  Dispatch a unit of work for execution.

  The `work_fn` is a zero-arity function that, when called, executes
  the runnable through the PolicyDriver and returns the result.

  Returns `{handle, new_state}` where `handle` is a reference the
  Worker uses to correlate completion messages.

  The executor MUST arrange for the calling process to receive:

    - `{handle, result}` on successful completion
    - `{:DOWN, handle, :process, pid, reason}` on crash
  """
  @callback dispatch(work_fn :: (-> term()), dispatch_opts(), executor_state()) ::
              {handle(), executor_state()}

  @doc """
  Releases a completed dispatch handle from executor state.

  The Worker calls this once after it receives either a result or a failure for
  the handle. Executors that track active work can use it to remove completed
  entries. Optional.

  This is local resource bookkeeping, not durable result acceptance, a broker
  acknowledgement, or cancellation confirmation. Persistence may subsequently
  fail. Raised/thrown callback failures are logged; the Worker retains the last
  executor state for cleanup and still processes the result. A handle is not
  released again after a duplicate notification.
  """
  @callback release(handle(), executor_state()) :: executor_state()

  @doc """
  Clean up executor resources.

  Called when the Worker is stopping. Optional. The default Task executor
  waits for its native work to stop. Custom executors must define their own
  cleanup and owner-death guarantees; callback failure containment does not
  provide cancellation confirmation for external work.
  """
  @callback cleanup(executor_state()) :: :ok

  @optional_callbacks [release: 2, cleanup: 1]
end
