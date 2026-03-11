defmodule Runic.Runner.ResultsTest do
  use ExUnit.Case, async: true

  require Runic
  alias Runic.Workflow
  alias Runic.Workflow.Fact

  setup do
    runner = :"results_runner_#{System.unique_integer([:positive])}"
    {:ok, _} = Runic.Runner.start_link(name: runner)
    {:ok, runner: runner}
  end

  describe "get_results/2 backward compatibility" do
    test "returns flat list of raw productions", %{runner: runner} do
      workflow =
        Runic.workflow(
          name: :compat,
          steps: [Runic.step(fn x -> x * 2 end, name: :double)]
        )

      {:ok, _pid} = Runic.Runner.start_workflow(runner, :compat, workflow)
      Runic.Runner.run(runner, :compat, 5)
      Process.sleep(50)

      {:ok, results} = Runic.Runner.get_results(runner, :compat)
      assert is_list(results)
      assert 10 in results
    end
  end

  describe "get_results/3 structured results" do
    test "empty opts uses Workflow.results/1", %{runner: runner} do
      workflow =
        Runic.workflow(
          name: :ports,
          steps: [Runic.step(fn x -> x * 2 end, name: :double)],
          output_ports: [result: [from: :double]]
        )

      {:ok, _pid} = Runic.Runner.start_workflow(runner, :ports, workflow)
      Runic.Runner.run(runner, :ports, 5)
      Process.sleep(50)

      {:ok, results} = Runic.Runner.get_results(runner, :ports, [])
      assert %{result: 10} = results
    end

    test "components option selects specific components", %{runner: runner} do
      workflow =
        Runic.workflow(
          name: :select,
          steps: [
            Runic.step(fn x -> x + 1 end, name: :add),
            Runic.step(fn x -> x * 2 end, name: :mult)
          ]
        )

      {:ok, _pid} = Runic.Runner.start_workflow(runner, :select, workflow)
      Runic.Runner.run(runner, :select, 5)
      Process.sleep(50)

      {:ok, results} = Runic.Runner.get_results(runner, :select, components: [:add])
      assert %{add: 6} = results
      refute Map.has_key?(results, :mult)
    end

    test "facts: true returns Fact structs", %{runner: runner} do
      workflow =
        Runic.workflow(
          name: :facts,
          steps: [Runic.step(fn x -> x * 2 end, name: :double)]
        )

      {:ok, _pid} = Runic.Runner.start_workflow(runner, :facts, workflow)
      Runic.Runner.run(runner, :facts, 5)
      Process.sleep(50)

      {:ok, results} =
        Runic.Runner.get_results(runner, :facts, components: [:double], facts: true)

      assert %{double: %Fact{value: 10}} = results
    end

    test "all: true returns all values as lists", %{runner: runner} do
      workflow =
        Runic.workflow(
          name: :all,
          steps: [Runic.step(fn x -> x * 2 end, name: :double)],
          output_ports: [result: [from: :double, cardinality: :one]]
        )

      {:ok, _pid} = Runic.Runner.start_workflow(runner, :all, workflow)
      Runic.Runner.run(runner, :all, 5)
      Process.sleep(50)

      {:ok, results} = Runic.Runner.get_results(runner, :all, all: true)
      assert %{result: values} = results
      assert is_list(values)
      assert 10 in values
    end

    test "not_found returns error", %{runner: runner} do
      assert {:error, :not_found} = Runic.Runner.get_results(runner, :nonexistent, [])
    end
  end
end
