defmodule Runic.TestSupport.BatchFailureComponent do
  use Runic.Workflow.SingleOutput
  alias Runic.Workflow.SingleOutput.Result
  defstruct [:name, :hash, :kind]

  def new(name, kind) do
    %__MODULE__{
      name: name,
      kind: kind,
      hash: Runic.Identity.derive(:component_definition, [name, kind])
    }
  end

  def run(component, _input, context) do
    case component.kind do
      :pid_exit ->
        GenServer.call(context.runtime.server, :ping, 5000)

      :key_error ->
        Map.fetch!(%{f: &Function.identity/1}, Map.get(context.runtime, :missing_key, :missing))

      :opaque ->
        Result.failure(URI.parse("http://x"))

      :reference ->
        Result.failure({:ref_error, context.runtime.reference})

      :function ->
        Result.failure(fn -> :not_portable end)

      :hook ->
        Result.value(:ok)
    end
  end
end

defimpl Runic.Component, for: Runic.TestSupport.BatchFailureComponent do
  def connectable?(_, _), do: true

  def connect(node, parent, workflow) do
    workflow |> Runic.Workflow.add_step(parent, node) |> Runic.Workflow.register_component(node)
  end

  def source(node),
    do:
      quote(
        do: Runic.TestSupport.BatchFailureComponent.new(unquote(node.name), unquote(node.kind))
      )

  def hash(node), do: node.hash
  def inputs(_), do: [in: [type: :any]]
  def outputs(_), do: [out: [type: :any]]
end
