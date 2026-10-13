# Run: MIX_ENV=test mix run examples/native_local_facts.exs
require Runic
alias Runic.{Runner, Workflow}
alias Runic.Workflow.{Execution, LocalBoundary, LocalFactError}

calculate =
  Runic.step(fn %{callback: callback, value: value} -> callback.(value) end, name: :calculate)

definition = Runic.workflow(steps: [calculate])
input = %{callback: fn value -> value * 2 end, value: 21}
{workflow, execution} = Workflow.execute(definition, input, identity_mode: :local, async: true)
[42] = Execution.outputs(execution)
[output] = Workflow.productions(workflow, :calculate)
:local = output.identity_mode
:local_sha256 = output.id.scheme
{:error, %LocalFactError{}} = LocalBoundary.check(output, :output)

IO.inspect(%{value: output.value, mode: output.identity_mode, scheme: output.id.scheme},
  label: "native local output"
)

{:ok, _} = Runner.start_link(name: NativeLocalExample)

{:ok, _} =
  Runner.start_workflow(NativeLocalExample, :local, definition,
    owner: self(),
    persistence: :disabled
  )

{:ok, id} = Runner.start_execution(NativeLocalExample, :local, input, identity_mode: :local)
{:ok, managed} = Runner.await_execution(NativeLocalExample, :local, id)
:not_managed = managed.persistence.status
:ok = Runner.stop(NativeLocalExample, :local)

IO.inspect(Execution.outputs(managed),
  label: "owned local execution without Store writes",
  charlists: :as_lists
)

# Export is explicit new portable admission, never a change to the local child.
portable_definition = Runic.workflow(steps: [Runic.step(fn value -> value end)])
{portable, _} = Workflow.execute(portable_definition, output.value)
:ok = LocalBoundary.check(portable, :workflow)
IO.puts("Selected scalar admitted into a new portable execution.")
