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
