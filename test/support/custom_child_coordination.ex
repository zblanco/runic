defmodule Runic.TestSupport.CustomChildCoordination do
  @moduledoc false
  use Runic.Workflow.SingleOutput
  defstruct [:hash, :name]

  def new do
    %__MODULE__{
      name: :custom,
      hash: Runic.Identity.digest(:component_definition, {__MODULE__, 1})
    }
  end

  def run(_, value, _), do: Runic.Workflow.SingleOutput.Result.value(value)
end

defimpl Runic.Component, for: Runic.TestSupport.CustomChildCoordination do
  alias Runic.Workflow
  def connectable?(_, _), do: true

  def connect(node, parent, workflow) do
    workflow
    |> Workflow.add_step(parent, node)
    |> Workflow.register_component(node)
    |> Workflow.draw_connection(node, node, :component_of, properties: %{kind: :step})
  end

  def source(_), do: quote(do: Runic.TestSupport.CustomChildCoordination.new())
  def hash(node), do: node.hash
  def inputs(_), do: [in: []]
  def outputs(_), do: [out: []]
end

defimpl Runic.Workflow.Coordinator, for: Runic.TestSupport.CustomChildCoordination do
  def finalize(_, workflow, _), do: {workflow, []}
end
