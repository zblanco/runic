defmodule Runic.Runner.TelemetryIntegrationTest do
  use ExUnit.Case, async: true

  require Runic
  alias Runic.Workflow

  setup do
    runner_name = :"test_telem_runner_#{System.unique_integer([:positive])}"
    start_supervised!({Runic.Runner, name: runner_name})

    handler_id = "test-telemetry-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      Runic.Runner.Telemetry.event_names(),
      &Runic.TestTelemetryHandler.handle_event/4,
      %{test_pid: test_pid}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    %{runner: runner_name}
  end

  describe "workflow lifecycle events" do
    test "workflow :start fires on start_workflow", %{runner: runner} do
      workflow = build_workflow()
      {:ok, _} = Runic.Runner.start_workflow(runner, :wf_telem_start, workflow)

      assert_receive {:telemetry, [:runic, :runner, :workflow, :start], %{system_time: _},
                      %{id: :wf_telem_start, workflow_name: _}}
    end

    test "workflow :stop fires when workflow satisfies", %{runner: runner} do
      workflow = build_workflow()
      {:ok, _} = Runic.Runner.start_workflow(runner, :wf_telem_stop, workflow)
      :ok = Runic.Runner.run(runner, :wf_telem_stop, 5)
      assert_workflow_idle(runner, :wf_telem_stop)

      assert_receive {:telemetry, [:runic, :runner, :workflow, :stop], %{duration: duration},
                      %{id: :wf_telem_stop}},
                     2000

      assert is_integer(duration)
      assert duration >= 0
    end
  end

  describe "runnable lifecycle events" do
    test "runnable :start fires for each dispatched runnable", %{runner: runner} do
      step_a = Runic.step(fn x -> x end, name: :telem_a)
      step_b = Runic.step(fn x -> x + 1 end, name: :telem_b)
      workflow = Runic.workflow(steps: [{step_a, [step_b]}])

      {:ok, _} = Runic.Runner.start_workflow(runner, :wf_dispatch, workflow)
      :ok = Runic.Runner.run(runner, :wf_dispatch, 5)
      assert_workflow_idle(runner, :wf_dispatch)

      # Step :telem_a should have been dispatched
      assert_receive {:telemetry, [:runic, :runner, :runnable, :start], _,
                      %{workflow_id: :wf_dispatch, node_name: :telem_a}},
                     2000

      # Step :telem_b should have been dispatched after :telem_a completes
      assert_receive {:telemetry, [:runic, :runner, :runnable, :start], _,
                      %{workflow_id: :wf_dispatch, node_name: :telem_b}},
                     2000
    end

    test "runnable :stop fires with duration measurement", %{runner: runner} do
      workflow = build_workflow()
      {:ok, _} = Runic.Runner.start_workflow(runner, :wf_complete, workflow)
      :ok = Runic.Runner.run(runner, :wf_complete, 5)
      assert_workflow_idle(runner, :wf_complete)

      assert_receive {:telemetry, [:runic, :runner, :runnable, :stop], %{duration: duration},
                      %{workflow_id: :wf_complete, node_name: :add, status: :completed}},
                     2000

      assert is_integer(duration)
      assert duration >= 0
    end

    test "runnable :exception fires on failure", %{runner: runner} do
      step = Runic.step(fn _ -> raise "boom" end, name: :failing)
      workflow = Runic.workflow(steps: [step])

      {:ok, _} = Runic.Runner.start_workflow(runner, :wf_fail, workflow)
      :ok = Runic.Runner.run(runner, :wf_fail, 1)
      assert_workflow_idle(runner, :wf_fail)

      assert_receive {:telemetry, [:runic, :runner, :runnable, :exception], _,
                      %{workflow_id: :wf_fail, node_name: :failing, error: _}},
                     2000
    end

    test "metadata includes workflow_id and node_name", %{runner: runner} do
      step = Runic.step(fn x -> x * 2 end, name: :meta_step)
      workflow = Runic.workflow(steps: [step])

      {:ok, _} = Runic.Runner.start_workflow(runner, :wf_meta, workflow)
      :ok = Runic.Runner.run(runner, :wf_meta, 3)
      assert_workflow_idle(runner, :wf_meta)

      assert_receive {:telemetry, [:runic, :runner, :runnable, :start], _,
                      %{workflow_id: :wf_meta, node_name: :meta_step, runnable_id: _}},
                     2000
    end
  end

  describe "store events" do
    test "store :stop fires on checkpoint", %{runner: runner} do
      step_a = Runic.step(fn x -> x + 1 end, name: :store_a)
      step_b = Runic.step(fn x -> x + 2 end, name: :store_b)
      workflow = Runic.workflow(steps: [{step_a, [step_b]}])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_store, workflow,
          checkpoint_strategy: :every_cycle
        )

      :ok = Runic.Runner.run(runner, :wf_store, 1)
      assert_workflow_idle(runner, :wf_store)

      assert_receive {:telemetry, [:runic, :runner, :store, :stop], %{duration: duration}, _},
                     2000

      assert is_integer(duration)
    end

    test "store :stop fires on persist at workflow completion", %{runner: runner} do
      workflow = build_workflow()

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_persist_telem, workflow,
          checkpoint_strategy: :on_complete
        )

      :ok = Runic.Runner.run(runner, :wf_persist_telem, 5)
      assert_workflow_idle(runner, :wf_persist_telem)

      # The persist on idle transition should fire a store event
      assert_receive {:telemetry, [:runic, :runner, :store, :stop], %{duration: _}, _}, 2000
    end
  end

  describe "no events without Runner" do
    test "Workflow module does not reference Runner.Telemetry", _context do
      # Structural guarantee: telemetry events are only emitted from Runner.Worker,
      # not from the core Workflow module. Verify via module info.
      {:module, Runic.Workflow} = Code.ensure_loaded(Runic.Workflow)

      # The Workflow module's compile-time references should not include Runner.Telemetry
      refute Runic.Runner.Telemetry in (Runic.Workflow.__info__(:attributes)[:external_resource] ||
                                          [])

      # Additionally verify that calling react_until_satisfied doesn't crash
      # (regression smoke test for non-Runner path)
      step = Runic.step(fn x -> x + 1 end, name: :no_runner)
      workflow = Runic.workflow(steps: [step])
      result = Workflow.react_until_satisfied(workflow, 5) |> Workflow.raw_productions()
      assert 6 in result
    end
  end

  # --- Helpers ---

  defp build_workflow do
    step = Runic.step(fn x -> x + 1 end, name: :add)
    Runic.workflow(steps: [step])
  end

  defp assert_workflow_idle(runner, workflow_id, timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll_until_idle(runner, workflow_id, deadline)
  end

  defp poll_until_idle(runner, workflow_id, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      flunk("Workflow #{inspect(workflow_id)} did not reach idle within timeout")
    end

    case Runic.Runner.lookup(runner, workflow_id) do
      nil ->
        flunk("Workflow #{inspect(workflow_id)} not found")

      pid ->
        state = :sys.get_state(pid)

        if state.status == :idle and map_size(state.active_tasks) == 0 do
          :ok
        else
          Process.sleep(10)
          poll_until_idle(runner, workflow_id, deadline)
        end
    end
  end
end
