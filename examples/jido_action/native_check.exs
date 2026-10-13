# MIX_INSTALL_DIR="$PWD/_build/native_fact_install" elixir examples/jido_action/native_check.exs
Mix.install(
  [
    {:runic, path: Path.expand("../..", __DIR__), override: true},
    {:jido_action,
     github: "agentjido/jido_action", ref: "5e52df87d8114a1c8f805ead3c278c47f9f869a4"}
  ],
  consolidate_protocols: false
)

for file <- ["adapter.ex", "component.ex", "native_fixture.ex"],
    do: Code.require_file(file, __DIR__)

ExUnit.start(seed: 36)
Code.require_file("native_contract_test.exs", __DIR__)
