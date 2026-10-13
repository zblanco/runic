defmodule Runic.Workflow.Call do
  @moduledoc """
  A composite that invokes one child per request-Step activation.

  `new/2` takes a Step that returns `ChildInvocation.new/1` and a required name.
  Its `out` port has `:many` cardinality and forwards each accepted value from
  the selected child producer. Request and input wiring are private. Invalid
  requests fail the Call activation. A selected producer can run several times;
  this port is not a barrier for all child branches.

  Children run as ordinary nodes in the parent's execution scope. Each Call
  activation owns a separate occurrence. Checkpoints retain its dynamic
  construction and accepted progress through the existing event log. Cancel
  and deadlines use the native parent task owner. Completion in local memory
  and Store acknowledgement remain separate states. The Call Runnable completes
  the request attempt; the output port forwards selected producer results.
  Execution scope quiescence reports the end of admitted work. Independent
  branch failure can coexist with output under the parent's failure policy.
  """
  @behaviour Runic.Workflow.SingleOutput
  @doc false
  def __runic_single_output__, do: true

  alias Runic.Component
  alias Runic.Workflow
  alias Runic.Workflow.{CallValue, CausalContext, ChildInvocation, Invocation, Step}
  alias Runic.Workflow.SingleOutput.Result
  defstruct [:hash, :name, :request_step, :output, :meta_refs]

  @spec new(Step.t(), keyword()) :: %__MODULE__{}
  def new(%Step{} = step, opts) do
    opts = Keyword.validate!(opts, [:name])
    name = Keyword.fetch!(opts, :name)

    unless is_atom(name) or is_binary(name),
      do: raise(ArgumentError, "Call name must be an atom or string")

    unless length(Component.inputs(step)) == 1 and
             Runic.Workflow.CallContract.for_step(step).authored_arity == 1,
           do: raise(ArgumentError, "Call request Step must accept one input port")

    if Enum.any?(step.meta_refs, &(&1.kind != :context)),
      do: raise(ArgumentError, "Call request Step supports runtime context only")

    hash = Runic.Identity.digest(:component_definition, {__MODULE__, name, Component.hash(step)})

    %__MODULE__{
      hash: hash,
      name: name,
      request_step: step,
      output: CallValue.new(hash, :output),
      meta_refs: step.meta_refs
    }
  end

  @doc false
  def run(call, input, context) do
    invocation =
      call.request_step
      |> Runic.Workflow.CallContract.for_step()
      |> Invocation.plan()
      |> Invocation.materialize(
        input,
        CausalContext.new(meta_context: context.meta, run_context: context.runtime)
      )

    case Invocation.call(invocation, call.request_step.work) do
      %ChildInvocation{} = request ->
        Result.value(request, metadata: Map.delete(context.input_metadata, :runic))

      other ->
        Result.failure({:invalid_child_invocation, other})
    end
  end

  @doc false
  def execute(call, runnable) do
    Runic.Workflow.SingleOutput.execute_with(call, runnable, fn node, work ->
      result =
        run(node, work.input_fact.value, Runic.Workflow.SingleOutput.Context.from_runnable(work))

      {result, prepare_child(result.value, work)}
    end)
  end

  @doc false
  def complete_value(runnable, value) do
    prepared = prepare_child(value, runnable)

    Runic.Workflow.SingleOutput.complete_value(runnable, value)
    |> Map.put(:execution_data, prepared)
  rescue
    error -> Runic.Workflow.Runnable.fail(runnable, {:child_construction_failed, error})
  catch
    kind, reason ->
      Runic.Workflow.Runnable.fail(runnable, {:child_construction_failed, {kind, reason}})
  end

  defp prepare_child(%ChildInvocation{} = request, runnable) do
    Runic.Workflow.ChildInvocation.Occurrence.prepare(
      request,
      Runic.Workflow.Runnable.activation_id(runnable)
    )
  end

  defp prepare_child(_, _), do: nil
end

defimpl Runic.Component, for: Runic.Workflow.Call do
  alias Runic.Workflow
  def connectable?(_, _), do: true

  def connect(call, parent, workflow) do
    workflow
    |> Workflow.add_step(parent, call)
    |> Workflow.add_step(call, call.output)
    |> Workflow.register_component(call)
  end

  def source(call) do
    {_, [event]} = Workflow.add_with_events(Workflow.new(), call.request_step)
    binary = :erlang.term_to_binary(event)

    quote do
      event = :erlang.binary_to_term(unquote(binary))
      workflow = Runic.Workflow.from_log([event])

      Runic.Workflow.Call.new(Runic.Workflow.get_component!(workflow, event.name),
        name: unquote(call.name)
      )
    end
  end

  def hash(call), do: call.hash
  def inputs(call), do: Runic.Component.inputs(call.request_step)
  def outputs(call), do: [out: [type: :any, cardinality: :many, from: call.output.hash]]
end

defimpl Runic.Workflow.Invokable, for: Runic.Workflow.Call do
  def match_or_execute(_), do: :execute
  defdelegate prepare(node, workflow, fact), to: Runic.Workflow.SingleOutput
  defdelegate execute(node, runnable), to: Runic.Workflow.Call

  def invoke(node, workflow, fact) do
    {:ok, runnable} = prepare(node, workflow, fact)
    Runic.Workflow.apply_runnable(workflow, execute(node, runnable))
  end
end

defimpl Runic.Workflow.Activator, for: Runic.Workflow.Call do
  alias Runic.Workflow
  alias Runic.Workflow.ChildInvocation.Occurrence
  alias Runic.Workflow.Events.RunnableActivated

  def activate_downstream(
        call,
        workflow,
        %{result: %{value: %Runic.Workflow.ChildInvocation{} = request}} = runnable
      ) do
    occurrence =
      Occurrence.new(
        Runic.Workflow.Runnable.activation_id(runnable),
        request.target,
        request.output,
        call.output.hash,
        runnable.result.hash
      )

    {workflow, additions} =
      Workflow.attach_child_occurrence(workflow, occurrence, call, runnable.execution_data)

    event = %RunnableActivated{
      fact_hash: runnable.result.hash,
      node_hash: occurrence.entry_hash,
      activation_kind: :runnable
    }

    {Workflow.apply_event(workflow, event), additions ++ [event]}
  end

  # A policy fallback value is already interpreted output. It does not request
  # another child unless it explicitly returns ChildInvocation data.
  def activate_downstream(call, workflow, runnable) do
    event = %RunnableActivated{
      fact_hash: runnable.result.hash,
      node_hash: call.output.hash,
      activation_kind: :runnable
    }

    {Workflow.apply_event(workflow, event), [event]}
  end
end
