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
    {:error, %{field: field, path: [field], reason: :local_identity, retry: false}}
  end

  def check(fact, field) do
    with :ok <- check_wrappers(fact, [field]) do
      Jido.Exec.Portable.validate(fact, field)
    end
  end

  def check_execution(%{identity_mode: :local}, _fact, field) do
    {:error, %{field: field, path: [field], reason: :local_identity, retry: false}}
  end

  def check_execution(%{identity_mode: :portable}, fact, field), do: check(fact, field)

  defp check_wrappers(%LocalValue{}, [field | _] = path) do
    {:error, %{field: field, path: path, reason: :local_identity, retry: false}}
  end

  defp check_wrappers(value, path) when is_map(value) do
    Enum.reduce_while(Map.to_list(value), :ok, fn {key, item}, :ok ->
      with :ok <- check_wrappers(key, path ++ [:key]),
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
end
