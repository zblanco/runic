defmodule Runic.FactBoundariesTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  require Runic

  alias Runic.Examples.{FactBoundary, LocalValue}
  alias Runic.Identity.{Canonical, CanonicalError}
  alias Runic.Runner
  alias Runic.TestSupport.ProjectedResource
  alias Runic.Workflow
  alias Runic.Workflow.{Execution, Fact}

  test "portable construction rejects a local term and identifies its field" do
    error =
      assert_raise CanonicalError, fn ->
        Fact.new(value: %{requests: [%{reply_to: self()}]})
      end

    assert error.reason == {:unsupported, :pid}
    assert error.path == [:value, :requests, 0, :reply_to]

    assert_raise CanonicalError, fn -> Fact.new(value: make_ref(), hash: 123) end
  end

  test "a supplied local payload digest cannot make native children inherit it" do
    value = %{reply_to: self()}
    digest = Runic.Identity.digest(:payload, {:local_probe, LocalValue.new(value).digest})
    parent = Fact.new(value: value, payload_digest: digest)

    assert_raise CanonicalError, fn ->
      Fact.new(value: value, ancestry: {:child, parent.hash})
    end

    assert {:error, %{path: [:input, :reply_to], reason: {:unsupported, :pid}}} =
             FactBoundary.check(parent.value, :input)
  end

  test "projection encodes a wrapper but does not make its raw value portable" do
    local = LocalValue.new(%{reply_to: self(), token: make_ref()})
    assert is_binary(Canonical.encode!(local))
    assert Fact.new(value: local).payload_digest == Fact.new(value: local).payload_digest

    for field <- [:input, :output, :metadata, :effects, :bindings] do
      assert {:error, %{field: ^field, path: [^field], reason: {:unsupported, :local_identity}}} =
               FactBoundary.check(local, field)
    end

    assert {:error, %{path: [:output, 0, :local], reason: {:unsupported, :local_identity}}} =
             FactBoundary.check([%{local: local}], :output)
  end

  test "the data gate checks nested raw fields before identity projection" do
    for {value, path, type} <- [
          {%{reply_to: self()}, [:input, :reply_to], :pid},
          {{:ok, [make_ref()]}, [:input, 1, 0], :reference},
          {%{callback: fn -> :ok end}, [:input, :callback], :function},
          {%{self() => :value}, [:input, {:map_key, 0}], :pid},
          {%{key: self()}, [:input, :key], :pid},
          {[1 | make_ref()], [:input, :tail], :reference},
          {[1 | 2], [:input, :tail], :improper_list},
          {%{payload: URI.parse("/local")}, [:input, :payload], URI}
        ] do
      assert {:error, %{field: :input, path: ^path, reason: {:unsupported, ^type}}} =
               FactBoundary.check(value, :input)
    end

    assert :ok =
             FactBoundary.check(%{values: [nil, true, 12, 2.5, "text", {:ok, :ready}]}, :input)
  end

  test "a general identity projection can omit a raw resource that the gate rejects" do
    digest = Fact.new(value: %ProjectedResource{name: :client, resource: nil}).payload_digest

    for {resource, type} <- [{self(), :pid}, {fn -> :ok end, :function}] do
      value = %ProjectedResource{name: :client, resource: resource}
      assert is_binary(Canonical.encode!(value))
      assert Fact.new(value: value).payload_digest == digest

      assert {:error, %{path: [:input, :client, :resource], reason: {:unsupported, ^type}}} =
               FactBoundary.check(%{client: value}, :input)
    end
  end

  test "native containers retain wrappers and a scalar child stays local" do
    root = Fact.new(value: LocalValue.new(%{pid: self(), token: make_ref()}))
    container = Fact.new(value: %{nested: {[root.value], :ok}}, ancestry: {:join, root.hash})

    assert {:error, %{path: [:output, :nested, 0, 0]}} =
             FactBoundary.check(container.value, :output)

    scalar = LocalValue.map(root.value, fn _ -> 7 end)
    child = Fact.new(value: scalar, ancestry: {:child, root.hash})
    assert child.value.value == 7
    assert child.ancestry == {:child, root.hash}

    assert {:error, %{reason: {:unsupported, :local_identity}}} =
             FactBoundary.check(child.value, :output)
  end

  test "repeated executions retain local payload identity and use distinct occurrences" do
    step =
      Runic.step(fn input -> LocalValue.map(input, &Map.put(&1, :done, true)) end, name: :local)

    definition = Runic.workflow(steps: [step])
    input = LocalValue.new(%{reply_to: self()})
    {workflow, first} = Workflow.execute(definition, input)
    {workflow, second} = Workflow.execute(workflow, input)

    refute first.id == second.id
    refute first.input_fact_id == second.input_fact_id
    assert first.persistence.status == :not_managed
    assert second.quiescent?
    assert [%LocalValue{value: %{done: true}}] = Execution.outputs(first)
    assert [%LocalValue{value: %{done: true}}] = Execution.outputs(second)

    roots = Enum.filter(Workflow.facts(workflow), &is_nil(&1.ancestry))
    assert length(roots) == 2
    assert roots |> Enum.map(& &1.payload_digest) |> Enum.uniq() |> length() == 1
  end

  test "a nested execution receives wrappers explicitly" do
    inner =
      Runic.workflow(
        steps: [Runic.step(fn input -> LocalValue.map(input, &Map.put(&1, :inner, true)) end)]
      )

    outer_step =
      Runic.step(fn input ->
        {_inner, execution} = Workflow.execute(inner, input, async: true)
        [output] = Execution.outputs(execution)
        output
      end)

    definition = Runic.workflow(steps: [outer_step])

    {_workflow, execution} =
      Workflow.execute(definition, LocalValue.new(%{reply_to: self()}), async: true)

    assert [%LocalValue{value: %{reply_to: pid, inner: true}}] = Execution.outputs(execution)
    assert pid == self()
  end

  test "a raw local output fails and a later portable execution uses the same graph" do
    step =
      Runic.step(
        fn
          :local -> %{reply_to: self()}
          :portable -> %{status: :ok}
        end,
        name: :output
      )

    definition = Runic.workflow(steps: [step])
    {workflow, failed} = Workflow.execute(definition, :local)
    assert Execution.outputs(failed) == []
    assert [%{error: %CanonicalError{reason: {:unsupported, :pid}}}] = failed.failures
    {_workflow, success} = Workflow.execute(workflow, :portable)
    assert Execution.outputs(success) == [%{status: :ok}]
  end

  test "context replacement is shallow and takes effect when work is prepared" do
    lookup = Runic.step(fn key -> context(:fetch).(key) end, name: :lookup)
    definition = Runic.workflow(steps: [lookup])
    old = fn _ -> :old end
    fresh = fn _ -> :fresh end

    workflow =
      definition
      |> Workflow.put_run_context(%{lookup: %{fetch: old, discarded: true}, other: %{keep: true}})
      |> Workflow.put_run_context(%{lookup: %{fetch: fresh}})

    assert Workflow.get_run_context(workflow, :lookup) == %{fetch: fresh}
    assert Workflow.get_run_context(workflow, :other) == %{keep: true}

    {:ok, prepared} =
      Workflow.Invokable.prepare(lookup, workflow, Fact.new(value: "key"))

    updated = Workflow.put_run_context(workflow, %{lookup: %{fetch: old}})
    assert Workflow.Invokable.execute(lookup, prepared).result.value == :fresh
    assert Workflow.get_run_context(updated, :lookup) == %{fetch: old}

    {workflow, execution} = Workflow.execute(workflow, "key")
    assert Execution.outputs(execution) == [:fresh]
    assert Enum.all?(Workflow.facts(workflow), &(FactBoundary.check(&1.value, :value) == :ok))
  end

  test "event replay and snapshot resume discard live context before pending work" do
    lookup = Runic.step(fn key -> context(:fetch).(key) end, name: :lookup)
    definition = Runic.workflow(steps: [lookup])
    observer = self()

    old = fn key ->
      send(observer, {:old, key})
      :old
    end

    fresh = fn key ->
      send(observer, {:fresh, key})
      :fresh
    end

    planned =
      definition
      |> Workflow.put_run_context(%{lookup: %{fetch: old}})
      |> Workflow.plan("key")

    replay = Workflow.from_events(Workflow.event_log(planned))
    assert replay.run_context == %{}
    assert {:ok, snapshot} = planned |> Runner.encode_snapshot() |> Runner.decode_snapshot()
    assert snapshot.run_context == %{}

    for restored <- [replay, snapshot] do
      completed =
        restored
        |> Workflow.put_run_context(%{lookup: %{fetch: fresh}})
        |> Workflow.react_until_satisfied()

      assert Workflow.raw_productions(completed) == [:fresh]
      assert_receive {:fresh, "key"}
    end

    refute_received {:old, _}
  end

  test "accepted portable events replay without repeating the context callback" do
    step = Runic.step(fn key -> context(:fetch).(key) end, name: :lookup)
    observer = self()

    fetch = fn key ->
      send(observer, {:lookup, key})
      %{found: true}
    end

    completed =
      Runic.workflow(steps: [step])
      |> Workflow.react_until_satisfied("key", run_context: %{lookup: %{fetch: fetch}})

    assert_receive {:lookup, "key"}
    replay = Workflow.from_events(Workflow.event_log(completed))
    assert replay.run_context == %{}
    assert Workflow.raw_productions(replay) == [%{found: true}]
    refute_received {:lookup, _}
  end

  test "missing restored context can produce successful nil without explicit validation" do
    step = Runic.step(fn _ -> context(:resource) end, name: :lookup)

    planned =
      Runic.workflow(steps: [step])
      |> Workflow.put_run_context(%{lookup: %{resource: :old}})
      |> Workflow.plan("key")

    restored = Workflow.from_events(Workflow.event_log(planned))
    assert restored.run_context == %{}
    assert {:error, %{lookup: [:resource]}} = Workflow.validate_run_context(restored, %{})
    completed = Workflow.react_until_satisfied(restored)
    assert [%Fact{value: nil}] = Workflow.productions(completed, :lookup)
    assert :ok = Workflow.validate_run_context(restored, %{lookup: %{resource: nil}})
  end

  test "a restored context default is optional and yields the selected default" do
    step = Runic.step(fn _ -> context(:resource, default: :fallback) end, name: :lookup)

    planned =
      Runic.workflow(steps: [step])
      |> Workflow.put_run_context(%{lookup: %{resource: :old}})
      |> Workflow.plan("key")

    restored = Workflow.from_events(Workflow.event_log(planned))
    assert restored.run_context == %{}
    assert :ok = Workflow.validate_run_context(restored, %{})

    assert [%Fact{value: :fallback}] =
             restored |> Workflow.react_until_satisfied() |> Workflow.productions(:lookup)

    explicit_nil = %{lookup: %{resource: nil}}
    assert :ok = Workflow.validate_run_context(restored, explicit_nil)

    assert [%Fact{value: :fallback}] =
             restored
             |> Workflow.put_run_context(explicit_nil)
             |> Workflow.react_until_satisfied()
             |> Workflow.productions(:lookup)
  end

  test "a nil context default is required for validation and resolves to nil" do
    step = Runic.step(fn _ -> context(:resource, default: nil) end, name: :lookup)
    definition = Runic.workflow(steps: [step])
    assert {:error, %{lookup: [:resource]}} = Workflow.validate_run_context(definition, %{})
    assert :ok = Workflow.validate_run_context(definition, %{lookup: %{resource: nil}})

    assert [%Fact{value: nil}] =
             definition |> Workflow.react_until_satisfied("key") |> Workflow.productions(:lookup)
  end

  test "Rule condition validation uses the Rule name but runtime requires global context" do
    rule =
      Runic.rule name: :gated do
        given(val: v)
        where(v > context(:threshold))
        then(fn %{val: v} -> {:ok, v} end)
      end

    definition = Runic.workflow(rules: [rule])
    scoped = %{gated: %{threshold: 1}}
    assert :ok = Workflow.validate_run_context(definition, scoped)

    assert [] ==
             definition
             |> Workflow.react_until_satisfied(5, run_context: scoped)
             |> Workflow.raw_productions()

    global = %{_global: %{threshold: 1}}
    assert :ok = Workflow.validate_run_context(definition, global)

    assert [{:ok, 5}] ==
             definition
             |> Workflow.react_until_satisfied(5, run_context: global)
             |> Workflow.raw_productions()
  end

  test "Rule reactions use a generated Step name and accept global resources" do
    rule =
      Runic.rule name: :tagged do
        given(val: v)
        where(v > 1)
        then(fn %{val: v} -> {context(:tag), v} end)
      end

    definition = Runic.workflow(rules: [rule])
    scoped = %{tagged: %{tag: :done}}
    assert {:error, missing} = Workflow.validate_run_context(definition, scoped)
    refute Map.has_key?(missing, :tagged)
    assert Map.values(missing) == [[:tag]]

    assert [{nil, 5}] ==
             definition
             |> Workflow.react_until_satisfied(5, run_context: scoped)
             |> Workflow.raw_productions()

    global = %{_global: %{tag: :done}}
    assert :ok = Workflow.validate_run_context(definition, global)

    assert [{:done, 5}] ==
             definition
             |> Workflow.react_until_satisfied(5, run_context: global)
             |> Workflow.raw_productions()
  end

  test "cancellation stops native work that uses a transient local callback" do
    runner = :"fact_boundary_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner})
    observer = self()

    fetch = fn key ->
      send(observer, {:started, self(), key})
      receive do: (:release -> %{found: true})
    end

    step = Runic.step(fn key -> context(:fetch).(key) end, name: :lookup)
    workflow = Runic.workflow(steps: [step])

    assert {:ok, worker} = Runner.start_workflow(runner, :lookup, workflow, owner: self())

    assert :ok = Runner.run(runner, :lookup, "key", run_context: %{lookup: %{fetch: fetch}})
    assert_receive {:started, task, "key"}, 1_000
    task_ref = Process.monitor(task)
    worker_ref = Process.monitor(worker)
    assert :ok = Runner.cancel(runner, :lookup)
    assert_receive {:DOWN, ^task_ref, :process, ^task, _}, 1_000
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 1_000
    refute Process.alive?(task)
  end
end
