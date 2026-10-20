defmodule Runic.Workflow.RetryScheduled do
  @moduledoc """
  Durable record of a retry that can start after an absolute deadline.

  `due_at` is Unix time in milliseconds. It can be compared after an Erlang VM
  restart. The event identity is stable for one activation and next attempt, so
  replay and an append retry after a lost acknowledgement do not add budget.
  """

  alias Runic.Identity
  alias Runic.Workflow.Runnable

  @type t :: %__MODULE__{
          version: pos_integer(),
          event_id: Identity.t(),
          runnable_id: term(),
          activation_id: Identity.t() | nil,
          attempt_id: Identity.t() | nil,
          attempt: non_neg_integer(),
          next_attempt: pos_integer(),
          delay_ms: non_neg_integer(),
          due_at: integer(),
          error: term()
        }

  @enforce_keys [
    :event_id,
    :runnable_id,
    :activation_id,
    :attempt_id,
    :attempt,
    :next_attempt,
    :delay_ms,
    :due_at,
    :error
  ]
  defstruct version: 1,
            event_id: nil,
            runnable_id: nil,
            activation_id: nil,
            attempt_id: nil,
            attempt: nil,
            next_attempt: nil,
            delay_ms: nil,
            due_at: nil,
            error: nil

  @doc false
  @spec new(Runnable.t(), non_neg_integer(), non_neg_integer(), integer(), term()) :: t()
  def new(%Runnable{} = runnable, attempt, delay_ms, due_at, error) do
    activation_id = Runnable.activation_id(runnable)
    next_attempt = attempt + 1

    %__MODULE__{
      event_id: Identity.derive(:event, [activation_id, __MODULE__, 1, next_attempt]),
      runnable_id: runnable.id,
      activation_id: activation_id,
      attempt_id: runnable.attempt_id,
      attempt: attempt,
      next_attempt: next_attempt,
      delay_ms: delay_ms,
      due_at: due_at,
      error: error
    }
  end
end
