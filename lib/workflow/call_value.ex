defmodule Runic.Workflow.CallValue do
  @moduledoc false
  use Runic.Workflow.SingleOutput
  alias Runic.Workflow.SingleOutput.Result
  defstruct [:hash, :name, :mode, :value]

  def new(key, mode, value \\ nil) do
    %__MODULE__{
      hash: Runic.Identity.derive(:node_occurrence, [key, mode]),
      name: "__runic_call__/#{key}/#{mode}",
      mode: mode,
      value: value
    }
  end

  def run(%{mode: :input, value: value}, _, context),
    do: Result.value(value, metadata: Map.delete(context.input_metadata, :runic))

  def run(_, input, context),
    do: Result.value(input, metadata: Map.delete(context.input_metadata, :runic))
end

defimpl Runic.Component, for: Runic.Workflow.CallValue do
  alias Runic.Workflow
  def connectable?(_, _), do: true

  def connect(node, parent, workflow) do
    workflow |> Workflow.add_step(parent, node) |> Workflow.register_component(node)
  end

  def source(node) do
    quote do: struct!(Runic.Workflow.CallValue, unquote(Macro.escape(Map.from_struct(node))))
  end

  def hash(node), do: node.hash
  def inputs(_), do: [in: [type: :any]]
  def outputs(_), do: [out: [type: :any]]
end
