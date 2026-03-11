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

    # Components with user-defined schemas (using port names)
    typed_step =
      Runic.step(
        fn x -> x * 3 end,
        name: "tripler",
        inputs: [
          in: [
            type: :integer,
            doc: "Integer to be tripled"
          ]
        ],
        outputs: [
          out: [
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
          in: [
            type: :integer,
            doc: "Any integer"
          ]
        ],
        outputs: [
          out: [
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
          in: [
            type: {:one_of, [:inc, :dec]},
            doc: "Counter increment/decrement commands"
          ]
        ],
        outputs: [
          state: [
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
    test "returns port contract for step inputs", %{step: step} do
      schema = Runic.Component.inputs(step)

      assert is_list(schema)
      assert Keyword.has_key?(schema, :in)

      in_schema = Keyword.fetch!(schema, :in)
      assert is_list(in_schema)
      assert Keyword.has_key?(in_schema, :type)
      assert Keyword.get(in_schema, :type) == :any
    end

    test "returns port contract for map inputs", %{map_step: map_step} do
      schema = Runic.Component.inputs(map_step)

      assert is_list(schema)
      assert Keyword.has_key?(schema, :items)

      items_schema = Keyword.fetch!(schema, :items)
      assert is_list(items_schema)
      assert Keyword.has_key?(items_schema, :type)
      assert Keyword.get(items_schema, :type) == :any
      assert Keyword.get(items_schema, :cardinality) == :many
    end

    test "returns port contract for reduce inputs", %{reduce_step: reduce_step} do
      schema = Runic.Component.inputs(reduce_step)

      assert is_list(schema)
      assert Keyword.has_key?(schema, :items)

      items_schema = Keyword.fetch!(schema, :items)
      assert is_list(items_schema)
      assert Keyword.has_key?(items_schema, :type)
      assert Keyword.get(items_schema, :type) == :any
      assert Keyword.get(items_schema, :cardinality) == :many
    end

    test "returns port contract for rule inputs", %{rule: rule} do
      schema = Runic.Component.inputs(rule)

      assert is_list(schema)
      assert Keyword.has_key?(schema, :in)

      in_schema = Keyword.fetch!(schema, :in)
      assert is_list(in_schema)
      assert Keyword.has_key?(in_schema, :type)
      assert Keyword.get(in_schema, :type) == :any
    end

    test "returns port contract for state machine inputs", %{state_machine: state_machine} do
      schema = Runic.Component.inputs(state_machine)

      assert is_list(schema)
      assert Keyword.has_key?(schema, :in)

      in_schema = Keyword.fetch!(schema, :in)
      assert is_list(in_schema)
      assert Keyword.has_key?(in_schema, :type)
      assert Keyword.get(in_schema, :type) == :any
    end

    test "returns user-defined schema for typed step inputs", %{typed_step: typed_step} do
      schema = Runic.Component.inputs(typed_step)

      assert is_list(schema)
      assert Keyword.has_key?(schema, :in)

      in_schema = Keyword.fetch!(schema, :in)
      assert is_list(in_schema)
      assert Keyword.get(in_schema, :type) == :integer
      assert Keyword.get(in_schema, :doc) == "Integer to be tripled"
    end

    test "returns user-defined schema for typed state machine inputs", %{
      typed_state_machine: typed_state_machine
    } do
      schema = Runic.Component.inputs(typed_state_machine)

      assert is_list(schema)
      assert Keyword.has_key?(schema, :in)

      in_schema = Keyword.fetch!(schema, :in)
      assert is_list(in_schema)
      assert Keyword.get(in_schema, :type) == {:one_of, [:inc, :dec]}
      assert Keyword.get(in_schema, :doc) == "Counter increment/decrement commands"
    end
  end

  describe "outputs/1" do
    test "returns port contract for step outputs", %{step: step} do
      schema = Runic.Component.outputs(step)

      assert is_list(schema)
      assert Keyword.has_key?(schema, :out)

      out_schema = Keyword.fetch!(schema, :out)
      assert is_list(out_schema)
      assert Keyword.has_key?(out_schema, :type)
      assert Keyword.get(out_schema, :type) == :any
    end

    test "returns port contract for map outputs", %{map_step: map_step} do
      schema = Runic.Component.outputs(map_step)

      assert is_list(schema)
      assert Keyword.has_key?(schema, :out)

      out_schema = Keyword.fetch!(schema, :out)
      assert is_list(out_schema)
      assert Keyword.has_key?(out_schema, :type)
      assert Keyword.get(out_schema, :cardinality) == :many
    end

    test "returns port contract for reduce outputs", %{reduce_step: reduce_step} do
      schema = Runic.Component.outputs(reduce_step)

      assert is_list(schema)
      assert Keyword.has_key?(schema, :result)

      result_schema = Keyword.fetch!(schema, :result)
      assert is_list(result_schema)
      assert Keyword.has_key?(result_schema, :type)
      assert Keyword.get(result_schema, :type) == :any
    end

    test "returns port contract for typed rule outputs", %{typed_rule: rule} do
      schema = Runic.Component.outputs(rule)

      assert is_list(schema)
      assert Keyword.has_key?(schema, :out)

      out_schema = Keyword.fetch!(schema, :out)
      assert is_list(out_schema)
      assert Keyword.has_key?(out_schema, :type)
      assert Keyword.get(out_schema, :type) == :string
    end

    test "returns port contract for state machine outputs", %{
      state_machine: state_machine
    } do
      schema = Runic.Component.outputs(state_machine)

      assert is_list(schema)
      assert Keyword.has_key?(schema, :state)

      state_schema = Keyword.fetch!(schema, :state)
      assert is_list(state_schema)
      assert Keyword.has_key?(state_schema, :type)
      assert Keyword.get(state_schema, :type) == :any
    end

    test "returns user-defined schema for typed step outputs", %{typed_step: typed_step} do
      schema = Runic.Component.outputs(typed_step)

      assert is_list(schema)
      assert Keyword.has_key?(schema, :out)

      out_schema = Keyword.fetch!(schema, :out)
      assert is_list(out_schema)
      assert Keyword.get(out_schema, :type) == :integer
      assert Keyword.get(out_schema, :doc) == "Tripled integer value"
    end

    test "returns user-defined schema for typed state machine outputs", %{
      typed_state_machine: typed_state_machine
    } do
      schema = Runic.Component.outputs(typed_state_machine)

      assert is_list(schema)
      assert Keyword.has_key?(schema, :state)

      state_schema = Keyword.fetch!(schema, :state)
      assert is_list(state_schema)
      assert Keyword.get(state_schema, :type) == :integer
      assert Keyword.get(state_schema, :doc) == "Current counter value"
    end
  end

  describe "compatibility checking with inputs/outputs" do
    test "can check if components are compatible based on their schemas", %{step: step1} do
      step2 = Runic.step(fn x -> x / 2 end, name: "halver")

      # Test that step outputs are compatible with step inputs
      step1_outputs = Runic.Component.outputs(step1)
      step2_inputs = Runic.Component.inputs(step2)

      # Both should have :out / :in keys
      assert Keyword.has_key?(step1_outputs, :out)
      assert Keyword.has_key?(step2_inputs, :in)

      # Basic compatibility check (same type)
      step1_output_type = Keyword.get(step1_outputs[:out], :type)
      step2_input_type = Keyword.get(step2_inputs[:in], :type)

      assert step1_output_type == step2_input_type
    end

    test "typed components have precise schema compatibility", %{typed_step: typed_step} do
      # Create another integer-compatible step
      compatible_step =
        Runic.step(
          fn x -> x + 10 end,
          name: "adder",
          inputs: [
            in: [
              type: :integer,
              doc: "Integer to add 10 to"
            ]
          ]
        )

      # Test precise type compatibility
      typed_outputs = Runic.Component.outputs(typed_step)
      compatible_inputs = Runic.Component.inputs(compatible_step)

      # Both specify integer type
      assert Keyword.get(typed_outputs[:out], :type) == :integer
      assert Keyword.get(compatible_inputs[:in], :type) == :integer

      # Compatible components should have matching types
      assert Keyword.get(typed_outputs[:out], :type) ==
               Keyword.get(compatible_inputs[:in], :type)
    end

    test "ports_compatible?/2 infers single-port connections", %{step: step} do
      rule =
        Runic.rule(
          fn :input -> :output end,
          name: "test_rule"
        )

      producer_outputs = Runic.Component.outputs(step)
      consumer_inputs = Runic.Component.inputs(rule)

      assert {:ok, :inferred} =
               Runic.Component.TypeCompatibility.ports_compatible?(
                 producer_outputs,
                 consumer_inputs
               )
    end

    test "ports_compatible?/2 rejects type mismatches" do
      producer_outputs = [out: [type: :string]]
      consumer_inputs = [in: [type: :integer]]

      assert {:error, [{:type_mismatch, :string, :integer}]} =
               Runic.Component.TypeCompatibility.ports_compatible?(
                 producer_outputs,
                 consumer_inputs
               )
    end

    test "ports_compatible?/2 matches multi-port by name" do
      producer_outputs = [
        left: [type: :integer],
        right: [type: :integer]
      ]

      consumer_inputs = [
        left: [type: :integer],
        right: [type: :integer]
      ]

      assert {:ok, :matched} =
               Runic.Component.TypeCompatibility.ports_compatible?(
                 producer_outputs,
                 consumer_inputs
               )
    end

    test "ports_compatible?/2 reports unmatched required ports" do
      producer_outputs = [left: [type: :integer]]

      consumer_inputs = [
        left: [type: :integer],
        right: [type: :integer, required: true]
      ]

      assert {:error, [{:unmatched_port, :right, :integer}]} =
               Runic.Component.TypeCompatibility.ports_compatible?(
                 producer_outputs,
                 consumer_inputs
               )
    end

    test "ports_compatible?/2 skips optional ports" do
      producer_outputs = [left: [type: :integer]]

      consumer_inputs = [
        left: [type: :integer],
        right: [type: :integer, required: false]
      ]

      assert {:ok, :matched} =
               Runic.Component.TypeCompatibility.ports_compatible?(
                 producer_outputs,
                 consumer_inputs
               )
    end
  end

  describe "schema validation" do
    test "step rejects invalid port options" do
      result =
        try do
          Code.eval_quoted(
            quote do
              require Runic

              Runic.step(fn x -> x end,
                name: "bad",
                inputs: [
                  in: [
                    type: :any,
                    bad_option: true
                  ]
                ]
              )
            end
          )
        rescue
          e in ArgumentError -> e
        end

      assert %ArgumentError{} = result
      assert result.message =~ "Invalid port options"
      assert result.message =~ ":bad_option"
    end

    test "rule rejects invalid port options" do
      result =
        try do
          Code.eval_quoted(
            quote do
              require Runic

              Runic.rule(
                condition: fn x -> x > 0 end,
                reaction: fn x -> x end,
                name: "bad_rule",
                inputs: [
                  in: [
                    invalid_key: true
                  ]
                ]
              )
            end
          )
        rescue
          e in ArgumentError -> e
        end

      assert %ArgumentError{} = result
      assert result.message =~ "Invalid port options"
    end

    test "state machine rejects invalid port options" do
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
                  in: [
                    bad_opt: :any
                  ]
                ]
              )
            end
          )
        rescue
          e in ArgumentError -> e
        end

      assert %ArgumentError{} = result
      assert result.message =~ "Invalid port options"
    end

    test "state machine accepts valid port options" do
      # Should not raise
      state_machine =
        Runic.state_machine(
          name: "valid_state_machine",
          init: 0,
          reducer: fn :inc, state -> state + 1 end,
          inputs: [
            in: [
              type: {:list, :atom}
            ]
          ],
          outputs: [
            state: [
              type: :integer
            ]
          ]
        )

      assert state_machine.name == "valid_state_machine"
    end

    test "step accepts all valid port options" do
      step =
        Runic.step(fn x -> x end,
          name: "validated",
          inputs: [
            in: [type: :integer, doc: "An integer", cardinality: :one, required: true]
          ],
          outputs: [
            out: [type: :integer, doc: "The same integer"]
          ]
        )

      assert step.name == "validated"
    end
  end

  describe "fact metadata" do
    test "fact defaults meta to empty map" do
      fact = Runic.Workflow.Fact.new(value: 42, ancestry: {1, 2})
      assert fact.meta == %{}
    end

    test "fact accepts meta parameter" do
      fact = Runic.Workflow.Fact.new(value: 42, ancestry: {1, 2}, meta: %{source_port: :out})
      assert fact.meta == %{source_port: :out}
    end

    test "fact hash excludes meta" do
      fact1 = Runic.Workflow.Fact.new(value: 42, ancestry: {1, 2})
      fact2 = Runic.Workflow.Fact.new(value: 42, ancestry: {1, 2}, meta: %{type: :integer})
      assert fact1.hash == fact2.hash
    end

    test "FactProduced event defaults meta to empty map" do
      event = %Runic.Workflow.Events.FactProduced{
        hash: 123,
        value: "test",
        ancestry: {1, 2},
        producer_label: :produced,
        weight: 0
      }

      assert event.meta == %{}
    end
  end
end
