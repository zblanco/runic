defmodule Runic.MixProject do
  use Mix.Project

  def project do
    [
      app: :runic,
      version: "0.1.0-alpha.1",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Docs
      name: "Runic",
      source_url: "https://github.com/zblanco/runic",
      docs: docs()
    ]
  end

  defp docs do
    [
      main: "readme",
      logo: "logo.png",
      extras: [
        "README.md",
        "guides/cheatsheet.md",
        "guides/usage-rules.md",
        "guides/protocols.md",
        "guides/scheduling.md"
      ],
      groups_for_extras: [
        Guides: ~r/guides\/.*/
      ],
      groups_for_modules: [
        Core: [Runic, Runic.Workflow],
        Components: [
          Runic.Workflow.Step,
          Runic.Workflow.Rule,
          Runic.Workflow.Condition,
          Runic.Workflow.StateMachine,
          Runic.Workflow.Accumulator,
          Runic.Workflow.Map,
          Runic.Workflow.Reduce,
          Runic.Workflow.Join
        ],
        Protocols: [
          Runic.Workflow.Invokable,
          Runic.Component,
          Runic.Transmutable
        ],
        Internal: [
          Runic.Workflow.Fact,
          Runic.Workflow.FanOut,
          Runic.Workflow.FanIn,
          Runic.Workflow.Runnable,
          Runic.Workflow.Components,
          Runic.Closure,
          Runic.ClosureMetadata
        ]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:uniq, "~> 0.6.1"},
      {:libgraph,
       git: "https://github.com/zblanco/libgraph.git", branch: "zw/multigraph-indexes"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false, warn_if_outdated: true},
      {:tidewave, "~> 0.4", only: :dev},
      {:bandit, "~> 1.0", only: :dev},
      {:benchee, "~> 1.3", only: :dev}
      # {:libgraph, "~> 0.16.0", path: "~/wrk/oss/libgraph"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      tidewave:
        "run --no-halt -e 'Agent.start(fn -> Bandit.start_link(plug: Tidewave, port: 4000) end)'"
    ]
  end
end
