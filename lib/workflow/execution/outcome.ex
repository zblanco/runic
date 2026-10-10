defmodule Runic.Workflow.Execution.Outcome do
  @moduledoc """
  One accepted computation result or uncertain executor observation.

  `sequence` preserves the order in which the execution scope accepted or
  observed outcomes. `order_key` is independent of completion timing and can be
  used for stable consumer selection. `id` is stable for the execution,
  activation, attempt, and outcome kind.

  Custom runnable IDs remain available in `runnable_ids` as metadata. Outcome
  identity and stable order use activation coordinates. When a custom runnable
  has no activation identity, it is derived from the node and input Fact. A
  missing terminal attempt identity is derived from that activation and the
  runnable's attempt number.

  `observed_at` is the acceptance time in the caller or Worker. For failed or
  skipped outcomes, `failure_action` records terminal handling (`:halt` or
  `:skip`). A skipped outcome can have no error when a custom node skips work.

  An `:uncertain` outcome means that an admitted outer executor unit ended
  without a result. It does not assert that the work failed or that external
  effects did not occur.
  """

  alias Runic.Identity
  alias Runic.Runner.Promise

  alias Runic.Workflow.Runnable

  @type kind :: :completed | :failed | :skipped | :uncertain

  @type t :: %__MODULE__{
          id: Identity.t(),
          execution_id: Identity.t(),
          kind: kind(),
          sequence: pos_integer(),
          activation_id: Identity.t() | nil,
          attempt_id: Identity.t() | nil,
          runnable_ids: [term()],
          node_hash: term() | nil,
          node_name: term() | nil,
          result: term() | nil,
          error: term() | nil,
          failure_action: :halt | :skip | nil,
          order_key: term(),
          observed_at: integer()
        }

  @enforce_keys [:id, :execution_id, :kind, :sequence, :runnable_ids, :order_key, :observed_at]
  defstruct [
    :id,
    :execution_id,
    :kind,
    :sequence,
    :activation_id,
    :attempt_id,
    :node_hash,
    :node_name,
    :result,
    :error,
    :failure_action,
    :order_key,
    :observed_at,
    runnable_ids: []
  ]

  @doc false
  @spec from_runnable(Identity.t(), Runnable.t(), pos_integer()) :: t()
  def from_runnable(execution_id, %Runnable{} = runnable, sequence) do
    kind = runnable_kind(runnable.status)
    activation_id = activation_id(runnable)

    attempt_id =
      runnable.attempt_id ||
        Identity.derive(:attempt, [activation_id, runnable.attempt_number || 0])

    build(execution_id, kind, sequence, [activation_id],
      activation_id: activation_id,
      attempt_id: attempt_id,
      runnable_ids: [runnable.id],
      node_hash: runnable.node.hash,
      node_name: Map.get(runnable.node, :name, runnable.node.hash),
      result: runnable.result,
      error: runnable.error,
      failure_action: failure_action(runnable.status),
      order_key: order_key(runnable)
    )
  end

  @doc false
  @spec uncertain(
          Identity.t(),
          {:runnable, Runnable.t()} | {:promise, Promise.t()},
          term(),
          pos_integer()
        ) ::
          t()
  def uncertain(execution_id, unit, reason, sequence) do
    runnables = unit_runnables(unit)
    first = Enum.min_by(runnables, &order_key/1)

    build(execution_id, :uncertain, sequence, Enum.map(runnables, &activation_id/1),
      activation_id: activation_id(first),
      attempt_id: nil,
      runnable_ids: Enum.map(runnables, & &1.id),
      node_hash: first.node.hash,
      node_name: Map.get(first.node, :name, first.node.hash),
      error: reason,
      order_key: order_key(first)
    )
  end

  defp build(execution_id, kind, sequence, activation_ids, attrs) do
    activation_id = Keyword.get(attrs, :activation_id)
    attempt_id = Keyword.get(attrs, :attempt_id)

    id =
      Identity.derive(:event, [
        execution_id,
        kind,
        activation_id,
        attempt_id,
        activation_ids
      ])

    struct!(
      __MODULE__,
      [
        id: id,
        execution_id: execution_id,
        kind: kind,
        sequence: sequence,
        observed_at: System.monotonic_time(:millisecond)
      ] ++ attrs
    )
  end

  defp activation_id(%Runnable{activation_id: %Identity{} = id}), do: id

  defp activation_id(%Runnable{node: node, input_fact: fact}),
    do: Runnable.runnable_id(node, fact)

  defp order_key(%Runnable{} = runnable) do
    {depth, _id} = Runnable.order_key(runnable)
    {depth, activation_id(runnable)}
  end

  defp failure_action(:failed), do: :halt
  defp failure_action(:skipped), do: :skip
  defp failure_action(_status), do: nil

  defp runnable_kind(:completed), do: :completed
  defp runnable_kind(:failed), do: :failed
  defp runnable_kind(:skipped), do: :skipped

  defp unit_runnables({:runnable, %Runnable{} = runnable}), do: [runnable]
  defp unit_runnables({:promise, %Promise{runnables: runnables}}), do: runnables
end
