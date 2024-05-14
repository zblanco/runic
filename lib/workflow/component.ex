defprotocol Runic.Component do
  @moduledoc """
  Protocol defining common behaviour of Runic components such as reflection, sub components or how the can be composed with others.
  """

  def component_of(workflow, component, sub_component_kind)

  def connectables(component)
end

defimpl Runic.Component, for: Runic.Workflow.Rule do
  def component_of(_workflow, rule, :reaction) do
    rule.workflow.graph
    |> Graph.vertices()
    |> Enum.filter(&match?(%Runic.Workflow.Step{}, &1))
    |> hd()
  end

  def connectables(_rule) do
    [:reaction]
  end
end
