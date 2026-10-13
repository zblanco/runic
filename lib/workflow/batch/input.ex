defmodule Runic.Workflow.Batch.Input do
  @moduledoc "A batch input. `parent` belongs to the source Fact, separate from each item."
  @enforce_keys [:items]
  defstruct [:items, parent: nil]
end

defimpl Runic.Identity.Projectable, for: Runic.Workflow.Batch.Input do
  def identity_document(value), do: %{version: 1, fields: Map.from_struct(value)}
end
