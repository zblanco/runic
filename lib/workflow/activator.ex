defprotocol Runic.Workflow.Activator do
  @moduledoc """
  Optional protocol for nodes with custom downstream activation patterns.

  After coordination finalization (if any), `apply_runnable/2` needs to
  activate downstream nodes. Most node types use the default pattern:
  find `:flow` successors and draw activation edges from the result fact.

  Some node types have non-standard activation patterns:

  - **FanOut** emits multiple facts, each activating all downstream nodes
  - **Condition/Conjunction/StateCondition/MemoryAssertion** activate via
    `prepare_next_runnables` after a satisfied match

  Nodes that implement this protocol override the default activation logic.
  Nodes that do **not** implement it get the standard single-fact activation.

  ## Return Value

  Implementations must return `{workflow, activation_events}` where
  `activation_events` is a list of `RunnableActivated` events that were
  folded into the workflow. This allows `apply_runnable/2` to capture
  activation edges in the event stream for replay correctness.

  ## Example

      defimpl Runic.Workflow.Activator, for: MyApp.CustomBroadcastNode do
        def activate_downstream(node, workflow, runnable) do
          # Custom multi-target activation logic
          Runic.Workflow.Private.activate_downstream_with_events(workflow, node, fact)
        end
      end
  """

  @doc """
  Activates downstream nodes after a runnable completes.

  Receives the node, the current workflow, and the completed runnable.
  Returns `{workflow, activation_events}` — the updated workflow with
  activation edges drawn and the list of `RunnableActivated` events produced.
  """
  @spec activate_downstream(
          node :: struct(),
          workflow :: Runic.Workflow.t(),
          runnable :: Runic.Workflow.Runnable.t()
        ) ::
          {Runic.Workflow.t(), [Runic.Workflow.Events.RunnableActivated.t()]}
  def activate_downstream(node, workflow, runnable)
end
