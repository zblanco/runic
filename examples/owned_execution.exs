# Run with: mix run examples/owned_execution.exs
require Runic

alias Runic.Runner

{:ok, runner} = Runner.start_link(name: OwnedExecutionExample.Runner)
observer = self()

step =
  Runic.step(
    fn input ->
      Process.flag(:trap_exit, true)
      send(observer, {:work_started, self()})
      receive do: (:finish -> input * 2)
    end,
    name: :process_item
  )

workflow = Runic.workflow(steps: [step])

{:ok, worker} =
  Runner.start_workflow(OwnedExecutionExample.Runner, :request, workflow, owner: self())

:ok = Runner.run(OwnedExecutionExample.Runner, :request, 21)

task =
  receive do
    {:work_started, pid} -> pid
  after
    5_000 -> raise "work did not start"
  end

:ok = Runner.cancel(OwnedExecutionExample.Runner, :request)
false = Process.alive?(worker)
false = Process.alive?(task)
IO.puts("Cancellation confirmed: Worker and native work have stopped.")
Supervisor.stop(runner)
