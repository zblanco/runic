defimpl Runic.Component, for: Runic.TestSupport.CoordinateComponent do
  def connectable?(_, _), do: true

  def connect(node, parent, workflow) do
    workflow
    |> Runic.Workflow.add_step(parent, node)
    |> Runic.Workflow.draw_connection(node, node, :component_of, properties: %{kind: :step})
    |> Runic.Workflow.register_component(node)
  end

  def source(node) do
    quote do
      Runic.TestSupport.CoordinateComponent.new(unquote(node.name))
    end
  end

  def hash(node), do: node.hash
  def inputs(_), do: [in: [type: :any]]
  def outputs(_), do: [out: [type: :any]]
end
