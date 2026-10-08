defmodule Runic.Workflow.CompactDispatchTest do
  use ExUnit.Case, async: true

  alias Runic.Workflow
  alias Runic.Workflow.{Activator, Fact, FanIn, FanOut, Invokable, Runnable}
  alias Runic.Workflow.Events.RunnableActivated
  alias Runic.Test.DispatchProbe
  require Runic

  test "mapped FanIn context has constant flat size across batch cardinalities" do
    sizes =
      for n <- [8, 32, 128] do
        workflow = ready_batch(Enum.to_list(1..n))
        {_, runnables} = Workflow.prepare_for_dispatch(workflow)
        assert length(runnables) == n

        for runnable <- runnables do
          assert %FanIn{} = runnable.node

          assert Map.keys(runnable.context.fan_in_context) |> Enum.sort() ==
                   [:expected_key, :fan_out_hash, :mode, :seen_key, :source_fact_hash]
        end

        runnables
        |> hd()
        |> Map.fetch!(:context)
        |> Map.fetch!(:fan_in_context)
        |> :erts_debug.flat_size()
      end

    assert Enum.uniq(sizes) |> length() == 1
  end

  test "limited preparation invokes only the selected contexts and excludes in-flight work" do
    workflow = probe_workflow(100)
    descriptors = Workflow.activation_descriptors(workflow)
    assert Enumerable.impl_for(descriptors) != nil
    refute_received {:prepared, _, _}

    selected = Enum.take(descriptors, 3)
    {unchanged, runnables} = Workflow.prepare_for_dispatch(workflow, limit: 3)
    assert unchanged == workflow
    assert length(runnables) == 3

    for descriptor <- selected do
      assert_received {:prepared, hash, :probes}
      assert hash == descriptor.node_hash
    end

    refute_received {:prepared, _, _}
    assert Enum.count(Workflow.activation_descriptors(unchanged)) == 100

    excluded = MapSet.new(selected, & &1.node_hash)

    {_, next} =
      Workflow.prepare_for_dispatch(workflow,
        limit: 2,
        exclude: &MapSet.member?(excluded, &1.node_hash)
      )

    assert length(next) == 2
    refute Enum.any?(next, &MapSet.member?(excluded, &1.node.hash))
    assert_received {:prepared, _, _}
    assert_received {:prepared, _, _}
    refute_received {:prepared, _, _}
  end

  test "lean replay FactRef owners remain visible to descriptor selection" do
    workflow = probe_workflow(1)
    [descriptor] = Enum.to_list(Workflow.activation_descriptors(workflow))
    fact = Map.fetch!(workflow.graph.vertices, descriptor.fact_hash)
    ref = struct(Runic.Workflow.FactRef, Map.from_struct(fact))
    graph = %{workflow.graph | vertices: Map.put(workflow.graph.vertices, fact.hash, ref)}
    workflow = %{workflow | graph: graph}

    assert [descriptor] == Enum.to_list(Workflow.activation_descriptors(workflow))
    assert {^workflow, []} = Workflow.prepare_for_dispatch(workflow, limit: 0)
  end

  test "zero and excluded prefixes perform no preparation; option validation is explicit" do
    workflow = probe_workflow(4)
    assert {^workflow, []} = Workflow.prepare_for_dispatch(workflow, limit: 0)
    assert {^workflow, []} = Workflow.prepare_for_dispatch(workflow, exclude: fn _ -> true end)
    refute_received {:prepared, _, _}
    assert_raise ArgumentError, fn -> Workflow.prepare_for_dispatch(workflow, limit: -1) end
    assert_raise ArgumentError, fn -> Workflow.prepare_for_dispatch(workflow, exclude: :bad) end
    assert_raise ArgumentError, fn -> Workflow.prepare_for_dispatch(workflow, typo: 1) end
  end

  test "skip and defer consume the limit and fold their reducers into subsequent preparation" do
    for mode <- [:skip, :defer] do
      workflow = probe_workflow(3, mode)
      {updated, []} = Workflow.prepare_for_dispatch(workflow, limit: 1)
      assert updated.name == mode
      assert Enum.count(Workflow.activation_descriptors(updated)) == 2
      assert_received {:prepared, _, :probes}
      refute_received {:prepared, _, _}
      {drained, []} = Workflow.prepare_for_dispatch(updated, limit: 2)
      assert Enum.empty?(Workflow.activation_descriptors(drained))
      assert_received {:prepared, _, ^mode}
      assert_received {:prepared, _, ^mode}
      refute_received {:prepared, _, _}
    end
  end

  test "empty options preserve the eager default including its order" do
    workflow = ready_batch([2, 2, 1, 3])
    assert Workflow.prepare_for_dispatch(workflow) == Workflow.prepare_for_dispatch(workflow, [])

    expected =
      Multigraph.edges(workflow.graph, by: [:runnable, :matchable])
      |> MapSet.new(&{&1.v1.hash, &1.v2.hash, &1.label})

    actual =
      Workflow.activation_descriptors(workflow)
      |> MapSet.new(&{&1.fact_hash, &1.node_hash, &1.activation_kind})

    assert expected == actual
  end

  test "bounded pulls preserve source ordering, duplicate occurrences, and completed graph" do
    workflow = ready_batch([3, 1, 3, 2, 1])
    eager = drain(workflow, :eager)
    bounded = drain(workflow, 2)
    assert Workflow.raw_productions(bounded) == Workflow.raw_productions(eager)
    assert [1, 2, 3, 1, 3] in Workflow.raw_productions(bounded)
    assert bounded.mapped == eager.mapped
    assert bounded.graph == eager.graph
  end

  test "a compact context prepared before the last arrival finalizes from current state" do
    map = Runic.map(fn x -> x end, name: :identity)
    reduce = Runic.reduce([], fn x, acc -> [x | acc] end, name: :collect, map: :identity)

    workflow =
      Workflow.new()
      |> Workflow.add(map)
      |> Workflow.add(reduce, to: :identity)
      |> Workflow.plan_eagerly([1, 2, 1])
      |> Workflow.react()

    {workflow, [first | remaining]} = Workflow.prepare_for_dispatch(workflow)
    workflow = Workflow.apply_runnable(workflow, Invokable.execute(first.node, first))

    {_, candidates} = Workflow.prepare_for_dispatch(workflow)
    early = Enum.find(candidates, &match?(%FanIn{}, &1.node))
    assert early != nil

    workflow =
      Enum.reduce(remaining, workflow, fn runnable, wf ->
        Workflow.apply_runnable(wf, Invokable.execute(runnable.node, runnable))
      end)

    completed = Workflow.apply_runnable(workflow, Invokable.execute(early.node, early))
    assert [1, 2, 1] in Workflow.raw_productions(completed)
    assert Enum.empty?(Workflow.activation_descriptors(completed))

    duplicate = Workflow.apply_runnable(completed, Invokable.execute(early.node, early))
    assert Workflow.raw_productions(duplicate) == Workflow.raw_productions(completed)
    assert duplicate.graph == completed.graph
  end

  test "bounded traversal includes rule matchable edges and newly composed steps" do
    rule = Runic.rule(fn x when is_integer(x) and x > 0 -> x * 2 end, name: :positive)
    workflow = Workflow.new() |> Workflow.add(rule) |> Workflow.plan(3)
    descriptors = Enum.to_list(Workflow.activation_descriptors(workflow))
    assert Enum.any?(descriptors, &(&1.activation_kind == :matchable))

    assert Workflow.raw_productions(drain(workflow, 1)) ==
             Workflow.raw_productions(drain(workflow, :eager))

    step = Runic.step(fn x -> x + 1 end, name: :later)
    changed = workflow |> Workflow.add(step) |> Workflow.plan(4)
    assert Enum.any?(Workflow.activation_descriptors(changed), &(&1.node_hash == step.hash))

    assert Workflow.raw_productions(drain(changed, 1)) ==
             Workflow.raw_productions(drain(changed, :eager))
  end

  test "FanOut activation events preserve fact and downstream order" do
    fan_out = %FanOut{hash: :fanout}
    a = Runic.step(fn x -> x end, name: :a)
    b = Runic.step(fn x -> x + 1 end, name: :b)
    facts = Enum.map(1..20, &Fact.new(value: &1))

    workflow = Workflow.new()

    graph =
      workflow.graph
      |> Multigraph.add_edge(fan_out, a, label: :flow)
      |> Multigraph.add_edge(fan_out, b, label: :flow)

    workflow = %{workflow | graph: graph}
    {_, events} = Activator.activate_downstream(fan_out, workflow, %Runnable{result: facts})

    expected =
      for fact <- facts, node <- Workflow.next_steps(workflow, fan_out) do
        %RunnableActivated{fact_hash: fact.hash, node_hash: node.hash, activation_kind: :runnable}
      end

    assert events == expected
  end

  defp ready_batch(values) do
    map = Runic.map(fn x -> x end, name: :identity)
    reduce = Runic.reduce([], fn x, acc -> [x | acc] end, name: :collect, map: :identity)

    Workflow.new()
    |> Workflow.add(map)
    |> Workflow.add(reduce, to: :identity)
    |> Workflow.plan_eagerly(values)
    |> Workflow.react()
    |> Workflow.react()
  end

  defp probe_workflow(n, mode \\ :ok) do
    workflow = Workflow.new(name: :probes)
    fact = Fact.new(value: :input)

    graph =
      Enum.reduce(1..n, workflow.graph, fn index, graph ->
        node = %DispatchProbe{hash: index, owner: self(), mode: mode}
        Multigraph.add_edge(graph, fact, node, label: :runnable)
      end)

    %{workflow | graph: graph}
  end

  defp drain(workflow, limit) do
    if Enum.empty?(Workflow.activation_descriptors(workflow)) do
      workflow
    else
      {workflow, prepared} =
        case limit do
          :eager -> Workflow.prepare_for_dispatch(workflow)
          limit -> Workflow.prepare_for_dispatch(workflow, limit: limit)
        end

      prepared
      |> Enum.reduce(workflow, fn runnable, wf ->
        Workflow.apply_runnable(wf, Invokable.execute(runnable.node, runnable))
      end)
      |> drain(limit)
    end
  end
end
