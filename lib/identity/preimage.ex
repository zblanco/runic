defmodule Runic.Identity.Preimage do
  @moduledoc false

  @magic "runic-id"
  @version 1

  @spec frame_v1(atom(), binary()) :: binary()
  def frame_v1(domain, canonical_bytes) when is_atom(domain) and is_binary(canonical_bytes) do
    domain_bytes = Atom.to_string(domain)

    <<@magic::binary, 0, @version::unsigned-16, byte_size(domain_bytes)::unsigned-16,
      domain_bytes::binary, byte_size(canonical_bytes)::unsigned-64, canonical_bytes::binary>>
  end
end
