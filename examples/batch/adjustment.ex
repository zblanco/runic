defmodule Runic.Examples.Batch.Adjustment do
  @moduledoc "A small price adjustment component. Runic owns its batch coordination."
  use Runic.Workflow.SingleOutput
  alias Runic.Workflow.SingleOutput.Result
  defstruct [:name, :hash]

  def new(name) do
    %__MODULE__{
      name: name,
      hash: Runic.Identity.derive(:component_definition, [:adjustment, name])
    }
  end

  @impl true
  def run(_component, price, context) when is_number(price) do
    Result.value(price + context.batch.parent.adjustment)
  end

  def run(_component, _price, _context), do: Result.failure(:invalid_price)
end
