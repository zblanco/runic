defmodule Runic.Workflow.Batch.Result do
  @moduledoc "A completed batch, with shared parent data and ordered terminal item outcomes."
  @enforce_keys [:id, :outcomes]
  defstruct [:id, :parent, :outcomes]
end

defimpl Runic.Identity.Projectable, for: Runic.Workflow.Batch.Result do
  def identity_document(value), do: %{version: 1, fields: Map.from_struct(value)}
end
