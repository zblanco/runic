defmodule Runic.Examples.JidoNativeFixture do
  @moduledoc false
  use Jido.Action,
    name: "native_local_echo",
    schema: Zoi.object(%{value: Zoi.integer(), token: Zoi.any()}),
    output_schema: Zoi.object(%{value: Zoi.integer(), token: Zoi.any()})

  @impl true
  def run(%{value: value, token: token}, _context) do
    if value < 0,
      do: {:error, :negative},
      else: {:ok, %{value: value + 1, token: token}, [:recorded]}
  end
end
