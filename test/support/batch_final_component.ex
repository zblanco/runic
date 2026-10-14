defmodule Runic.TestSupport.BatchFinalComponent do
  use Runic.Workflow.SingleOutput
  alias Runic.Workflow.SingleOutput.Result
  defstruct [:name, :hash, meta_refs: []]

  def new(name, refs \\ []) do
    if pid = Process.get({__MODULE__, :constructor_observer}), do: send(pid, {:constructed, name})

    %__MODULE__{
      name: name,
      meta_refs: refs,
      hash: Runic.Identity.derive(:component_definition, [name, refs])
    }
  end

  def run(_node, value, context) do
    if pid = context.runtime[:observer], do: send(pid, {:custom_views, context})
    Result.value(value)
  end
end

defimpl Runic.Component, for: Runic.TestSupport.BatchFinalComponent do
  def connectable?(_, _), do: true

  def connect(node, parent, workflow),
    do:
      workflow |> Runic.Workflow.add_step(parent, node) |> Runic.Workflow.register_component(node)

  def source(node),
    do:
      quote(
        do:
          Runic.TestSupport.BatchFinalComponent.new(
            unquote(node.name),
            unquote(Macro.escape(node.meta_refs))
          )
      )

  def hash(node), do: node.hash
  def inputs(_), do: [in: [type: :any]]
  def outputs(_), do: [out: [type: :any]]
end
