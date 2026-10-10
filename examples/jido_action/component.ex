defimpl Runic.Component, for: Runic.Examples.JidoAction do
  alias Runic.Workflow

  def connectable?(_, _), do: true

  def connect(node, parent, workflow) do
    workflow
    |> Workflow.add_step(parent, node)
    |> Workflow.draw_connection(node, node, :component_of, properties: %{kind: :step})
    |> Workflow.register_component(node)
  end

  def source(node) do
    source = Runic.Component.source(node.action)

    quote do
      Runic.Examples.JidoAction.from_action(unquote(source))
    end
  end

  def hash(node), do: node.hash
  def inputs(node), do: Runic.Component.inputs(node.action)
  def outputs(node), do: Runic.Component.outputs(node.action)
end
