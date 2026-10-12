# Optional Jido V3 check. Run from the Runic root:
# MIX_INSTALL_DIR="$PWD/_build/fact_modes_install" elixir examples/jido_action/fact_check.exs
Mix.install(
  [
    {:runic, path: Path.expand("../..", __DIR__), override: true},
    {:jido_action,
     github: "agentjido/jido_action", ref: "5e52df87d8114a1c8f805ead3c278c47f9f869a4"}
  ],
  consolidate_protocols: false
)

Code.require_file("fact_boundary.ex", __DIR__)
ExUnit.start(seed: 36)
Code.require_file("fact_contract_test.exs", __DIR__)
