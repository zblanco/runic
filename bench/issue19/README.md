# Issue 19 shared benchmark

Run `mix run bench/issue19/run.exs --label baseline --sizes 128,512 --cases collect,sum`.
Invoke this exact file by absolute path from another worktree to compare its loaded implementation without copying or changing the harness. The scenario module is compiled against that worktree's Runic macros. No runtime implementation replacement is used.

Timing, memory, and envelope inspection are separate passes. Timing uses three fresh-process samples after warmup and includes graph construction, admission, execution, output verification, and final cardinality queries; it excludes compilation and peer startup. It is not directly comparable with the earlier phase-only probe. Memory uses process-spawn tracing only in its separate pass and approximately 2 ms sampling. `owner_peak_bytes` is the workflow-owner process; `tree_peak_bytes` sums it and live descendants (including Tasks); referenced off-heap binaries are deduplicated by runtime identity and reported separately. Remote peer heaps are excluded. Sampling may miss short peaks; sums of separate maxima are not simultaneous totals. Full graph/history remains retained in every implemented mode.

Envelope measurements use standalone uncompressed Erlang external term size for requests and responses, not actual network packet counts or distribution atom-cache/compression behavior. Flat words estimate term-copy expansion, not actual RSS. Sharing-aware context size samples the first context per node per wave; its maximum is a sampled diagnostic, while encoded and flat sizes cover every envelope. Serialized retained workflow size also loses sharing and is not its live heap size. All metrics are deliberately named for what they measure.

`peer_tcp` executes each runnable in a second local BEAM with two schedulers using OTP `peer` alternative RPC over loopback TCP. It exercises actual serialization and a separate VM; it is not native distributed-Erlang RPC or a WAN benchmark. Task mode uses eight concurrent ordered Tasks by default. Inline mode prepares a frontier, executes its independent runnables, then applies their results. Bounded mode selects before prepare using `prepare_for_dispatch/2`; it does not make FanOut demand-driven or bound retained history. Range input (`stream` case) checks lazy-capable input representation, not a claim of lazy admission.

Examples:

```sh
mix run bench/issue19/run.exs --label compact --preparation bounded --limit 64 --execution task
mix run bench/issue19/run.exs --label foundation --execution peer_tcp --sizes 128,512 --cases collect,sum --pass timing
mix run bench/issue19/run.exs --label integrated --sizes 2048,8192 --cases collect,sum --pass memory
```

Use `--pass timing|memory|envelopes` for a selected pass. `--cases` accepts collect, sum, deep (four map steps), binary (distinct 1 KiB payloads), repeated (four distinct batches), stream (Range), slow_first (10 ms delay on the first item), and latency (a requested 2 ms sleep per mapped item, representing waiting work rather than CPU throughput). Cases validate exact output and one occurrence of the expected reduction. They do not replace semantic regression suites.

Serialize comparable runs across worktrees. Raw CSV starts with a comment recording the implementation commit and runtime. Record the harness commit separately in the comparison report. A valid comparison also needs the branch's tests, API/identity behavior, and known limitations.

This PR implements legacy coordination only. The harness retains the comparison's optional `--coordination batch` switch for compatible experimental branches and rejects it when unsupported. Foundation results and reproduction details are in [the foundation report](../../.docs/issue-19-foundation.md).

References: [OTP peer](https://www.erlang.org/doc/apps/stdlib/peer.html), [BEAM term copying and sharing](https://www.erlang.org/doc/system/eff_guide_processes.html).
