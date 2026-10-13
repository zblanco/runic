defmodule Runic.TestSupport.OrdinaryChildComposite do
  @moduledoc false
  use Runic.Workflow.SingleOutput
  require Runic
  defstruct [:hash, :name, :leaf, :outputs]

  def new do
    if Process.get(:runic_test_constructor_error), do: raise("constructor unavailable")

    if observer = Process.get(:runic_test_constructor_observer),
      do: send(observer, :target_constructed)

    leaf = Runic.step(fn n -> n * 2 end, name: :leaf)

    %__MODULE__{
      name: :composite,
      hash: Runic.Identity.digest(:component_definition, {__MODULE__, 1}),
      leaf: leaf,
      outputs: [out: [from: leaf.name]]
    }
  end

  def run(_, value, _), do: Runic.Workflow.SingleOutput.Result.value(value + 1)
end

defimpl Runic.Component, for: Runic.TestSupport.OrdinaryChildComposite do
  alias Runic.Workflow
  def connectable?(_, _), do: true

  def connect(node, parent, workflow) do
    workflow
    |> Workflow.add_step(parent, node)
    |> Workflow.add_step(node, node.leaf)
    |> Workflow.register_component(node)
    |> Workflow.register_component(node.leaf)
    |> Workflow.draw_connection(node, node, :component_of, properties: %{kind: :internal})
  end

  def source(_), do: quote(do: Runic.TestSupport.OrdinaryChildComposite.new())
  def hash(node), do: node.hash
  def inputs(_), do: [in: []]
  def outputs(node), do: node.outputs
end
