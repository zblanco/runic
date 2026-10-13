defmodule Runic.NativeProfileCostTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true
  require Runic
  alias Runic.{Runner, Workflow, Identity}
  alias Runic.Workflow.{Fact, Invokable, LocalBoundary, LocalFactError, LocalScope, Runnable}

  defp hash_count(fun) do
    Code.ensure_loaded!(Fact)
    mfa = {Fact, :local_payload_digest, 2}
    :erlang.trace_pattern(mfa, true, [:call_count])

    try do
      result = fun.()
      {:call_count, count} = :erlang.trace_info(mfa, :call_count)
      {result, count}
    after
      :erlang.trace_pattern(mfa, false, [:call_count])
    end
  end

  test "a local chain hashes each new payload once, independent of value size" do
    a = Runic.step(fn x -> x end, name: :a)
    b = Runic.step(fn x -> x end, name: :b)
    c = Runic.step(fn x -> x end, name: :c)
    definition = Runic.workflow(steps: [{a, [{b, [c]}]}])

    for size <- [16, 16_384] do
      value = Enum.to_list(1..size)

      {{wf, execution}, count} =
        hash_count(fn -> Workflow.execute(definition, value, identity_mode: :local) end)

      assert execution.failures == []
      assert length(Workflow.facts(wf)) == 4
      assert count == 4
    end
  end

  test "shallow propagation adds no payload allocation; full boundaries still verify" do
    {fact, count} = hash_count(fn -> Fact.local(Enum.to_list(1..16_384)) end)
    assert count == 1

    {_, count} =
      hash_count(fn ->
        for _ <- 1..100 do
          assert :ok = Fact.check_parents(fact)
          assert :ok = LocalBoundary.validate_profile!(fact, :fact)
        end
      end)

    assert count == 0
    {_, count} = hash_count(fn -> LocalBoundary.validate_current!(fact, :input) end)
    assert count == 1
    {_, count} = hash_count(fn -> Fact.new(Map.from_struct(fact)) end)
    assert count == 1
  end

  test "caller-chosen local root IDs get a proof while replay still requires it" do
    scope = LocalScope.new()
    id = Identity.local_digest(:fact_occurrence, {:caller, :chosen})
    {fact, count} = hash_count(fn -> Fact.local(7, id: id, local_scope: scope) end)
    assert count == 1
    assert fact.id == id
    assert fact.local_scope == scope
    assert :ok = LocalBoundary.validate_current!(fact, :input)
    event = Workflow.Events.FactProduced.new(fact, producer_label: :input)
    assert [restored] = Workflow.facts(Workflow.from_events([event], nil, allow_local: true))
    assert restored == fact

    assert_raise LocalFactError, fn ->
      Workflow.from_events([%{event | payload_digest: nil}], nil, allow_local: true)
    end

    error =
      assert_raise LocalFactError, fn ->
        Fact.new(value: 7, hash: id, identity_mode: :local, local_scope: scope)
      end

    assert error.reason == :missing_local_payload
    assert Exception.message(error) =~ "invalid local fact profile"
  end

  test "nil-context public Runnable can be accepted without losing its result" do
    node = Runic.step(fn x -> x + 1 end, name: :increment)
    input = Fact.new(value: 7)
    output = Fact.child(input, value: 8, ancestry: {node.hash, input.hash})
    wf = Workflow.new() |> Workflow.add(node) |> Workflow.log_fact(input)
    event = Workflow.Events.FactProduced.new(output, producer_label: :produced)

    attempt = %Runnable{
      id: :legacy,
      node: node,
      input_fact: input,
      context: nil,
      status: :completed,
      result: output,
      events: [event]
    }

    {wf, accepted, _} = Workflow.accept_runnable(wf, attempt)
    assert accepted.status == :completed
    assert Workflow.raw_productions(wf) == [8]
  end

  test "a nil-context custom Invokable completes in a Worker without stopping its owner" do
    node = %Runic.TestSupport.NilContextNode{
      hash: Identity.digest(:component_definition, :nil_context)
    }

    definition = Workflow.new() |> Workflow.add_step(node)
    runner = :"nil_context_worker_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner})

    {:ok, worker} =
      Runner.start_workflow(runner, :nil_ctx, definition, owner: self(), persistence: :disabled)

    {:ok, id} = Runner.start_execution(runner, :nil_ctx, 7)
    assert {:ok, execution} = Runner.await_execution(runner, :nil_ctx, id)
    assert execution.failures == []
    assert Workflow.Execution.outputs(execution) == [8]
    assert Process.alive?(worker)
    assert :ok = Runner.cancel(runner, :nil_ctx)
  end

  test "edge-less portable Step retains upstream nil values and identity bytes" do
    {golden, _} =
      Code.eval_file(Path.join(__DIR__, "fixtures/portable_edge_less_meta_golden.exs"))

    acc = Runic.accumulator(0, fn _, state -> state end, name: :source)

    step =
      Workflow.Step.new(
        name: :read,
        hash: Identity.digest(:component_definition, [:portable_edge_less_meta_golden]),
        work: fn x, ctx -> {x, Map.get(ctx, :state), Map.get(ctx, :values)} end,
        meta_refs: [
          %{kind: :state_of, target: :source, field_path: [], context_key: :state},
          %{kind: :all_values_of, target: :source, field_path: [], context_key: :values}
        ]
      )

    wf = Workflow.new() |> Workflow.add(acc) |> Workflow.add(step)
    {:ok, prepared} = Invokable.prepare(step, wf, Fact.new(value: 7))
    assert prepared.context.meta_context == %{}
    assert prepared.context.meta_parents == []
    completed = Invokable.execute(step, prepared)
    output = completed.result
    assert output.value == {7, nil, nil}
    assert to_string(step.hash) == golden.step_hash
    assert to_string(prepared.input_fact.hash) == golden.root_hash
    assert to_string(output.hash) == golden.output_hash
    assert to_string(output.payload_digest) == golden.output_payload_digest
    assert to_string(output.content_digest) == golden.output_content_digest
  end

  test "portable meta history stays out of contexts and satisfied events" do
    acc = Runic.accumulator(0, fn _, state -> state + 1 end, name: :source)

    rule =
      Runic.rule name: :observe do
        given(value: v)
        where(length(all_values_of(:source)) >= 0)
        then(fn %{value: v} -> v end)
      end

    wf =
      Workflow.new()
      |> Workflow.add(acc)
      |> Workflow.add(rule)
      |> Workflow.enable_event_emission()

    wf = Enum.reduce(1..51, wf, fn n, wf -> Workflow.react_until_satisfied(wf, n) end)

    events =
      Enum.filter(wf.uncommitted_events, &is_struct(&1, Workflow.Events.ConditionSatisfied))

    assert length(events) >= 51
    assert Enum.all?(events, &(&1.meta_parents == []))
    # Hashes and weight have bounded encodings; source history cannot grow this record.
    assert Enum.max(Enum.map(events, &byte_size(:erlang.term_to_binary(&1)))) < 1_024
    condition = Map.fetch!(wf.graph.vertices, rule.condition_hash)
    {:ok, prepared} = Invokable.prepare(condition, wf, Fact.new(value: 52))
    assert prepared.context.meta_parents == []
    {values, parents} = Workflow.prepare_meta_context_with_parents(wf, condition)
    assert parents == []
    assert values != %{}
  end

  test "untrusted adapter data uses full validation; shallow folds are not an import codec" do
    fact = Fact.local(7)
    swapped = %{fact | local_scope: LocalScope.new()}
    assert :ok = LocalBoundary.validate_profile!(swapped, :fact)
    assert_raise LocalFactError, fn -> LocalBoundary.validate_current!(swapped, :input) end
    assert_raise LocalFactError, fn -> Fact.new(Map.from_struct(swapped)) end
    runner = :"native_profile_admission_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner})
    definition = Runic.workflow(steps: [Runic.step(fn x -> x end)])

    {:ok, worker} =
      Runner.start_workflow(runner, :local, definition, owner: self(), persistence: :disabled)

    assert {:error, %LocalFactError{reason: :local_identity_mismatch}} =
             Runner.run(runner, :local, swapped)

    assert Process.alive?(worker)
    bad_workflow = Workflow.log_fact(definition, swapped)

    assert {:error, %LocalFactError{reason: :local_identity_mismatch}} =
             Runner.start_workflow(runner, :bad_graph, bad_workflow,
               owner: self(),
               persistence: :disabled
             )
  end
end
