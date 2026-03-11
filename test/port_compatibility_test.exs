defmodule Runic.PortCompatibilityTest do
  use ExUnit.Case, async: true
  require Runic
  alias Runic.Workflow

  describe "port enforcement in Workflow.add/3" do
    test "compatible typed components connect without error" do
      producer =
        Runic.step(fn x -> x + 1 end,
          name: :producer,
          outputs: [out: [type: :integer]]
        )

      consumer =
        Runic.step(fn x -> x * 2 end,
          name: :consumer,
          inputs: [in: [type: :integer]]
        )

      workflow =
        Workflow.new()
        |> Workflow.add(producer)
        |> Workflow.add(consumer, to: :producer)

      assert workflow
    end

    test "untyped components connect to anything (gradual typing)" do
      untyped_producer = Runic.step(fn x -> x end, name: :untyped_producer)
      untyped_consumer = Runic.step(fn x -> x end, name: :untyped_consumer)

      typed_consumer =
        Runic.step(fn x -> x end,
          name: :typed_consumer,
          inputs: [in: [type: :string]]
        )

      workflow =
        Workflow.new()
        |> Workflow.add(untyped_producer)
        |> Workflow.add(untyped_consumer, to: :untyped_producer)
        |> Workflow.add(typed_consumer, to: :untyped_producer)

      assert workflow
    end

    test "incompatible types raise IncompatiblePortError" do
      int_producer =
        Runic.step(fn x -> x + 1 end,
          name: :int_producer,
          outputs: [out: [type: :integer]]
        )

      string_consumer =
        Runic.step(fn x -> String.upcase(x) end,
          name: :string_consumer,
          inputs: [in: [type: :string]]
        )

      assert_raise Runic.IncompatiblePortError, fn ->
        Workflow.new()
        |> Workflow.add(int_producer)
        |> Workflow.add(string_consumer, to: :int_producer)
      end
    end

    test "IncompatiblePortError has descriptive message" do
      int_producer =
        Runic.step(fn x -> x + 1 end,
          name: :int_producer,
          outputs: [out: [type: :integer]]
        )

      string_consumer =
        Runic.step(fn x -> String.upcase(x) end,
          name: :string_consumer,
          inputs: [in: [type: :string]]
        )

      error =
        assert_raise Runic.IncompatiblePortError, fn ->
          Workflow.new()
          |> Workflow.add(int_producer)
          |> Workflow.add(string_consumer, to: :int_producer)
        end

      assert error.message =~ "port contracts are incompatible"
      assert error.message =~ ":integer"
      assert error.message =~ ":string"
      assert error.producer == int_producer
      assert error.consumer == string_consumer
    end

    test "validate: :off bypasses enforcement" do
      int_producer =
        Runic.step(fn x -> x + 1 end,
          name: :int_producer,
          outputs: [out: [type: :integer]]
        )

      string_consumer =
        Runic.step(fn x -> String.upcase(x) end,
          name: :string_consumer,
          inputs: [in: [type: :string]]
        )

      workflow =
        Workflow.new()
        |> Workflow.add(int_producer)
        |> Workflow.add(string_consumer, to: :int_producer, validate: :off)

      assert workflow
    end

    test "validate: :warn logs but does not raise" do
      import ExUnit.CaptureLog

      int_producer =
        Runic.step(fn x -> x + 1 end,
          name: :int_producer,
          outputs: [out: [type: :integer]]
        )

      string_consumer =
        Runic.step(fn x -> String.upcase(x) end,
          name: :string_consumer,
          inputs: [in: [type: :string]]
        )

      log =
        capture_log(fn ->
          Workflow.new()
          |> Workflow.add(int_producer)
          |> Workflow.add(string_consumer, to: :int_producer, validate: :warn)
        end)

      assert log =~ "Port incompatibility"
      assert log =~ "string_consumer"
      assert log =~ "int_producer"
    end

    test ":any typed consumer accepts any typed producer" do
      typed_producer =
        Runic.step(fn x -> x end,
          name: :typed,
          outputs: [out: [type: :integer]]
        )

      any_consumer =
        Runic.step(fn x -> x end,
          name: :any_consumer,
          inputs: [in: [type: :any]]
        )

      workflow =
        Workflow.new()
        |> Workflow.add(typed_producer)
        |> Workflow.add(any_consumer, to: :typed)

      assert workflow
    end

    test ":any typed producer connects to any typed consumer" do
      any_producer =
        Runic.step(fn x -> x end,
          name: :any_producer,
          outputs: [out: [type: :any]]
        )

      typed_consumer =
        Runic.step(fn x -> x end,
          name: :typed_consumer,
          inputs: [in: [type: :string]]
        )

      workflow =
        Workflow.new()
        |> Workflow.add(any_producer)
        |> Workflow.add(typed_consumer, to: :any_producer)

      assert workflow
    end

    test "root connection skips validation" do
      # Any component can be added to root without validation
      typed =
        Runic.step(fn x -> x end,
          name: :root_step,
          inputs: [in: [type: :string]]
        )

      workflow = Workflow.new() |> Workflow.add(typed)
      assert workflow
    end

    test "single-input consumer connects to multi-output producer" do
      accumulator =
        Runic.accumulator(0, fn _event, state -> state + 1 end, name: :counter)

      downstream =
        Runic.step(fn x -> x * 10 end, name: :downstream)

      workflow =
        Workflow.new()
        |> Workflow.add(accumulator)
        |> Workflow.add(downstream, to: :counter)

      assert workflow
    end

    test "list type compatibility is checked recursively" do
      list_producer =
        Runic.step(fn x -> [x] end,
          name: :list_producer,
          outputs: [out: [type: {:list, :integer}]]
        )

      list_consumer =
        Runic.step(fn x -> x end,
          name: :list_consumer,
          inputs: [in: [type: {:list, :string}]]
        )

      assert_raise Runic.IncompatiblePortError, fn ->
        Workflow.new()
        |> Workflow.add(list_producer)
        |> Workflow.add(list_consumer, to: :list_producer)
      end
    end

    test "list type with compatible elements connects" do
      list_producer =
        Runic.step(fn x -> [x] end,
          name: :list_producer,
          outputs: [out: [type: {:list, :integer}]]
        )

      list_consumer =
        Runic.step(fn x -> x end,
          name: :list_consumer,
          inputs: [in: [type: {:list, :any}]]
        )

      workflow =
        Workflow.new()
        |> Workflow.add(list_producer)
        |> Workflow.add(list_consumer, to: :list_producer)

      assert workflow
    end
  end

  describe "Workflow.connectable?/3 with ports" do
    test "returns :ok for compatible components" do
      producer = Runic.step(fn x -> x end, name: :a)
      consumer = Runic.step(fn x -> x end, name: :b)

      workflow = Workflow.new() |> Workflow.add(producer)
      assert :ok = Workflow.connectable?(workflow, consumer, to: :a)
    end

    test "returns error for incompatible components" do
      producer =
        Runic.step(fn x -> x end,
          name: :a,
          outputs: [out: [type: :integer]]
        )

      consumer =
        Runic.step(fn x -> x end,
          name: :b,
          inputs: [in: [type: :string]]
        )

      workflow = Workflow.new() |> Workflow.add(producer)

      assert {:error, {:incompatible_ports, _reasons}} =
               Workflow.connectable?(workflow, consumer, to: :a)
    end

    test "returns :ok without :to option" do
      consumer = Runic.step(fn x -> x end, name: :b)
      assert :ok = Workflow.connectable?(Workflow.new(), consumer)
    end
  end

  describe "multi-port matching" do
    test "multi-port consumer with matching names succeeds" do
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

    test "multi-port consumer with missing required port fails" do
      producer_outputs = [
        left: [type: :integer]
      ]

      consumer_inputs = [
        left: [type: :integer],
        right: [type: :integer]
      ]

      assert {:error, reasons} =
               Runic.Component.TypeCompatibility.ports_compatible?(
                 producer_outputs,
                 consumer_inputs
               )

      assert Enum.any?(reasons, fn
               {:unmatched_port, :right, _} -> true
               _ -> false
             end)
    end

    test "optional ports don't cause failure when unmatched" do
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

    test "single consumer infers from multi-output producer" do
      producer_outputs = [
        state: [type: :map],
        events: [type: {:list, :any}]
      ]

      consumer_inputs = [in: [type: :any]]

      assert {:ok, :inferred} =
               Runic.Component.TypeCompatibility.ports_compatible?(
                 producer_outputs,
                 consumer_inputs
               )
    end

    test "single consumer rejects when no producer output is type-compatible" do
      producer_outputs = [
        state: [type: :map],
        events: [type: {:list, :any}]
      ]

      consumer_inputs = [in: [type: :integer]]

      assert {:error, _} =
               Runic.Component.TypeCompatibility.ports_compatible?(
                 producer_outputs,
                 consumer_inputs
               )
    end
  end
end
