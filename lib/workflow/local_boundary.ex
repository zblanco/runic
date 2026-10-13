defmodule Runic.Workflow.LocalBoundary do
  @moduledoc """
  Rejects native local facts, scopes, and identities before persistence or
  remote export. It does not certify arbitrary code or legacy projections.

  Custom remote executors must call check/2 on their dispatch envelope before
  sending it. Local Task, GenStage, and Flow execution can retain local facts.
  """
  alias Runic.Identity
  alias Runic.Workflow.{Fact, FactRef, LocalFactError, LocalScope}

  alias Runic.Workflow.Events.{
    FactProduced,
    StateInitiated,
    JoinCompleted,
    FanOutFactEmitted,
    FanInCompleted
  }

  @scope_records %{
    Fact => {:identity_mode, :local_scope, [:id, :hash, :payload_digest, :content_digest]},
    FactRef => {:identity_mode, :local_scope, [:id, :hash, :payload_digest, :content_digest]},
    FactProduced => {:identity_mode, :local_scope, [:hash, :payload_digest, :content_digest]},
    StateInitiated => {:init_identity_mode, :init_local_scope, [:init_fact_hash]},
    JoinCompleted => {:result_identity_mode, :result_local_scope, [:result_fact_hash]},
    FanOutFactEmitted =>
      {:emitted_identity_mode, :emitted_local_scope,
       [:emitted_fact_hash, :emitted_payload_digest, :emitted_content_digest]},
    FanInCompleted => {:result_identity_mode, :result_local_scope, [:result_fact_hash]}
  }

  def check(value, field), do: walk(value, [field])

  def check!(value, field) do
    case check(value, field) do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end

  @doc false
  def validate_current!(value, field), do: validate_scopes(value, [field])

  defp validate_scopes(%LocalScope{} = scope, path) do
    unless LocalScope.valid?(scope),
      do: raise(LocalFactError, field: hd(path), path: path, reason: :foreign_local_scope)

    :ok
  end

  defp validate_scopes(%module{} = record, path) when is_map_key(@scope_records, module) do
    {mode_key, scope_key, identities} = Map.fetch!(@scope_records, module)

    native? =
      Map.get(record, mode_key, :portable) == :local or
        Enum.any?(identities, &match?(%Identity{scheme: :local_sha256}, Map.get(record, &1)))

    if native? do
      cond do
        Map.get(record, mode_key) != :local ->
          raise LocalFactError,
            field: hd(path),
            path: path ++ [mode_key],
            reason: :invalid_local_profile

        is_nil(Map.get(record, scope_key)) ->
          raise LocalFactError,
            field: hd(path),
            path: path ++ [scope_key],
            reason: :missing_local_scope

        not LocalScope.valid?(Map.get(record, scope_key)) ->
          raise LocalFactError,
            field: hd(path),
            path: path ++ [scope_key],
            reason: :foreign_local_scope

        true ->
          :ok
      end
    end

    validate_scope_fields(record, path)
  end

  defp validate_scopes(value, path) when is_map(value), do: validate_scope_fields(value, path)

  defp validate_scopes(value, path) when is_tuple(value),
    do: value |> Tuple.to_list() |> validate_scopes(path)

  defp validate_scopes(value, path) when is_list(value), do: validate_scope_list(value, path, 0)
  defp validate_scopes(_, _), do: :ok

  defp validate_scope_list([], _, _), do: :ok

  defp validate_scope_list([head | tail], path, index) do
    validate_scopes(head, path ++ [index])

    if is_list(tail),
      do: validate_scope_list(tail, path, index + 1),
      else: validate_scopes(tail, path ++ [:tail])
  end

  defp validate_scope_fields(value, path) do
    Enum.each(Map.to_list(value), fn {key, item} ->
      validate_scopes(key, path ++ [:map_key])
      validate_scopes(item, path ++ [key])
    end)
  end

  defp walk(%Fact{identity_mode: :local}, path), do: reject(path ++ [:identity_mode], :local_fact)

  defp walk(%FactRef{identity_mode: :local}, path),
    do: reject(path ++ [:identity_mode], :local_fact)

  defp walk(%Identity{scheme: :local_sha256}, path), do: reject(path, :local_identity)
  defp walk(%LocalScope{}, path), do: reject(path, :local_scope)

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

  defp walk(value, path) when is_tuple(value), do: value |> Tuple.to_list() |> walk(path)
  defp walk(value, path) when is_list(value), do: walk_list(value, path, 0)
  defp walk(_, _), do: :ok
  defp walk_list([], _, _), do: :ok

  defp walk_list([value | rest], path, index) do
    with :ok <- walk(value, path ++ [index]) do
      if is_list(rest), do: walk_list(rest, path, index + 1), else: walk(rest, path ++ [:tail])
    end
  end

  defp reject([field | _] = path, reason),
    do: {:error, %LocalFactError{field: field, path: path, reason: reason}}
end
