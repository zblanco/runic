defmodule Runic.Workflow.InputBinding do
  @moduledoc """
  Internal, serializable lowering node for named component-port connections.

  An input binding projects safe paths from ordinary domain values and assembles
  the target's declared input shape. It is an invokable compiler artifact, not
  a registered user-authored component.
  """

  alias Runic.Workflow.Components

  @type binding :: %{
          id: Runic.Workflow.Connection.connection_id(),
          source_hash: term(),
          source_port: atom(),
          source_port_index: non_neg_integer(),
          source_port_count: pos_integer(),
          target_port: atom(),
          selector: list(),
          target_path: list()
        }

  @type t :: %__MODULE__{
          hash: non_neg_integer(),
          target_component_hash: term(),
          source_order: list(term()),
          bindings: list(binding()),
          input_ports: keyword()
        }

  @enforce_keys [:hash, :target_component_hash, :source_order, :bindings, :input_ports]
  defstruct [:hash, :target_component_hash, :source_order, :bindings, :input_ports]

  @spec new(keyword()) :: t()
  def new(opts) do
    target_component_hash = Keyword.fetch!(opts, :target_component_hash)
    source_order = Keyword.fetch!(opts, :source_order)
    bindings = Keyword.fetch!(opts, :bindings)
    input_ports = Keyword.fetch!(opts, :input_ports)

    hash =
      Components.fact_hash(
        {__MODULE__, target_component_hash, source_order, bindings, input_ports}
      )

    %__MODULE__{
      hash: hash,
      target_component_hash: target_component_hash,
      source_order: source_order,
      bindings: bindings,
      input_ports: input_ports
    }
  end

  @spec bind(t(), term()) :: term()
  def bind(%__MODULE__{} = binding, input) do
    source_values = source_values(binding.source_order, input)

    values_by_port =
      Enum.reduce(binding.bindings, %{}, fn connection, acc ->
        source_value = Map.fetch!(source_values, connection.source_hash)

        value =
          source_value
          |> project_port(connection)
          |> select_path(connection.selector, connection)

        put_target_value(acc, connection.target_port, connection.target_path, value, connection)
      end)

    ordered_values =
      Enum.map(binding.input_ports, fn {port, _schema} -> Map.get(values_by_port, port) end)

    case ordered_values do
      [value] -> value
      values -> values
    end
  end

  @doc false
  @spec fact_meta(t()) :: map()
  def fact_meta(%__MODULE__{} = binding) do
    sources =
      Enum.map(binding.bindings, fn source_binding ->
        Map.take(source_binding, [
          :id,
          :source_hash,
          :source_port,
          :target_port,
          :selector,
          :target_path
        ])
      end)

    %{runic: %{input_bindings: sources}}
  end

  defp source_values([source_hash], input), do: %{source_hash => input}

  defp source_values(source_order, input) when is_list(input) do
    if length(source_order) == length(input) do
      Map.new(Enum.zip(source_order, input))
    else
      binding_error!(
        "input binding expected #{length(source_order)} joined values, got #{length(input)}",
        nil,
        []
      )
    end
  end

  defp source_values(source_order, input) do
    binding_error!(
      "input binding expected joined values for #{length(source_order)} sources, got: #{inspect(input)}",
      nil,
      []
    )
  end

  defp project_port(value, %{source_port_count: 1}), do: value

  defp project_port(value, connection) do
    fetch_segment(value, connection.source_port, connection.source_port_index, connection)
  end

  defp select_path(value, path, connection) do
    Enum.reduce(path, value, fn segment, current ->
      fetch_segment(current, segment, segment, connection)
    end)
  end

  defp fetch_segment(value, segment, _position, connection) when is_map(value) do
    selected =
      case Map.fetch(value, segment) do
        {:ok, selected} ->
          {:ok, selected}

        :error when is_atom(segment) ->
          Map.fetch(value, Atom.to_string(segment))

        :error ->
          :error
      end

    case selected do
      {:ok, result} -> result
      :error -> missing_segment!(value, segment, connection)
    end
  end

  defp fetch_segment(value, segment, _position, connection)
       when is_list(value) and is_atom(segment) do
    case Keyword.fetch(value, segment) do
      {:ok, selected} -> selected
      :error -> missing_segment!(value, segment, connection)
    end
  end

  defp fetch_segment(value, _segment, position, connection)
       when is_list(value) and is_integer(position) do
    case Enum.fetch(value, position) do
      {:ok, selected} -> selected
      :error -> missing_segment!(value, position, connection)
    end
  end

  defp fetch_segment(value, _segment, position, _connection)
       when is_tuple(value) and is_integer(position) and position >= 0 and
              position < tuple_size(value),
       do: elem(value, position)

  defp fetch_segment(value, segment, _position, connection),
    do: missing_segment!(value, segment, connection)

  defp missing_segment!(value, segment, connection) do
    binding_error!(
      "cannot read segment #{inspect(segment)} from #{inspect(value)} for connection #{inspect(connection.id)}",
      connection,
      [segment]
    )
  end

  defp put_target_value(acc, port, [], value, connection) do
    if Map.has_key?(acc, port) do
      binding_error!("target port #{inspect(port)} is assigned more than once", connection, [])
    end

    Map.put(acc, port, value)
  end

  defp put_target_value(acc, port, path, value, connection) do
    current = Map.get(acc, port, container_for(path))
    Map.put(acc, port, put_path(current, path, value, connection))
  end

  defp put_path(_current, [], value, _connection), do: value

  defp put_path(current, [segment | rest], value, connection)
       when is_atom(segment) or is_binary(segment) do
    map = if is_nil(current), do: %{}, else: current

    unless is_map(map) do
      binding_error!(
        "target path requires a map at #{inspect(segment)}, got: #{inspect(map)}",
        connection,
        [segment | rest]
      )
    end

    child = Map.get(map, segment, container_for(rest))
    Map.put(map, segment, put_path(child, rest, value, connection))
  end

  defp put_path(current, [segment | rest], value, connection)
       when is_integer(segment) and segment >= 0 do
    list = if is_nil(current), do: [], else: current

    unless is_list(list) do
      binding_error!(
        "target path requires a list at index #{segment}, got: #{inspect(list)}",
        connection,
        [segment | rest]
      )
    end

    list = pad_list(list, segment + 1)

    child =
      case Enum.fetch(list, segment) do
        {:ok, nil} -> container_for(rest)
        {:ok, existing} -> existing
      end

    List.replace_at(list, segment, put_path(child, rest, value, connection))
  end

  defp container_for([]), do: nil
  defp container_for([segment | _]) when is_integer(segment), do: []
  defp container_for(_path), do: %{}

  defp pad_list(list, size) do
    list ++ List.duplicate(nil, max(size - length(list), 0))
  end

  defp binding_error!(message, connection, path) do
    raise Runic.InputBindingError, message: message, connection: connection, path: path
  end
end
