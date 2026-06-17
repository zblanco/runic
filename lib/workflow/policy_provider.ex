defprotocol Runic.Workflow.PolicyProvider do
  @fallback_to_any true

  @moduledoc """
  Optional protocol for workflow nodes that carry scheduler policy defaults.

  `Runic.Workflow.SchedulerPolicy.resolve/2` consults this protocol before
  applying workflow or runtime scheduler policy rules. This lets custom
  components declare their own execution policy while still allowing callers to
  override that policy from the workflow scheduler policy list.

  Implementations may return:

  - `nil` when the component has no policy defaults
  - a keyword list
  - a map
  - a `%Runic.Workflow.SchedulerPolicy{}`
  """

  @doc """
  Returns scheduler policy defaults for this workflow node.
  """
  @spec scheduler_policy(node :: struct()) ::
          Runic.Workflow.SchedulerPolicy.t() | map() | keyword() | nil
  def scheduler_policy(node)
end

defimpl Runic.Workflow.PolicyProvider, for: Any do
  def scheduler_policy(_node), do: nil
end
