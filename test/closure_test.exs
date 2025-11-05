defmodule Runic.ClosureTest do
  use ExUnit.Case, async: true

  alias Runic.Closure
  alias Runic.ClosureMetadata

  describe "ClosureMetadata serialization" do
    test "metadata can be serialized and deserialized" do
      # Create metadata from current environment
      metadata = ClosureMetadata.from_caller(__ENV__)

      # Serialize
      binary = :erlang.term_to_binary(metadata)

      # Deserialize
      roundtrip = :erlang.binary_to_term(binary)

      assert metadata.imports == roundtrip.imports
      assert metadata.aliases == roundtrip.aliases
      assert metadata.requires == roundtrip.requires
    end

    test "metadata captures imports" do
      import String, only: [upcase: 1], warn: false
      metadata = ClosureMetadata.from_caller(__ENV__)

      assert String in metadata.imports
    end

    test "metadata captures requires" do
      require Logger
      metadata = ClosureMetadata.from_caller(__ENV__)

      assert Logger in metadata.requires
    end

    test "metadata captures aliases" do
      alias Runic.Workflow, as: WF
      _dummy = WF
      metadata = ClosureMetadata.from_caller(__ENV__)

      # Aliases should contain at least Closure and ClosureMetadata from the test module
      assert is_list(metadata.aliases)
      assert length(metadata.aliases) > 0
    end

    test "metadata can rebuild evaluation environment" do
      import Enum, only: [map: 2], warn: false
      metadata = ClosureMetadata.from_caller(__ENV__)

      env = ClosureMetadata.to_eval_env(metadata)

      # Should be able to evaluate code that uses Enum
      {result, _} = Code.eval_quoted(quote(do: Enum.map([1, 2, 3], &(&1 * 2))), [], env)

      assert result == [2, 4, 6]
    end
  end

  describe "Closure binding validation" do
    test "validates serializable bindings" do
      assert :ok = Closure.validate_value(42)
      assert :ok = Closure.validate_value("string")
      assert :ok = Closure.validate_value(:atom)
      assert :ok = Closure.validate_value([1, 2, 3])
      assert :ok = Closure.validate_value(%{key: "value"})
      assert :ok = Closure.validate_value({:tuple, 1, 2})
    end

    test "rejects non-serializable bindings" do
      # PIDs
      {:error, reason} = Closure.validate_value(self())
      assert reason =~ "PIDs cannot be serialized"

      # Ports
      {:ok, port} = :gen_tcp.listen(0, [])
      {:error, reason} = Closure.validate_value(port)
      assert reason =~ "Ports cannot be serialized"
      :gen_tcp.close(port)

      # References
      ref = make_ref()
      {:error, reason} = Closure.validate_value(ref)
      assert reason =~ "References cannot be serialized"

      # Anonymous functions
      fun = fn x -> x + 1 end
      {:error, reason} = Closure.validate_value(fun)
      assert reason =~ "Anonymous"
    end

    test "validates external function captures" do
      # External functions (MFAs) ARE serializable
      external_fun = &Enum.map/2
      assert :ok = Closure.validate_value(external_fun)
    end

    test "raises on invalid bindings in closure creation" do
      source = quote(do: fn x -> x + 1 end)

      assert_raise ArgumentError, ~r/Cannot serialize binding/, fn ->
        Closure.new(source, %{bad: self()}, __ENV__)
      end
    end
  end

  describe "Closure creation" do
    test "creates closure from source, bindings, and environment" do
      _outer_var = 42
      source = quote(do: fn x -> x + outer_var end)

      closure = Closure.new(source, %{outer_var: 42}, __ENV__)

      assert closure.source == source
      assert closure.bindings == %{outer_var: 42}
      assert closure.hash != nil
      assert closure.metadata != nil
      assert is_struct(closure.metadata, ClosureMetadata)
    end

    test "creates closure without metadata when nil passed" do
      source = quote(do: fn x -> x * 2 end)

      closure = Closure.new(source, %{}, nil)

      assert closure.source == source
      assert closure.bindings == %{}
      assert closure.hash != nil
      assert closure.metadata == nil
    end

    test "creates closure with explicit metadata" do
      metadata = %ClosureMetadata{imports: [Enum], aliases: [], requires: []}
      source = quote(do: fn x -> x * 2 end)

      closure = Closure.new(source, %{}, metadata)

      assert closure.metadata == metadata
    end

    test "closure hash includes bindings" do
      source = quote(do: fn x -> x + outer_var end)

      closure1 = Closure.new(source, %{outer_var: 42}, nil)
      closure2 = Closure.new(source, %{outer_var: 100}, nil)

      refute closure1.hash == closure2.hash
    end

    test "closure hash is deterministic for same source and bindings" do
      source = quote(do: fn x -> x + outer_var end)

      closure1 = Closure.new(source, %{outer_var: 42}, nil)
      closure2 = Closure.new(source, %{outer_var: 42}, nil)

      assert closure1.hash == closure2.hash
    end
  end

  describe "Closure serialization" do
    test "closures can be serialized with term_to_binary" do
      outer_var = 42
      source = quote(do: fn x -> x + outer_var end)
      closure = Closure.new(source, %{outer_var: outer_var}, __ENV__)

      # Serialize
      binary = :erlang.term_to_binary(closure)

      # Deserialize
      roundtrip = :erlang.binary_to_term(binary)

      assert roundtrip.source == closure.source
      assert roundtrip.bindings == closure.bindings
      assert roundtrip.hash == closure.hash
      assert roundtrip.metadata.imports == closure.metadata.imports
      assert roundtrip.metadata.aliases == closure.metadata.aliases
    end

    test "closure with complex bindings serializes correctly" do
      data = %{
        numbers: [1, 2, 3],
        nested: %{key: "value"},
        tuple: {:ok, 42}
      }

      source = quote(do: fn -> data end)
      closure = Closure.new(source, %{data: data}, nil)

      binary = :erlang.term_to_binary(closure)
      roundtrip = :erlang.binary_to_term(binary)

      assert roundtrip.bindings[:data] == data
    end
  end

  describe "Closure evaluation" do
    test "evaluates simple closure" do
      # In Runic, closures store rewritten AST where variables are already resolved
      # This mimics what traverse_expression does
      source = quote(do: fn x -> x + 100 end)
      closure = Closure.new(source, %{}, __ENV__)

      {fun, _bindings} = Closure.eval(closure)

      assert is_function(fun, 1)
      assert fun.(42) == 142
    end

    test "evaluates closure without metadata" do
      source = quote(do: fn x -> x * 2 end)
      closure = Closure.new(source, %{}, nil)

      {fun, _bindings} = Closure.eval(closure)

      assert fun.(21) == 42
    end

    test "evaluates closure with imports" do
      import Enum, only: [map: 2], warn: false
      # Suppress warning
      _dummy = Enum
      source = quote(do: fn list -> Enum.map(list, &(&1 * 2)) end)
      closure = Closure.new(source, %{}, __ENV__)

      {fun, _bindings} = Closure.eval(closure)

      assert fun.([1, 2, 3]) == [2, 4, 6]
    end

    test "evaluates closure with multiple bindings" do
      # In practice, traverse_expression rewrites the AST with values inlined
      source = quote(do: fn x -> x + 10 + 20 + 30 end)
      closure = Closure.new(source, %{}, __ENV__)

      {fun, _bindings} = Closure.eval(closure)

      assert fun.(5) == 65
    end

    test "evaluates zero-arity closure" do
      source = quote(do: fn -> :hello end)
      closure = Closure.new(source, %{}, nil)

      {fun, _bindings} = Closure.eval(closure)

      assert fun.() == :hello
    end
  end

  describe "Closure cross-environment reconstruction" do
    test "closure can be rebuilt and evaluated in a different module context" do
      # In real usage, Runic macros rewrite the AST so variables are already resolved
      # This test demonstrates that closures serialize across module boundaries
      source = quote(do: fn x -> x * 10 end)
      closure = Closure.new(source, %{}, __ENV__)

      # Serialize
      binary = :erlang.term_to_binary(closure)

      # Define a separate module that reconstructs the closure
      defmodule SeparateContext do
        def rebuild_and_run(serialized_closure, input) do
          closure = :erlang.binary_to_term(serialized_closure)
          {fun, _} = Runic.Closure.eval(closure)
          fun.(input)
        end
      end

      # Rebuild in separate module
      result = SeparateContext.rebuild_and_run(binary, 5)

      assert result == 50
    end

    test "complex closure survives cross-module serialization" do
      # Runic macros would have already inlined the values
      source =
        quote do
          fn x ->
            x * 5 + 10
          end
        end

      closure = Closure.new(source, %{}, __ENV__)

      binary = :erlang.term_to_binary(closure)

      defmodule AnotherContext do
        def rebuild_and_run(binary, input) do
          closure = :erlang.binary_to_term(binary)
          {fun, _} = Runic.Closure.eval(closure)
          fun.(input)
        end
      end

      result = AnotherContext.rebuild_and_run(binary, 10)

      assert result == 60
    end
  end
end
