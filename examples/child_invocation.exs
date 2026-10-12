# Run with: mix run examples/child_invocation.exs
# A report service chooses a reusable child pipeline for each request.
require Runic
alias Runic.Workflow
alias Runic.Workflow.Call

defmodule ReportService do
  require Runic
  alias Runic.Workflow
  alias Runic.Workflow.ChildInvocation

  def request(%{amount: amount}) do
    target =
      Workflow.new(
        name: :tax,
        input_ports: [in: [type: :integer]],
        output_ports: [out: [type: :integer, from: :calculate]]
      )
      |> Workflow.add(Runic.step(fn value -> div(value * 120, 100) end, name: :calculate))

    ChildInvocation.new(target: target, input: amount)
  end
end

request = Runic.step(&ReportService.request/1, name: :request)

workflow =
  Workflow.new()
  |> Workflow.add(Call.new(request, name: :report))
  |> Workflow.add(Runic.step(fn total -> %{total: total} end, name: :receipt),
    connections: [[from: {:report, :out}, to: :in]]
  )

{completed, execution} = Workflow.execute(workflow, %{amount: 100})
IO.inspect(Workflow.results(completed, [:report, :receipt]), label: "report")
IO.inspect(execution.persistence.status, label: "Store acknowledgement")
# %{report: 120, receipt: %{total: 120}}
# :not_managed -- local execution does not acknowledge a Store.
