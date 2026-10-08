defimpl Runic.Workflow.Invokable, for: Runic.Test.DispatchProbe do
  alias Runic.Workflow
  alias Runic.Workflow.{CausalContext, Runnable}

  def match_or_execute(_node), do: :execute
  def invoke(_node, workflow, _fact), do: workflow

  def prepare(node, workflow, fact) do
    send(node.owner, {:prepared, node.hash, workflow.name})

    case node.mode do
      :ok ->
        {:ok, Runnable.new(node, fact, CausalContext.basic(node.hash, fact, 0))}

      mode when mode in [:skip, :defer] ->
        {mode,
         fn wf ->
           wf
           |> Workflow.mark_runnable_as_ran(node, fact)
           |> Map.put(:name, mode)
         end}
    end
  end

  def execute(_node, runnable), do: Runnable.complete(runnable, :ok, [])
end
