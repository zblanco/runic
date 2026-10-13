defmodule Runic.TestSupport.NativeMetaNode do
  @moduledoc false
  use Runic.Workflow.SingleOutput
  defstruct [:hash, :name, meta_refs: []]

  def new(kind) do
    %__MODULE__{
      name: :reader,
      hash: Runic.Identity.digest(:component_definition, {:native_meta_node, kind}),
      meta_refs: [%{kind: kind, target: :source, field_path: [], context_key: :read}]
    }
  end

  def run(_, _, context),
    do: Runic.Workflow.SingleOutput.Result.value(Map.fetch!(context.meta, :read))
end

defimpl Runic.Component, for: Runic.TestSupport.NativeMetaNode do
  alias Runic.Workflow
  def connectable?(_, _), do: true

  def connect(node, parent, workflow) do
    workflow
    |> Workflow.add_step(parent, node)
    |> Workflow.draw_connection(node, node, :component_of, properties: %{kind: :step})
    |> Workflow.register_component(node)
    |> Workflow.draw_meta_ref_edge(
      node,
      Workflow.get_component!(workflow, :source),
      hd(node.meta_refs)
    )
  end

  def source(node),
    do: quote(do: Runic.TestSupport.NativeMetaNode.new(unquote(hd(node.meta_refs).kind)))

  def hash(node), do: node.hash
  def inputs(_), do: [in: [type: :any]]
  def outputs(_), do: [out: [type: :any]]
end
