defimpl Runic.Identity.Projectable, for: Runic.Closure do
  def identity_document(closure) do
    %{
      kind: :closure,
      version: 1,
      source: closure.source,
      bindings: project_bindings(closure.bindings)
    }
  end

  defp project_bindings(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {key, value} -> {key, project_binding(value)} end)
  end

  defp project_binding(function) when is_function(function) do
    info = Function.info(function)

    case Keyword.fetch!(info, :type) do
      :external ->
        {:mfa, Keyword.fetch!(info, :module), Keyword.fetch!(info, :name),
         Keyword.fetch!(info, :arity)}

      :local ->
        function
    end
  end

  defp project_binding(list) when is_list(list), do: Enum.map(list, &project_binding/1)

  defp project_binding(tuple) when is_tuple(tuple) do
    # Preserve the distinction between literal tuple data and MFA references.
    {:tuple, tuple |> Tuple.to_list() |> Enum.map(&project_binding/1)}
  end

  defp project_binding(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {key, value} -> {project_binding(key), project_binding(value)} end)
  end

  defp project_binding(value), do: value
end
