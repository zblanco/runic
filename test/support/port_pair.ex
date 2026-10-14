defmodule Runic.TestSupport.PortPair do
  @moduledoc false
  require Runic
  defstruct [:hash, :name, :left, :right, :inputs, :outputs]

  def new(name) do
    left = %{Runic.step(fn n -> n + 1 end, name: :left) | name: "#{name}/left"}
    right = %{Runic.step(fn n -> n * 2 end, name: :right) | name: "#{name}/right"}

    %__MODULE__{
      name: name,
      hash: Runic.Identity.digest(:component_definition, {__MODULE__, name}),
      left: left,
      right: right,
      inputs: [in: [type: :integer]],
      outputs: [
        left: [type: :integer, from: left.name],
        right: [type: :integer, from: right.name]
      ]
    }
  end
end
