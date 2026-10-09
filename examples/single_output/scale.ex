defmodule Runic.Examples.Scale do
  @moduledoc "A reconstructable, single-output component with application configuration."
  use Runic.Workflow.SingleOutput

  alias Runic.Workflow.SingleOutput.Result

  defstruct [:name, :hash, :factor]

  def new(name, factor) when is_number(factor) do
    %__MODULE__{
      name: name,
      factor: factor,
      hash: Runic.Identity.digest(:component_definition, {:scale, 1, name, factor})
    }
  end

  @impl true
  def run(node, value, _context) when is_number(value) do
    Result.value(value * node.factor, metadata: %{scale: %{factor: node.factor}})
  end

  def run(_node, _value, _context), do: Result.failure(:expected_number)
end
