defmodule Runic.Examples.JidoFactBoundary do
  @moduledoc """
  Example data gate for the full raw Jido Fact envelope. It checks nested local
  wrappers and every raw field, including metadata, before saving or remote
  dispatch. Jido keeps its input, output, schema, and effect checks.

  A native scalar output can lose the input's local marker. The consumer must
  retain an execution marker and use check_execution/3 for that execution.
  These data checks do not validate a workflow or its component definitions.
  """
  alias Jido.Exec.Fact.LocalValue

  def check(%{meta: %{jido: %{identity_mode: :local}}}, field) do
    reject([field], :local_identity)
  end

  def check(fact, field) do
    with :ok <- check_wrappers(fact, [field]) do
      case Jido.Exec.Portable.validate(fact, field) do
        :ok -> :ok
        {:error, %{details: %{path: path, type: type}}} -> reject(path, type)
      end
    end
  end

  def check_execution(%{identity_mode: :local}, _fact, field) do
    reject([field], :local_identity)
  end

  def check_execution(%{identity_mode: :portable}, fact, field), do: check(fact, field)

  def check_execution(_marker, _fact, field), do: reject([field], :unknown_identity_mode)

  defp check_wrappers(%LocalValue{}, path), do: reject(path, :local_identity)

  defp check_wrappers(value, path) when is_map(value) do
    value
    |> Map.to_list()
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {{key, item}, index}, :ok ->
      with :ok <- check_wrappers(key, path ++ [{:map_key, index}]),
           :ok <- check_wrappers(item, path ++ [key]) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp check_wrappers(value, path) when is_tuple(value) do
    value |> Tuple.to_list() |> check_wrappers(path)
  end

  defp check_wrappers(value, path) when is_list(value), do: check_list(value, path, 0)
  defp check_wrappers(_value, _path), do: :ok

  defp check_list([], _path, _index), do: :ok

  defp check_list([item | rest], path, index) do
    with :ok <- check_wrappers(item, path ++ [index]) do
      if is_list(rest),
        do: check_list(rest, path, index + 1),
        else: check_wrappers(rest, path ++ [:tail])
    end
  end

  defp reject([field | _] = path, type) do
    {:error, %{field: field, path: path, reason: {:unsupported, type}, retry: false}}
  end
end
