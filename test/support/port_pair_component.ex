defimpl Runic.Component, for: Runic.TestSupport.PortPair do
  alias Runic.Workflow
  def connectable?(_, _), do: true

  def connect(node, parent, workflow) do
    workflow
    |> Workflow.add_step(parent, node.left)
    |> Workflow.add_step(parent, node.right)
    |> Workflow.register_component(node.left)
    |> Workflow.register_component(node.right)
    |> Workflow.register_component(node)
    |> Workflow.draw_connection(node, node.left, :component_of, properties: %{kind: :internal})
  end

  def source(node) do
    quote do: Runic.TestSupport.PortPair.new(unquote(node.name))
  end

  def hash(node), do: node.hash
  def inputs(node), do: node.inputs
  def outputs(node), do: node.outputs
end
