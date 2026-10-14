defmodule Runic.TestSupport.CoordinateComponent do
  @moduledoc false
  use Runic.Workflow.SingleOutput, batch_parent: false

  alias Runic.Workflow.SingleOutput.Result

  defstruct [:hash, :name]

  def new(name) do
    %__MODULE__{
      name: name,
      hash: Runic.Identity.digest(:component_definition, {__MODULE__, name})
    }
  end

  @impl true
  def run(_node, value, context) do
    Result.value(%{value: value, index: context.batch.index})
  end
end
