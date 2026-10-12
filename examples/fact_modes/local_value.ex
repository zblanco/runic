defmodule Runic.Examples.LocalValue do
  @moduledoc """
  A consumer wrapper for a value used in one live VM. This is example code.

  The digest identifies the term in this VM. It does not identify a portable
  payload. Keep the wrapper through each local stage. Do not save or send it
  through a remote executor, even if its value has become a scalar.
  """
  @enforce_keys [:value, :digest]
  defstruct [:value, :digest]

  def new(value) do
    %__MODULE__{
      value: value,
      digest: :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
    }
  end

  def map(%__MODULE__{value: value}, work), do: new(work.(value))
end
