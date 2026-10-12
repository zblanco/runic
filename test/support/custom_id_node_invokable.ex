defimpl Runic.Workflow.Invokable, for: Runic.Test.CustomIdNode do
  alias Runic.Workflow
  alias Runic.Workflow.{CausalContext, Runnable}

  def match_or_execute(_node), do: :execute

  def invoke(node, workflow, fact) do
    {:ok, runnable} = prepare(node, workflow, fact)
    Workflow.apply_runnable(workflow, execute(node, runnable))
  end

  def prepare(node, workflow, fact) do
    context = CausalContext.basic(node.hash, fact, Workflow.ancestry_depth(workflow, fact))
    {:ok, Runnable.new(node.id, node, fact, context)}
  end

  def execute(node, runnable) do
    send(node.owner, {:custom_started, node.name})
    Runnable.fail(runnable, :custom_failure)
  end
end
