defmodule Runic.Runner.RunnerTest do
  use ExUnit.Case, async: true

  describe "supervision tree" do
    test "starts with a name" do
      runner_name = :"test_runner_#{System.unique_integer([:positive])}"
      pid = start_supervised!({Runic.Runner, name: runner_name})
      assert Process.alive?(pid)
    end

    test "starts all children" do
      runner_name = :"test_runner_#{System.unique_integer([:positive])}"
      start_supervised!({Runic.Runner, name: runner_name})

      assert Process.whereis(Module.concat(runner_name, Store)) |> Process.alive?()
      assert Process.whereis(Module.concat(runner_name, Registry)) |> Process.alive?()
      assert Process.whereis(Module.concat(runner_name, TaskSupervisor)) |> Process.alive?()
      assert Process.whereis(Module.concat(runner_name, WorkerSupervisor)) |> Process.alive?()
    end

    test "raises without :name" do
      assert_raise KeyError, fn ->
        Runic.Runner.start_link([])
      end
    end

    test "ETS table exists after startup" do
      runner_name = :"test_runner_#{System.unique_integer([:positive])}"
      start_supervised!({Runic.Runner, name: runner_name})
      table_name = Module.concat(runner_name, StoreTable)
      assert :ets.info(table_name) != :undefined
    end
  end

  describe "naming" do
    test "multiple runners with different names don't conflict" do
      runner1 = :"test_runner_#{System.unique_integer([:positive])}"
      runner2 = :"test_runner_#{System.unique_integer([:positive])}"

      pid1 = start_supervised!({Runic.Runner, name: runner1}, id: :runner1)
      pid2 = start_supervised!({Runic.Runner, name: runner2}, id: :runner2)

      assert pid1 != pid2
      assert Process.alive?(pid1)
      assert Process.alive?(pid2)
    end
  end

  describe "store access" do
    test "get_store returns the store module and state" do
      runner_name = :"test_runner_#{System.unique_integer([:positive])}"
      start_supervised!({Runic.Runner, name: runner_name})

      {store_mod, store_state} = Runic.Runner.get_store(runner_name)
      assert store_mod == Runic.Runner.Store.ETS
      assert is_map(store_state)
      assert Map.has_key?(store_state, :table)
    end
  end

  describe "API shell" do
    test "lookup returns nil for non-existent workflow" do
      runner_name = :"test_runner_#{System.unique_integer([:positive])}"
      start_supervised!({Runic.Runner, name: runner_name})
      assert Runic.Runner.lookup(runner_name, :nonexistent) == nil
    end

    test "list_workflows returns empty list initially" do
      runner_name = :"test_runner_#{System.unique_integer([:positive])}"
      start_supervised!({Runic.Runner, name: runner_name})
      assert Runic.Runner.list_workflows(runner_name) == []
    end

    test "run returns {:error, :not_found} for non-existent workflow" do
      runner_name = :"test_runner_#{System.unique_integer([:positive])}"
      start_supervised!({Runic.Runner, name: runner_name})
      assert Runic.Runner.run(runner_name, :nonexistent, :input) == {:error, :not_found}
    end

    test "get_results returns {:error, :not_found} for non-existent workflow" do
      runner_name = :"test_runner_#{System.unique_integer([:positive])}"
      start_supervised!({Runic.Runner, name: runner_name})
      assert Runic.Runner.get_results(runner_name, :nonexistent) == {:error, :not_found}
    end

    test "get_workflow returns {:error, :not_found} for non-existent workflow" do
      runner_name = :"test_runner_#{System.unique_integer([:positive])}"
      start_supervised!({Runic.Runner, name: runner_name})
      assert Runic.Runner.get_workflow(runner_name, :nonexistent) == {:error, :not_found}
    end

    test "stop returns {:error, :not_found} for non-existent workflow" do
      runner_name = :"test_runner_#{System.unique_integer([:positive])}"
      start_supervised!({Runic.Runner, name: runner_name})
      assert Runic.Runner.stop(runner_name, :nonexistent) == {:error, :not_found}
    end

    test "resume returns {:error, :not_found} when no persisted state" do
      runner_name = :"test_runner_#{System.unique_integer([:positive])}"
      start_supervised!({Runic.Runner, name: runner_name})
      assert Runic.Runner.resume(runner_name, :nonexistent) == {:error, :not_found}
    end
  end

  describe "custom options" do
    test "accepts custom store options" do
      runner_name = :"test_runner_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Runic.Runner, name: runner_name, store: Runic.Runner.Store.ETS, store_opts: []}
      )

      assert Process.whereis(Module.concat(runner_name, Store)) |> Process.alive?()
    end
  end
end
