defmodule Runic.WorkflowResultsTest do
  use ExUnit.Case, async: true

  require Runic
  alias Runic.Workflow
  alias Runic.Workflow.Fact

  describe "results/1 with output_ports" do
    test "extracts values using :from bindings" do
      workflow =
        Runic.workflow(
          name: :pipeline,
          steps: [
            {Runic.step(fn x -> x + 1 end, name: :add),
             [Runic.step(fn x -> x * 2 end, name: :double)]}
          ],
          output_ports: [result: [type: :integer, from: :double]]
        )

      result =
        workflow
        |> Workflow.react_until_satisfied(5)
        |> Workflow.results()

      assert %{result: 12} = result
    end

    test "uses port name as component name when no :from" do
      workflow =
        Runic.workflow(
          name: :simple,
          steps: [Runic.step(fn x -> x * 2 end, name: :out)],
          output_ports: [out: [type: :integer]]
        )

      result =
        workflow
        |> Workflow.react_until_satisfied(5)
        |> Workflow.results()

      assert %{out: 10} = result
    end

    test "port with cardinality: :many returns full list" do
      workflow =
        Runic.workflow(
          name: :multi,
          steps: [
            Runic.step(fn x -> x + 1 end, name: :a),
            Runic.step(fn x -> x + 2 end, name: :b)
          ],
          output_ports: [items: [from: :a, cardinality: :many]]
        )

      result =
        workflow
        |> Workflow.react_until_satisfied(5)
        |> Workflow.results()

      assert %{items: items} = result
      assert is_list(items)
      assert 6 in items
    end

    test "port with cardinality: :one returns last value" do
      workflow =
        Runic.workflow(
          name: :single,
          steps: [Runic.step(fn x -> x * 3 end, name: :triple)],
          output_ports: [val: [from: :triple, cardinality: :one]]
        )

      result =
        workflow
        |> Workflow.react_until_satisfied(4)
        |> Workflow.results()

      assert %{val: 12} = result
    end

    test "component with no productions returns nil for :one, [] for :many" do
      workflow =
        Runic.workflow(
          name: :empty,
          steps: [Runic.step(fn x -> x end, name: :noop)],
          output_ports: [
            single: [from: :noop, cardinality: :one],
            multi: [from: :noop, cardinality: :many]
          ]
        )

      # Don't feed any input — no productions
      result = Workflow.results(workflow)

      assert %{single: nil, multi: []} = result
    end

    test "multiple output ports each extract independently" do
      workflow =
        Runic.workflow(
          name: :multi_out,
          steps: [
            Runic.step(fn x -> x + 1 end, name: :add),
            Runic.step(fn x -> x * 2 end, name: :mult)
          ],
          output_ports: [
            added: [from: :add, type: :integer],
            multiplied: [from: :mult, type: :integer]
          ]
        )

      result =
        workflow
        |> Workflow.react_until_satisfied(5)
        |> Workflow.results()

      assert %{added: 6, multiplied: 10} = result
    end
  end

  describe "results/1 without output_ports" do
    test "falls back to raw_productions_by_component" do
      workflow =
        Runic.workflow(
          name: :no_ports,
          steps: [
            Runic.step(fn x -> x + 1 end, name: :add),
            Runic.step(fn x -> x * 2 end, name: :mult)
          ]
        )

      result =
        workflow
        |> Workflow.react_until_satisfied(5)
        |> Workflow.results()

      assert %{add: [6], mult: [10]} = result
    end
  end

  describe "results/2 explicit component selection" do
    test "extracts named components regardless of output_ports" do
      workflow =
        Runic.workflow(
          name: :with_ports,
          steps: [
            Runic.step(fn x -> x + 1 end, name: :add),
            Runic.step(fn x -> x * 2 end, name: :mult)
          ],
          output_ports: [result: [from: :add]]
        )

      result =
        workflow
        |> Workflow.react_until_satisfied(5)
        |> Workflow.results([:mult])

      assert %{mult: 10} = result
      refute Map.has_key?(result, :add)
    end

    test "returns last value per component" do
      workflow =
        Runic.workflow(
          name: :simple,
          steps: [Runic.step(fn x -> x * 2 end, name: :double)]
        )

      result =
        workflow
        |> Workflow.react_until_satisfied(5)
        |> Workflow.results([:double])

      assert %{double: 10} = result
    end

    test "missing component name returns nil" do
      workflow =
        Runic.workflow(
          name: :simple,
          steps: [Runic.step(fn x -> x end, name: :noop)]
        )

      result =
        workflow
        |> Workflow.react_until_satisfied(5)
        |> Workflow.results([:nonexistent])

      assert %{nonexistent: nil} = result
    end
  end

  describe "results/3 options" do
    test "facts: true returns %Fact{} structs" do
      workflow =
        Runic.workflow(
          name: :facts_test,
          steps: [Runic.step(fn x -> x * 2 end, name: :double)]
        )

      result =
        workflow
        |> Workflow.react_until_satisfied(5)
        |> Workflow.results([:double], facts: true)

      assert %{double: %Fact{value: 10}} = result
    end

    test "all: true returns list of all values for :one cardinality" do
      workflow =
        Runic.workflow(
          name: :all_test,
          steps: [Runic.step(fn x -> x * 2 end, name: :double)],
          output_ports: [result: [from: :double, cardinality: :one]]
        )

      result =
        workflow
        |> Workflow.react_until_satisfied(5)
        |> Workflow.results(nil, all: true)

      assert %{result: values} = result
      assert is_list(values)
      assert 10 in values
    end

    test "all: true with :many cardinality still returns list" do
      workflow =
        Runic.workflow(
          name: :all_many,
          steps: [Runic.step(fn x -> x * 2 end, name: :double)],
          output_ports: [result: [from: :double, cardinality: :many]]
        )

      result =
        workflow
        |> Workflow.react_until_satisfied(5)
        |> Workflow.results(nil, all: true)

      assert %{result: values} = result
      assert is_list(values)
    end

    test "facts: true, all: true returns list of facts" do
      workflow =
        Runic.workflow(
          name: :both_opts,
          steps: [Runic.step(fn x -> x * 2 end, name: :double)]
        )

      result =
        workflow
        |> Workflow.react_until_satisfied(5)
        |> Workflow.results([:double], facts: true, all: true)

      assert %{double: facts} = result
      assert is_list(facts)
      assert Enum.all?(facts, &match?(%Fact{}, &1))
    end

    test "default opts match results/1 behavior" do
      workflow =
        Runic.workflow(
          name: :defaults,
          steps: [Runic.step(fn x -> x * 2 end, name: :double)],
          output_ports: [result: [from: :double]]
        )

      executed = Workflow.react_until_satisfied(workflow, 5)

      assert Workflow.results(executed) == Workflow.results(executed, nil, [])
    end

    test "nil component_names with opts uses output port contract" do
      workflow =
        Runic.workflow(
          name: :nil_names,
          steps: [Runic.step(fn x -> x * 2 end, name: :double)],
          output_ports: [result: [from: :double]]
        )

      result =
        workflow
        |> Workflow.react_until_satisfied(5)
        |> Workflow.results(nil, facts: true)

      assert %{result: %Fact{value: 10}} = result
    end

    test "explicit component_names with opts uses component selection" do
      workflow =
        Runic.workflow(
          name: :explicit_opts,
          steps: [
            Runic.step(fn x -> x + 1 end, name: :add),
            Runic.step(fn x -> x * 2 end, name: :mult)
          ],
          output_ports: [result: [from: :add]]
        )

      result =
        workflow
        |> Workflow.react_until_satisfied(5)
        |> Workflow.results([:mult], facts: true)

      assert %{mult: %Fact{value: 10}} = result
      refute Map.has_key?(result, :add)
      refute Map.has_key?(result, :result)
    end

    test "no output_ports fallback with facts: true returns productions_by_component" do
      workflow =
        Runic.workflow(
          name: :fallback_facts,
          steps: [Runic.step(fn x -> x * 2 end, name: :double)]
        )

      result =
        workflow
        |> Workflow.react_until_satisfied(5)
        |> Workflow.results(nil, facts: true)

      assert %{double: [%Fact{value: 10}]} = result
    end
  end

  describe "results with stateful components" do
    test "accumulator with all: true returns all produced states" do
      acc = Runic.accumulator(0, fn x, state -> state + x end, name: :running_sum)

      workflow =
        Workflow.new(name: :acc_test)
        |> Workflow.add(acc)
        |> Map.put(:output_ports, total: [from: :running_sum, cardinality: :many])

      result =
        workflow
        |> Workflow.react(1)
        |> Workflow.react(2)
        |> Workflow.react(3)
        |> Workflow.results()

      assert %{total: values} = result
      assert is_list(values)
      assert 6 in values
      assert 0 in values
    end

    test "accumulator with single reaction returns value" do
      acc = Runic.accumulator(0, fn x, state -> state + x end, name: :running_sum)

      workflow =
        Workflow.new(name: :acc_single)
        |> Workflow.add(acc)
        |> Map.put(:output_ports, total: [from: :running_sum])

      result =
        workflow
        |> Workflow.react(5)
        |> Workflow.results()

      assert %{total: _value} = result
    end
  end
end
