defmodule Runic.Workflow.Execution do
  @moduledoc """
  A process-local observation of one workflow admission scope.

  An execution starts with one explicit input occurrence. It ends when the
  scope has no active work and either has no ready work or admission has
  stopped. The workflow remains reusable after the scope ends.

  `outcomes` are in actual acceptance or observation order. Use
  `ordered_outcomes/2` with `order: :stable` when a consumer needs selection
  that is independent of concurrent completion timing.

  `persistence` reports the existing Runner Worker persistence boundary. It is
  not an exactly-once external-effect acknowledgement. Immediate execution uses
  `:not_managed` because it has no Runner Store acknowledgement.
  """

  alias Runic.Identity
  alias Runic.Workflow

  alias Runic.Workflow.{
    ExecutionUncertain,
    Fact,
    Runnable,
    RunnableCompleted,
    RunnableDispatched,
    RunnableFailed
  }

  alias Runic.Workflow.Execution.Outcome

  @type admission :: :open | :stopped
  @type status :: :active | :ready | :stopped | :quiescent

  @type persistence :: %{
          status: :not_managed | :saved | :pending | {:error, term()},
          event_cursor: non_neg_integer() | nil,
          pending_events: non_neg_integer()
        }

  @type unit :: %{
          kind: :runnable | :promise,
          id: term(),
          runnable_ids: [term()],
          node_names: [term()],
          order_key: term()
        }

  @type ready :: %{
          id: term(),
          activation_id: Identity.t() | nil,
          node_hash: term(),
          node_name: term(),
          input_fact_id: term(),
          order_key: term()
        }

  @type t :: %__MODULE__{
          id: Identity.t(),
          input_id: Identity.t(),
          input_fact_id: Identity.t(),
          status: status(),
          admission: admission(),
          active: [unit()],
          ready: [ready()],
          outcomes: [Outcome.t()],
          failures: [Outcome.t()],
          quiescent?: boolean(),
          persistence: persistence(),
          started_at: integer(),
          observed_at: integer()
        }

  @enforce_keys [:id, :input_id, :input_fact_id, :started_at]
  defstruct [
    :id,
    :input_id,
    :input_fact_id,
    :started_at,
    :observed_at,
    status: :ready,
    admission: :open,
    active: [],
    ready: [],
    outcomes: [],
    failures: [],
    quiescent?: false,
    persistence: %{status: :not_managed, event_cursor: nil, pending_events: 0}
  ]

  @doc false
  @spec start(Workflow.t(), term(), keyword()) :: {t(), Fact.t()}
  def start(%Workflow{} = workflow, input, opts \\ []) do
    execution_id = execution_id(workflow, Keyword.get(opts, :execution_id))
    draft = Fact.new(value: input)
    input_id = Identity.derive(:input_command, [execution_id, draft.payload_digest])
    input_fact_id = Identity.derive(:fact_occurrence, [input_id, :root])
    input_fact = Fact.new(value: input, id: input_fact_id)
    now = System.monotonic_time(:millisecond)

    {%__MODULE__{
       id: execution_id,
       input_id: input_id,
       input_fact_id: input_fact_id,
       started_at: now,
       observed_at: now
     }, input_fact}
  end

  @doc false
  @spec record(t(), Workflow.t(), Runnable.t()) :: t()
  def record(%__MODULE__{} = execution, %Workflow{} = workflow, %Runnable{} = runnable) do
    if same_root?(workflow, runnable.input_fact, execution.input_fact_id) do
      outcome = Outcome.from_runnable(execution.id, runnable, length(execution.outcomes) + 1)
      %{execution | outcomes: execution.outcomes ++ [outcome]}
    else
      execution
    end
  end

  @doc false
  @spec record_uncertain(t(), Workflow.t(), term(), term()) :: t()
  def record_uncertain(%__MODULE__{} = execution, %Workflow{} = workflow, unit, reason) do
    if Enum.any?(
         unit_runnables(unit),
         &same_root?(workflow, &1.input_fact, execution.input_fact_id)
       ) do
      outcome = Outcome.uncertain(execution.id, unit, reason, length(execution.outcomes) + 1)
      %{execution | outcomes: execution.outcomes ++ [outcome]}
    else
      execution
    end
  end

  @doc false
  @spec record_events(t(), Workflow.t(), [struct()]) :: t()
  def record_events(%__MODULE__{} = execution, %Workflow{} = workflow, events) do
    {execution, _dispatched} =
      Enum.reduce(events, {execution, %{}}, fn
        %RunnableDispatched{} = event, {scope, dispatched} ->
          {scope, Map.put(dispatched, event.attempt_id, event)}

        %RunnableCompleted{} = event, {scope, dispatched} ->
          case Map.get(dispatched, event.attempt_id) do
            %RunnableDispatched{} = dispatch ->
              if same_root?(workflow, dispatch.input_fact, scope.input_fact_id) do
                outcome =
                  Outcome.from_event(scope.id, event, dispatch, length(scope.outcomes) + 1)

                {%{scope | outcomes: scope.outcomes ++ [outcome]}, dispatched}
              else
                {scope, dispatched}
              end

            nil ->
              {scope, dispatched}
          end

        %RunnableFailed{} = event, {scope, dispatched} ->
          case Map.get(dispatched, event.attempt_id) do
            %RunnableDispatched{} = dispatch ->
              if same_root?(workflow, dispatch.input_fact, scope.input_fact_id) do
                outcome =
                  Outcome.from_event(scope.id, event, dispatch, length(scope.outcomes) + 1)

                {%{scope | outcomes: scope.outcomes ++ [outcome]}, dispatched}
              else
                {scope, dispatched}
              end

            nil ->
              {scope, dispatched}
          end

        %ExecutionUncertain{} = event, {scope, dispatched} ->
          if uncertain_in_scope?(workflow, event, scope.input_fact_id) do
            outcome = Outcome.from_event(scope.id, event, length(scope.outcomes) + 1)
            {%{scope | outcomes: scope.outcomes ++ [outcome]}, dispatched}
          else
            {scope, dispatched}
          end

        _event, acc ->
          acc
      end)

    execution
  end

  @doc false
  @spec observe(t(), Workflow.t(), [term()], admission(), persistence()) :: t()
  def observe(
        %__MODULE__{} = execution,
        %Workflow{} = workflow,
        active_units,
        admission,
        persistence
      ) do
    active =
      active_units
      |> Enum.filter(fn unit ->
        Enum.any?(
          unit_runnables(unit),
          &same_root?(workflow, &1.input_fact, execution.input_fact_id)
        )
      end)
      |> Enum.map(&unit_descriptor/1)
      |> Enum.sort_by(& &1.order_key)

    ready =
      workflow
      |> Workflow.next_runnables()
      |> Enum.filter(fn {_node, fact} -> same_root?(workflow, fact, execution.input_fact_id) end)
      |> Enum.map(fn {node, fact} -> ready_descriptor(workflow, node, fact) end)
      |> Enum.sort_by(& &1.order_key)

    quiescent? = active == [] and (admission == :stopped or ready == [])

    status =
      cond do
        admission == :stopped -> :stopped
        active != [] -> :active
        ready != [] -> :ready
        true -> :quiescent
      end

    failures = Enum.filter(execution.outcomes, &(&1.kind in [:failed, :skipped, :uncertain]))

    %{
      execution
      | status: status,
        admission: admission,
        active: active,
        ready: ready,
        failures: failures,
        quiescent?: quiescent?,
        persistence: persistence,
        observed_at: System.monotonic_time(:millisecond)
    }
  end

  @doc "Returns outcomes in observed order or stable consumer-selection order."
  @spec ordered_outcomes(t(), keyword()) :: [Outcome.t()]
  def ordered_outcomes(%__MODULE__{} = execution, opts \\ []) do
    case Keyword.get(opts, :order, :observed) do
      :observed -> execution.outcomes
      :stable -> Enum.sort_by(execution.outcomes, &{&1.order_key, &1.sequence})
      other -> raise ArgumentError, "invalid outcome order: #{inspect(other)}"
    end
  end

  @doc "Returns successful computed values in observed or stable order."
  @spec outputs(t(), keyword()) :: [term()]
  def outputs(%__MODULE__{} = execution, opts \\ []) do
    execution
    |> ordered_outcomes(opts)
    |> Enum.filter(&(&1.kind == :completed))
    |> Enum.map(fn
      %Outcome{result: %Fact{value: value}} -> value
      %Outcome{result: result} -> result
    end)
  end

  @doc "Returns failed and uncertain outcomes in observed or stable order."
  @spec failures(t(), keyword()) :: [Outcome.t()]
  def failures(%__MODULE__{} = execution, opts \\ []) do
    execution
    |> ordered_outcomes(opts)
    |> Enum.filter(&(&1.kind in [:failed, :skipped, :uncertain]))
  end

  @doc "Returns true when the execution scope cannot make more progress by itself."
  @spec quiescent?(t()) :: boolean()
  def quiescent?(%__MODULE__{quiescent?: quiescent?}), do: quiescent?

  defp execution_id(_workflow, %Identity{domain: :execution} = id), do: id

  defp execution_id(_workflow, %Identity{} = id) do
    raise ArgumentError, "expected an :execution identity, got: #{inspect(id.domain)}"
  end

  defp execution_id(workflow, nil) do
    Identity.derive(:execution, [workflow.hash, workflow.name, Uniq.UUID.uuid4()])
  end

  defp execution_id(_workflow, other) do
    raise ArgumentError, "expected :execution_id to be a Runic.Identity, got: #{inspect(other)}"
  end

  defp same_root?(workflow, fact, root_id) do
    Workflow.root_ancestor_hash(workflow, fact) == root_id
  end

  defp uncertain_in_scope?(workflow, event, root_id) do
    event
    |> Map.get(:members)
    |> List.wrap()
    |> Enum.any?(fn member ->
      case Map.get(workflow.graph.vertices, Map.get(member, :input_fact_id)) do
        %Fact{} = fact -> same_root?(workflow, fact, root_id)
        _other -> false
      end
    end)
  end

  defp ready_descriptor(workflow, node, fact) do
    activation_id = Runnable.runnable_id(node, fact)

    %{
      id: activation_id,
      activation_id: activation_id,
      node_hash: node.hash,
      node_name: Map.get(node, :name, node.hash),
      input_fact_id: fact.hash,
      order_key: {Workflow.ancestry_depth(workflow, fact), activation_id}
    }
  end

  defp unit_descriptor({:runnable, %Runnable{} = runnable}) do
    %{
      kind: :runnable,
      id: runnable.id,
      runnable_ids: [runnable.id],
      node_names: [Map.get(runnable.node, :name, runnable.node.hash)],
      order_key: Runnable.order_key(runnable)
    }
  end

  defp unit_descriptor({:promise, promise}) do
    order_key = promise.runnables |> Enum.map(&Runnable.order_key/1) |> Enum.min()

    %{
      kind: :promise,
      id: promise.id,
      runnable_ids: Enum.map(promise.runnables, & &1.id),
      node_names: Enum.map(promise.runnables, &Map.get(&1.node, :name, &1.node.hash)),
      order_key: order_key
    }
  end

  defp unit_runnables({:runnable, %Runnable{} = runnable}), do: [runnable]
  defp unit_runnables({:promise, promise}), do: promise.runnables
end
