defprotocol Runic.Component do
  @moduledoc """
  The Component protocol is implemented by datastructures which know how to become a Runic Workflow
    by implementing the `to_workflow/1` transformation.
  """
  @fallback_to_any true
  def to_workflow(flowable)
end
