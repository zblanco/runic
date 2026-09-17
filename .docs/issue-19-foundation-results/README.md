# Foundation comparison results

See [the foundation report](../issue-19-foundation.md) for interpretation and reproduction.

The comparison used Elixir 1.19.5 / OTP 28, 16 origin schedulers, eight concurrent Tasks and two schedulers in the local peer VM. Timings are medians of three independent-process samples after warmup. Memory was sampled separately, approximately every 2 ms. Encoding totals estimate standalone external-term size, not network traffic.

For inline map/collect over 2,048 items:

| Implementation | Median time | Sampled peak process-tree memory |
|---|---:|---:|
| Baseline | 6,275.748 ms | 111.103 MiB |
| Compact dispatch | 2,909.840 ms | 26.708 MiB |
| Graph indexes | 4,086.500 ms | 92.626 MiB |
| Integrated foundation | 174.246 ms | 15.607 MiB |

Baseline and foundation both retain 4,098 facts and 8,203 edges. The production baseline is `a9407d6`; the measured integrated foundation is `ea82d5b`; the original comparison report was recorded at `a8e6f7b`. The Git-pinned Multigraph runtime matches the measured implementation, with graph-specific tests maintained in [Multigraph PR #4](https://github.com/zblanco/libgraph/pull/4).

Validation before artifact cleanup:

- Runic: 55 doctests, 1,421 tests, zero failures, 13 existing skips.
- Multigraph: 114 doctests, 117 tests, zero failures.
- Six-case Runic harness smoke and exact public-API results at 512, 2,048 and 8,192 items passed.
- The native Multigraph probe completed 60 samples through 8,192 edges.

CSV files, generated summaries, provenance JSON and test logs are temporary artifacts. Keep only interpreted Markdown results in this directory. To generate new data:

```sh
runic_results=$(mktemp -d /tmp/runic-issue19.XXXXXX)
python3 bench/issue19/matrix.py "$PWD" foundation "$runic_results"
python3 bench/issue19/summarize.py "$runic_results" > "$runic_results/summary.csv"
```

Optional bounded preparation is distinct from bounded source admission or history reclamation; see the report for the measured trade-offs.
