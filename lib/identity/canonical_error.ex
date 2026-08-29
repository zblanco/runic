defmodule Runic.Identity.CanonicalError do
  @moduledoc "Raised when a value cannot be represented by the canonical identity codec."

  defexception [:reason, path: []]

  @type t :: %__MODULE__{reason: term(), path: [term()]}

  @impl Exception
  def message(%__MODULE__{} = error) do
    "cannot canonically encode identity document at #{format_path(error.path)}: " <>
      format_reason(error.reason)
  end

  defp format_path([]), do: "$"

  defp format_path(path) do
    Enum.reduce(path, "$", fn segment, acc -> acc <> "[#{inspect(segment)}]" end)
  end

  defp format_reason({:unsupported, type}), do: "unsupported #{type} value"
  defp format_reason({:limit, name, value}), do: "#{name} limit exceeded (#{value})"
  defp format_reason(reason), do: inspect(reason)
end
