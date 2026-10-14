defmodule Runic.Workflow.BatchFinalReviewTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  require Runic
  alias Runic.{Runner, Workflow}
  alias Runic.Workflow.Batch
  alias Runic.TestSupport.{BatchFinalComponent, OrdinaryComponent}

  test "Root stays outside Batch coordinate, context and failure-scope membership" do
    root = Workflow.root()
    root_id = Workflow.Components.vertex_id_of(root)
    batch = Runic.batch(OrdinaryComponent.new(:member, :data), name: :batch)

    workflow =
      Workflow.new()
      |> Workflow.add(batch)
      |> Workflow.plan_eagerly(Batch.input([1], :parent))
      |> Workflow.react()

    {workflow, [member]} = Workflow.prepare_for_dispatch(workflow)
    assert member.node.hash == Workflow.Components.vertex_id_of(member.node)
    refute Map.has_key?(workflow.mapped.batch_members, root_id)

    for graph <- [Workflow.new(), workflow],
        fact <- [Workflow.Fact.new(value: :input), member.input_fact] do
      assert Batch.context(graph, root, fact) == nil
      assert Batch.item_scope(graph, root, fact) == nil
      refute Batch.provides_context?(graph, root, :batch)
    end

    assert Batch.context(workflow, member.node, member.input_fact).parent == :parent
    assert Batch.item_scope(workflow, member.node, member.input_fact) == member.input_fact.hash
    assert Batch.provides_context?(workflow, member.node, :batch)
  end

  test "Batch removal keeps public connections and zero-weight flow live and after replay" do
    a = Runic.step(fn value -> [value + 1] end, name: :a)
    batch = Runic.batch(OrdinaryComponent.new(:member, :data), name: :batch)
    c = Runic.step(fn value -> value end, name: :c)

    template =
      Workflow.new()
      |> Workflow.add(a)
      |> Workflow.add(batch, to: :a)
      |> Workflow.add(c, to: :batch)

    assert component_edges(template) |> Enum.sort() == [a: :batch, batch: :c]
    {before, _} = Workflow.execute(template, 1)
    assert [%Batch.Result{outcomes: [%{value: 2}]}] = Workflow.raw_productions(before, :c)
    removed = Workflow.remove_component(template, :batch)

    for workflow <- [
          removed,
          Workflow.from_log(Workflow.build_log(removed)),
          Workflow.from_events(Workflow.build_log(removed))
        ] do
      assert component_edges(workflow) == [a: :c]
      assert [%{weight: 0}] = Multigraph.out_edges(workflow.graph, a, by: :flow)
      {completed, _} = Workflow.execute(workflow, 1)
      assert Workflow.raw_productions(completed, :c) == [[2]]
    end
  end

  test "forced inner FanIn skip keeps the accepted sibling's outer activation" do
    member = OrdinaryComponent.new(:member, :data)
    inner = Runic.batch(member, name: :inner)
    outer = Runic.batch(inner, name: :outer)

    workflow =
      Workflow.new()
      |> Workflow.add(outer)
      |> Workflow.enable_event_emission()
      |> Workflow.plan_eagerly([[1], [2]])
      |> apply_ready()
      |> apply_ready()
      |> apply_ready()

    {workflow, collectors} = Workflow.prepare_for_dispatch(workflow)
    good = Enum.find(collectors, &(&1.input_fact.value == 1))
    bad = Enum.find(collectors, &(&1.input_fact.value == 2))
    assert good.node.hash == inner.fan_in.hash

    assert Batch.item_scope(workflow, bad.node, bad.input_fact) ==
             elem(bad.input_fact.ancestry, 1)

    workflow = Workflow.apply_runnable(workflow, Workflow.execute_runnable(good))
    {workflow, before_skip} = Workflow.prepare_for_dispatch(workflow)
    sibling = Enum.find(before_skip, &(&1.node.hash == outer.fan_in.hash))
    assert sibling

    consumed = %Workflow.Events.ActivationConsumed{
      fact_hash: bad.input_fact.hash,
      node_hash: bad.node.hash,
      from_label: :runnable
    }

    skipped = %{bad | status: :skipped, error: :forced_collector_skip, events: [consumed]}
    workflow = Workflow.apply_runnable(workflow, skipped)
    {workflow, after_skip} = Workflow.prepare_for_dispatch(workflow)
    assert Enum.any?(after_skip, &(&1.id == sibling.id))

    refute Enum.any?(
             workflow.uncommitted_events,
             &match?(%Workflow.Events.ActivationSuppressed{}, &1)
           )

    [id] = Batch.invocations(workflow, outer)

    assert {:ok, [%{status: :completed}, %{status: :pending}]} =
             Batch.outcomes(workflow, outer, id)

    item_id = elem(bad.input_fact.ancestry, 1)
    item = workflow.graph.vertices[item_id]
    bad_metadata = %{item | meta: %{runic_batch: %{item_id: :wrong, source_fact_id: :wrong}}}

    bad_graph = %{
      workflow.graph
      | vertices: Map.put(workflow.graph.vertices, item_id, bad_metadata)
    }

    assert Batch.item_scope(%{workflow | graph: bad_graph}, bad.node, bad.input_fact) == nil

    assert Batch.item_scope(workflow, bad.node, %{
             bad.input_fact
             | ancestry: {outer.fan_in.hash, item_id}
           }) == nil
  end

  for mode <- [:lazy, :hybrid] do
    @tag mode: mode
    test "non-Batch #{mode} resume builds each component once", ctx do
      runner = :"batch_final_ctor_#{System.unique_integer([:positive])}"
      start_supervised!({Runner, name: runner})
      workflow = Workflow.new() |> Workflow.add(BatchFinalComponent.new(:plain))
      {:ok, _} = Runner.start_workflow(runner, :plain, workflow)
      :ok = Runner.stop(runner, :plain)
      Process.put({BatchFinalComponent, :constructor_observer}, self())

      try do
        assert {:ok, worker} = Runner.resume(runner, :plain, rehydration: ctx.mode)
        assert Process.alive?(worker)
        assert_receive {:constructed, :plain}
        refute_received {:constructed, :plain}
      after
        Process.delete({BatchFinalComponent, :constructor_observer})
      end
    end
  end

  test "native batch context is excluded from required keys and custom meta views" do
    step = Runic.step(fn value -> value + context(:batch).parent end, name: :step_member)
    workflow = Workflow.new() |> Workflow.add(Runic.batch(step, name: :step_batch))
    assert Workflow.required_context_keys(workflow) == %{}
    assert Workflow.validate_run_context(workflow, %{}) == :ok
    nonmember = Workflow.new() |> Workflow.add(step)
    assert Workflow.required_context_keys(nonmember) == %{step_member: [batch: :required]}

    refs = [
      %{kind: :context, target: :batch, context_key: :batch},
      %{kind: :context, target: :external, context_key: :external}
    ]

    custom = BatchFinalComponent.new(:custom, refs)

    workflow =
      Workflow.new()
      |> Workflow.add(Runic.batch(custom, name: :custom_batch))
      |> Workflow.put_run_context(%{
        _global: %{observer: self(), batch: :user_batch, external: 9}
      })

    assert Workflow.required_context_keys(workflow) == %{custom: [external: :required]}
    assert Workflow.validate_run_context(workflow, %{}) == {:error, %{custom: [:external]}}
    {_, _} = Workflow.execute(workflow, Batch.input([1], :parent))

    assert_receive {:custom_views,
                    %{
                      batch: %{parent: :parent},
                      meta: %{external: 9},
                      runtime: %{batch: :user_batch}
                    } = view}

    refute Map.has_key?(view.meta, :batch)
  end

  test "completed, pending and uncertain outcomes have nil activation and attempt fields" do
    batch = Runic.batch(OrdinaryComponent.new(:member, :data), name: :batch)
    template = Workflow.new() |> Workflow.add(batch)
    {completed, _} = Workflow.execute(template, [1])
    [id] = Batch.invocations(completed, batch)

    assert {:ok, [%{status: :completed, activation_id: nil, attempt_id: nil}]} =
             Batch.outcomes(completed, batch, id)

    pending = template |> Workflow.plan_eagerly([1]) |> apply_ready()
    [id] = Batch.invocations(pending, batch)

    assert {:ok, [%{status: :pending, activation_id: nil, attempt_id: nil}]} =
             Batch.outcomes(pending, batch, id)

    {pending, [member]} = Workflow.prepare_for_dispatch(pending)

    uncertain =
      Workflow.append_runnable_events(pending, [
        Workflow.ExecutionUncertain.new({:runnable, member}, :lost)
      ])

    assert {:ok, [%{status: :uncertain, activation_id: nil, attempt_id: nil}]} =
             Batch.outcomes(uncertain, batch, id)
  end

  test "merging a removed template with an active copy keeps the active member index" do
    batch = Runic.batch(OrdinaryComponent.new(:member, :data), name: :batch)
    active = Workflow.new() |> Workflow.add(batch)
    removed = Workflow.remove_component(active, :batch)
    merged = Workflow.merge(removed, active)
    assert Batch.present?(merged)
    assert Map.has_key?(merged.mapped.batch_members, batch.component.hash)
    assert Map.has_key?(merged.mapped.batch_members, batch.fan_in.hash)
    {completed, _} = Workflow.execute(merged, [1])
    [id] = Batch.invocations(completed, batch)
    assert {:ok, [%{value: 1}]} = Batch.outcomes(completed, batch, id)
  end

  defp component_edges(workflow),
    do:
      Workflow.component_graph(workflow)
      |> Multigraph.edges()
      |> Enum.map(&{&1.v1.name, &1.v2.name})

  defp apply_ready(workflow) do
    {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

    Enum.reduce(runnables, workflow, fn runnable, workflow ->
      Workflow.apply_runnable(workflow, Workflow.execute_runnable(runnable))
    end)
  end
end
