defmodule Runic.Examples.JidoFactContractTest do
  use ExUnit.Case, async: true
  require Runic
  alias Jido.Exec.Fact, as: JidoFact
  alias Runic.Examples.JidoFactBoundary
  alias Runic.Workflow
  alias Runic.Workflow.Fact

  test "the real Jido wrapper passes through native containers and Jido children" do
    reference = make_ref()
    value = %{reply_to: self(), token: reference, uri: URI.parse("/local")}
    root = JidoFact.local_root(value)
    native = Fact.new(value: [root.value], ancestry: {:native_container, root.hash})
    child = JidoFact.child(native, value: value, ancestry: {:jido_child, native.hash})

    assert JidoFact.value(child) == value
    assert child.meta.jido.identity_mode == :local

    assert {:error, %{field: :output, path: [:output], reason: {:unsupported, :local_identity}}} =
             JidoFactBoundary.check(child, :output)
  end

  test "local identity persists when the Jido child value is a portable scalar" do
    root = JidoFact.local_root(%{reply_to: self()})
    child = JidoFact.child(root, value: 7, ancestry: {:scalar, root.hash})

    assert child.value == 7
    assert :ok = Jido.Exec.Portable.validate(child.value, :output)

    assert {:error, %{reason: {:unsupported, :local_identity}}} =
             JidoFactBoundary.check(child, :output)
  end

  test "a URI-only local wrapper in a native container is rejected at its field" do
    root = JidoFact.local_root(URI.parse("/local"))

    for {value, path} <- [
          {[root.value], [:output, :value, 0]},
          {{:ok, root.value}, [:output, :value, 1]},
          {%{resource: root.value}, [:output, :value, :resource]},
          {%{root.value => :resource}, [:output, :value, {:map_key, 0}]}
        ] do
      native = Fact.new(value: value, ancestry: {:native_container, root.hash})
      assert native.meta == %{}
      assert :ok = Jido.Exec.Portable.validate(native, :output)

      assert {:error,
              %{
                field: :output,
                path: ^path,
                reason: {:unsupported, :local_identity},
                retry: false
              }} =
               JidoFactBoundary.check(native, :output)
    end

    # Check a raw caller-supplied improper list too.
    raw = %{Fact.new(value: 7) | value: [1 | root.value]}

    assert {:error, %{path: [:output, :value, :tail], reason: {:unsupported, :local_identity}}} =
             JidoFactBoundary.check(raw, :output)
  end

  test "the complete fact gate checks metadata handles and wrappers" do
    fact = Fact.new(value: 7, meta: %{reply_to: self()})
    assert {:error, error} = JidoFactBoundary.check(fact, :output)

    assert error == %{
             field: :output,
             path: [:output, :meta, :reply_to],
             reason: {:unsupported, :pid},
             retry: false
           }

    local = JidoFact.local_root(URI.parse("/local"))
    fact = Fact.new(value: 7, meta: %{resource: local.value})

    assert {:error, %{path: [:output, :meta, :resource], reason: {:unsupported, :local_identity}}} =
             JidoFactBoundary.check(fact, :output)

    assert :ok = JidoFactBoundary.check(Fact.new(value: 7, meta: %{status: :ready}), :output)
  end

  test "the consumer keeps local execution scope after a native scalar output" do
    root = JidoFact.local_root(URI.parse("/local"))
    marker = %{identity_mode: root.meta.jido.identity_mode}

    scalar_step =
      Runic.step(fn %JidoFact.LocalValue{value: %URI{path: "/local"}} -> 7 end, name: :scalar)

    definition = Runic.workflow(steps: [scalar_step])
    completed = Workflow.react_until_satisfied(definition, root)
    [scalar] = Workflow.productions(completed, :scalar)
    assert scalar.value == 7
    assert scalar.meta == %{}
    assert scalar.ancestry == {scalar_step.hash, root.hash}
    assert :ok = JidoFactBoundary.check(scalar, :output)

    # The consumer keeps this marker for the whole execution. Runic does not.
    assert {:error, %{reason: {:unsupported, :local_identity}}} =
             JidoFactBoundary.check_execution(marker, scalar, :output)

    # The application explicitly selects the scalar and admits it as new data.
    portable_step = Runic.step(fn value when is_integer(value) -> value end, name: :export)
    portable_definition = Runic.workflow(steps: [portable_step])
    {portable, execution} = Workflow.execute(portable_definition, scalar.value)
    [output] = Workflow.productions(portable, :export)
    portable_marker = %{identity_mode: :portable, execution_id: execution.id}
    assert output.value == 7
    assert output.ancestry == {portable_step.hash, execution.input_fact_id}

    assert [%Fact{hash: input_id, value: 7, ancestry: nil}] =
             Enum.filter(Workflow.facts(portable), &is_nil(&1.ancestry))

    assert input_id == execution.input_fact_id
    refute output.hash == scalar.hash
    assert :ok = JidoFactBoundary.check_execution(portable_marker, output, :output)
  end

  test "one consumer match handles wrapper and metadata handle errors" do
    root = JidoFact.local_root(URI.parse("/local"))
    wrapper = Fact.new(value: [root.value])
    handle = Fact.new(value: 7, meta: %{reply_to: self()})

    for {fact, expected_path, expected_type} <- [
          {wrapper, [:output, :value, 0], :local_identity},
          {handle, [:output, :meta, :reply_to], :pid},
          {root, [:output], :local_identity}
        ] do
      assert {:error, %{field: :output, path: path, reason: {:unsupported, type}, retry: false}} =
               JidoFactBoundary.check(fact, :output)

      assert path == expected_path
      assert type == expected_type
    end
  end

  test "unknown and missing execution modes return field errors" do
    fact = Fact.new(value: 7)

    for marker <- [%{}, %{identity_mode: :unknown}, %{identity_mode: nil}, nil] do
      assert {:error,
              %{
                field: :output,
                path: [:output],
                reason: {:unsupported, :unknown_identity_mode},
                retry: false
              }} =
               JidoFactBoundary.check_execution(marker, fact, :output)
    end
  end

  test "a consumer gate rejects data before the remote transport callback" do
    observer = self()

    dispatch = fn marker, fact ->
      with :ok <- JidoFactBoundary.check_execution(marker, fact, :dispatch) do
        send(observer, {:transport, fact})
        :ok
      end
    end

    root = JidoFact.local_root(URI.parse("/local"))

    for {marker, fact} <- [
          {%{identity_mode: :portable}, Fact.new(value: [root.value])},
          {%{identity_mode: :portable}, Fact.new(value: 7, meta: %{reply_to: self()})},
          {%{identity_mode: :local}, Fact.new(value: 7)},
          {%{}, Fact.new(value: 7)}
        ] do
      assert {:error, %{field: :dispatch, path: _, reason: {:unsupported, _}, retry: false}} =
               dispatch.(marker, fact)
    end

    refute_received {:transport, _}
    portable = Fact.new(value: 7)
    assert :ok = dispatch.(%{identity_mode: :portable}, portable)
    assert_receive {:transport, ^portable}
  end

  test "Jido durable validation identifies raw process-local fields" do
    assert {:error, error} =
             Jido.Exec.Portable.validate(%{items: [%{reply_to: self()}]}, :input)

    assert error.details.path == [:input, :items, 0, :reply_to]
    assert error.details.type == :pid
    assert error.details.retry == false
  end

  test "a portable Jido parent cannot publish a local child" do
    parent = Fact.new(value: %{})

    assert_raise Runic.Identity.CanonicalError, fn ->
      JidoFact.child(parent, value: make_ref(), ancestry: {:jido_child, parent.hash})
    end
  end
end
