Code.require_file("support.exs", __DIR__)

defmodule Runic.Bench.OwnerExecution.Preparation do
  @moduledoc false

  require Runic

  alias Runic.Bench.OwnerExecution.Support
  alias Runic.{Runner, Workflow}
  alias Runic.Workflow.Fact

  def run do
    options =
      Support.options!(
        [engine: :string, width: :integer, concurrency: :integer, transform: :boolean],
        engine: "legacy",
        width: 3_000,
        concurrency: 8,
        transform: false
      )

    engine = Support.engine!(options)
    width = Support.positive_integer!(options, :width)
    concurrency = Support.positive_integer!(options, :concurrency)
    transform? = Keyword.fetch!(options, :transform)

    if concurrency > width do
      raise ArgumentError, "--concurrency cannot be greater than --width"
    end

    runner = :owner_execution_preparation_bench
    workflow = workflow(width, self())
    {:ok, _runner} = Runner.start_link(name: runner)

    worker_options =
      [max_concurrency: concurrency, dispatch_mode: :manual]
      |> Keyword.merge(engine_options(engine))
      |> maybe_transform(transform?)

    {:ok, _worker} = Runner.start_workflow(runner, :wide, workflow, worker_options)

    report =
      Support.measure(fn ->
        :ok = Runner.continue(runner, :wide)

        workers =
          for _worker <- 1..concurrency do
            receive do
              {:started, _index, pid} -> pid
            after
              30_000 -> raise "preparation benchmark timed out"
            end
          end

        Process.sleep(100)
        workers
      end)

    Support.print(
      "Owner execution preparation memory",
      [engine: engine, width: width, concurrency: concurrency, transform: transform?],
      report
    )

    Enum.each(report.result, &send(&1, :release))
    :ok = Runner.stop(runner, :wide, persist: false)
  end

  defp workflow(width, observer) do
    workflow = Workflow.new()
    fact = Fact.new(value: :input)

    graph =
      Enum.reduce(1..width, workflow.graph, fn index, graph ->
        work = fn input ->
          send(observer, {:started, index, self()})
          receive do: (:release -> input)
        end

        step = Runic.step(work, name: {:wide, index})

        step = %{
          step
          | hash: Runic.Identity.derive(:component_definition, [:wide_preparation, index])
        }

        Multigraph.add_edge(graph, fact, step, label: :runnable)
      end)

    %{workflow | graph: graph}
  end

  defp engine_options(:legacy), do: []
  defp engine_options(:owner), do: [execution_engine: :owner]

  defp maybe_transform(options, false), do: options

  defp maybe_transform(options, true) do
    Keyword.put(options, :hooks, transform_runnables: fn runnables, _workflow -> runnables end)
  end
end

Runic.Bench.OwnerExecution.Preparation.run()
