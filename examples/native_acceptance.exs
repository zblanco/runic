require Runic
alias Runic.Workflow
alias Runic.Workflow.{Fact, Invokable, Join, PolicyDriver, SchedulerPolicy}

a = Runic.step(fn x -> x end, name: :a)
b = Runic.step(fn x -> x end, name: :b)
result = Runic.step(fn a, b -> {a, b} end, name: :result)
workflow = Runic.workflow(steps: [a, b, {[a, b], [result]}])
join = Enum.find(Multigraph.vertices(workflow.graph), &is_struct(&1, Join))
first = Fact.local(1)
second = Fact.local(2)
x = Fact.child(first, value: 1, ancestry: {a.hash, first.hash})
y = Fact.child(second, value: 2, ancestry: {b.hash, second.hash})
workflow = workflow |> Workflow.log_fact(x) |> Workflow.log_fact(y)
workflow = Invokable.invoke(join, workflow, x)
{:ok, prepared} = Invokable.prepare(join, workflow, y)

# A scheduler records the accepted result, after current graph checks.
{attempt, events} =
  PolicyDriver.execute(prepared, SchedulerPolicy.default_policy(), emit_events: true)

{workflow, accepted, events} = Workflow.accept_runnable(workflow, attempt, events)
record = %{status: accepted.status, error: accepted.error, events: events}
:completed = attempt.status
:failed = record.status
[] = Workflow.productions(workflow)
IO.inspect(record.status, label: "scheduler accepted status")
