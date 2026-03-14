defmodule Runic.ClosureOptionBindingsTest do
  @moduledoc """
  Tests that closure serialization captures variables used in step options
  (like `name:`) in addition to pinned variables in the function body.

  This reproduces a bug where dynamically composed workflows (e.g. building
  steps inside Enum.reduce with runtime-computed names) fail to reconstruct
  from their event log because the `name:` variable isn't captured in the
  closure's bindings.
  """
  use ExUnit.Case, async: true

  require Runic
  alias Runic.Workflow

  describe "closure captures option variables" do
    test "step with runtime name variable roundtrips through build_log/from_log" do
      # Simulates what WorkflowComposer.compose does:
      # building steps dynamically with runtime-computed names and pinned body vars
      tool_name = :attack
      args = %{target: "goblin"}
      step_name = :tool_abc123

      step =
        Runic.step(
          fn input ->
            {^tool_name, ^args, input}
          end,
          name: step_name
        )

      workflow = Workflow.new() |> Workflow.add(step)

      # Serialize the build log (this is what the event-sourced store persists)
      log = Workflow.build_log(workflow)
      binary = :erlang.term_to_binary(log)
      deserialized_log = :erlang.binary_to_term(binary)

      # Reconstruct the workflow from the log — this is where the bug manifests
      # as CompileError: "undefined variable step_name"
      rebuilt = Workflow.from_log(deserialized_log)

      # Verify the rebuilt workflow produces the same results
      results =
        rebuilt
        |> Workflow.react_until_satisfied("test_input")
        |> Workflow.raw_productions()

      assert {:attack, %{target: "goblin"}, "test_input"} in results
    end

    test "step with runtime name in Enum.reduce roundtrips through from_events" do
      # This is the exact pattern from WorkflowComposer.compose/1
      tool_calls = [
        %{"id" => "tc1", "tool" => "look", "args" => %{}},
        %{
          "id" => "tc2",
          "tool" => "move",
          "args" => %{"direction" => "north"},
          "depends_on" => "tc1"
        }
      ]

      {workflow, _added} =
        Enum.reduce(tool_calls, {Workflow.new(name: :tools), %{}}, fn tc, {wf, added} ->
          tc_id = tc["id"]
          tool = String.to_atom(tc["tool"])
          args = tc["args"] || %{}
          step_name = :"tool_#{tc_id}"

          step =
            Runic.step(
              fn input ->
                {^tool, ^args, input}
              end,
              name: step_name
            )

          dep = tc["depends_on"]

          wf =
            if dep && Map.has_key?(added, dep) do
              Workflow.add(wf, step, to: :"tool_#{dep}")
            else
              Workflow.add(wf, step)
            end

          {wf, Map.put(added, tc_id, step_name)}
        end)

      # Run the workflow to completion
      ran =
        workflow
        |> Workflow.enable_event_emission()
        |> Workflow.react_until_satisfied("go")

      # Collect all events for replay
      build_events = Workflow.build_log(workflow)
      runtime_events = Enum.reverse(ran.uncommitted_events)
      all_events = build_events ++ runtime_events

      # Serialize and deserialize (simulates DB persistence)
      binary = :erlang.term_to_binary(all_events)
      deserialized = :erlang.binary_to_term(binary)

      # Reconstruct from events — this crashes with CompileError
      rebuilt = Workflow.from_events(deserialized)

      assert Workflow.raw_productions(rebuilt) == Workflow.raw_productions(ran)
    end

    test "step name variable is included in closure bindings" do
      step_name = :my_dynamic_step

      step =
        Runic.step(
          fn x -> x end,
          name: step_name
        )

      # The closure should include step_name in its bindings
      assert step.closure != nil

      assert Map.has_key?(step.closure.bindings, :step_name),
             "Expected step_name in closure bindings, got: #{inspect(Map.keys(step.closure.bindings))}"
    end

    test "step keyword form captures name variable in bindings" do
      step_name = :keyword_step
      multiplier = 3

      step =
        Runic.step(
          work: fn x -> x * ^multiplier end,
          name: step_name
        )

      assert step.name == :keyword_step
      assert step.closure != nil
      assert Map.has_key?(step.closure.bindings, :step_name)
      assert Map.has_key?(step.closure.bindings, :multiplier)

      workflow = Workflow.new() |> Workflow.add(step)
      log = Workflow.build_log(workflow)
      rebuilt = Workflow.from_log(log)

      results =
        rebuilt
        |> Workflow.react_until_satisfied(5)
        |> Workflow.raw_productions()

      assert 15 in results
    end

    test "condition with runtime name variable roundtrips through build_log" do
      cond_name = :dynamic_check
      threshold = 10

      cond_node =
        Runic.condition(
          fn x -> x > ^threshold end,
          name: cond_name
        )

      assert cond_node.name == :dynamic_check
      assert cond_node.closure != nil
      assert Map.has_key?(cond_node.closure.bindings, :cond_name)
      assert Map.has_key?(cond_node.closure.bindings, :threshold)

      # Use the condition inside a rule (expression form) so we get a meaningful production
      rule =
        Runic.rule(
          fn x when x > 0 -> {:passed, ^threshold, x} end,
          name: cond_name
        )

      workflow = Workflow.new() |> Workflow.add(rule)
      log = Workflow.build_log(workflow)
      rebuilt = Workflow.from_log(log)

      results =
        rebuilt
        |> Workflow.react_until_satisfied(15)
        |> Workflow.raw_productions()

      assert {:passed, 10, 15} in results
    end

    test "rule expression form captures name variable in bindings" do
      rule_name = :dynamic_rule
      multiplier = 2

      r =
        Runic.rule(
          fn x when x > 0 -> x * ^multiplier end,
          name: rule_name
        )

      assert r.name == :dynamic_rule
      assert not is_nil(r.closure)
      assert Map.has_key?(r.closure.bindings, :rule_name)
      assert Map.has_key?(r.closure.bindings, :multiplier)

      workflow = Workflow.new() |> Workflow.add(r)
      log = Workflow.build_log(workflow)
      rebuilt = Workflow.from_log(log)

      results =
        rebuilt
        |> Workflow.react_until_satisfied(5)
        |> Workflow.raw_productions()

      assert 10 in results
    end

    test "rule keyword form captures name variable in bindings" do
      rule_name = :kw_rule
      factor = 3

      r =
        Runic.rule(
          condition: fn x -> x > 0 end,
          reaction: fn x -> x * ^factor end,
          name: rule_name
        )

      assert r.name == :kw_rule
      assert not is_nil(r.closure)
      assert Map.has_key?(r.closure.bindings, :rule_name)
      assert Map.has_key?(r.closure.bindings, :factor)

      workflow = Workflow.new() |> Workflow.add(r)
      log = Workflow.build_log(workflow)
      rebuilt = Workflow.from_log(log)

      results =
        rebuilt
        |> Workflow.react_until_satisfied(4)
        |> Workflow.raw_productions()

      assert 12 in results
    end

    test "map with runtime name variable roundtrips through build_log" do
      map_name = :dynamic_map
      offset = 100

      m =
        Runic.map(
          fn x -> x + ^offset end,
          name: map_name
        )

      assert m.name == :dynamic_map
      assert not is_nil(m.closure)
      assert Map.has_key?(m.closure.bindings, :map_name)
      assert Map.has_key?(m.closure.bindings, :offset)

      source_step = Runic.step(fn -> [1, 2, 3] end, name: :source)

      workflow =
        Workflow.new()
        |> Workflow.add(source_step)
        |> Workflow.add(m, to: :source)

      log = Workflow.build_log(workflow)
      rebuilt = Workflow.from_log(log)

      results =
        rebuilt
        |> Workflow.react_until_satisfied(:go)
        |> Workflow.raw_productions()

      assert 101 in results
      assert 102 in results
      assert 103 in results
    end

    test "reduce with runtime name variable roundtrips through build_log" do
      reduce_name = :dynamic_reduce
      offset = 10

      source_step = Runic.step(fn -> [1, 2, 3] end, name: :nums)

      r =
        Runic.reduce(
          0,
          fn x, acc -> x + acc + ^offset end,
          name: reduce_name
        )

      assert r.name == :dynamic_reduce
      assert not is_nil(r.closure)
      assert Map.has_key?(r.closure.bindings, :reduce_name)
      assert Map.has_key?(r.closure.bindings, :offset)

      workflow =
        Workflow.new()
        |> Workflow.add(source_step)
        |> Workflow.add(r, to: :nums)

      log = Workflow.build_log(workflow)
      rebuilt = Workflow.from_log(log)

      results =
        rebuilt
        |> Workflow.react_until_satisfied(:go)
        |> Workflow.raw_productions()

      assert 36 in results
    end

    test "multiple option variables are all captured" do
      step_name = :multi_opt
      input_schema = [:x, :y]
      output_schema = [:result]

      step =
        Runic.step(
          fn x -> x * 2 end,
          name: step_name,
          inputs: input_schema,
          outputs: output_schema
        )

      assert step.name == :multi_opt
      assert step.closure != nil
      assert Map.has_key?(step.closure.bindings, :step_name)
      assert Map.has_key?(step.closure.bindings, :input_schema)
      assert Map.has_key?(step.closure.bindings, :output_schema)
    end
  end
end
