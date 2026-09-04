defmodule Runic.Identity.IntegrityError do
  @moduledoc "Raised when content does not reproduce its declared Runic identity."

  defexception [:expected, :actual]

  @type t :: %__MODULE__{expected: Runic.Identity.t(), actual: Runic.Identity.t()}

  @impl Exception
  def message(%__MODULE__{} = error) do
    "Runic identity verification failed: expected #{Runic.Identity.short_string(error.expected)}, " <>
      "got #{Runic.Identity.short_string(error.actual)}"
  end
end
