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
    StateInitiated =>
      {:init_identity_mode, :init_local_scope, [:init_fact_hash, :init_payload_digest]},
    JoinCompleted =>
      {:result_identity_mode, :result_local_scope, [:result_fact_hash, :result_payload_digest]},
    FanOutFactEmitted =>
      {:emitted_identity_mode, :emitted_local_scope,
       [:emitted_fact_hash, :emitted_payload_digest, :emitted_content_digest]},
    FanInCompleted =>
      {:result_identity_mode, :result_local_scope, [:result_fact_hash, :result_payload_digest]}
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

  @doc false
  def validate_profile!(%module{} = record, field) when is_map_key(@scope_records, module),
    do: validate_record(record, [field], false)

  def validate_profile!(_, _), do: :ok

  @doc false
  def validate_profiles!(value, field), do: validate_profiles(value, [field])

  defp validate_profiles(%module{} = record, path) when is_map_key(@scope_records, module),
    do: validate_record(record, path, false)

  defp validate_profiles(%LocalScope{} = scope, path), do: validate_scopes(scope, path)

  defp validate_profiles(value, path) when is_map(value) do
    Enum.each(Map.to_list(value), fn {key, item} -> validate_profiles(item, path ++ [key]) end)
  end

  defp validate_profiles(value, path) when is_list(value),
    do:
      value
      |> Enum.with_index()
      |> Enum.each(fn {item, index} -> validate_profiles(item, path ++ [index]) end)

  defp validate_profiles(value, path) when is_tuple(value),
    do: value |> Tuple.to_list() |> validate_profiles(path)

  defp validate_profiles(_, _), do: :ok

  @doc false
  def validate_event!(workflow, %module{} = event) when is_map_key(@scope_records, module) do
    {mode_key, scope_key, _} = Map.fetch!(@scope_records, module)
    validate_profile!(event, :event)

    if Map.get(event, mode_key, :portable) == :local do
      ancestry =
        Map.get(event, :ancestry) || Map.get(event, :init_ancestry) ||
          Map.get(event, :result_ancestry) || Map.get(event, :emitted_ancestry)

      parent =
        case ancestry do
          {_, hash} -> Map.get(workflow.graph.vertices, hash)
          _ -> nil
        end

      parents = [parent | event_parents(workflow, event)] |> Enum.reject(&is_nil/1)
      local_parents = Enum.filter(parents, &(Map.get(&1, :identity_mode, :portable) == :local))

      case Fact.check_parents(local_parents) do
        :ok -> :ok
        {:error, error} -> raise error
      end

      if Enum.any?(local_parents, &(Map.get(&1, :local_scope) != Map.get(event, scope_key))),
        do:
          raise(LocalFactError,
            field: :event,
            path: [:event, scope_key],
            reason: :local_parent_scope_mismatch
          )
    end

    :ok
  end

  def validate_event!(_, _), do: :ok

  defp event_parents(workflow, %JoinCompleted{join_hash: hash}) do
    case Map.get(workflow.graph.vertices, hash) do
      %Runic.Workflow.Join{} = join -> Runic.Workflow.Join.pending_parents(join, workflow)
      _ -> []
    end
  end

  defp event_parents(workflow, %FanInCompleted{seen_key: key}),
    do:
      workflow.mapped
      |> Map.get(key, %{})
      |> Map.values()
      |> Enum.map(&Map.get(workflow.graph.vertices, &1))

  defp event_parents(_, _), do: []

  defp validate_scopes(%LocalScope{} = scope, path) do
    unless LocalScope.valid?(scope),
      do: raise(LocalFactError, field: hd(path), path: path, reason: :foreign_local_scope)

    :ok
  end

  defp validate_scopes(%module{} = record, path) when is_map_key(@scope_records, module) do
    validate_record(record, path, true)
    validate_scope_fields(record, path)
  end

  defp validate_scopes(value, path) when is_map(value), do: validate_scope_fields(value, path)

  defp validate_scopes(value, path) when is_tuple(value),
    do: value |> Tuple.to_list() |> validate_scopes(path)

  defp validate_scopes(value, path) when is_list(value), do: validate_scope_list(value, path, 0)
  defp validate_scopes(_, _), do: :ok

  defp validate_record(%module{} = record, path, verify_payload?) do
    {mode_key, scope_key, identities} = Map.fetch!(@scope_records, module)

    native? =
      Map.get(record, mode_key, :portable) == :local or
        not is_nil(Map.get(record, scope_key)) or
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

      {payload_key, value_key} =
        case module do
          Fact -> {:payload_digest, :value}
          FactProduced -> {:payload_digest, :value}
          StateInitiated -> {:init_payload_digest, :init_value}
          JoinCompleted -> {:result_payload_digest, :result_value}
          FanInCompleted -> {:result_payload_digest, :result_value}
          FanOutFactEmitted -> {:emitted_payload_digest, :emitted_value}
          _ -> {nil, nil}
        end

      if payload_key && is_nil(Map.get(record, payload_key)),
        do:
          raise(LocalFactError,
            field: hd(path),
            path: path ++ [payload_key],
            reason: :missing_local_payload
          )

      if payload_key &&
           not match?(
             %Identity{scheme: :local_sha256, domain: :payload, version: 1, digest: digest}
             when is_binary(digest) and byte_size(digest) == 32,
             Map.get(record, payload_key)
           ),
         do:
           raise(LocalFactError,
             field: hd(path),
             path: path ++ [payload_key],
             reason: :invalid_local_profile
           )

      if verify_payload? && payload_key && Map.get(record, payload_key) &&
           Map.get(record, payload_key) !=
             Fact.local_payload_digest(Map.get(record, value_key), Map.get(record, scope_key)),
         do:
           raise(LocalFactError,
             field: hd(path),
             path: path ++ [payload_key],
             reason: :local_identity_mismatch
           )
    end

    :ok
  end

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
