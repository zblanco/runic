defmodule Runic.TestSupport.CustomChildActivation do
  @moduledoc false
  use Runic.Workflow.SingleOutput
  require Runic
  defstruct [:hash, :name, :leaf]

  def new do
    %__MODULE__{
      hash: Runic.Identity.digest(:component_definition, {__MODULE__, 1}),
      name: :wrapper,
      leaf: Runic.step(fn n -> n * 2 end, name: :leaf)
    }
  end

  def run(_, value, _), do: Runic.Workflow.SingleOutput.Result.value(value)
end

defimpl Runic.Component, for: Runic.TestSupport.CustomChildActivation do
  alias Runic.Workflow
  def connectable?(_, _), do: true

  def connect(node, parent, workflow) do
    workflow
    |> Workflow.add_step(parent, node)
    |> Workflow.add_step(node, node.leaf)
    |> Workflow.register_component(node)
    |> Workflow.register_component(node.leaf)
  end

  def source(_), do: quote(do: Runic.TestSupport.CustomChildActivation.new())
  def hash(node), do: node.hash
  def inputs(_), do: [in: []]
  def outputs(node), do: [out: [from: node.leaf.hash]]
end

defimpl Runic.Workflow.Activator, for: Runic.TestSupport.CustomChildActivation do
  def activate_downstream(node, workflow, runnable) do
    event = %Runic.Workflow.Events.RunnableActivated{
      fact_hash: runnable.result.hash,
      node_hash: node.leaf.hash,
      activation_kind: :runnable
    }

    {Runic.Workflow.apply_event(workflow, event), [event]}
  end
end
