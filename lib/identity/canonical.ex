defmodule Runic.Identity.Canonical do
  @moduledoc """
  Restricted deterministic encoding used by Runic identity scheme version 1.

  The format uses explicit type tags and length framing. Map entries are sorted
  by their encoded key bytes, making identity independent of map construction
  order and BEAM map iteration order. Process-local and executable terms are
  rejected rather than assigned misleading portable identities.
  """

  import Bitwise

  alias Runic.Identity
  alias Runic.Identity.CanonicalError

  @default_max_depth 64
  @default_max_items 100_000
  @default_max_bytes 16 * 1024 * 1024

  @type option ::
          {:max_depth, pos_integer()}
          | {:max_items, pos_integer()}
          | {:max_bytes, pos_integer()}

  @doc "Encodes an identity-safe value into canonical version 1 bytes."
  @spec encode!(term(), [option()]) :: binary()
  def encode!(term, opts \\ []) do
    limits = %{
      max_depth: Keyword.get(opts, :max_depth, @default_max_depth),
      max_items: Keyword.get(opts, :max_items, @default_max_items),
      max_bytes: Keyword.get(opts, :max_bytes, @default_max_bytes)
    }

    {encoded, items} = encode(term, [], 0, limits)

    if items > limits.max_items do
      raise CanonicalError, reason: {:limit, :item_count, items}
    end

    if byte_size(encoded) > limits.max_bytes do
      raise CanonicalError, reason: {:limit, :byte_size, byte_size(encoded)}
    end

    encoded
  end

  defp encode(_term, path, depth, %{max_depth: max_depth}) when depth > max_depth do
    raise CanonicalError, reason: {:limit, :depth, depth}, path: Enum.reverse(path)
  end

  defp encode(nil, _path, _depth, _limits), do: {<<0x00>>, 1}
  defp encode(false, _path, _depth, _limits), do: {<<0x01>>, 1}
  defp encode(true, _path, _depth, _limits), do: {<<0x02>>, 1}

  defp encode(integer, _path, _depth, _limits) when is_integer(integer) do
    {frame(0x10, Integer.to_string(integer)), 1}
  end

  defp encode(float, path, _depth, _limits) when is_float(float) do
    <<bits::unsigned-64>> = <<float::float-64>>
    exponent = bits >>> 52 &&& 0x7FF

    if exponent == 0x7FF do
      raise CanonicalError, reason: {:unsupported, :non_finite_float}, path: Enum.reverse(path)
    end

    {<<0x11, bits::unsigned-64>>, 1}
  end

  defp encode(binary, _path, _depth, _limits) when is_binary(binary) do
    {frame(0x20, binary), 1}
  end

  defp encode(atom, _path, _depth, _limits) when is_atom(atom) do
    {frame(0x21, Atom.to_string(atom)), 1}
  end

  defp encode(%Identity{} = identity, _path, _depth, _limits) do
    {frame(0x40, Identity.to_binary(identity)), 1}
  end

  defp encode(%module{} = value, path, depth, limits) do
    document =
      try do
        Runic.Identity.Projectable.identity_document(value)
      rescue
        Protocol.UndefinedError ->
          raise CanonicalError, reason: {:unsupported, module}, path: Enum.reverse(path)
      end

    {encoded, items} = encode({module, document}, path, depth, limits)
    {frame(0x41, encoded), items}
  end

  defp encode(list, path, depth, limits) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.map_reduce(1, fn {value, index}, items ->
      {encoded, child_items} = encode(value, [index | path], depth + 1, limits)
      next_items = items + child_items
      ensure_item_limit!(next_items, [index | path], limits)
      {encoded, next_items}
    end)
    |> then(fn {encoded, items} -> {sequence(0x30, encoded), items} end)
  end

  defp encode(tuple, path, depth, limits) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.map_reduce(1, fn {value, index}, items ->
      {encoded, child_items} = encode(value, [index | path], depth + 1, limits)
      next_items = items + child_items
      ensure_item_limit!(next_items, [index | path], limits)
      {encoded, next_items}
    end)
    |> then(fn {encoded, items} -> {sequence(0x31, encoded), items} end)
  end

  defp encode(map, path, depth, limits) when is_map(map) and not is_struct(map) do
    map
    |> Enum.map(fn {key, value} ->
      {encoded_key, key_items} = encode(key, [:key | path], depth + 1, limits)
      {encoded_value, value_items} = encode(value, [key | path], depth + 1, limits)
      {encoded_key, encoded_value, key_items + value_items}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_reduce(1, fn {key, value, child_items}, items ->
      next_items = items + child_items
      ensure_item_limit!(next_items, path, limits)
      {sequence(0x32, [key, value]), next_items}
    end)
    |> then(fn {entries, items} -> {sequence(0x33, entries), items} end)
  end

  defp encode(term, path, _depth, _limits) do
    type =
      cond do
        is_function(term) -> :function
        is_pid(term) -> :pid
        is_port(term) -> :port
        is_reference(term) -> :reference
        true -> :term
      end

    raise CanonicalError, reason: {:unsupported, type}, path: Enum.reverse(path)
  end

  defp frame(tag, bytes), do: <<tag, byte_size(bytes)::unsigned-64, bytes::binary>>

  defp ensure_item_limit!(items, path, %{max_items: max_items}) when items > max_items do
    raise CanonicalError, reason: {:limit, :item_count, items}, path: Enum.reverse(path)
  end

  defp ensure_item_limit!(_items, _path, _limits), do: :ok

  defp sequence(tag, encoded_items) do
    payload = Enum.map(encoded_items, &<<byte_size(&1)::unsigned-64, &1::binary>>)
    IO.iodata_to_binary([<<tag, length(encoded_items)::unsigned-64>>, payload])
  end
end
