defmodule Runic.Workflow.ExecutionUncertain do
  @moduledoc """
  Records an admitted executor unit that ended without an accepted result.

  This is an execution observation, not a failed node attempt. Its prepared
  activations remain unresolved and may repeat work on explicit recovery.
  `reason` is the observed executor exit, outer timeout, or invalid reply.
  For a Promise, `runnable_ids` identifies its prepared frontier; it does not
  claim which members started or completed. No input or output is included.

  Recording and replay do not consume activations or acknowledge persistence.
  """

  alias Runic.Runner.Promise
  alias Runic.Workflow.Runnable

  @type t :: %__MODULE__{
          unit_kind: :runnable | :promise,
          runnable_ids: [term()],
          reason: term(),
          observed_at: integer()
        }
  @enforce_keys [:unit_kind, :runnable_ids, :reason, :observed_at]
  defstruct [:unit_kind, :runnable_ids, :reason, :observed_at]

  @doc false
  def new({:runnable, %Runnable{id: id}}, reason), do: build(:runnable, [id], reason)

  def new({:promise, %Promise{runnables: runnables}}, reason),
    do: build(:promise, Enum.map(runnables, & &1.id), reason)

  defp build(kind, ids, reason) do
    %__MODULE__{
      unit_kind: kind,
      runnable_ids: ids,
      reason: reason,
      observed_at: System.monotonic_time(:millisecond)
    }
  end
end
