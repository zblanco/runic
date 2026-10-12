defmodule Runic.Examples.JidoFactContractTest do
  use ExUnit.Case, async: true
  alias Jido.Exec.Fact, as: JidoFact
  alias Runic.Examples.JidoFactBoundary
  alias Runic.Workflow.Fact

  test "the real Jido wrapper passes through native containers and Jido children" do
    reference = make_ref()
    value = %{reply_to: self(), token: reference, uri: URI.parse("/local")}
    root = JidoFact.local_root(value)
    native = Fact.new(value: [root.value], ancestry: {:native_container, root.hash})
    child = JidoFact.child(native, value: value, ancestry: {:jido_child, native.hash})

    assert JidoFact.value(child) == value
    assert child.meta.jido.identity_mode == :local

    assert {:error, %{field: :output, path: [:output], reason: :local_identity}} =
             JidoFactBoundary.check(child, :output)
  end

  test "local identity persists when the Jido child value is a portable scalar" do
    root = JidoFact.local_root(%{reply_to: self()})
    child = JidoFact.child(root, value: 7, ancestry: {:scalar, root.hash})

    assert child.value == 7
    assert :ok = Jido.Exec.Portable.validate(child.value, :output)
    assert {:error, %{reason: :local_identity}} = JidoFactBoundary.check(child, :output)
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
