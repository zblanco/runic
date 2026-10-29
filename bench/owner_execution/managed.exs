Code.require_file("support.exs", __DIR__)

defmodule Runic.Bench.OwnerExecution.Managed do
  @moduledoc false

  require Runic

  alias Runic.Bench.OwnerExecution.Support
  alias Runic.{Runner, Workflow}

  def run do
    options =
      Support.options!(
        [engine: :string, retained: :integer, attempts: :integer],
        engine: "legacy",
        retained: 1_000_000,
        attempts: 6
      )

    engine = Support.engine!(options)
    retained_count = Support.positive_integer!(options, :retained)
    attempts = Support.positive_integer!(options, :attempts)
    runner = :owner_execution_managed_bench
    owner = self()
    workflow = workflow(retained_count)

    {:ok, _runner} = Runner.start_link(name: runner)

    worker_options =
      [
        max_concurrency: 1,
        on_complete: fn id, completed -> send(owner, {:completed, id, completed}) end
      ] ++ engine_options(engine)

    {:ok, _worker} = Runner.start_workflow(runner, :memory, workflow, worker_options)

    report =
      Support.measure(fn ->
        for input <- 1..attempts do
          :ok = Runner.run(runner, :memory, input)

          receive do
            {:completed, :memory, _completed} -> :ok
          after
            30_000 -> raise "managed benchmark timed out"
          end
        end
      end)

    Support.print(
      "Owner execution managed memory",
      [engine: engine, retained: retained_count, attempts: attempts],
      report
    )

    :ok = Runner.stop(runner, :memory, persist: false)
  end

  defp workflow(retained_count) do
    retained = Enum.to_list(1..retained_count)
    step = Runic.step(fn selected -> selected * 2 end, name: :projected_work)

    hook = fn _event, _context ->
      if hd(retained) == 1, do: :ok
    end

    Workflow.new()
    |> Workflow.add_step(step)
    |> Workflow.set_scheduler_policies([{:projected_work, %{timeout_ms: 5_000}}])
    |> Map.put(:before_hooks, %{step.hash => [hook]})
  end

  defp engine_options(:legacy), do: []
  defp engine_options(:owner), do: [execution_engine: :owner]
end

Runic.Bench.OwnerExecution.Managed.run()
