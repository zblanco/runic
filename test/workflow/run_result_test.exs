defmodule Runic.Workflow.RunResultTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  alias Runic.Workflow
  alias Runic.Workflow.{RunnableCompleted, RunnableDispatched}
  alias Runic.Workflow.RunResult

  require Runic

  describe "step/3" do
    test "returns a structured result for one reaction cycle" do
      workflow = Runic.workflow(steps: [Runic.step(fn x -> x * 2 end, name: :double)])

      assert {:ok, %RunResult{status: :ok, cycles: 1, workflow: stepped} = result} =
               Workflow.step(workflow, 5)

      assert result.failed_runnable == nil
      assert result.error == nil
      assert Workflow.raw_productions(stepped) == [10]
      assert result.events != []
    end

    test "returns failure metadata without changing react/3 compatibility" do
      workflow =
        Runic.workflow(steps: [Runic.step(fn _input -> raise "boom" end, name: :explode)])
        |> Workflow.set_scheduler_policies([{:default, %{max_retries: 0}}])

      assert {:error,
              %RunResult{
                status: :error,
                cycles: 1,
                failed_runnable: failed,
                error: %RuntimeError{message: "boom"},
                workflow: stepped
              }} = Workflow.step(workflow, :input)

      assert failed.status == :failed
      assert Workflow.raw_productions(stepped) == []
      assert %Workflow{} = Workflow.react(workflow, :input)
    end
  end

  describe "run/3" do
    test "runs until no runnables remain and returns cycle metadata" do
      workflow =
        Runic.workflow(
          steps: [
            {Runic.step(fn x -> x + 1 end, name: :add),
             [Runic.step(fn x -> x * 2 end, name: :double)]}
          ]
        )

      assert {:ok, %RunResult{status: :ok, cycles: 2, workflow: ran}} =
               Workflow.run(workflow, 5)

      assert Enum.sort(Workflow.raw_productions(ran)) == [6, 12]
      refute Workflow.is_runnable?(ran)
    end

    test "returns max_cycles without discarding the partial workflow" do
      workflow =
        Runic.workflow(
          steps: [
            {Runic.step(fn x -> x + 1 end, name: :add),
             [Runic.step(fn x -> x * 2 end, name: :double)]}
          ]
        )

      assert {:error,
              %RunResult{
                status: :max_cycles,
                cycles: 1,
                error: {:max_cycles, 1},
                workflow: partial
              }} = Workflow.run(workflow, 5, max_cycles: 1)

      assert Workflow.raw_productions(partial) == [6]
      assert Workflow.is_runnable?(partial)
    end

    test "calls checkpoints after each completed cycle including the initial input cycle" do
      checkpoints = start_supervised!({Agent, fn -> [] end})
      workflow = Runic.workflow(steps: [Runic.step(fn x -> x + 1 end, name: :add)])

      assert {:ok, %RunResult{cycles: 1}} =
               Workflow.run(workflow, 5,
                 checkpoint: fn wrk ->
                   Agent.update(checkpoints, fn states ->
                     [Workflow.raw_productions(wrk) | states]
                   end)
                 end
               )

      assert [[6]] = Agent.get(checkpoints, &Enum.reverse/1)
    end

    test "react_until_satisfied/3 keeps returning the workflow" do
      workflow = Runic.workflow(steps: [Runic.step(fn x -> x * 3 end, name: :triple)])

      assert %Workflow{} = ran = Workflow.react_until_satisfied(workflow, 7)
      assert Workflow.raw_productions(ran) == [21]
    end

    test "emits runnable lifecycle events for durable local execution" do
      workflow =
        Runic.workflow(steps: [Runic.step(fn x -> x + 1 end, name: :add)])
        |> Workflow.set_scheduler_policies(add: %{execution_mode: :durable})

      assert {:ok, %RunResult{events: events}} = Workflow.run(workflow, 5)

      assert Enum.any?(events, &match?(%RunnableDispatched{}, &1))
      assert Enum.any?(events, &match?(%RunnableCompleted{}, &1))
    end
  end
end
