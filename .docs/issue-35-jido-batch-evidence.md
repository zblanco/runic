# Jido evidence for the Batch contract

Read-only source: local `jido_action` at
`8e9b3f7b268e175091b0eb3720bab3b8633d3c24` (detached HEAD). No consumer source
or dependency was changed. This is the older Action baseline identified by
tracking issue #30. It is not a claim that a V3 adoption was completed.

The current local compiler uses these collection conventions:

- `lib/jido_flow/compiler.ex:325-376` constructs FanOut, a native Map wrapper,
  Reduce/FanIn, and graph ownership connections.
- `lib/jido_flow/compiler/collection.ex:103-107` keeps the input frame on the
  first result token.
- `collection.ex:115-122` emits an empty token with the input and result frame.
- `collection.ex:128-134` puts index, item ID, input, and prior results on item
  tokens. The item ID uses Flow digest, map name, and index.
- `collection.ex:149-169` finds the carried input, sorts results by index,
  extracts values, and applies ordered effects.

Runic Batch can replace the manual FanOut/FanIn connections, empty token,
first-item input retention, item coordination identity, and final index sort.
The proposed adapter can send `Batch.input(items, %{input_frame: ..., results:
...})`. A SingleOutput Action member can use `context.batch.parent` and item
coordinates. Its output remains an explicitly converted Jido value. The final
adapter can use `Batch.Result.parent` and the already ordered outcomes.

Jido must keep expression resolution, Action parameter validation, error
conversion, fail-fast/collect choice, state commit, and effect delivery order.
No Action source migration, line-count reduction, integration test result,
production compatibility, or exactly-once effect claim is made here. The custom
price example proves that the Runic contract does not require Jido semantics,
Fact ancestry inspection, or consumer event construction.

The Batch parent measurement distinguishes stored item data from copied worker
context. A source parent is not copied into stored item Facts. It still enters
each prepared worker context and the completed Result. This replaces the
first-item storage convention; it does not promise lower worker copy cost.

Measured with Elixir 1.20.4 / OTP 28, three items, and a 1,001-entry parent map:

| Measurement | Result |
| --- | ---: |
| Parent ETF bytes | 8,490 |
| Three stored item Facts, ETF bytes | 5,902 |
| Empty destination process baseline, bytes | 2,696 |
| Destination process with each prepared context, bytes | 88,496 |
| Flat words in each prepared context | 8,015 |

Command: `MIX_ENV=test mix run examples/batch/measure.exs`. The source Fact and
completed Result also store the parent. The item number is separate from those
stores. Destination process memory includes heap allocation overhead. These
numbers describe this local fixture; they are not a scheduler benchmark.
