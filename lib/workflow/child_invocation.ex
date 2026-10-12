defmodule Runic.Workflow.ChildInvocation do
  @moduledoc """
  Data for one child call, returned by a `Runic.Workflow.Call` request Step.

  `new/1` takes `:target`, `:input`, and an optional `:output` port. Runic
  validates and saves the target through its existing construction event.
  Each Call activation creates a separate child occurrence. The target stays
  reusable. An ordinary Step return value is never interpreted as a request.

  Targets can be Steps, SingleOutput custom components, or declared stateless
  workflows built from these nodes, input bindings, and joins. The selected
  output must have one producer. Stateful and collection components need a
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

    if Enum.any?(Map.get(node, :meta_refs, []), &(&1.kind != :context)),
      do: raise(ArgumentError, "child graph metadata references need an instance contract")
  end
end
