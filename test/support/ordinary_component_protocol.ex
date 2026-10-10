defimpl Runic.Component, for: Runic.TestSupport.OrdinaryComponent do
  alias Runic.Workflow
  alias Runic.TestSupport.OrdinaryComponent

  def connectable?(_, _), do: true

  def connect(node, parent, workflow) do
    workflow
    |> Workflow.add_step(parent, node)
    |> Workflow.draw_connection(node, node, :component_of, properties: %{kind: :step})
    |> Workflow.register_component(node)
  end

  def source(node) do
    quote do
      OrdinaryComponent.new(
        unquote(node.name),
        unquote(node.operation),
        unquote(Macro.escape(node.config))
      )
    end
  end

  def hash(node), do: node.hash
  def inputs(_), do: [in: [type: :any]]
  def outputs(_), do: [out: [type: :any]]
end
