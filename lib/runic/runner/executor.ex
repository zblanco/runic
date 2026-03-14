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

  This contract matches `Task.Supervisor.async_nolink` semantics,
  making the default `Runic.Runner.Executor.Task` a zero-cost abstraction.

  ## Built-in Executors

    - `Runic.Runner.Executor.Task` — default, uses `Task.Supervisor.async_nolink`
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
  Clean up executor resources.

  Called when the Worker is stopping. Optional.
  """
  @callback cleanup(executor_state()) :: :ok

  @optional_callbacks [cleanup: 1]
end
