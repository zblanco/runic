defmodule Runic.NativeReplayBoundaryTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  require Runic
  alias Runic.{Runner, Workflow}
  alias Runic.Workflow.{Fact, FactRef, FactResolver, LocalFactError, Rehydration}

  alias Runic.Workflow.Events.{
    FactProduced,
    StateInitiated,
    JoinCompleted,
    FanOutFactEmitted,
    FanInCompleted
  }

  alias Runic.TestSupport.NativeReadSpy

  defp native_events do
    fact = Fact.local(7)

    common = %{
      hash: fact.hash,
      value: fact.value,
      ancestry: fact.ancestry,
      identity_mode: :local,
      local_scope: fact.local_scope
    }

    [
      {FactProduced.new(fact, producer_label: :input), :local_scope},
      {%StateInitiated{
         init_fact_hash: common.hash,
         init_payload_digest: fact.payload_digest,
         init_value: common.value,
         init_ancestry: common.ancestry,
         init_identity_mode: :local,
         init_local_scope: common.local_scope
       }, :init_local_scope},
      {%JoinCompleted{
         result_fact_hash: common.hash,
         result_payload_digest: fact.payload_digest,
         result_value: common.value,
         result_ancestry: common.ancestry,
         result_identity_mode: :local,
         result_local_scope: common.local_scope
       }, :result_local_scope},
      {%FanOutFactEmitted{
         emitted_fact_hash: common.hash,
         emitted_payload_digest: fact.payload_digest,
         emitted_value: common.value,
         emitted_identity_mode: :local,
         emitted_local_scope: common.local_scope
       }, :emitted_local_scope},
      {%FanInCompleted{
         result_fact_hash: common.hash,
         result_payload_digest: fact.payload_digest,
         result_value: common.value,
         result_ancestry: common.ancestry,
         result_identity_mode: :local,
         result_local_scope: common.local_scope
       }, :result_local_scope}
    ]
  end

  test "every native event requires its original scope, whether nil or absent" do
    for {event, key} <- native_events(), missing <- [nil, :absent] do
      incomplete = if missing == nil, do: Map.put(event, key, nil), else: Map.delete(event, key)

      error =
        assert_raise LocalFactError, fn ->
          Workflow.from_events([incomplete], nil, allow_local: true)
        end

      assert error.reason == :missing_local_scope
      assert error.path == [:events, 0, key]
    end

    fact = Fact.local(7)

    assert_raise ArgumentError, fn ->
      Fact.new(value: 7, identity_mode: :local, hash: fact.hash)
    end
  end

  test "valid native event fields preserve identities and scopes in same-VM replay" do
    producer = Runic.step(fn x -> x end, name: :producer)
    base = Workflow.new() |> Workflow.add_step(producer)

    for {event, key} <- native_events(), fact_mode <- [:full, :ref] do
      event =
        Enum.reduce([:accumulator_hash, :join_hash, :fan_in_hash, :fan_out_hash], event, fn field,
                                                                                            event ->
          if Map.has_key?(event, field), do: Map.put(event, field, producer.hash), else: event
        end)

      rebuilt = Workflow.from_events([event], base, allow_local: true, fact_mode: fact_mode)
      assert [fact] = Workflow.facts(rebuilt)
      assert fact.identity_mode == :local
      assert fact.local_scope == Map.fetch!(event, key)

      id_field =
        Enum.find(
          [:hash, :init_fact_hash, :result_fact_hash, :emitted_fact_hash],
          &Map.has_key?(event, &1)
        )

      assert fact.hash == Map.fetch!(event, id_field)
    end
  end

  test "every native event rejects a swapped valid scope and a missing payload proof" do
    scope = Runic.Workflow.LocalScope.new()

    for {event, scope_key} <- native_events() do
      swapped = Map.put(event, scope_key, scope)

      error =
        assert_raise LocalFactError, fn ->
          Workflow.from_events([swapped], nil, allow_local: true)
        end

      assert error.reason == :local_identity_mismatch

      payload_key =
        case scope_key do
          :local_scope -> :payload_digest
          :init_local_scope -> :init_payload_digest
          :emitted_local_scope -> :emitted_payload_digest
          :result_local_scope -> :result_payload_digest
        end

      for missing <- [nil, :absent] do
        incomplete =
          if missing == nil,
            do: Map.put(event, payload_key, nil),
            else: Map.delete(event, payload_key)

        error =
          assert_raise LocalFactError, fn ->
            Workflow.from_events([incomplete], nil, allow_local: true)
          end

        assert error.reason == :missing_local_payload
      end
    end

    fact = Fact.local(7)

    assert_raise LocalFactError, fn ->
      Fact.new(Map.put(Map.from_struct(fact), :local_scope, scope))
    end

    assert_raise LocalFactError, fn ->
      Fact.new(value: 7, hash: fact.hash, identity_mode: :local, local_scope: scope)
    end
  end

  test "a correctly recomputed payload cannot change an in-graph parent's scope" do
    producer = Runic.step(fn x -> x end, name: :producer)
    parent = Fact.local(7)
    child = Fact.child(parent, value: 8, ancestry: {producer.hash, parent.hash})
    base = Workflow.new() |> Workflow.add_step(producer) |> Workflow.log_fact(parent)
    new_scope = Runic.Workflow.LocalScope.new()

    forged = %{
      child
      | local_scope: new_scope,
        payload_digest: Fact.local_payload_digest(8, new_scope)
    }

    event = FactProduced.new(forged, producer_label: :produced)

    error =
      assert_raise LocalFactError, fn ->
        Workflow.from_events([event], base, allow_local: true)
      end

    assert error.reason == :local_parent_scope_mismatch
  end

  test "default replay rejects local bases and explicit replay rejects foreign bases" do
    definition = Runic.workflow(steps: [Runic.step(fn x -> x end)])
    {local, _} = Workflow.execute(definition, 7, identity_mode: :local)
    assert_raise LocalFactError, fn -> Workflow.from_events([], local) end
    assert Workflow.from_events([], local, allow_local: true) == local

    graph =
      Enum.reduce(Workflow.facts(local), local.graph, fn fact, graph ->
        foreign = %{fact | local_scope: %{fact.local_scope | vm: <<0::256>>}}
        %{graph | vertices: Map.put(graph.vertices, fact.hash, foreign)}
      end)

    foreign = %{local | graph: graph}
    assert_raise LocalFactError, fn -> Workflow.from_events([], foreign) end
    assert_raise LocalFactError, fn -> Workflow.from_events([], foreign, allow_local: true) end
  end

  test "legacy root Facts from a decoded snapshot can be re-admitted" do
    root = Fact.new(value: 7) |> Map.drop([:identity_mode, :local_scope])
    definition = Runic.workflow(steps: [Runic.step(fn x -> x + 1 end)])
    planned = Workflow.plan(definition, root)
    assert %Workflow{} = planned
    completed = Workflow.react_until_satisfied(definition, root)
    assert Workflow.raw_productions(completed) == [8]
    assert FactProduced.new(root, producer_label: :input).identity_mode == :portable
    assert {:ok, decoded} = Runner.decode_snapshot(Runner.encode_snapshot(planned))
    old = Enum.find(Workflow.facts(decoded), &is_nil(&1.ancestry))
    assert Workflow.raw_productions(Workflow.react_until_satisfied(definition, old)) == [8]
  end

  test "projected references reject all native markers before cache or Store reads" do
    local = Fact.local(7)
    portable = Fact.new(value: 7)

    for ref <- [
          %FactRef{hash: local.hash},
          %FactRef{hash: portable.hash, payload_digest: local.payload_digest},
          %FactRef{hash: portable.hash, local_scope: local.local_scope},
          %FactRef{hash: local.hash} |> Map.delete(:identity_mode)
        ] do
      for cache <- [%{}, %{ref.hash => 7}] do
        resolver = %FactResolver{store: {NativeReadSpy, self()}, cache: cache}
        assert {:error, %LocalFactError{}} = FactResolver.resolve(ref, resolver)
        refute_received {:native_store_read, _}
      end
    end

    resolver = %FactResolver{store: {NativeReadSpy, self()}, cache: %{local.hash => 7}}

    assert_raise LocalFactError, fn ->
      FactResolver.preload(resolver, [portable.hash, local.hash])
    end

    refute_received {:native_store_read, _}
  end

  test "dehydration keeps cold local values and identities in memory" do
    definition = Runic.workflow(steps: [Runic.step(fn x -> x end)])
    {wf, _} = Workflow.execute(definition, self(), identity_mode: :local)
    facts = Workflow.facts(wf)
    dehydrated = Rehydration.dehydrate(wf, MapSet.new(Enum.map(facts, & &1.hash)))
    assert Workflow.facts(dehydrated) == facts
    {fused, _} = Rehydration.rehydrate_fused(wf, {NativeReadSpy, self()})
    assert Workflow.facts(fused) == facts
    hot = Rehydration.classify(fused).hot
    resolver = FactResolver.new({NativeReadSpy, self()})
    {resolved, ^resolver} = Rehydration.resolve_hot(fused, hot, resolver)
    assert Workflow.facts(resolved) == facts
    refute_received {:native_store_read, _}
  end
end
