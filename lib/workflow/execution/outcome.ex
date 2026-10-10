defmodule Runic.Workflow.Execution.Outcome do
  @moduledoc """
  One accepted computation result or uncertain executor observation.

  `sequence` preserves the order in which the execution scope accepted or
  observed outcomes. `order_key` is independent of completion timing and can be
  used for stable consumer selection. `id` is stable for the execution,
  activation, attempt, and outcome kind.

  An `:uncertain` outcome means that an admitted outer executor unit ended
  without a result. It does not assert that the work failed or that external
  effects did not occur.
  """

  alias Runic.Identity
  alias Runic.Runner.Promise

  alias Runic.Workflow.{ExecutionUncertain, Runnable, RunnableCompleted, RunnableFailed}

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

    build(execution_id, kind, sequence,
      activation_id: runnable.activation_id,
      attempt_id: runnable.attempt_id,
      runnable_ids: [runnable.id],
      node_hash: runnable.node.hash,
      node_name: Map.get(runnable.node, :name, runnable.node.hash),
      result: runnable.result,
      error: runnable.error,
      order_key: Runnable.order_key(runnable)
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
    first = Enum.min_by(runnables, &Runnable.order_key/1)

    build(execution_id, :uncertain, sequence,
      activation_id: first.activation_id,
      attempt_id: nil,
      runnable_ids: Enum.map(runnables, & &1.id),
      node_hash: first.node.hash,
      node_name: Map.get(first.node, :name, first.node.hash),
      error: reason,
      order_key: Runnable.order_key(first)
    )
  end

  @doc false
  def from_event(execution_id, %RunnableCompleted{} = event, dispatched, sequence) do
    build(execution_id, :completed, sequence,
      activation_id: event.activation_id,
      attempt_id: event.attempt_id,
      runnable_ids: [event.runnable_id],
      node_hash: event.node_hash,
      node_name: dispatched && dispatched.node_name,
      result: event.result_fact,
      order_key:
        Map.get(event, :order_key) || (dispatched && Map.get(dispatched, :order_key)) ||
          {0, event.activation_id},
      observed_at: event.completed_at
    )
  end

  def from_event(execution_id, %RunnableFailed{} = event, dispatched, sequence) do
    kind = if event.failure_action == :skip, do: :skipped, else: :failed

    build(execution_id, kind, sequence,
      activation_id: event.activation_id,
      attempt_id: event.attempt_id,
      runnable_ids: [event.runnable_id],
      node_hash: event.node_hash,
      node_name: dispatched && dispatched.node_name,
      error: event.error,
      failure_action: event.failure_action,
      order_key:
        Map.get(event, :order_key) || (dispatched && Map.get(dispatched, :order_key)) ||
          {0, event.activation_id},
      observed_at: event.failed_at
    )
  end

  def from_event(execution_id, %ExecutionUncertain{} = event, sequence) do
    first =
      event
      |> Map.get(:members)
      |> List.wrap()
      |> Enum.min_by(& &1.order_key, fn -> %{} end)

    build(execution_id, :uncertain, sequence,
      activation_id: Map.get(first, :activation_id),
      attempt_id: nil,
      runnable_ids: event.runnable_ids,
      node_hash: Map.get(first, :node_hash),
      node_name: Map.get(first, :node_name),
      error: event.reason,
      order_key: Map.get(event, :order_key) || {0, Map.get(first, :activation_id)},
      observed_at: event.observed_at
    )
  end

  defp build(execution_id, kind, sequence, attrs) do
    activation_id = Keyword.get(attrs, :activation_id)
    attempt_id = Keyword.get(attrs, :attempt_id)
    runnable_ids = Keyword.fetch!(attrs, :runnable_ids)

    id =
      Identity.derive(:event, [
        execution_id,
        kind,
        activation_id,
        attempt_id,
        runnable_ids
      ])

    struct!(
      __MODULE__,
      [
        id: id,
        execution_id: execution_id,
        kind: kind,
        sequence: sequence,
        runnable_ids: runnable_ids,
        observed_at: Keyword.get(attrs, :observed_at, System.monotonic_time(:millisecond))
      ] ++ attrs
    )
  end

  defp runnable_kind(:completed), do: :completed
  defp runnable_kind(:failed), do: :failed
  defp runnable_kind(:skipped), do: :skipped

  defp unit_runnables({:runnable, %Runnable{} = runnable}), do: [runnable]
  defp unit_runnables({:promise, %Promise{runnables: runnables}}), do: runnables
end
