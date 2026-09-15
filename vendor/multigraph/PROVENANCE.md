# Experimental Multigraph dependency

This directory vendors the existing Runic dependency **Multigraph 0.16.1-mg.4**
under its original MIT license (see `LICENSE`). It adds no new dependency.
The untouched package's `lib`, `mix.exs`, `README.md`, and `LICENSE` were copied
from Runic's locally installed Hex package before applying this experiment.
The vendoring commit is separate from the optimization commit so reviewers can
inspect a small algorithmic diff rather than an entire new package.

Upstream source: https://github.com/zblanco/libgraph/tree/zw/multigraph-fork

Locked Hex package:

- Inner checksum: `2bbe149f5411b0e3bf0624c7bf2e3da2738efeac2f9a67bbbcb807ab171f0a76`
- Outer checksum: `b9f3e2577cef4658eeedf97c76d22a86d33a7aab702a93c1da9c122e849e9037`
- Original `lib/multigraph.ex` SHA-256: `432d2a0fd75a3650be05a8b0d461142385d79cfaa86977ff76c4a1ba7dfb0a78`

Runic's `mix.exs` uses an explicit path override for this experiment. The original
Hex lock entry remains as provenance; Mix selects the path dependency. Do not
publish Runic with this experimental dependency specification. The production
integration should upstream the focused patch and select a released Multigraph
version, or explicitly adopt maintenance of this source. Other files preserve
the original package as shipped, including its development dependency metadata;
Runic builds the path dependency in dependency mode and adds no new packages.

The data structure and stored graph format are unchanged. The changes are pure
persistent-map operations, so no process, ETS table, or runtime ownership is added.
