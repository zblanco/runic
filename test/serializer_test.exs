defmodule SerializerTest do
  use ExUnit.Case
  require Runic

  alias Runic.Workflow

  describe "Workflow.to_mermaid/2" do
    test "serializes a simple workflow to Mermaid flowchart" do
      wrk =
        Runic.workflow(
          name: "test workflow",
          steps: [
            Runic.step(fn num -> num + 1 end, name: :add_one)
          ]
        )

      mermaid = Workflow.to_mermaid(wrk)

      assert mermaid =~ "flowchart TB"
      assert mermaid =~ "add_one"
    end

    test "serializes workflow with branching" do
      wrk =
        Runic.workflow(
          name: "branching workflow",
          steps: [
            {Runic.step(fn x -> x end, name: :start),
             [
               Runic.step(fn x -> x + 1 end, name: :branch_a),
               Runic.step(fn x -> x * 2 end, name: :branch_b)
             ]}
          ]
        )

      mermaid = Workflow.to_mermaid(wrk)

      assert mermaid =~ "start"
      assert mermaid =~ "branch_a"
      assert mermaid =~ "branch_b"
      # Should have flow edges
      assert mermaid =~ "-->"
    end

    test "respects direction option" do
      wrk = Runic.workflow(name: "test")

      mermaid_tb = Workflow.to_mermaid(wrk, direction: :TB)
      mermaid_lr = Workflow.to_mermaid(wrk, direction: :LR)

      assert mermaid_tb =~ "flowchart TB"
      assert mermaid_lr =~ "flowchart LR"
    end

    test "includes style definitions" do
      wrk = Runic.workflow(name: "test")

      mermaid = Workflow.to_mermaid(wrk)

      assert mermaid =~ "classDef step"
      assert mermaid =~ "classDef rule"
      assert mermaid =~ "classDef root"
    end

    test "includes memory edges when requested" do
      wrk =
        Runic.workflow(
          name: "test",
          steps: [Runic.step(fn x -> x + 1 end, name: :add)]
        )
        |> Workflow.plan_eagerly(1)
        |> Workflow.react()

      mermaid_with_memory = Workflow.to_mermaid(wrk, include_memory: true)
      mermaid_without = Workflow.to_mermaid(wrk, include_memory: false)

      # Memory version should have causal edges
      assert mermaid_with_memory =~ "Causal edges"
      refute mermaid_without =~ "Causal edges"
    end
  end

  describe "Workflow.to_mermaid_sequence/2" do
    test "generates sequence diagram from causal reactions" do
      wrk =
        Runic.workflow(
          name: "sequence test",
          steps: [
            {Runic.step(fn x -> x + 1 end, name: :first),
             [Runic.step(fn x -> x * 2 end, name: :second)]}
          ]
        )
        |> Workflow.react_until_satisfied(5)

      sequence = Workflow.to_mermaid_sequence(wrk)

      assert sequence =~ "sequenceDiagram"
    end

    test "handles workflow with no reactions" do
      wrk = Runic.workflow(name: "empty")

      sequence = Workflow.to_mermaid_sequence(wrk)

      assert sequence =~ "sequenceDiagram"
      assert sequence =~ "No causal reactions yet"
    end
  end

  describe "Workflow.to_dot/2" do
    test "serializes workflow to DOT format" do
      wrk =
        Runic.workflow(
          name: "dot test",
          steps: [
            Runic.step(fn x -> x + 1 end, name: :increment)
          ]
        )

      dot = Workflow.to_dot(wrk)

      assert dot =~ "digraph"
      assert dot =~ "rankdir=TB"
      assert dot =~ "increment"
      assert dot =~ "->"
    end

    test "respects direction option" do
      wrk = Runic.workflow(name: "test")

      dot = Workflow.to_dot(wrk, direction: :LR)

      assert dot =~ "rankdir=LR"
    end

    test "escapes special characters in labels" do
      wrk =
        Runic.workflow(
          name: "test with \"quotes\"",
          steps: [
            Runic.step(fn x -> x end, name: "step with\nnewline")
          ]
        )

      dot = Workflow.to_dot(wrk)

      # Should properly escape quotes in DOT format (\" is valid DOT escaping)
      assert dot =~ "\\\""
      # Newlines should be escaped as \\n in the output
      assert dot =~ "step with"
    end
  end

  describe "Workflow.to_cytoscape/2" do
    test "returns list of elements" do
      wrk =
        Runic.workflow(
          name: "cytoscape test",
          steps: [
            Runic.step(fn x -> x + 1 end, name: :step1)
          ]
        )

      elements = Workflow.to_cytoscape(wrk)

      assert is_list(elements)
      assert Enum.all?(elements, &match?(%{data: %{}}, &1))
    end

    test "includes nodes with proper structure" do
      wrk =
        Runic.workflow(
          name: "test",
          steps: [Runic.step(fn x -> x end, name: :my_step)]
        )

      elements = Workflow.to_cytoscape(wrk)

      node = Enum.find(elements, fn el ->
        el[:data][:name] == "my_step"
      end)

      assert node != nil
      assert node.data[:id] != nil
      assert node.data[:kind] == "step"
      assert node.data[:background_color] != nil
    end

    test "includes edges with proper structure" do
      wrk =
        Runic.workflow(
          name: "test",
          steps: [
            {Runic.step(fn x -> x end, name: :parent),
             [Runic.step(fn x -> x end, name: :child)]}
          ]
        )

      elements = Workflow.to_cytoscape(wrk)

      edge = Enum.find(elements, fn el ->
        el[:data][:label] == "flow"
      end)

      assert edge != nil
      assert edge.data[:source] != nil
      assert edge.data[:target] != nil
    end
  end

  describe "Workflow.to_edgelist/2" do
    test "returns list of tuples by default" do
      wrk =
        Runic.workflow(
          name: "edgelist test",
          steps: [
            {Runic.step(fn x -> x end, name: :a),
             [Runic.step(fn x -> x end, name: :b)]}
          ]
        )

      edges = Workflow.to_edgelist(wrk)

      assert is_list(edges)
      assert Enum.all?(edges, fn e -> tuple_size(e) == 3 end)

      # Should contain root -> a and a -> b edges
      assert Enum.any?(edges, fn {from, to, label} ->
        from == :root and to == :a and label == :flow
      end)

      assert Enum.any?(edges, fn {from, to, label} ->
        from == :a and to == :b and label == :flow
      end)
    end

    test "returns string format when requested" do
      wrk =
        Runic.workflow(
          name: "test",
          steps: [Runic.step(fn x -> x end, name: :step1)]
        )

      result = Workflow.to_edgelist(wrk, format: :string)

      assert is_binary(result)
      assert result =~ "root -> step1 [flow]"
    end

    test "includes memory edges when requested" do
      wrk =
        Runic.workflow(
          name: "test",
          steps: [Runic.step(fn x -> x + 1 end, name: :add)]
        )
        |> Workflow.plan_eagerly(1)
        |> Workflow.react()

      edges_with = Workflow.to_edgelist(wrk, include_memory: true, include_facts: true)
      edges_without = Workflow.to_edgelist(wrk, include_memory: false)

      # Memory version should have more edges
      assert length(edges_with) > length(edges_without)
    end
  end

  describe "Serializer helper functions" do
    alias Runic.Workflow.Serializer

    test "node_id generates unique IDs" do
      step1 = Runic.step(fn x -> x end, name: :step1)
      step2 = Runic.step(fn x -> x + 1 end, name: :step2)

      id1 = Serializer.node_id(step1)
      id2 = Serializer.node_id(step2)

      refute id1 == id2
    end

    test "node_label extracts name when present" do
      step = Runic.step(fn x -> x end, name: :my_step_name)

      label = Serializer.node_label(step)

      assert label == "my_step_name"
    end

    test "escape_label handles special characters" do
      assert Serializer.escape_label("test[brackets]") =~ "brackets"
      assert Serializer.escape_label("test{braces}") =~ "braces"
      assert Serializer.escape_label("test<arrows>") =~ "arrows"
      refute Serializer.escape_label("test\nline") =~ "\n"
    end

    test "node_shape returns appropriate shapes" do
      step = Runic.step(fn x -> x end, name: :s)
      assert {_, "[", "]"} = Serializer.node_shape(step)

      assert {_, "((", "))"} = Serializer.node_shape(%Runic.Workflow.Root{})
    end
  end

  describe "Workflow with rules" do
    test "serializes rules to mermaid" do
      wrk =
        Runic.workflow(
          name: "rule workflow",
          rules: [
            Runic.rule(fn x when x > 0 -> :positive end, name: :check_positive)
          ]
        )

      mermaid = Workflow.to_mermaid(wrk)

      assert mermaid =~ "check_positive"
    end
  end

  describe "Workflow with map/reduce" do
    test "serializes map component" do
      map_component = Runic.map(fn x -> x * 2 end, name: :double_each)

      wrk =
        Runic.workflow(name: "map workflow")
        |> Workflow.add(map_component)

      mermaid = Workflow.to_mermaid(wrk)

      assert mermaid =~ "double_each"
    end
  end
end
