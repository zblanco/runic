defmodule Runic.MixProject do
  use Mix.Project

  @repo_url "https://github.com/zblanco/runic"
  @version "0.1.0-alpha.5"

  def project do
    [
      app: :runic,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description: "Powerful workflow graph composition and runtime for Elixir",
      name: "Runic",
      package: package(),
      docs: docs()
    ]
  end

  defp docs do
    [
      logo: "logo.png",
      source_url: @repo_url,
      extras: [
        "README.md",
        "guides/cheatsheet.md",
        "guides/usage-rules.md",
        "guides/protocols.md",
        "guides/scheduling.md",
        "guides/durable-execution.md",
        "guides/execution-strategies.md",
        "guides/state-based-components.md"
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
          Runic.Workflow.FSM,
          Runic.Workflow.Aggregate,
          Runic.Workflow.Saga,
          Runic.Workflow.ProcessManager,
          Runic.Workflow.Accumulator,
          Runic.Workflow.Map,
          Runic.Workflow.Reduce,
          Runic.Workflow.Join
        ],
        "Scheduling & Execution": [
          Runic.Workflow.SchedulerPolicy,
          Runic.Workflow.PolicyDriver,
          Runic.Workflow.RunnableDispatched,
          Runic.Workflow.RunnableCompleted,
          Runic.Workflow.RunnableFailed
        ],
        Runner: [
          Runic.Runner,
          Runic.Runner.Worker,
          Runic.Runner.Executor,
          Runic.Runner.Executor.Task,
          Runic.Runner.Executor.GenStage,
          Runic.Runner.Scheduler,
          Runic.Runner.Scheduler.Default,
          Runic.Runner.Scheduler.ChainBatching,
          Runic.Runner.Scheduler.FlowBatch,
          Runic.Runner.Scheduler.ContractTest,
          Runic.Runner.Promise,
          Runic.Runner.PromiseBuilder,
          Runic.Runner.Store,
          Runic.Runner.Store.ETS,
          Runic.Runner.Store.Mnesia,
          Runic.Runner.Telemetry
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
      extra_applications: [:logger, :mnesia]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:uniq, "~> 0.6.1"},
      {:telemetry, "~> 1.0"},
      {:libgraph, "~> 0.16.1-mg.1", hex: :multigraph},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false, warn_if_outdated: true},
      {:tidewave, "~> 0.4", only: :dev},
      {:bandit, "~> 1.0", only: :dev},
      {:benchee, "~> 1.3", only: :dev},
      {:gen_stage, "~> 1.2"},
      {:flow, "~> 1.2"}
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

  defp package do
    [
      maintainers: ["Zack White"],
      licenses: ["Apache-2.0"],
      links: %{"Github" => @repo_url}
    ]
  end
end
