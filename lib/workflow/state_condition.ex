defmodule Runic.Workflow.StateCondition do
  defstruct [:hash, :work, :state_hash]

  def new(work, state_hash, hash) do
    %__MODULE__{
      state_hash: state_hash,
      work: work,
      hash: hash
    }
  end
end

defimpl Runic.Workflow.Activator, for: Runic.Workflow.StateCondition do
  alias Runic.Workflow
  alias Runic.Workflow.Runnable
  alias Runic.Workflow.Private

  def activate_downstream(%Runic.Workflow.StateCondition{} = node, %Workflow{} = wf, %Runnable{
        result: true,
        input_fact: fact
      }) do
    Private.activate_downstream_with_events(wf, node, fact)
  end

  def activate_downstream(%Runic.Workflow.StateCondition{}, %Workflow{} = wf, %Runnable{}),
    do: {wf, []}
end
