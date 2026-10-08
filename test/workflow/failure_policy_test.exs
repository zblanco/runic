defmodule Runic.Workflow.FailurePolicyTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Runic.Runner
  alias Runic.Workflow
  alias Runic.Workflow.RunnableFailed

  require Runic

  setup do
    counter = :counters.new(1, [])
    :persistent_term.put({__MODULE__, :counter}, counter)
    on_exit(fn -> :persistent_term.erase({__MODULE__, :counter}) end)
    %{counter: counter}
  end

  def exit_normally(_input) do
    count()
    Process.exit(self(), :normal)
  end

  def always_fail(_item) do
    count()
    raise "failed"
  end

  def run_named(name, value) do
    count()

    if :persistent_term.get({__MODULE__, :failure_name}, nil) == name do
      raise "#{name} failed"
    else
      value
    end
  end

  defp count, do: :counters.add(:persistent_term.get({__MODULE__, :counter}), 1, 1)

  test "serial execution records a halt failure and stops the ready batch" do
    test_pid = self()
    failure_key = {:runic_failure, make_ref()}

    build_step = fn name ->
      Runic.step(
        fn value ->
          if Process.get(failure_key) == name do
            raise "halt"
          else
            send(test_pid, {:executed, name})
            value
          end
        end,
        name: name
      )
    end

    workflow =
      Workflow.new()
      |> Workflow.add(build_step.(:first_root))
      |> Workflow.add(build_step.(:second_root))
      |> Workflow.plan_eagerly(1)

    {_prepared_workflow, [first | _]} = Workflow.prepare_for_dispatch(workflow)
    Process.put(failure_key, first.node.name)

    halted =
      Workflow.react_until_satisfied(workflow, nil,
        scheduler_policies: [{:default, %{max_retries: 0, on_failure: :halt}}]
      )

    assert halted.halted_by_failure
    refute_received {:executed, _name}
    assert Workflow.react_until_satisfied(halted) == halted
  end

  test "an async runnable exit becomes a durable halt failure", %{counter: counter} do
    workflow =
      Runic.workflow(steps: [Runic.step(&__MODULE__.exit_normally/1, name: :exits)])
      |> Workflow.react_until_satisfied(1,
        async: true,
        max_concurrency: 1,
        scheduler_policies: [{:default, %{on_failure: :halt}}]
      )

    assert :counters.get(counter, 1) == 1

    assert [%RunnableFailed{error: {:task_crashed, :normal}, failure_action: :halt}] =
             Enum.filter(workflow.runnable_events, &match?(%RunnableFailed{}, &1))
  end

  test "event replay restores terminal halt state" do
    event = %RunnableFailed{
      runnable_id: :failed,
      node_hash: :failed,
      error: :boom,
      failed_at: System.monotonic_time(:millisecond),
      attempts: 1,
      failure_action: :halt
    }

    workflow = Workflow.from_events([event])

    assert workflow.halted_by_failure
    assert workflow.runnable_events == [event]
  end

  test "async execution admits no work after a halt failure", %{counter: counter} do
    workflow =
      Workflow.new(name: "async_halt")
      |> Workflow.add(Runic.step(&__MODULE__.always_fail/1, name: :first))
      |> Workflow.add(Runic.step(&__MODULE__.always_fail/1, name: :second))
      |> Workflow.react_until_satisfied(1,
        async: true,
        max_concurrency: 1,
        scheduler_policies: [{:default, %{on_failure: :halt}}]
      )

    assert :counters.get(counter, 1) == 1
    assert workflow.halted_by_failure
  end

  test "a Runner records an external task exit as a durable failure", %{counter: counter} do
    runner = :failure_policy_external_exit_runner
    start_supervised!({Runner, name: runner})
    test_pid = self()

    workflow =
      Runic.workflow(steps: [Runic.step(&__MODULE__.exit_normally/1, name: :exits)])
      |> Workflow.set_scheduler_policies([
        {:default, %{execution_mode: :durable, on_failure: :halt}}
      ])

    assert {:ok, _pid} =
             Runner.start_workflow(runner, :external_exit, workflow,
               max_concurrency: 1,
               hooks: [on_idle: fn _state -> send(test_pid, :external_exit_idle) end]
             )

    :ok = Runner.run(runner, :external_exit, 1)
    assert_receive :external_exit_idle, 2_000
    assert :counters.get(counter, 1) == 1

    assert {:ok, result} = Runner.get_workflow(runner, :external_exit)
    assert result.halted_by_failure

    assert Enum.any?(result.runnable_events, fn
             %RunnableFailed{error: {:task_crashed, :normal}, failure_action: :halt} -> true
             _event -> false
           end)
  end

  test "a Runner dispatches no new work after a halt failure", %{counter: counter} do
    runner = :failure_policy_halt_runner
    start_supervised!({Runner, name: runner})
    test_pid = self()

    failing = Runic.step(fn value -> __MODULE__.run_named(:failing, value) end, name: :failing)
    waiting = Runic.step(fn value -> __MODULE__.run_named(:waiting, value) end, name: :waiting)

    workflow =
      Workflow.new(name: "worker_halt")
      |> Workflow.add(failing)
      |> Workflow.add(waiting)
      |> Workflow.set_scheduler_policies([
        {:default, %{execution_mode: :durable, on_failure: :halt}}
      ])

    :persistent_term.put({__MODULE__, :failure_name}, :failing)

    on_exit(fn ->
      :persistent_term.erase({__MODULE__, :failure_name})
    end)

    assert {:ok, _pid} =
             Runner.start_workflow(runner, :halt, workflow,
               max_concurrency: 1,
               hooks: [
                 transform_runnables: fn runnables, _workflow ->
                   Enum.sort_by(runnables, &(&1.node.name != :failing))
                 end,
                 on_idle: fn _state -> send(test_pid, :halt_idle) end
               ]
             )

    :ok = Runner.run(runner, :halt, 1)
    assert_receive :halt_idle, 2_000
    assert :counters.get(counter, 1) == 1
  end
end
