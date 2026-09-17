# Foundation comparison evidence

See [the foundation report](../issue-19-foundation.md) for interpretation and reproduction.

Raw CSV files are an unchanged subset of the earlier serialized comparison: baseline, compact dispatch, graph indexes and their integrated foundation. Some files include compilation output before the CSV header. The comment records the original worktree commit. `provenance.json` preserves that provenance and identifies the equivalent foundation source. Runic's workflow implementation and pinned Multigraph runtime match the measured foundation; graph-specific tests now live in the companion Multigraph PR.

`summary.csv` is regenerated with:

```sh
python3 bench/issue19/summarize.py .docs/issue-19-foundation-results > .docs/issue-19-foundation-results/summary.csv
```

`graph-summary.csv` summarizes the separate fixed-degree query/relabel probes. `pr-tests.txt` records fresh full-suite validation of the extracted PR branch. Memory and timing use different runs; encoding bytes are estimates, and peer TCP is local second-VM execution. Optional bounded preparation is distinct from bounded source admission or history reclamation.
