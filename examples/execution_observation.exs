require Runic

alias Runic.Runner
alias Runic.Workflow
alias Runic.Workflow.Execution

workflow =
  Runic.workflow(
    name: :invoice,
    steps: [
      {Runic.step(&(&1 + 1), name: :subtotal),
       [Runic.step(&(&1 * 2), name: :total)]}
    ]
  )

{workflow, immediate} = Workflow.execute(workflow, 10)

IO.inspect(
  %{
    execution_id: immediate.id,
    quiescent?: immediate.quiescent?,
    outputs: Execution.outputs(immediate)
  },
  label: "immediate"
)

{:ok, _runner} = Runner.start_link(name: ExampleRunner)
{:ok, _worker} = Runner.start_workflow(ExampleRunner, :invoice, workflow, executor: :inline)
{:ok, execution_id} = Runner.start_execution(ExampleRunner, :invoice, 20)
{:ok, managed} = Runner.await_execution(ExampleRunner, :invoice, execution_id)

IO.inspect(
  %{
    execution_id: managed.id,
    quiescent?: managed.quiescent?,
    outputs: Execution.outputs(managed),
    persistence: managed.persistence.status
  },
  label: "managed"
)
