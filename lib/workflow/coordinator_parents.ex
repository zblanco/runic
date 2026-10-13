defprotocol Runic.Workflow.CoordinatorParents do
  @moduledoc """
  Declares the Fact parents a coordinator will read during finalization.

  `parents/3` runs against the graph with the completed events staged, before
  deferred hooks and `Coordinator.finalize/3`. Return the actual Facts that
  supply coordination values. Runic adds the input and prepared meta parents,
  then checks that all local parents have one valid scope.

  Coordinators without this contract can still process portable workflows.
  Native local workflows reject them before finalization. Implementations must
  declare all read parents and use `Fact.child/2` for their results. This check
  cannot undo external effects or validate arbitrary code captures.
  """
  @fallback_to_any true
  @spec parents(struct(), Runic.Workflow.t(), Runic.Workflow.Runnable.t()) ::
          {:ok, [Runic.Workflow.Fact.t()]} | :unsupported
  def parents(node, workflow, runnable)
end

defimpl Runic.Workflow.CoordinatorParents, for: Any do
  def parents(_, _, _), do: :unsupported
end

defimpl Runic.Workflow.CoordinatorParents, for: Runic.Workflow.Join do
  def parents(join, workflow, _runnable),
    do: {:ok, Runic.Workflow.Join.pending_parents(join, workflow)}
end

defimpl Runic.Workflow.CoordinatorParents, for: Runic.Workflow.FanIn do
  def parents(fan_in, workflow, runnable),
    do: {:ok, Runic.Workflow.FanIn.pending_parents(fan_in, workflow, runnable.context)}
end
