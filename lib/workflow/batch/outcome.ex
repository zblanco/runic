defmodule Runic.Workflow.Batch.Outcome do
  @moduledoc "One batch item outcome in input order. Identity includes the batch invocation."
  @enforce_keys [:id, :batch_id, :index, :status]
  defstruct [:id, :batch_id, :index, :status, :value, :error]
  @doc false
  def project_error(%{__exception__: true} = exception) when is_struct(exception) do
    {:exception, exception.__struct__, project_error(Map.from_struct(exception))}
  end

  def project_error(error) when is_tuple(error),
    do: {:tuple, error |> Tuple.to_list() |> Enum.map(&project_error/1)}

  def project_error(error) when is_list(error), do: {:list, Enum.map(error, &project_error/1)}

  def project_error(error) when is_map(error) and not is_struct(error),
    do: {:map, Map.new(error, fn {key, value} -> {project_error(key), project_error(value)} end)}

  def project_error(error), do: {:value, error}
end

defimpl Runic.Identity.Projectable, for: Runic.Workflow.Batch.Outcome do
  def identity_document(value) do
    fields = Map.from_struct(value)

    error = Runic.Workflow.Batch.Outcome.project_error(value.error)

    %{version: 1, fields: Map.put(fields, :error, error)}
  end
end
