defmodule Runic.Workflow.StableAdmissionOrderTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  require Runic

  alias Runic.Workflow
  alias Runic.Workflow.{Fact, Runnable, RunnableFailed}

  test "stable serial admission stops at the lowest ready key" do
    owner = self()
    workflow = workflow(owner)
    prepared = Workflow.prepared_runnables(workflow)
    expected = Enum.min_by(prepared, &Runnable.order_key/1)
    completed = Workflow.react_until_satisfied(workflow, nil, runnable_order: :stable)

    assert_received {:started, name, _pid}
    assert name == expected.node.name
    refute_received {:started, _, _}

    assert [%RunnableFailed{order_key: key}] =
             Enum.filter(completed.runnable_events, &is_struct(&1, RunnableFailed))

    assert key == Runnable.order_key(expected)
  end

  test "stable admission retains actual reversed completion order" do
    owner = self()
    workflow = workflow(owner, true)
    prepared = Workflow.prepared_runnables(workflow) |> Enum.sort_by(&Runnable.order_key/1)
    [first, second] = prepared

    task =
      Task.async(fn ->
        Workflow.react_until_satisfied(workflow, nil,
          async: true,
          max_concurrency: 2,
          runnable_order: :stable
        )
      end)

    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)

    assert_receive {:started, one, one_pid}, 2_000
    assert_receive {:started, two, two_pid}, 2_000
    pids = %{one => one_pid, two => two_pid}
    later = Map.fetch!(pids, second.node.name)
    monitor = Process.monitor(later)
    send(later, :release)
    assert_receive {:DOWN, ^monitor, :process, ^later, :normal}, 2_000
    send(Map.fetch!(pids, first.node.name), :release)
    completed = Task.await(task, 2_000)
    errors = Enum.filter(completed.runnable_events, &is_struct(&1, RunnableFailed))
    assert Enum.map(errors, & &1.order_key) == Enum.map([second, first], &Runnable.order_key/1)
    assert Enum.min_by(errors, & &1.order_key).runnable_id == first.id
  end

  defp workflow(owner, block? \\ false) do
    nodes =
      for label <- [:one, :two] do
        Runic.step(
          fn _ ->
            current_label = context(:label)
            observer = context(:observer)
            send(observer, {:started, current_label, self()})
            if context(:block?), do: receive(do: (:release -> :ok))
            raise Atom.to_string(current_label)
          end,
          name: label
        )
      end

    Workflow.new()
    |> Workflow.add_steps(nodes)
    |> Workflow.enable_event_emission()
    |> Workflow.put_run_context(%{
      _global: %{observer: owner, block?: block?},
      one: %{label: :one},
      two: %{label: :two}
    })
    |> Workflow.plan_eagerly(Fact.new(value: 1))
  end
end
