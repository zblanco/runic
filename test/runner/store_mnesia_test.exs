defmodule Runic.Runner.Store.MnesiaTest do
  use ExUnit.Case, async: false

  alias Runic.Runner.Store.Mnesia, as: MnesiaStore
  alias Runic.Workflow

  require Runic

  setup do
    runner_name = :"test_mnesia_#{System.unique_integer([:positive])}"

    start_supervised!({MnesiaStore, runner_name: runner_name, disc_copies: false})

    {:ok, store_state} = MnesiaStore.init_store(runner_name: runner_name)

    on_exit(fn ->
      table = store_state.table
      :mnesia.delete_table(table)
    end)

    %{store_state: store_state, runner_name: runner_name}
  end

  # --- A. Lifecycle ---

  describe "lifecycle" do
    test "start_link creates a Mnesia table", %{store_state: %{table: table}} do
      assert :mnesia.table_info(table, :type) == :set
    end

    test "table attributes are correct", %{store_state: %{table: table}} do
      assert :mnesia.table_info(table, :attributes) == [:workflow_id, :log, :updated_at]
    end

    test "idempotent table creation", %{runner_name: runner_name} do
      # Starting a second GenServer for the same table should not crash
      # (table already exists)
      assert {:ok, pid} =
               GenServer.start_link(MnesiaStore, runner_name: runner_name, disc_copies: false)

      GenServer.stop(pid)
    end
  end

  # --- B. CRUD ---

  describe "CRUD" do
    test "save and load round-trip", %{store_state: state} do
      log = [:event_1, :event_2]
      assert :ok = MnesiaStore.save(:wf_1, log, state)
      assert {:ok, ^log} = MnesiaStore.load(:wf_1, state)
    end

    test "load returns {:error, :not_found} for unknown ID", %{store_state: state} do
      assert {:error, :not_found} = MnesiaStore.load(:nonexistent, state)
    end

    test "save overwrites (upsert)", %{store_state: state} do
      MnesiaStore.save(:wf_1, [:old], state)
      MnesiaStore.save(:wf_1, [:new], state)
      assert {:ok, [:new]} = MnesiaStore.load(:wf_1, state)
    end

    test "delete removes entry", %{store_state: state} do
      MnesiaStore.save(:wf_1, [:data], state)
      assert :ok = MnesiaStore.delete(:wf_1, state)
      assert {:error, :not_found} = MnesiaStore.load(:wf_1, state)
    end

    test "checkpoint behaves same as save", %{store_state: state} do
      log = [:checkpoint_event]
      assert :ok = MnesiaStore.checkpoint(:wf_1, log, state)
      assert {:ok, ^log} = MnesiaStore.load(:wf_1, state)
    end
  end

  # --- C. Listing ---

  describe "listing" do
    test "list returns empty list when no entries", %{store_state: state} do
      assert {:ok, []} = MnesiaStore.list(state)
    end

    test "list returns all IDs", %{store_state: state} do
      MnesiaStore.save(:wf_a, [:a], state)
      MnesiaStore.save(:wf_b, [:b], state)
      MnesiaStore.save(:wf_c, [:c], state)

      {:ok, ids} = MnesiaStore.list(state)
      assert Enum.sort(ids) == [:wf_a, :wf_b, :wf_c]
    end

    test "exists? returns true for saved entries", %{store_state: state} do
      MnesiaStore.save(:wf_1, [:data], state)
      assert MnesiaStore.exists?(:wf_1, state)
    end

    test "exists? returns false for missing entries", %{store_state: state} do
      refute MnesiaStore.exists?(:missing, state)
    end
  end

  # --- D. Serialization round-trip ---

  describe "serialization round-trip" do
    test "save and restore a real Workflow build_log", %{store_state: state} do
      step = Runic.step(fn x -> x * 2 end, name: :double)
      workflow = Workflow.new() |> Workflow.add(step)

      log = Workflow.build_log(workflow)
      assert :ok = MnesiaStore.save(:my_workflow, log, state)

      {:ok, loaded_log} = MnesiaStore.load(:my_workflow, state)
      assert loaded_log == log

      restored = Workflow.from_log(loaded_log)
      ran = Workflow.react_until_satisfied(restored, 5)
      assert Workflow.raw_productions(ran) == [10]
    end

    test "save and restore a full Workflow.log with reactions", %{store_state: state} do
      step_a = Runic.step(fn x -> x + 1 end, name: :add)
      step_b = Runic.step(fn x -> x * 2 end, name: :double)
      workflow = Runic.workflow(steps: [{step_a, [step_b]}])

      ran = Workflow.react_until_satisfied(workflow, 5)
      log = Workflow.log(ran)

      assert :ok = MnesiaStore.save(:pipeline_wf, log, state)
      {:ok, loaded_log} = MnesiaStore.load(:pipeline_wf, state)

      restored = Workflow.from_log(loaded_log)
      assert Workflow.raw_productions(restored) == Workflow.raw_productions(ran)
    end
  end

  # --- E. Concurrent access ---

  describe "concurrent access" do
    test "multiple processes writing different IDs don't interfere", %{store_state: state} do
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            id = :"wf_#{i}"
            MnesiaStore.save(id, [i], state)
            {:ok, [^i]} = MnesiaStore.load(id, state)
            :ok
          end)
        end

      results = Task.await_many(tasks, 5_000)
      assert Enum.all?(results, &(&1 == :ok))
    end

    test "read-after-write from different process sees the write", %{store_state: state} do
      MnesiaStore.save(:shared, [:written], state)

      result =
        Task.async(fn -> MnesiaStore.load(:shared, state) end)
        |> Task.await(5_000)

      assert {:ok, [:written]} = result
    end
  end

  # --- F. Integration with Runner ---

  describe "Runner integration" do
    test "Runner with Mnesia store runs a workflow end-to-end" do
      runner_name = :"test_mnesia_runner_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Runic.Runner, name: runner_name, store: MnesiaStore, store_opts: [disc_copies: false]}
      )

      step = Runic.step(fn x -> x + 1 end, name: :add_one)
      workflow = Runic.workflow(steps: [step])

      {:ok, _pid} = Runic.Runner.start_workflow(runner_name, :wf_mnesia, workflow)
      :ok = Runic.Runner.run(runner_name, :wf_mnesia, 5)
      assert_workflow_idle(runner_name, :wf_mnesia)

      {:ok, results} = Runic.Runner.get_results(runner_name, :wf_mnesia)
      assert 6 in results
    end

    test "Runner with Mnesia store persists and resumes" do
      runner_name = :"test_mnesia_resume_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Runic.Runner, name: runner_name, store: MnesiaStore, store_opts: [disc_copies: false]}
      )

      step = Runic.step(fn x -> x * 3 end, name: :triple)
      workflow = Runic.workflow(steps: [step])

      {:ok, _pid} = Runic.Runner.start_workflow(runner_name, :wf_persist, workflow)
      :ok = Runic.Runner.run(runner_name, :wf_persist, 7)
      assert_workflow_idle(runner_name, :wf_persist)

      {:ok, original_results} = Runic.Runner.get_results(runner_name, :wf_persist)
      :ok = Runic.Runner.stop(runner_name, :wf_persist)
      Process.sleep(50)

      {:ok, _pid2} = Runic.Runner.resume(runner_name, :wf_persist)
      {:ok, resumed_results} = Runic.Runner.get_results(runner_name, :wf_persist)
      assert Enum.sort(original_results) == Enum.sort(resumed_results)
    end

    test "Runner with Mnesia store supports multi-step pipeline" do
      runner_name = :"test_mnesia_pipeline_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Runic.Runner, name: runner_name, store: MnesiaStore, store_opts: [disc_copies: false]}
      )

      step_a = Runic.step(fn x -> x + 1 end, name: :step_a)
      step_b = Runic.step(fn x -> x * 2 end, name: :step_b)
      workflow = Runic.workflow(steps: [{step_a, [step_b]}])

      {:ok, _pid} = Runic.Runner.start_workflow(runner_name, :wf_pipe, workflow)
      :ok = Runic.Runner.run(runner_name, :wf_pipe, 5)
      assert_workflow_idle(runner_name, :wf_pipe)

      {:ok, results} = Runic.Runner.get_results(runner_name, :wf_pipe)
      # (5 + 1) * 2 = 12
      assert 12 in results
    end
  end

  # --- G. Mnesia-specific ---

  describe "Mnesia-specific" do
    test "ram_copies table is set type", %{store_state: %{table: table}} do
      assert :mnesia.table_info(table, :type) == :set
      assert node() in :mnesia.table_info(table, :ram_copies)
    end

    test "table survives store process restart", %{store_state: _state} do
      # Use an isolated runner for this test to avoid conflicts with the setup supervisor
      runner = :"test_mnesia_restart_#{System.unique_integer([:positive])}"
      name = Module.concat(runner, Store)

      {:ok, pid} =
        GenServer.start_link(MnesiaStore, [runner_name: runner, disc_copies: false], name: name)

      {:ok, restart_state} = MnesiaStore.init_store(runner_name: runner)
      MnesiaStore.save(:survivor, [:data], restart_state)

      # The table is owned by Mnesia, not the GenServer process.
      # Stopping and restarting the GenServer should not lose data.
      GenServer.stop(pid)

      {:ok, _pid2} =
        GenServer.start_link(MnesiaStore, [runner_name: runner, disc_copies: false], name: name)

      assert {:ok, [:data]} = MnesiaStore.load(:survivor, restart_state)

      on_exit(fn -> :mnesia.delete_table(restart_state.table) end)
    end

    test "delete on non-existent key is a no-op", %{store_state: state} do
      assert :ok = MnesiaStore.delete(:nonexistent, state)
    end
  end

  # --- Helpers ---

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
