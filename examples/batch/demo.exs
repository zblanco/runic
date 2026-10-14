# Run from the repository root: MIX_ENV=test mix run examples/batch/demo.exs
unless Code.ensure_loaded?(Runic.Examples.Batch.Adjustment) do
  Code.require_file("adjustment.ex", __DIR__)
  Code.require_file("adjustment_component.ex", __DIR__)
end

require Runic
alias Runic.Workflow
alias Runic.Workflow.Batch

batch = Runic.batch(Runic.Examples.Batch.Adjustment.new(:price), name: :prices)

workflow =
  Workflow.new()
  |> Workflow.add(batch)
  |> Workflow.add(Runic.step(fn result -> result end, name: :result), to: :prices)

{completed, _execution} =
  Workflow.execute(workflow, Batch.input([10, :invalid, 20], %{adjustment: 3}),
    scheduler_policies: [{:price, %{on_failure: :skip}}]
  )

[result] = Workflow.raw_productions(completed, :result)
IO.inspect(result, label: "Ordered price outcomes")
