defmodule Runic.Workflow.Connection do
  @moduledoc """
  A durable named-port connection between two workflow components.

  Connections describe authored intent. `Runic.Workflow.add/3` validates a
  complete connection group and lowers it into executable flow nodes. The
  connection itself remains data and is stored on logical `:connects_to` edges
  and in `%Runic.Workflow.ComponentAdded{}` events.

  The compact keyword form accepted by `Runic.Workflow.add/3` is normalized
  into this struct:

      [from: {:orders, :order}, to: :order]

  Safe `:selector` and `:target_path` lists may contain atom, string, or
  non-negative integer segments. They never contain executable functions.
  """

  alias Runic.Workflow.Components

  @type component_ref :: atom() | String.t() | non_neg_integer() | {atom() | String.t(), atom()}
  @type port_name :: atom()
  @type path_segment :: atom() | String.t() | non_neg_integer()
  @type connection_id :: atom() | String.t() | non_neg_integer()

  @type t :: %__MODULE__{
          id: connection_id(),
          source: component_ref(),
          source_port: port_name(),
          target: component_ref(),
          target_port: port_name(),
          selector: list(path_segment()),
          target_path: list(path_segment())
        }

  @enforce_keys [:id, :source, :source_port, :target, :target_port]
  defstruct [:id, :source, :source_port, :target, :target_port, selector: [], target_path: []]

  @doc false
  @spec normalize_all!(list(), struct()) :: [t()]
  def normalize_all!(connections, target) when is_list(connections) and connections != [] do
    target_ref = durable_ref(target)

    Enum.map(connections, &normalize!(&1, target_ref))
  end

  def normalize_all!(connections, _target) do
    raise ArgumentError,
          ":connections must be a non-empty list, got: #{inspect(connections)}"
  end

  @doc false
  @spec normalize!(t() | map() | keyword(), component_ref()) :: t()
  def normalize!(%__MODULE__{target: target} = connection, target),
    do: validate_connection!(connection)

  def normalize!(%__MODULE__{target: connection_target}, target) do
    raise ArgumentError,
          "connection targets #{inspect(connection_target)}, but it was supplied while adding #{inspect(target)}"
  end

  def normalize!(connection, target) when is_list(connection) or is_map(connection) do
    spec = if is_list(connection), do: Map.new(connection), else: connection
    {source, source_port} = normalize_source!(fetch!(spec, :from), spec)
    target_port = Map.get(spec, :to) || Map.get(spec, :target_port)

    selector = normalize_path!(Map.get(spec, :selector, []), :selector)
    target_path = normalize_path!(Map.get(spec, :target_path, []), :target_path)
    source = durable_ref(source)

    id =
      Map.get(spec, :id) ||
        Components.fact_hash({source, source_port, target, target_port, selector, target_path})

    validate_connection!(%__MODULE__{
      id: id,
      source: source,
      source_port: source_port,
      target: target,
      target_port: target_port,
      selector: selector,
      target_path: target_path
    })
  end

  def normalize!(connection, _target) do
    raise ArgumentError,
          "connection must be a keyword list, map, or Connection struct, got: #{inspect(connection)}"
  end

  defp normalize_source!({source, source_port}, _spec), do: {source, source_port}

  defp normalize_source!(source, spec) do
    case Map.get(spec, :source_port) do
      nil ->
        raise ArgumentError,
              "connection from #{inspect(source)} must declare :source_port or use from: {source, port}"

      source_port ->
        {source, source_port}
    end
  end

  defp normalize_path!(path, _field) when is_list(path) do
    if Enum.all?(path, &path_segment?/1) do
      path
    else
      raise ArgumentError,
            "connection paths support only atom, string, and non-negative integer segments"
    end
  end

  defp normalize_path!(path, field) do
    raise ArgumentError, "connection #{field} must be a list, got: #{inspect(path)}"
  end

  defp path_segment?(segment),
    do: is_atom(segment) or is_binary(segment) or (is_integer(segment) and segment >= 0)

  defp validate_connection!(%__MODULE__{} = connection) do
    unless is_atom(connection.source_port) do
      raise ArgumentError,
            "source port must be an atom, got: #{inspect(connection.source_port)}"
    end

    unless is_atom(connection.target_port) do
      raise ArgumentError,
            "target port must be an atom, got: #{inspect(connection.target_port)}"
    end

    normalize_path!(connection.selector, :selector)
    normalize_path!(connection.target_path, :target_path)

    unless is_atom(connection.id) or is_binary(connection.id) or
             (is_integer(connection.id) and connection.id >= 0) do
      raise ArgumentError,
            "connection id must be an atom, string, or non-negative integer, got: #{inspect(connection.id)}"
    end

    connection
  end

  defp fetch!(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "connection is missing required #{inspect(key)}"
    end
  end

  defp durable_ref(%{name: name}) when not is_nil(name), do: name
  defp durable_ref(%{hash: hash}) when not is_nil(hash), do: hash
  defp durable_ref(reference), do: reference
end
