defmodule Runic.WorkflowBoundaryTest do
  use ExUnit.Case, async: true
  require Runic
  alias Runic.Workflow

  describe "workflow boundary ports" do
    test "workflow without ports returns empty contracts" do
      workflow =
        Runic.workflow(
          name: :no_ports,
          steps: [Runic.step(fn x -> x + 1 end, name: :add)]
        )

      assert Runic.Component.inputs(workflow) == []
      assert Runic.Component.outputs(workflow) == []
    end

    test "workflow with input_ports surfaces them via Component.inputs/1" do
      workflow =
        Runic.workflow(
          name: :with_inputs,
          steps: [Runic.step(fn x -> x + 1 end, name: :add)],
          input_ports: [
            value: [type: :integer, doc: "Value to process"]
          ]
        )

      inputs = Runic.Component.inputs(workflow)
      assert [{:value, opts}] = inputs
      assert Keyword.get(opts, :type) == :integer
      assert Keyword.get(opts, :doc) == "Value to process"
    end

    test "workflow with output_ports surfaces them via Component.outputs/1" do
      workflow =
        Runic.workflow(
          name: :with_outputs,
          steps: [Runic.step(fn x -> x * 2 end, name: :double)],
          output_ports: [
            result: [type: :integer, doc: "Doubled value"]
          ]
        )

      outputs = Runic.Component.outputs(workflow)
      assert [{:result, opts}] = outputs
      assert Keyword.get(opts, :type) == :integer
    end

    test "workflow with both input and output ports" do
      workflow =
        Runic.workflow(
          name: :full_ports,
          steps: [Runic.step(fn x -> x * 2 end, name: :double)],
          input_ports: [in: [type: :integer]],
          output_ports: [out: [type: :integer]]
        )

      assert [{:in, _}] = Runic.Component.inputs(workflow)
      assert [{:out, _}] = Runic.Component.outputs(workflow)
    end
  end

  describe "boundary port bindings" do
    test "input port with valid :to binding succeeds" do
      workflow =
        Runic.workflow(
          name: :bound_input,
          steps: [Runic.step(fn x -> x + 1 end, name: :add)],
          input_ports: [
            value: [type: :integer, to: :add]
          ]
        )

      assert workflow.input_ports == [value: [type: :integer, to: :add]]
    end

    test "output port with valid :from binding succeeds" do
      workflow =
        Runic.workflow(
          name: :bound_output,
          steps: [Runic.step(fn x -> x * 2 end, name: :double)],
          output_ports: [
            result: [type: :integer, from: :double]
          ]
        )

      assert workflow.output_ports == [result: [type: :integer, from: :double]]
    end

    test "input port with invalid :to binding raises" do
      assert_raise ArgumentError, ~r/references component :nonexistent/, fn ->
        Runic.workflow(
          name: :bad_binding,
          steps: [Runic.step(fn x -> x end, name: :step)],
          input_ports: [
            value: [type: :any, to: :nonexistent]
          ]
        )
      end
    end

    test "output port with invalid :from binding raises" do
      assert_raise ArgumentError, ~r/references component :nonexistent/, fn ->
        Runic.workflow(
          name: :bad_binding,
          steps: [Runic.step(fn x -> x end, name: :step)],
          output_ports: [
            result: [type: :any, from: :nonexistent]
          ]
        )
      end
    end

    test "ports without :to/:from bindings are valid" do
      workflow =
        Runic.workflow(
          name: :no_bindings,
          steps: [Runic.step(fn x -> x end, name: :step)],
          input_ports: [in: [type: :any]],
          output_ports: [out: [type: :any]]
        )

      assert workflow.input_ports == [in: [type: :any]]
      assert workflow.output_ports == [out: [type: :any]]
    end
  end

  describe "workflow-as-component composition" do
    test "workflow with ports composes into another workflow" do
      inner =
        Runic.workflow(
          name: :inner,
          steps: [Runic.step(fn x -> x + 1 end, name: :add)],
          input_ports: [in: [type: :integer]],
          output_ports: [out: [type: :integer]]
        )

      outer =
        Workflow.new(:outer)
        |> Workflow.add(Runic.step(fn x -> x end, name: :entry))
        |> Workflow.add(inner, to: :entry)

      assert outer
    end

    test "workflow with typed ports rejects incompatible downstream connection" do
      string_producer =
        Runic.step(fn x -> to_string(x) end,
          name: :string_producer,
          outputs: [out: [type: :string]]
        )

      inner =
        Runic.workflow(
          name: :inner,
          steps: [Runic.step(fn x -> x end, name: :passthrough)],
          input_ports: [in: [type: :integer]]
        )

      assert_raise Runic.IncompatiblePortError, fn ->
        Workflow.new(:outer)
        |> Workflow.add(string_producer)
        |> Workflow.add(inner, to: :string_producer)
      end
    end

    test "workflow without ports is connectable to anything" do
      inner =
        Runic.workflow(
          name: :inner,
          steps: [Runic.step(fn x -> x end, name: :passthrough)]
        )

      assert Runic.Component.connectable?(inner, Runic.step(fn x -> x end, name: :any))
    end

    test "connectable? returns false for incompatible workflow ports" do
      typed_workflow =
        Runic.workflow(
          name: :typed,
          steps: [Runic.step(fn x -> x end, name: :passthrough)],
          output_ports: [out: [type: :string]]
        )

      int_consumer =
        Runic.step(fn x -> x end,
          name: :consumer,
          inputs: [in: [type: :integer]]
        )

      refute Runic.Component.connectable?(typed_workflow, int_consumer)
    end

    test "connectable? returns true for compatible workflow ports" do
      typed_workflow =
        Runic.workflow(
          name: :typed,
          steps: [Runic.step(fn x -> x end, name: :passthrough)],
          output_ports: [out: [type: :integer]]
        )

      int_consumer =
        Runic.step(fn x -> x end,
          name: :consumer,
          inputs: [in: [type: :integer]]
        )

      assert Runic.Component.connectable?(typed_workflow, int_consumer)
    end
  end

  describe "workflow struct fields" do
    test "input_ports defaults to nil" do
      workflow = Workflow.new(:test)
      assert workflow.input_ports == nil
    end

    test "output_ports defaults to nil" do
      workflow = Workflow.new(:test)
      assert workflow.output_ports == nil
    end

    test "ports can be set directly on struct" do
      workflow = %Workflow{Workflow.new(:test) | input_ports: [in: [type: :any]]}
      assert [{:in, _}] = Runic.Component.inputs(workflow)
    end
  end
end
