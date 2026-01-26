defmodule Runic.MixProject do
  use Mix.Project

  def project do
    [
      app: :runic,
      version: "0.1.0-alpha.1",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
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
      {:tidewave, "~> 0.4", only: :dev},
      {:bandit, "~> 1.0", only: :dev},
      {:benchee, "~> 1.3", only: :dev}
      # {:libgraph, "~> 0.16.0", path: "~/wrk/oss/libgraph"}
    ]
  end

  defp aliases do
    [
      tidewave:
        "run --no-halt -e 'Agent.start(fn -> Bandit.start_link(plug: Tidewave, port: 4000) end)'"
    ]
  end
end
