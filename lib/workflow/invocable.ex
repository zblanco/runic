defprotocol Runic.Workflow.Invocable do
  @moduledoc """
  Protocol enforcing how an operation/step/node within a workflow can always be activated in context of a workflow.

  The return of an implementation's `activate/3` should always return a new workflow.

  `activate/3`

  The activation protocol invokes the runnable protocol to evaluate valid steps in that cycle starting with conditionals.
  """
  def invoke(node, workflow, fact)
  def match_or_execute(node)
end
