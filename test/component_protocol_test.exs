defmodule Runic.ComponentProtocolTest do
  use ExUnit.Case, async: true
  require Runic

  setup do
    # Basic components without user-defined schemas (use defaults)
    step = Runic.step(fn x -> x * 2 end, name: "doubler")

    map_step = Runic.map(fn x -> x + 1 end, name: "incrementer")

    reduce_step = Runic.reduce(0, fn acc, x -> acc + x end, name: "summer")

    rule =
      Runic.rule(
        fn :input -> :output end,
        name: "number_classifier"
      )

    state_machine =
      Runic.state_machine(
        name: "counter",
        init: 0,
        reducer: fn
          :inc, state -> state + 1
          :dec, state -> state - 1
          :reset, _state -> 0
        end
      )

    # Components with user-defined schemas
    typed_step =
      Runic.step(
        fn x -> x * 3 end,
        name: "tripler",
        inputs: [
          step: [
            type: :integer,
            doc: "Integer to be tripled"
          ]
        ],
        outputs: [
          step: [
            type: :integer,
            doc: "Tripled integer value"
          ]
        ]
      )

    typed_rule =
      Runic.rule(
        condition: fn
          num when is_integer(num) ->
            true

          _otherwise ->
            false
        end,
        reaction: fn num -> to_string(num) end,
        name: "integer to string",
        inputs: [
          condition: [
            type: :integer,
            doc: "Any integer"
          ]
        ],
        outputs: [
          reaction: [
            type: :string,
            doc: "Integer converted to string"
          ]
        ]
      )

    typed_state_machine =
      Runic.state_machine(
        name: "typed_counter",
        init: 0,
        reducer: fn
          :inc, state -> state + 1
          :dec, state -> state - 1
        end,
        inputs: [
          reactors: [
            type: {:one_of, [:inc, :dec]},
            doc: "Counter increment/decrement commands"
          ]
        ],
        outputs: [
          accumulator: [
            type: :integer,
            doc: "Current counter value"
          ]
        ]
      )

    %{
      step: step,
      map_step: map_step,
      reduce_step: reduce_step,
      rule: rule,
      typed_rule: typed_rule,
      state_machine: state_machine,
      typed_step: typed_step,
      typed_state_machine: typed_state_machine
    }
  end

  describe "inputs/1" do
    test "returns nimble_options schema for step inputs", %{step: step} do
      schema = Runic.Component.inputs(step)

      assert is_list(schema)
      assert Keyword.has_key?(schema, :step)

      step_schema = Keyword.fetch!(schema, :step)
      assert is_list(step_schema)
      # Should define expected input types for the step function
      assert Keyword.has_key?(step_schema, :type)
      assert Keyword.get(step_schema, :type) == :any
    end

    test "returns nimble_options schema for map inputs", %{map_step: map_step} do
      schema = Runic.Component.inputs(map_step)

      assert is_list(schema)
      assert Keyword.has_key?(schema, :fan_out)

      fan_out_schema = Keyword.fetch!(schema, :fan_out)
      assert is_list(fan_out_schema)
      assert Keyword.has_key?(fan_out_schema, :type)
      assert Keyword.get(fan_out_schema, :type) == :any
    end

    test "returns nimble_options schema for reduce inputs", %{reduce_step: reduce_step} do
      schema = Runic.Component.inputs(reduce_step)

      assert is_list(schema)
      assert Keyword.has_key?(schema, :fan_in)

      fan_in_schema = Keyword.fetch!(schema, :fan_in)
      assert is_list(fan_in_schema)
      assert Keyword.has_key?(fan_in_schema, :type)
      assert {:custom, _, :enumerable_type, _} = Keyword.get(fan_in_schema, :type)
    end

    test "returns nimble_options schema for rule inputs", %{rule: rule} do
      schema = Runic.Component.inputs(rule)

      assert is_list(schema)
      assert Keyword.has_key?(schema, :condition)

      condition_schema = Keyword.fetch!(schema, :condition)
      assert is_list(condition_schema)
      assert Keyword.has_key?(condition_schema, :type)
      assert Keyword.get(condition_schema, :type) == :any
    end

    test "returns nimble_options schema for state machine inputs", %{state_machine: state_machine} do
      schema = Runic.Component.inputs(state_machine)

      assert is_list(schema)
      assert Keyword.has_key?(schema, :reactors)

      reactors_schema = Keyword.fetch!(schema, :reactors)
      assert is_list(reactors_schema)
      assert Keyword.has_key?(reactors_schema, :type)
      assert Keyword.get(reactors_schema, :type) == {:list, :any}
    end

    test "returns user-defined schema for typed step inputs", %{typed_step: typed_step} do
      schema = Runic.Component.inputs(typed_step)

      assert is_list(schema)
      assert Keyword.has_key?(schema, :step)

      step_schema = Keyword.fetch!(schema, :step)
      assert is_list(step_schema)
      assert Keyword.get(step_schema, :type) == :integer
      assert Keyword.get(step_schema, :doc) == "Integer to be tripled"
    end

    test "returns user-defined schema for typed state machine inputs", %{
      typed_state_machine: typed_state_machine
    } do
      schema = Runic.Component.inputs(typed_state_machine)

      assert is_list(schema)
      assert Keyword.has_key?(schema, :reactors)

      reactors_schema = Keyword.fetch!(schema, :reactors)
      assert is_list(reactors_schema)
      assert Keyword.get(reactors_schema, :type) == {:one_of, [:inc, :dec]}
      assert Keyword.get(reactors_schema, :doc) == "Counter increment/decrement commands"
    end
  end

  describe "outputs/1" do
    test "returns nimble_options schema for step outputs", %{step: step} do
      schema = Runic.Component.outputs(step)

      assert is_list(schema)
      assert Keyword.has_key?(schema, :step)

      step_schema = Keyword.fetch!(schema, :step)
      assert is_list(step_schema)
      assert Keyword.has_key?(step_schema, :type)
      assert Keyword.get(step_schema, :type) == :any
    end

    test "returns nimble_options schema for map outputs", %{map_step: map_step} do
      schema = Runic.Component.outputs(map_step)

      assert is_list(schema)
      assert Keyword.has_key?(schema, :leaf)

      leaf_schema = Keyword.fetch!(schema, :leaf)
      assert is_list(leaf_schema)
      assert Keyword.has_key?(leaf_schema, :type)
      assert {:custom, _, :enumerable_type, _} = Keyword.get(leaf_schema, :type)
    end

    test "returns nimble_options schema for reduce outputs", %{reduce_step: reduce_step} do
      schema = Runic.Component.outputs(reduce_step)

      assert is_list(schema)
      assert Keyword.has_key?(schema, :fan_in)

      fan_in_schema = Keyword.fetch!(schema, :fan_in)
      assert is_list(fan_in_schema)
      assert Keyword.has_key?(fan_in_schema, :type)
      assert Keyword.get(fan_in_schema, :type) == :any
    end

    test "returns nimble_options schema for typed rule outputs", %{typed_rule: rule} do
      schema = Runic.Component.outputs(rule)

      assert is_list(schema)
      assert Keyword.has_key?(schema, :reaction)

      # condition_schema = Keyword.fetch!(schema, :condition)
      # assert is_list(condition_schema)
      # assert Keyword.has_key?(condition_schema, :type)
      # assert Keyword.get(condition_schema, :type) == :string

      reaction_schema = Keyword.fetch!(schema, :reaction)
      assert is_list(reaction_schema)
      assert Keyword.has_key?(reaction_schema, :type)
      assert Keyword.get(reaction_schema, :type) == :string
    end

    test "returns nimble_options schema for state machine outputs", %{
      state_machine: state_machine
    } do
      schema = Runic.Component.outputs(state_machine)

      assert is_list(schema)
      assert Keyword.has_key?(schema, :accumulator)

      accumulator_schema = Keyword.fetch!(schema, :accumulator)
      assert is_list(accumulator_schema)
      assert Keyword.has_key?(accumulator_schema, :type)
      assert Keyword.get(accumulator_schema, :type) == :any
    end

    test "returns user-defined schema for typed step outputs", %{typed_step: typed_step} do
      schema = Runic.Component.outputs(typed_step)

      assert is_list(schema)
      assert Keyword.has_key?(schema, :step)

      step_schema = Keyword.fetch!(schema, :step)
      assert is_list(step_schema)
      assert Keyword.get(step_schema, :type) == :integer
      assert Keyword.get(step_schema, :doc) == "Tripled integer value"
    end

    test "returns user-defined schema for typed state machine outputs", %{
      typed_state_machine: typed_state_machine
    } do
      schema = Runic.Component.outputs(typed_state_machine)

      assert is_list(schema)
      assert Keyword.has_key?(schema, :accumulator)

      accumulator_schema = Keyword.fetch!(schema, :accumulator)
      assert is_list(accumulator_schema)
      assert Keyword.get(accumulator_schema, :type) == :integer
      assert Keyword.get(accumulator_schema, :doc) == "Current counter value"
    end
  end

  describe "compatibility checking with inputs/outputs" do
    test "can check if components are compatible based on their schemas", %{step: step1} do
      step2 = Runic.step(fn x -> x / 2 end, name: "halver")

      # Test that step outputs are compatible with step inputs
      step1_outputs = Runic.Component.outputs(step1)
      step2_inputs = Runic.Component.inputs(step2)

      # Both should have :step key and compatible types
      assert Keyword.has_key?(step1_outputs, :step)
      assert Keyword.has_key?(step2_inputs, :step)

      # Basic compatibility check (same type)
      step1_output_type = Keyword.get(step1_outputs[:step], :type)
      step2_input_type = Keyword.get(step2_inputs[:step], :type)

      assert step1_output_type == step2_input_type
    end

    test "typed components have precise schema compatibility", %{typed_step: typed_step} do
      # Create another integer-compatible step
      compatible_step =
        Runic.step(
          fn x -> x + 10 end,
          name: "adder",
          inputs: [
            step: [
              type: :integer,
              doc: "Integer to add 10 to"
            ]
          ]
        )

      # Test precise type compatibility
      typed_outputs = Runic.Component.outputs(typed_step)
      compatible_inputs = Runic.Component.inputs(compatible_step)

      # Both specify integer type
      assert Keyword.get(typed_outputs[:step], :type) == :integer
      assert Keyword.get(compatible_inputs[:step], :type) == :integer

      # Compatible components should have matching types
      assert Keyword.get(typed_outputs[:step], :type) ==
               Keyword.get(compatible_inputs[:step], :type)
    end
  end

  describe "schema validation" do
    test "state machine rejects invalid subcomponent keys in inputs" do
      # The validation happens at macro expansion time, so we need to test this way
      result =
        try do
          Code.eval_quoted(
            quote do
              require Runic

              Runic.state_machine(
                name: "invalid_state_machine",
                init: 0,
                reducer: fn :inc, state -> state + 1 end,
                inputs: [
                  invalid_key: [
                    type: :any
                  ]
                ]
              )
            end
          )
        rescue
          e in ArgumentError -> e
        end

      assert %ArgumentError{} = result
      assert result.message =~ "Invalid subcomponent keys [:invalid_key] for state_machine"
    end

    test "state machine rejects invalid subcomponent keys in outputs" do
      result =
        try do
          Code.eval_quoted(
            quote do
              require Runic

              Runic.state_machine(
                name: "invalid_state_machine",
                init: 0,
                reducer: fn :inc, state -> state + 1 end,
                outputs: [
                  bad_output: [
                    type: :any
                  ]
                ]
              )
            end
          )
        rescue
          e in ArgumentError -> e
        end

      assert %ArgumentError{} = result
      assert result.message =~ "Invalid subcomponent keys [:bad_output] for state_machine"
    end

    test "state machine accepts valid subcomponent keys" do
      # Should not raise
      state_machine =
        Runic.state_machine(
          name: "valid_state_machine",
          init: 0,
          reducer: fn :inc, state -> state + 1 end,
          inputs: [
            reactors: [
              type: {:list, :atom}
            ]
          ],
          outputs: [
            accumulator: [
              type: :integer
            ]
          ]
        )

      assert state_machine.name == "valid_state_machine"
    end
  end
end
