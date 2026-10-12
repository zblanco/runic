defmodule Runic.Examples.JidoFactBoundary do
  @moduledoc """
  Example data gate for the Jido local adapter. Check a fact before saving or
  remotely dispatching it. A scalar child of a local fact is still local.
  Jido keeps its input, output, schema, and effect checks.
  """

  def check(%{meta: %{jido: %{identity_mode: :local}}}, field) do
    {:error, %{field: field, path: [field], reason: :local_identity, retry: false}}
  end

  def check(fact, field), do: Jido.Exec.Portable.validate(fact.value, field)
end
