defmodule Runic.IdentityRegressionTest do
  use ExUnit.Case, async: true

  require Runic

  alias Runic.Identity
  alias Runic.Identity.{Canonical, IntegrityError}
  alias Runic.Workflow
  alias Runic.Workflow.{Fact, FactResolver, Facts, Step}
  alias Runic.Workflow.Events.FactProduced

  test "projected structs cannot alias ordinary tuples, including as map keys" do
    range = 1..3
    tuple = {:projected, Range, %{first: 1, last: 3, step: 1}}

    refute Canonical.encode!(range) == Canonical.encode!(tuple)
    refute Canonical.encode!(range) == Canonical.encode!({Range, %{first: 1, last: 3, step: 1}})
    refute Canonical.encode!(%{range => :value}) == Canonical.encode!(%{tuple => :value})

    first = Fact.new(value: range)
    second = Fact.new(value: tuple)
    refute first.payload_digest == second.payload_digest
    refute first.id == second.id

    workflow = Workflow.new() |> Workflow.log_fact(first) |> Workflow.log_fact(second)
    assert length(Workflow.facts(workflow)) == 2

    resolver = %FactResolver{cache: %{first.hash => tuple}}

    assert {:error, %IntegrityError{}} = FactResolver.resolve(Facts.to_ref(first), resolver)
  end

  test "all step macro forms support pinned external captures and replay" do
    mapper = &Enum.sum/1

    steps = [
      Runic.step(fn values -> (^mapper).(values) end),
      Runic.step(work: fn values -> (^mapper).(values) end, name: :keyword_sum),
      Runic.step(fn values -> (^mapper).(values) end, name: :named_sum)
    ]

    for step <- steps do
      assert Step.run(step, [1, 2, 3]) == 6
      workflow = Workflow.new() |> Workflow.add(step)
      rebuilt = workflow |> Workflow.build_log() |> Workflow.from_log()
      restored = Workflow.get_component(rebuilt, step.name)
      assert restored.hash == step.hash
      assert Step.run(restored, [1, 2, 3]) == 6
      assert Runic.Component.hash(rebuilt) == Runic.Component.hash(workflow)
    end
  end

  test "nested external captures survive binding projection" do
    config = %{mappers: [&Enum.sum/1]}
    step = Runic.step(fn values -> hd((^config).mappers).(values) end)
    assert Step.run(step, [1, 2]) == 3
  end

  test "function bindings cannot alias literal MFA tuples" do
    source = quote(do: fn -> binding end)
    function = Runic.Closure.new(source, %{binding: &Enum.sum/1}, nil)
    tuple = Runic.Closure.new(source, %{binding: {:mfa, Enum, :sum, 1}}, nil)
    refute function.hash == tuple.hash
    refute Runic.Closure.identity_bindings(function) == Runic.Closure.identity_bindings(tuple)
  end

  test "condition, reduce and accumulator macros support pinned external captures" do
    predicate = &Enum.empty?/1
    combiner = &Kernel.+/2

    for condition <- [
          Runic.condition(fn values -> (^predicate).(values) end),
          Runic.condition(fn values -> (^predicate).(values) end, name: :empty)
        ] do
      assert condition.work.([])
      refute condition.work.([1])
    end

    reduce = Runic.reduce(0, fn value, acc -> (^combiner).(value, acc) end)
    accumulator = Runic.accumulator(0, fn value, acc -> (^combiner).(value, acc) end)
    assert reduce.fan_in.reducer.(2, 3) == 5
    assert accumulator.reducer.(2, 3) == 5
  end

  test "workflow artifacts distinguish call contracts with different execution behavior" do
    work = fn input, context -> {input, context} end
    positional = Step.new(name: :example, work: work)

    contextual =
      Step.new(
        name: :example,
        work: work,
        meta_refs: [%{kind: :context, target: nil, context_key: :config, field_path: []}]
      )

    assert positional.hash == contextual.hash
    assert Step.run_with_meta_context(positional, [1, 2], %{config: 3}) == {1, 2}
    assert Step.run_with_meta_context(contextual, [1, 2], %{config: 3}) == {[1, 2], %{config: 3}}
    refute artifact(positional) == artifact(contextual)
  end

  test "workflow artifacts include port contracts and executable definitions behind explicit keys" do
    first = Step.new(name: :value, work: &Function.identity/1, outputs: [value: :integer])
    second = Step.new(name: :value, work: &Function.identity/1, outputs: [value: :string])
    assert first.hash == second.hash
    refute artifact(first) == artifact(second)

    first = Step.new(name: :value, hash: 42, work: fn value -> value + 1 end)
    second = Step.new(name: :value, hash: 42, work: fn value -> value + 2 end)
    refute artifact(first) == artifact(second)
  end

  test "workflow artifact identity survives execution and runtime context changes" do
    workflow = Workflow.new() |> Workflow.add(Runic.map(fn value -> value * 2 end, name: :double))
    digest = Runic.Component.hash(workflow)

    executed =
      workflow
      |> Workflow.put_run_context(%{_global: %{runtime: :value}})
      |> Workflow.react_until_satisfied([1, 2])

    assert Runic.Component.hash(executed) == digest
  end

  test "Cytoscape elements encode full typed hashes as JSON strings" do
    step = Step.new(name: :echo, work: &Function.identity/1)
    workflow = Workflow.new() |> Workflow.add(step) |> Workflow.react_until_satisfied(42)
    elements = Workflow.to_cytoscape(workflow, include_facts: true, include_memory: true)
    decoded = elements |> JSON.encode!() |> JSON.decode!()
    node = Enum.find(decoded, &(&1["data"]["name"] == "echo" and &1["data"]["hash"] != nil))

    assert node["data"]["hash"] == Identity.to_string(step.hash)

    assert Enum.any?(
             decoded,
             &String.starts_with?(&1["data"]["hash"] || "", "runic:sha256:v1:fact_occurrence:")
           )
  end

  test "explicit Fact IDs distinguish equal inputs and survive replay and hydration" do
    first_id = Identity.derive(:fact_occurrence, [:first_ingress])
    second_id = Identity.derive(:fact_occurrence, [:second_ingress])
    first = Fact.new(id: first_id, value: :same)
    second = Fact.new(id: second_id, value: :same)

    assert first.id == first_id
    assert first.hash == first_id
    assert second.id == second_id
    assert first.payload_digest == second.payload_digest

    events = Enum.map([first, second], &FactProduced.new(&1, producer_label: :input, weight: 0))
    replayed = Workflow.from_events(events)
    assert MapSet.new(Workflow.facts(replayed), & &1.id) == MapSet.new([first_id, second_id])

    lean = Workflow.from_events(Enum.map(events, &%{&1 | value: nil}), nil, fact_mode: :ref)
    resolver = %FactResolver{cache: %{first_id => :same, second_id => :same}}

    for id <- [first_id, second_id] do
      assert {:ok, %Fact{id: ^id, hash: ^id, value: :same}} =
               FactResolver.resolve(Map.fetch!(lean.graph.vertices, id), resolver)
    end
  end

  test "Fact constructor reconciles compatibility hashes and rejects invalid or conflicting IDs" do
    id = Identity.derive(:fact_occurrence, [:input])
    other = Identity.derive(:fact_occurrence, [:other])
    assert Fact.new(id: id, hash: id, value: 1).id == id
    assert Fact.new(hash: id, value: 1).id == id
    assert Fact.new(hash: 42, value: 1).hash == 42

    for hash <- [other, 42] do
      assert_raise ArgumentError, ~r/id and hash must identify the same occurrence/, fn ->
        Fact.new(id: id, hash: hash, value: 1)
      end
    end

    for invalid <- [
          Identity.digest(:payload, :value),
          %{id | digest: <<1>>},
          %{id | version: 2},
          42
        ] do
      assert_raise ArgumentError, ~r/expected a valid Fact occurrence identity/, fn ->
        Fact.new(id: invalid, value: 1)
      end
    end
  end

  defp artifact(step), do: Workflow.new() |> Workflow.add(step) |> Runic.Component.hash()
end
