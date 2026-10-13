defmodule Runic.Examples.FactBoundary do
  @moduledoc """
  A consumer gate for saved or remotely dispatched data. This is example code.

  Check raw fields before a Store write or remote dispatch. Identity projection
  alone cannot make this check: a projection can omit live values. This gate
  also rejects the example wrapper, including wrappers of scalar values.

  This small profile accepts canonical values after it checks raw fields.
  Production consumers must also check their code, captured bindings, policies,
  metadata, and transport schema. Do not use it to validate a workflow graph.
  """
  alias Runic.Examples.LocalValue
  alias Runic.Identity.{Canonical, CanonicalError}

  def check(value, field) do
    with :ok <- walk(value, [field]) do
      Canonical.encode!(value)
      :ok
    end
  rescue
    error in CanonicalError ->
      {:error, %{field: field, path: [field | error.path], reason: error.reason, retry: false}}
  end

  defp walk(%LocalValue{}, path), do: reject(path, :local_identity)
  defp walk(value, path) when is_pid(value), do: reject(path, :pid)
  defp walk(value, path) when is_port(value), do: reject(path, :port)
  defp walk(value, path) when is_reference(value), do: reject(path, :reference)
  defp walk(value, path) when is_function(value), do: reject(path, :function)

  defp walk(value, path) when is_map(value) do
    value
    |> Map.to_list()
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {{key, item}, index}, :ok ->
      with :ok <- walk(key, path ++ [{:map_key, index}]),
           :ok <- walk(item, path ++ [key]) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp walk(value, path) when is_tuple(value) do
    value |> Tuple.to_list() |> walk(path)
  end

  defp walk(value, path) when is_list(value), do: walk_list(value, path, 0)
  defp walk(_value, _path), do: :ok

  defp walk_list([], _path, _index), do: :ok

  defp walk_list([item | rest], path, index) do
    with :ok <- walk(item, path ++ [index]) do
      if is_list(rest) do
        walk_list(rest, path, index + 1)
      else
        with :ok <- walk(rest, path ++ [:tail]) do
          reject(path ++ [:tail], :improper_list)
        end
      end
    end
  end

  defp reject([field | _] = path, type) do
    {:error, %{field: field, path: path, reason: {:unsupported, type}, retry: false}}
  end
end
