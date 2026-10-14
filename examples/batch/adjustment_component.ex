defimpl Runic.Component, for: Runic.Examples.Batch.Adjustment do
  alias Runic.Workflow
  def connectable?(_, _), do: true

  def connect(component, parent, workflow) do
    workflow |> Workflow.add_step(parent, component) |> Workflow.register_component(component)
  end

  def source(component) do
    quote do: Runic.Examples.Batch.Adjustment.new(unquote(component.name))
  end

  def hash(component), do: component.hash
  def inputs(_), do: [in: [type: :any]]
  def outputs(_), do: [out: [type: :any]]
end
