defmodule Runic.Workflow.ExecutionUncertain do
  @moduledoc """
  Records an admitted executor unit that ended without an accepted result.

  This is an execution observation, not a failed node attempt. Its prepared
  activations remain unresolved and may repeat work on explicit recovery.
  `reason` is the observed executor exit, outer timeout, or invalid reply.
  For a Promise, `runnable_ids` identifies its prepared frontier; it does not
  claim which members started or completed. No input or output is included.
  `members` retains stable activation, prepared-attempt, node, and input
  occurrence identities without retaining input values. It does not claim
  which internal retry attempt was running when the executor ended.
  `order_key` is the earliest prepared member's stable causal admission key.

  Recording and replay do not consume activations or acknowledge persistence.
  """

  alias Runic.Runner.Promise
  alias Runic.Workflow.Runnable

  @type t :: %__MODULE__{
          unit_kind: :runnable | :promise,
          runnable_ids: [term()],
          members: [map()],
          order_key: term(),
          reason: term(),
          observed_at: integer()
        }
  @enforce_keys [:unit_kind, :runnable_ids, :reason, :observed_at]
  defstruct [:unit_kind, :runnable_ids, :members, :order_key, :reason, :observed_at]

  @doc false
  def new({:runnable, %Runnable{} = runnable}, reason), do: build(:runnable, [runnable], reason)

  def new({:promise, %Promise{runnables: runnables}}, reason),
    do: build(:promise, runnables, reason)

  defp build(kind, runnables, reason) do
    %__MODULE__{
      unit_kind: kind,
      runnable_ids: Enum.map(runnables, & &1.id),
      members: Enum.map(runnables, &member/1),
      order_key: runnables |> Enum.map(&Runnable.order_key/1) |> Enum.min(fn -> {0, nil} end),
      reason: reason,
      observed_at: System.monotonic_time(:millisecond)
    }
  end

  defp member(runnable) do
    %{
      runnable_id: runnable.id,
      activation_id: runnable.activation_id,
      prepared_attempt_id: runnable.attempt_id,
      node_hash: runnable.node.hash,
      node_name: Map.get(runnable.node, :name, runnable.node.hash),
      input_fact_id: runnable.input_fact.hash,
      order_key: Runnable.order_key(runnable)
    }
  end
end
