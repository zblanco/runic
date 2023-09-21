defmodule Runic.Workflow.Join do
  alias Runic.Workflow.Components
  defstruct [:hash, :joins]

  def new(joins) when is_list(joins) do
    %__MODULE__{joins: joins, hash: Components.fact_hash(joins)}
  end
end
