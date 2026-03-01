defmodule Runic.Workflow.MemoryAssertion do
  alias Runic.Workflow.Components
  defstruct [:memory_assertion, :hash, :state_hash]

  def new(opts) do
    struct!(__MODULE__, opts)
  end

  def new(memory_assertion, state_hash) do
    %__MODULE__{
      state_hash: state_hash,
      memory_assertion: memory_assertion,
      hash: Components.work_hash(memory_assertion)
    }
  end
end

defimpl Runic.Workflow.Activator, for: Runic.Workflow.MemoryAssertion do
  alias Runic.Workflow
  alias Runic.Workflow.Runnable
  alias Runic.Workflow.Private

  def activate_downstream(%Runic.Workflow.MemoryAssertion{} = node, %Workflow{} = wf, %Runnable{
        result: true,
        input_fact: fact
      }) do
    Private.activate_downstream_with_events(wf, node, fact)
  end

  def activate_downstream(%Runic.Workflow.MemoryAssertion{}, %Workflow{} = wf, %Runnable{}),
    do: {wf, []}
end
