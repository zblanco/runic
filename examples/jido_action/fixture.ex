defmodule Runic.Examples.JidoActionFixture do
  @moduledoc false
  use Jido.Action,
    name: "single_output_add",
    schema: Zoi.object(%{value: Zoi.integer()})

  @impl true
  def run(%{value: value}, context) do
    if value < 0 do
      {:error, :negative}
    else
      {:ok, %{value: value + Map.get(context, :offset, 1)}, [:recorded]}
    end
  end
end
