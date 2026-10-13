defmodule Runic.Workflow.ChildInvocation do
  @moduledoc """
  Data for one child call, returned by a `Runic.Workflow.Call` request Step.

  `new/1` takes `:target`, `:input`, and an optional `:output` port. Runic
  validates and saves the target through its existing construction event.
  Each Call activation creates a separate child occurrence. The target stays
  reusable. An ordinary Step return value is never interpreted as a request.

  Targets can be Steps, SingleOutput custom components, or declared stateless
  workflows built from these nodes, input bindings, and joins. The selected
  output must have one producer; that producer can emit several values. Call
  forwards each accepted selected-port value. An independent branch failure
  does not retract accepted output. Stateful and collection components need a
  separate instance contract and are rejected. Target hooks and live runtime
  context must be supplied by the parent and are not copied into a definition.

  Child work is normal parent work. Failure, retry, cancellation, observation,
  and Store acknowledgement use the parent runtime contracts. Accepted progress
  replays without calling the child again. Unaccepted external work can repeat.
  """
  alias Runic.Component
  alias Runic.Workflow
  alias Runic.Workflow.{InputBinding, Join, Root, SingleOutput}

  @enforce_keys [:target, :input, :output]
  defstruct [:target, :input, :output]

  @type t :: %__MODULE__{target: Runic.Workflow.ComponentAdded.t(), input: term(), output: atom()}

  @spec new(keyword()) :: t()
  def new(opts) do
    opts = Keyword.validate!(opts, [:target, :input, :output])
    target = Keyword.fetch!(opts, :target)
    validate_target!(target)
    outputs = Component.outputs(target)

    output =
      Keyword.get_lazy(opts, :output, fn ->
        case outputs do
          [{port, _}] -> port
          _ -> raise ArgumentError, "child target must select an output port"
        end
      end)

    unless Keyword.has_key?(outputs, output),
      do: raise(ArgumentError, "child target has no output port #{inspect(output)}")

    {_workflow, [event]} = Workflow.add_with_events(Workflow.new(), target)
    validate_saved_graph!(target, event)
    request = %__MODULE__{target: event, input: Keyword.fetch!(opts, :input), output: output}
    graph(request)
    request
  end

  @doc false
  def graph(%__MODULE__{} = request) do
    workflow = Workflow.from_log([request.target])
    target = Workflow.get_component!(workflow, request.target.name)
    validate_target!(target)
    Enum.each(Multigraph.vertices(workflow.graph), &validate_node!/1)
    # The public port compiler resolves and validates the selected output.
    collector = Runic.Workflow.CallValue.new(:collector, :output)

    Workflow.add(workflow, collector,
      connections: [[from: {target.name, request.output}, to: :in]]
    )
  end

  defp validate_saved_graph!(%Workflow{} = target, event) do
    rebuilt = Runic.Workflow.Definition.rebuild(event.workflow_definition)

    unless graph_shape(target) == graph_shape(rebuilt),
      do:
        raise(
          ArgumentError,
          "child target build log does not preserve its graph; use recorded public construction"
        )
  rescue
    error in [KeyError, FunctionClauseError] ->
      raise ArgumentError,
            "child target build log cannot reconstruct its graph: #{Exception.message(error)}"
  end

  defp validate_saved_graph!(_, _), do: :ok

  # Compare graph coordinates and declarative edge data. Callback code remains
  # under the existing trusted source/closure compatibility contract.
  defp graph_shape(workflow) do
    vertices =
      workflow.graph
      |> Multigraph.vertices()
      |> Enum.map(&{Runic.Workflow.Components.vertex_id_of(&1), &1.__struct__})
      |> Enum.sort()

    edges =
      workflow.graph
      |> Multigraph.edges()
      |> Enum.map(fn edge ->
        {Runic.Workflow.Components.vertex_id_of(edge.v1),
         Runic.Workflow.Components.vertex_id_of(edge.v2), edge.label, edge.weight,
         Map.delete(edge.properties || %{}, :getter_fn)}
      end)
      |> Enum.sort()

    {vertices, edges}
  end

  defp validate_target!(%Workflow{} = target) do
    unless target.input_ports && target.output_ports,
      do: raise(ArgumentError, "child workflow must declare input and output ports")

    if target.before_hooks != %{} or target.after_hooks != %{} or target.run_context != %{} or
         target.scheduler_policies != [],
       do:
         raise(
           ArgumentError,
           "child target cannot contain hooks, policies, or live runtime context"
         )

    if target.runnable_events != [] or Workflow.productions(target) != [],
      do: raise(ArgumentError, "child target must be an unexecuted definition")

    target.graph |> Multigraph.vertices() |> Enum.each(&validate_node!/1)
  end

  defp validate_target!(node), do: validate_node!(node)

  defp validate_node!(%Root{}), do: :ok
  defp validate_node!(%InputBinding{}), do: :ok
  defp validate_node!(%Join{}), do: :ok
  defp validate_node!(%Workflow{} = workflow), do: validate_target!(workflow)

  defp validate_node!(node) when is_struct(node, Runic.Workflow.Call),
    do: raise(ArgumentError, "nested dynamic Calls need an instance contract")

  defp validate_node!(node) do
    unless SingleOutput.supported?(node),
      do:
        raise(
          ArgumentError,
          "unsupported child node #{inspect(node.__struct__)}; child invocation requires stateless SingleOutput nodes"
        )

    if Runic.Workflow.Activator.impl_for(node) != nil or
         Runic.Workflow.Coordinator.impl_for(node) != nil,
       do:
         raise(
           ArgumentError,
           "custom child activation or coordination needs an instance contract"
         )

    if Enum.any?(Map.get(node, :meta_refs, []), &(&1.kind != :context)),
      do: raise(ArgumentError, "child graph metadata references need an instance contract")
  end
end
