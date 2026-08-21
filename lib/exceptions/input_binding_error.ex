defmodule Runic.InputBindingError do
  @moduledoc "Raised when a data-driven input binding cannot project or assemble a value."

  defexception [:message, :connection, path: []]
end
