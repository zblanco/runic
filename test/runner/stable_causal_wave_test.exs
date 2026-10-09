defmodule Runic.Runner.StableCausalWaveTest do
  use ExUnit.Case, async: false
  require Runic
  alias Runic.{Runner, Workflow}

  for default <- [:inline, Runic.Runner.Executor.Task] do
    test "stable wave waits for mixed executors with default #{default}" do
      owner = self()

      blocked =
        Runic.step(
          fn value ->
            send(owner, {:blocked, self()})
            receive do: (:release -> value)
          end,
          name: :blocked
        )

      fast = Runic.step(fn value -> value end, name: :fast)

      child =
        Runic.step(
          fn value ->
            send(owner, :child)
            value
          end,
          name: :child
        )

      policies =
        if unquote(default) == :inline,
          do: [{:blocked, %{executor: Runic.Runner.Executor.Task}}],
          else: [{:fast, %{executor: :inline}}, {:child, %{executor: :inline}}]

      workflow =
        Runic.workflow(steps: [blocked, {fast, [child]}])
        |> Workflow.set_scheduler_policies(policies)

      runner = :"stable_mixed_#{System.unique_integer([:positive])}"
      start_supervised!({Runner, name: runner})

      {:ok, _} =
        Runner.start_workflow(runner, :mixed, workflow,
          runnable_order: :stable,
          executor: unquote(default),
          max_concurrency: 2,
          hooks: [
            on_complete: fn runnable, _, _ ->
              if runnable.node.name == :fast, do: send(owner, :fast_done)
            end
          ],
          on_complete: fn _, _ -> send(owner, :done) end
        )

      :ok = Runner.run(runner, :mixed, 1)
      assert_receive {:blocked, pid}, 1000

      try do
        assert_receive :fast_done, 1000
        assert {:ok, %{active_units: 1}} = Runner.admission_status(runner, :mixed)
        refute_received :child
      after
        send(pid, :release)
      end

      assert_receive :child, 1000
      assert_receive :done, 1000
    end
  end

  test "admitted chain Promise keeps its documented internal progress" do
    owner = self()

    blocked =
      Runic.step(
        fn value ->
          send(owner, {:blocked, self()})
          receive do: (:release -> value)
        end,
        name: :blocked
      )

    fast = Runic.step(fn value -> value end, name: :fast)

    child =
      Runic.step(
        fn value ->
          send(owner, :chain_child)
          value
        end,
        name: :chain_child
      )

    workflow = Runic.workflow(steps: [blocked, {fast, [child]}])
    runner = :"stable_chain_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner})

    {:ok, _} =
      Runner.start_workflow(runner, :chain, workflow,
        runnable_order: :stable,
        max_concurrency: 2,
        promise_opts: [min_chain_length: 2],
        on_complete: fn _, _ -> send(owner, :done) end
      )

    :ok = Runner.run(runner, :chain, 1)
    assert_receive {:blocked, pid}, 1000

    try do
      assert_receive :chain_child, 1000
      assert {:ok, %{active_units: 1}} = Runner.admission_status(runner, :chain)
    after
      send(pid, :release)
    end

    assert_receive :done, 1000
  end
end
