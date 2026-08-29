# Runic Identity Scheme Version 1 Test Vectors

- **Status:** Executable contract in `test/identity_test.exs`
- **Scheme:** SHA-256
- **Canonical codec:** `runic_canonical_v1`
- **Preimage frame:** `runic-id`, zero separator, unsigned 16-bit version, unsigned 16-bit domain length, domain bytes, unsigned 64-bit payload length, canonical bytes

All integers are unsigned big-endian lengths unless a canonical value rule says otherwise. Hex values are lowercase only for presentation.

## Canonical primitive vectors

| Logical value | Canonical bytes (hex) |
|---|---|
| `nil` | `00` |
| `false` | `01` |
| `true` | `02` |
| `42` | `1000000000000000023432` |
| `-7` | `1000000000000000022d37` |
| `1.5` | `113ff8000000000000` |
| binary `"hi"` | `2000000000000000026869` |
| atom `:hi` | `2100000000000000026869` |

Lists use tag `0x30`; tuples use tag `0x31`. Both contain an unsigned 64-bit item count followed by individually length-framed canonical values. Maps use tag `0x33`, sort entries by the complete canonical key bytes, and wrap each key/value pair with tag `0x32`.

## Payload identity vector

Identity document:

```elixir
%{
  codec: :runic_canonical,
  schema_version: 1,
  value: %{a: 1, b: 2}
}
```

Tagged text identity:

```text
runic:sha256:v1:payload:21205882d75b9c3a549850de3b90d8347acfd5b648858d1256ad64883511b90c
```

Compact binary identity (hex):

```text
01000100077061796c6f616421205882d75b9c3a549850de3b90d8347acfd5b648858d1256ad64883511b90c
```

Implementations must compare the scheme, version, domain, and all 32 digest bytes. Short display strings are never authoritative keys.
