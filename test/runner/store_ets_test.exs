defmodule Runic.Runner.Store.ETSTest do
  use ExUnit.Case, async: true

  alias Runic.Runner.Store.ETS
  alias Runic.Workflow

  require Runic

  setup do
    runner_name = :"test_store_#{System.unique_integer([:positive])}"
    start_supervised!({ETS, runner_name: runner_name})
    {:ok, store_state} = ETS.init_store(runner_name: runner_name)
    %{store_state: store_state, runner_name: runner_name}
  end

  # --- A. Lifecycle ---

  describe "lifecycle" do
    test "start_link creates a named ETS table", %{store_state: %{table: table}} do
      assert :ets.info(table) != :undefined
    end

    test "table survives caller exit", %{store_state: store_state} do
      ETS.save(:wf_1, [:event_a], store_state)

      task =
        Task.async(fn ->
          ETS.load(:wf_1, store_state)
        end)

      assert {:ok, [:event_a]} = Task.await(task)
    end
  end

  # --- B. CRUD ---

  describe "CRUD" do
    test "save and load round-trip", %{store_state: state} do
      log = [:event_1, :event_2]
      assert :ok = ETS.save(:wf_1, log, state)
      assert {:ok, ^log} = ETS.load(:wf_1, state)
    end

    test "load returns {:error, :not_found} for unknown ID", %{store_state: state} do
      assert {:error, :not_found} = ETS.load(:nonexistent, state)
    end

    test "save overwrites (upsert)", %{store_state: state} do
      ETS.save(:wf_1, [:old], state)
      ETS.save(:wf_1, [:new], state)
      assert {:ok, [:new]} = ETS.load(:wf_1, state)
    end

    test "delete removes entry", %{store_state: state} do
      ETS.save(:wf_1, [:data], state)
      assert :ok = ETS.delete(:wf_1, state)
      assert {:error, :not_found} = ETS.load(:wf_1, state)
    end

    test "checkpoint behaves same as save", %{store_state: state} do
      log = [:checkpoint_event]
      assert :ok = ETS.checkpoint(:wf_1, log, state)
      assert {:ok, ^log} = ETS.load(:wf_1, state)
    end
  end

  # --- C. Listing ---

  describe "listing" do
    test "list returns empty list when no entries", %{store_state: state} do
      assert {:ok, []} = ETS.list(state)
    end

    test "list returns all IDs", %{store_state: state} do
      ETS.save(:wf_a, [:a], state)
      ETS.save(:wf_b, [:b], state)
      ETS.save(:wf_c, [:c], state)

      {:ok, ids} = ETS.list(state)
      assert Enum.sort(ids) == [:wf_a, :wf_b, :wf_c]
    end

    test "exists? returns true for saved entries", %{store_state: state} do
      ETS.save(:wf_1, [:data], state)
      assert ETS.exists?(:wf_1, state)
    end

    test "exists? returns false for missing entries", %{store_state: state} do
      refute ETS.exists?(:missing, state)
    end
  end

  # --- D. Serialization round-trip ---

  describe "serialization round-trip" do
    test "save and restore a real Workflow build_log", %{store_state: state} do
      step = Runic.step(fn x -> x * 2 end, name: :double)
      workflow = Workflow.new() |> Workflow.add(step)

      log = Workflow.build_log(workflow)
      assert :ok = ETS.save(:my_workflow, log, state)

      {:ok, loaded_log} = ETS.load(:my_workflow, state)
      assert loaded_log == log

      restored = Workflow.from_log(loaded_log)
      ran = Workflow.react_until_satisfied(restored, 5)
      assert Workflow.raw_productions(ran) == [10]
    end
  end

  # --- E. Concurrent access ---

  describe "concurrent access" do
    test "multiple processes writing different IDs don't interfere", %{store_state: state} do
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            id = :"wf_#{i}"
            ETS.save(id, [i], state)
            {:ok, [^i]} = ETS.load(id, state)
            :ok
          end)
        end

      results = Task.await_many(tasks, 5_000)
      assert Enum.all?(results, &(&1 == :ok))
    end

    test "read-after-write from different process sees the write", %{store_state: state} do
      ETS.save(:shared, [:written], state)

      result =
        Task.async(fn -> ETS.load(:shared, state) end)
        |> Task.await(5_000)

      assert {:ok, [:written]} = result
    end
  end
end
