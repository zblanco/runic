defimpl Runic.Workflow.Invokable, for: Runic.Test.SkippedNode do
  alias Runic.Workflow
  alias Runic.Workflow.{CausalContext, Runnable}
  alias Runic.Workflow.Events.ActivationConsumed

  def match_or_execute(_node), do: :execute

  def invoke(node, workflow, fact) do
    {:ok, runnable} = prepare(node, workflow, fact)
    Workflow.apply_runnable(workflow, execute(node, runnable))
  end

  def prepare(node, workflow, fact) do
    context = CausalContext.basic(node.hash, fact, Workflow.ancestry_depth(workflow, fact))
    {:ok, Runnable.new(node, fact, context)}
  end

  def execute(node, runnable) do
    Runnable.skip(runnable, [
      %ActivationConsumed{
        fact_hash: runnable.input_fact.hash,
        node_hash: node.hash,
        from_label: :runnable
      }
    ])
  end
end
