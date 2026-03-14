defprotocol Runic.Workflow.Coordinator do
  @moduledoc """
  Optional protocol for nodes that need post-fold coordination.

  After `apply_event/2` has folded a runnable's events into the workflow,
  some node types need to inspect the updated graph to determine if a
  coordination step is complete (e.g. all Join branches satisfied, all
  FanIn items collected).

  Nodes that implement this protocol will have `finalize/3` called during
  `apply_runnable/2`. The callback receives the node, the current workflow
  (with events already folded), and the original runnable. It returns
  `{workflow, derived_events}` where `derived_events` have been folded
  into the returned workflow.

  Nodes that do **not** implement this protocol are assumed to need no
  coordination — `apply_runnable/2` skips the coordination step for them.

  ## Built-in Implementations

  - `Runic.Workflow.Join` — rechecks branch satisfaction after folding
    `JoinFactReceived` events, emits `JoinCompleted` + `JoinEdgeRelabeled`
    events when all branches are satisfied.

  - `Runic.Workflow.FanIn` — rechecks whether all fan-out items have been
    processed, emits `FanInCompleted` + sister `ActivationConsumed` events
    when ready.

  ## Example

      defimpl Runic.Workflow.Coordinator, for: MyApp.CustomCoordinationNode do
        def finalize(node, workflow, runnable) do
          # Check coordination condition, emit derived events if complete
          {workflow, []}
        end
      end
  """

  @doc """
  Post-fold coordination finalization.

  Called after all events from `execute/2` have been folded into the workflow.
  Returns `{workflow, derived_events}` where `derived_events` have already
  been folded into the returned workflow.
  """
  @spec finalize(
          node :: struct(),
          workflow :: Runic.Workflow.t(),
          runnable :: Runic.Workflow.Runnable.t()
        ) ::
          {Runic.Workflow.t(), [struct()]}
  def finalize(node, workflow, runnable)
end
