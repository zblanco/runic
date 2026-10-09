# Run with: mix run examples/owned_execution.exs
require Runic

alias Runic.{Runner, Workflow}

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

# A nested timeout reuses the managed scope and keeps its parent's I/O route.
inner =
  Runic.workflow(
    steps: [
      Runic.step(
        fn input ->
          IO.puts("owned output")
          input
        end,
        name: :write
      )
    ]
  )
  |> Workflow.set_scheduler_policies([{:write, %{timeout_ms: 60_000}}])

capture =
  Runic.step(
    fn input ->
      {:ok, "owned output\n"} =
        StringIO.open("", fn device ->
          group_leader = Process.group_leader()

          try do
            Process.group_leader(self(), device)
            result = Workflow.react_until_satisfied(inner, input)
            true = Workflow.raw_productions(result) == [input]
            elem(StringIO.contents(device), 1)
          after
            Process.group_leader(self(), group_leader)
          end
        end)

      input
    end,
    name: :capture
  )

{:ok, _worker} =
  Runner.start_workflow(
    OwnedExecutionExample.Runner,
    :io_request,
    Runic.workflow(steps: [capture]),
    owner: self(),
    hooks: [on_idle: fn _ -> send(observer, :io_complete) end]
  )

:ok = Runner.run(OwnedExecutionExample.Runner, :io_request, 21)

receive do
  :io_complete -> :ok
after
  5_000 -> raise "I/O example did not complete"
end

{:ok, [21]} = Runner.get_results(OwnedExecutionExample.Runner, :io_request)
:ok = Runner.stop(OwnedExecutionExample.Runner, :io_request, persist: false)
IO.puts("Nested timed work kept its parent's I/O device.")
Supervisor.stop(runner)
