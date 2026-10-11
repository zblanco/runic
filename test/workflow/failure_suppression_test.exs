defmodule Runic.Workflow.FailureSuppressionTest do
  use ExUnit.Case, async: true

  require Runic

  alias Runic.Runner.Store.ETS
  alias Runic.Workflow

  alias Runic.Workflow.{
    Fact,
    FactRef,
    FactResolver,
    Invokable,
    Join,
    PolicyDriver,
    SchedulerPolicy
  }

  alias Runic.Workflow.Events.{ActivationConsumed, FactProduced, Serializer}

  @moduletag capture_log: true

  test "failed input suppression survives replay without removing another input's work" do
    %{base: base, ready: ready, failed: failed} = fixture = join_fixture()

    live = Workflow.apply_runnable(ready, failed)
    assert_suppressed(fixture, live)

    events = Enum.reverse(live.uncommitted_events)
    assert {:ok, persisted_events} = events |> Serializer.to_binary() |> Serializer.from_binary()
    replayed = Workflow.from_events(persisted_events, base)
    assert edge_labels(replayed) == edge_labels(live)

    failure_events = Enum.drop(events, length(ready.uncommitted_events))
    assert [%ActivationConsumed{} = consumed | suppressed] = failure_events
    assert consumed.fact_hash == failed.input_fact.hash
    assert consumed.node_hash == failed.node.hash

    assert MapSet.new(suppressed, &{&1.__struct__, &1.fact_hash, &1.node_hash, &1.from_label}) ==
             MapSet.new([
               {Runic.Workflow.Events.ActivationSuppressed, fixture.bad_b.hash, fixture.join.hash,
                :joined},
               {Runic.Workflow.Events.ActivationSuppressed, fixture.bad_c.hash, fixture.join.hash,
                :runnable}
             ])

    replayed_again = Enum.reduce(failure_events, replayed, &Workflow.apply_event(&2, &1))
    assert edge_labels(replayed_again) == edge_labels(replayed)

    for workflow <- [live, replayed] do
      completed = Workflow.react_until_satisfied(workflow)
      refute Workflow.is_runnable?(completed)

      assert Workflow.raw_productions(completed, :combine) ==
               [{{:a, :good}, {:b, :good}, {:c, :good}}]
    end
  end

  test "failure suppresses the same input when event emission is disabled" do
    %{ready: ready, failed: failed} = fixture = join_fixture()
    ready = Workflow.disable_event_emission(ready)

    live = Workflow.apply_runnable(ready, failed)
    assert_suppressed(fixture, live)
    assert live.uncommitted_events == ready.uncommitted_events
  end

  for fact_mode <- [:full, :ref] do
    test "failure isolates handoff inputs with a shared external parent in #{fact_mode} replay" do
      upstream =
        Workflow.new()
        |> Workflow.add(Runic.step(fn _ -> :bad end, name: :bad_source))
        |> Workflow.add(Runic.step(fn _ -> :good end, name: :good_source))
        |> Workflow.react_until_satisfied(:source_input)

      [bad] = Workflow.productions(upstream, :bad_source)
      [good] = Workflow.productions(upstream, :good_source)
      assert {_, parent_hash} = bad.ancestry
      assert {_, ^parent_hash} = good.ancestry
      refute bad.hash == good.hash

      %{base: base, ready: ready, failed: failed} =
        fixture = join_fixture(%{bad: bad, good: good})

      refute Map.has_key?(ready.graph.vertices, parent_hash)
      assert Workflow.root_ancestor_hash(ready, bad) == nil

      full_events = Enum.reverse(ready.uncommitted_events)
      events = if unquote(fact_mode) == :ref, do: strip_values(full_events), else: full_events
      recovered = Workflow.from_events(events, base, fact_mode: unquote(fact_mode))

      input = Map.fetch!(recovered.graph.vertices, bad.hash)
      assert {:ok, runnable} = Invokable.prepare(failed.node, recovered, input)
      failed = Invokable.execute(runnable.node, runnable)
      assert failed.status == :failed
      live = Workflow.apply_runnable(recovered, failed)
      assert_suppressed(fixture, live)

      failure_events = Enum.reverse(live.uncommitted_events)

      replayed =
        Workflow.from_events(events ++ failure_events, base, fact_mode: unquote(fact_mode))

      assert edge_labels(replayed) == edge_labels(live)

      completed =
        (full_events ++ failure_events)
        |> Workflow.from_events(base)
        |> Workflow.react_until_satisfied()

      refute Workflow.is_runnable?(completed)

      assert Workflow.raw_productions(completed, :combine) == [
               {{:a, :good}, {:b, :good}, {:c, :good}}
             ]
    end
  end

  for mode <- [:public, :skipped] do
    test "#{mode} downstream suppression survives replay" do
      %{base: base, ready: ready, failed: failed} = fixture = join_fixture()

      live =
        case unquote(mode) do
          :public ->
            Workflow.skip_downstream_subgraph(ready, failed.node)

          :skipped ->
            skipped =
              ready
              |> find_runnable(failed.node, :bad)
              |> PolicyDriver.execute(SchedulerPolicy.io_policy(max_retries: 0))

            assert skipped.status == :skipped
            Workflow.apply_runnable(ready, skipped)
        end

      if unquote(mode) == :public do
        assert join_labels(live, fixture.join) == %{
                 fixture.bad_b.hash => :upstream_failed,
                 fixture.bad_c.hash => :upstream_failed,
                 fixture.good_c.hash => :upstream_failed
               }
      else
        assert_suppressed(fixture, live)
      end

      events = Enum.reverse(live.uncommitted_events)
      new_events = Enum.drop(events, length(ready.uncommitted_events))

      suppressed =
        case unquote(mode) do
          :public ->
            new_events

          :skipped ->
            assert [%ActivationConsumed{} | suppressed] = new_events
            suppressed
        end

      assert length(suppressed) == if(unquote(mode) == :public, do: 3, else: 2)
      assert Enum.all?(suppressed, &is_struct(&1, Runic.Workflow.Events.ActivationSuppressed))
      replayed = Workflow.from_events(events, base)
      assert edge_labels(replayed) == edge_labels(live)
    end
  end

  test "I/O policy skip preserves another input's ready child in live state and replay" do
    a =
      Runic.step(
        fn
          :bad -> raise "failed input"
          input -> input
        end,
        name: :a
      )

    b = Runic.step(fn input -> {:b, input} end, name: :b)
    base = Runic.workflow(steps: [{a, [b]}]) |> Workflow.enable_event_emission()
    ready = base |> Workflow.react(:good) |> Workflow.plan_eagerly(:bad)

    skipped =
      ready
      |> find_runnable(a, :bad)
      |> PolicyDriver.execute(SchedulerPolicy.io_policy(max_retries: 0))

    assert skipped.status == :skipped
    live = Workflow.apply_runnable(ready, skipped)
    replayed = Workflow.from_events(Enum.reverse(live.uncommitted_events), base)
    assert edge_labels(replayed) == edge_labels(live)

    for workflow <- [live, replayed] do
      assert [%{node: %{name: :b}, input_fact: %{value: :good}}] =
               Workflow.prepared_runnables(workflow)

      completed = Workflow.react_until_satisfied(workflow)
      refute Workflow.is_runnable?(completed)
      assert Workflow.raw_productions(completed, :b) == [{:b, :good}]
    end
  end

  test "lazy recovery suppresses matching FactRef edges and preserves an unrelated input" do
    %{base: base, ready: ready, failed: failed} = fixture = join_fixture()
    {store_mod, store_state} = store = setup_store()
    :ok = store_mod.save_fact(failed.input_fact.hash, failed.input_fact.value, store_state)

    stored_events = ready.uncommitted_events |> Enum.reverse() |> strip_values()
    recovered = Workflow.from_events(stored_events, base, fact_mode: :ref)
    input_ref = Map.fetch!(recovered.graph.vertices, failed.input_fact.hash)
    assert %FactRef{} = input_ref
    assert {:ok, %Fact{} = input} = FactResolver.resolve(input_ref, FactResolver.new(store))
    assert {:ok, runnable} = Invokable.prepare(failed.node, recovered, input)

    for fact <- [fixture.bad_b, fixture.bad_c, fixture.good_c] do
      assert %FactRef{} = Map.fetch!(recovered.graph.vertices, fact.hash)
    end

    live = Workflow.apply_runnable(recovered, Invokable.execute(runnable.node, runnable))
    assert_suppressed(fixture, live)

    replayed =
      Workflow.from_events(stored_events ++ Enum.reverse(live.uncommitted_events), base,
        fact_mode: :ref
      )

    assert edge_labels(replayed) == edge_labels(live)
  end

  test "failure with an unresolved FactRef input consumes its activation" do
    step = Runic.step(fn input -> input + 1 end, name: :step)
    base = Workflow.new() |> Workflow.add(step) |> Workflow.enable_event_emission()
    ready = Workflow.plan_eagerly(base, 1)
    events = ready.uncommitted_events |> Enum.reverse() |> strip_values()
    recovered = Workflow.from_events(events, base, fact_mode: :ref)

    assert [%{input_fact: %FactRef{}} = runnable] = Workflow.prepared_runnables(recovered)
    failed = Invokable.execute(runnable.node, runnable)
    assert failed.status == :failed

    live = Workflow.apply_runnable(recovered, failed)
    refute Workflow.is_runnable?(live)
    assert Enum.to_list(Workflow.activation_descriptors(live)) == []

    replayed =
      Workflow.from_events(events ++ Enum.reverse(live.uncommitted_events), base, fact_mode: :ref)

    refute Workflow.is_runnable?(replayed)
  end

  defp join_fixture(inputs \\ %{bad: :bad, good: :good}) do
    a =
      Runic.step(
        fn
          :bad -> raise "failed branch"
          input -> {:a, input}
        end,
        name: :a
      )

    b = Runic.step(fn input -> {:b, input} end, name: :b)
    c = Runic.step(fn input -> {:c, input} end, name: :c)
    combine = Runic.step(fn a, b, c -> {a, b, c} end, name: :combine)

    base =
      Workflow.new()
      |> Workflow.add(a)
      |> Workflow.add(b)
      |> Workflow.add(c)
      |> Workflow.add(combine, to: [:a, :b, :c])
      |> Workflow.enable_event_emission()

    [%Join{} = join] = Workflow.next_steps(base, a)

    ready =
      base
      |> Workflow.plan_eagerly(inputs.bad)
      |> execute(b, :bad)
      |> execute(c, :bad)
      |> execute(join, {:b, :bad})
      |> Workflow.plan_eagerly(inputs.good)
      |> execute(c, :good)

    failed = ready |> find_runnable(a, :bad) |> then(&Invokable.execute(a, &1))
    [bad_b] = Workflow.productions(ready, :b)
    c_facts = Workflow.productions(ready, :c)
    bad_c = Enum.find(c_facts, &(&1.value == {:c, :bad}))
    good_c = Enum.find(c_facts, &(&1.value == {:c, :good}))

    assert join_labels(ready, join) == %{
             bad_b.hash => :joined,
             bad_c.hash => :runnable,
             good_c.hash => :runnable
           }

    %{
      base: base,
      ready: ready,
      failed: failed,
      join: join,
      bad_b: bad_b,
      bad_c: bad_c,
      good_c: good_c
    }
  end

  defp find_runnable(workflow, node, value) do
    runnable =
      workflow
      |> Workflow.prepared_runnables()
      |> Enum.find(&(&1.node.hash == node.hash and &1.input_fact.value == value))

    assert runnable
    runnable
  end

  defp execute(workflow, node, value) do
    runnable = find_runnable(workflow, node, value)
    Workflow.apply_runnable(workflow, Invokable.execute(node, runnable))
  end

  defp assert_suppressed(fixture, workflow) do
    assert join_labels(workflow, fixture.join) == %{
             fixture.bad_b.hash => :upstream_failed,
             fixture.bad_c.hash => :upstream_failed,
             fixture.good_c.hash => :runnable
           }

    refute Enum.any?(Workflow.activation_descriptors(workflow), fn activation ->
             activation.fact_hash == fixture.failed.input_fact.hash and
               activation.node_hash == fixture.failed.node.hash
           end)
  end

  defp join_labels(workflow, join) do
    workflow.graph
    |> Multigraph.in_edges(join)
    |> Enum.filter(&(&1.label in [:runnable, :joined, :upstream_failed]))
    |> Map.new(&{&1.v1.hash, &1.label})
  end

  defp edge_labels(%Workflow{graph: graph}) do
    MapSet.new(Multigraph.edges(graph), fn edge ->
      {graph.vertex_identifier.(edge.v1), graph.vertex_identifier.(edge.v2), edge.label}
    end)
  end

  defp strip_values(events) do
    Enum.map(events, fn
      %FactProduced{} = event -> %{event | value: nil}
      event -> event
    end)
  end

  defp setup_store do
    runner_name = :"failure_suppression_#{System.unique_integer([:positive])}"
    start_supervised!({ETS, runner_name: runner_name})
    {:ok, store_state} = ETS.init_store(runner_name: runner_name)
    {ETS, store_state}
  end
end
