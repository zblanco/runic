defmodule Runic.Workflow.SingleOutput do
  @moduledoc """
  The native lifecycle for a node producing one value or an explicit failure.

  Add `use Runic.Workflow.SingleOutput` to a component struct's module and
  implement `c:run/3`. The generated `Runic.Workflow.Invokable` implementation
  shares preparation, hooks, child Fact construction, activation consumption,
  and collection tracking with ordinary Steps. No Runner or storage is needed.

  The struct must have `:hash` and `:name`. Composition, ports, identity, and
  reconstructable source remain the responsibility of `Runic.Component`;
  this behaviour does not implement or replace that protocol. Nodes with
  different readiness, state, or multiple-output semantics should continue
  implementing low-level `Runic.Workflow.Invokable` directly.

  The callback owns application validation and result interpretation. Use
  `Runic.Workflow.SingleOutput.Result.value/2` for data and `failure/1` for an
  attempt failure. It runs once per attempt, after before hooks and before
  success hooks. A failure does not publish an output or deferred hook changes.
  Raises, throws, and catchable exits become failed Runnables. Task ownership,
  timeouts, retry classification, and durable acceptance stay in their existing
  execution layers; arbitrary external effects are not made exactly once.

  Save callback code/configuration through the component's existing source or
  closure representation. The callback context is transient and is not added
  to construction events. Restoring accepted lifecycle events does not invoke
  callbacks or hooks again. Code and captured bindings must remain compatible
  with the selected persistence/remote execution profile.
  """

  alias Runic.Workflow
  alias Runic.Workflow.{CallContract, CausalContext, Fact, FanIn, FanOut, HookRunner}
  alias Runic.Workflow.{Invocation, Runnable, Step}
  alias Runic.Workflow.Events.{ActivationConsumed, FactProduced, MapReduceTracked}
  alias Runic.Workflow.SingleOutput.{Context, Result}

  @doc "Performs one application attempt without access to the workflow graph."
  @callback run(component :: struct(), input :: term(), Context.t()) :: Result.t()

  @doc "Installs the ordinary Invokable lifecycle for the calling struct module."
  defmacro __using__([]) do
    quote do
      @behaviour Runic.Workflow.SingleOutput

      @doc false
      def __runic_single_output__, do: true

      defimpl Runic.Workflow.Invokable, for: __MODULE__ do
        def match_or_execute(_node), do: :execute

        defdelegate prepare(node, workflow, fact), to: Runic.Workflow.SingleOutput
        defdelegate execute(node, runnable), to: Runic.Workflow.SingleOutput
        defdelegate invoke(node, workflow, fact), to: Runic.Workflow.SingleOutput
      end
    end
  end

  @doc false
  def supported?(%Step{}), do: true

  def supported?(%module{}) do
    function_exported?(module, :__runic_single_output__, 0) and module.__runic_single_output__()
  end

  @doc false
  def prepare(node, workflow, fact) do
    meta =
      if Map.get(node, :meta_refs, []) != [],
        do: Workflow.prepare_meta_context(workflow, node),
        else: %{}

    context =
      CausalContext.new(
        node_hash: node.hash,
        input_fact: fact,
        ancestry_depth: Workflow.ancestry_depth(workflow, fact),
        hooks: Workflow.get_hooks(workflow, node.hash),
        run_context: Workflow.get_run_context(workflow, node.name),
        meta_context: meta,
        fan_out_context: collection_context(workflow, node, fact)
      )

    runnable = Runnable.new(node, fact, context)

    runnable =
      case node do
        %Step{} ->
          Runnable.with_invocation(runnable, node |> CallContract.for_step() |> Invocation.plan())

        _ ->
          runnable
      end

    {:ok, runnable}
  end

  @doc false
  def invoke(node, workflow, fact) do
    {:ok, runnable} = prepare(node, workflow, fact)
    Workflow.apply_runnable(workflow, execute(node, runnable))
  end

  @doc false
  def execute(node, %Runnable{input_fact: fact, context: context} = runnable) do
    with {:ok, before_fns} <- HookRunner.run_before(context, node, fact) do
      case run_work(node, runnable) do
        %Result{status: :value} = result ->
          result_fact = child_fact(runnable, result)

          case HookRunner.run_after(context, node, fact, result_fact) do
            {:ok, after_fns} -> complete(runnable, result_fact, before_fns ++ after_fns)
            {:error, reason} -> Runnable.fail(runnable, {:hook_error, reason})
          end

        %Result{status: :failure, error: reason} ->
          Runnable.fail(runnable, reason)

        other ->
          Runnable.fail(runnable, {:invalid_single_output_result, other})
      end
    else
      {:error, reason} -> Runnable.fail(runnable, {:hook_error, reason})
    end
  rescue
    exception -> Runnable.fail(runnable, exception)
  catch
    kind, reason -> Runnable.fail(runnable, {kind, reason})
  end

  defp run_work(%Step{} = step, runnable) do
    plan = runnable.invocation || step |> CallContract.for_step() |> Invocation.plan()
    invocation = Invocation.materialize(plan, runnable.input_fact.value, runnable.context)
    Result.value(Invocation.call(invocation, step.work))
  end

  defp run_work(%module{} = node, runnable) do
    module.run(node, runnable.input_fact.value, Context.from_runnable(runnable))
  end

  # A policy fallback supplies already-interpreted data, not another callback
  # attempt. Preserve its no-hooks behavior while sharing native completion.
  @doc false
  def complete_value(runnable, value) do
    complete(runnable, child_fact(runnable, Result.value(value)), [])
  rescue
    exception -> Runnable.fail(runnable, exception)
  catch
    kind, reason -> Runnable.fail(runnable, {kind, reason})
  end

  defp child_fact(runnable, %Result{value: value, metadata: metadata}) do
    Result.validate_metadata!(metadata)

    Fact.new(
      value: value,
      ancestry: {runnable.node.hash, runnable.input_fact.hash},
      meta: metadata
    )
  end

  defp complete(runnable, fact, hook_fns) do
    context = runnable.context

    events = [
      FactProduced.new(fact, producer_label: :produced, weight: context.ancestry_depth + 1),
      %ActivationConsumed{
        fact_hash: runnable.input_fact.hash,
        node_hash: runnable.node.hash,
        from_label: :runnable
      }
    ]

    events =
      case context.fan_out_context do
        %{source_fact_hash: source, fan_out_hash: fan_out, fan_out_fact_hash: item} ->
          events ++
            [
              %MapReduceTracked{
                source_fact_hash: source,
                fan_out_hash: fan_out,
                fan_out_fact_hash: item,
                step_hash: runnable.node.hash,
                result_fact_hash: fact.hash
              }
            ]

        _ ->
          events
      end

    Runnable.complete(%{runnable | error: nil}, fact, events, hook_fns)
  end

  defp collection_context(workflow, node, fact) do
    registered? = MapSet.member?(workflow.mapped.mapped_paths, node.hash)
    collectors = if registered?, do: [], else: collection_sources(workflow, node)

    # Most ordinary nodes are not in a collection. Do not walk their causal
    # history just to discover that: keep preparation independent of its depth.
    origin = if registered? or collectors != [], do: FanOut.origin(workflow, fact)

    case origin do
      {source, fan_out, item} ->
        if registered? or fan_out in collectors do
          %{
            is_reduced: true,
            source_fact_hash: source,
            fan_out_hash: fan_out,
            fan_out_fact_hash: item
          }
        end

      nil ->
        nil
    end
  end

  # Native Map/Reduce marks its pipeline paths. Custom composites may instead
  # directly connect an ordinary node to a FanIn associated with this FanOut.
  # Do not track arbitrary descendants: unused tracking would retain batches.
  defp collection_sources(workflow, node) do
    Enum.flat_map(Multigraph.out_edges(workflow.graph, node, by: :flow), fn
      %{v2: %FanIn{} = collector} ->
        Enum.map(Multigraph.in_edges(workflow.graph, collector, by: :fan_in), & &1.v1.hash)

      _ ->
        []
    end)
  end
end
