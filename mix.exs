defmodule Runic.MixProject do
  use Mix.Project

  def project do
    [
      app: :runic,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
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
      {:uniq, "~> 0.5.3"},
      {:libgraph, "~> 0.16.0", github: "zblanco/libgraph", branch: "zw/multigraph-indexes"}
      # {:libgraph, "~> 0.16.0", path: "~/wrk/oss/libgraph"}
    ]
  end
end
