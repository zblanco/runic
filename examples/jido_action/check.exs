# Optional network/dependency check; not part of Runic's default test suite.
# Run: elixir examples/jido_action/check.exs
Mix.install(
  [
    {:runic, path: Path.expand("../..", __DIR__), override: true},
    {:jido_action,
     github: "agentjido/jido_action", ref: "22f7c2a38fc9c07e3b117c5e4a53e1a0bdde32aa"}
  ],
  consolidate_protocols: false
)

Code.require_file("adapter.ex", __DIR__)
Code.require_file("component.ex", __DIR__)
Code.require_file("fixture.ex", __DIR__)
ExUnit.start(seed: 905_355)
Code.require_file("contract_test.exs", __DIR__)
