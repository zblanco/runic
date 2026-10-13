defmodule Runic.Workflow.BatchOpusTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true
  require Runic
  alias Runic.{Runner, Workflow}
  alias Runic.Workflow.{Batch, Fact, Invokable, SingleOutput}
  alias Runic.TestSupport.{BatchFailureComponent, OrdinaryComponent}

  for kind <- [:pid_exit, :key_error, :opaque, :reference, :function, :before_hook, :after_hook],
      policy <- [:skip, :halt],
      path <- [:immediate, :runner] do
    @tag kind: kind, policy: policy, path: path
    test "#{kind} terminal errors survive #{policy} through #{path} and replay", ctx do
      {server, monitor} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^monitor, :process, ^server, :normal}
      reference = make_ref()

      node =
        BatchFailureComponent.new(
          :member,
          if(ctx.kind in [:before_hook, :after_hook], do: :hook, else: ctx.kind)
        )

      batch = Runic.batch(node, name: :batch)

      workflow =
        Workflow.new()
        |> Workflow.add(batch)
        |> Workflow.enable_event_emission()
        |> Workflow.put_run_context(%{_global: %{server: server, reference: reference}})

      workflow =
        if ctx.kind in [:before_hook, :after_hook] do
          field = if ctx.kind == :before_hook, do: :before_hooks, else: :after_hooks

          Map.put(workflow, field, %{
            node.hash => [
              fn _, _ ->
                raise FunctionClauseError,
                  module: __MODULE__,
                  function: :hook,
                  arity: 1,
                  args: [self(), &Function.identity/1]
              end
            ]
          })
        else
          workflow
        end

      opts =
        if ctx.policy == :skip,
          do: [scheduler_policies: [{:member, %{on_failure: :skip}}]],
          else: []

      {completed, replayed} =
        if ctx.path == :immediate do
          {completed, execution} = Workflow.execute(workflow, [1], opts)
          assert execution.admission == if(ctx.policy == :skip, do: :open, else: :stopped)

          {completed,
           Workflow.from_events(
             Workflow.build_log(completed) ++ Enum.reverse(completed.uncommitted_events)
           )}
        else
          runner = runner()
          {:ok, worker} = Runner.start_workflow(runner, :errors, workflow)
          {:ok, id} = Runner.start_execution(runner, :errors, [1], opts)
          assert {:ok, execution} = Runner.await_execution(runner, :errors, id)
          assert execution.admission == if(ctx.policy == :skip, do: :open, else: :stopped)
          assert Process.alive?(worker)
          {:ok, completed} = Runner.get_workflow(runner, :errors)
          assert :ok = Runner.stop(runner, :errors)
          {:ok, recovered} = Runner.resume(runner, :errors)
          assert Process.alive?(recovered)
          {:ok, replayed} = Runner.get_workflow(runner, :errors)
          {completed, replayed}
        end

      [id] = Batch.invocations(completed, batch)
      assert {:ok, [outcome]} = Batch.outcomes(completed, batch, id)
      assert outcome.status == if(ctx.policy == :skip, do: :skipped, else: :failed)
      assert outcome.activation_id.domain == :activation
      assert outcome.attempt_id.domain == :attempt
      assert_error(ctx.kind, outcome.error, server, reference)
      assert {:ok, [^outcome]} = Batch.outcomes(replayed, batch, id)
    end
  end

  test "failure identity uses its occurrence while normal completed data stays strict" do
    activation = Runic.Identity.derive(:activation, [:failure])
    attempt = Runic.Identity.derive(:attempt, [activation, 0])

    outcome = %Batch.Outcome{
      id: activation,
      batch_id: activation,
      index: 0,
      status: :failed,
      activation_id: activation,
      attempt_id: attempt
    }

    for error <- [self(), make_ref(), fn -> :ok end, URI.parse("http://x")] do
      assert %Runic.Identity{} = Runic.Identity.project(:payload, %{outcome | error: error})

      assert_raise Runic.Identity.CanonicalError, fn ->
        Runic.Identity.project(:payload, %{outcome | status: :completed, value: error, error: nil})
      end
    end

    one = %{outcome | error: {:exit, self()}}
    two = %{outcome | error: {:exit, make_ref()}}
    assert Runic.Identity.project(:payload, one) == Runic.Identity.project(:payload, two)

    refute Runic.Identity.project(:payload, one) ==
             Runic.Identity.project(:payload, %{
               two
               | attempt_id: Runic.Identity.derive(:attempt, [activation, 1])
             })
  end

  test "removing a nested Batch removes the owned tree and permits add, execution and build replay" do
    inner = Runic.batch(OrdinaryComponent.new(:member, :data), name: :inner)
    outer = Runic.batch(inner, name: :outer)

    workflow =
      Workflow.new()
      |> Workflow.add(outer)
      |> Workflow.add(Runic.step(fn value -> value end, name: :consumer), to: :outer)

    assert_raise ArgumentError, ~r/remove owning Batch :outer/, fn ->
      Workflow.remove_component(workflow, :inner)
    end

    assert_raise ArgumentError, ~r/remove owning Batch :outer/, fn ->
      Workflow.remove_component(workflow, :member)
    end

    removed = Workflow.remove_component(workflow, :outer)
    refute Map.has_key?(removed.mapped, :batch_sources)
    refute Map.has_key?(removed.mapped, :batch_members)

    for name <- [
          :outer,
          :inner,
          :member,
          "outer.fan_out",
          "outer.fan_in",
          "inner.fan_out",
          "inner.fan_in"
        ] do
      assert Workflow.get_component(removed, name) == nil
    end

    reusable = removed |> Workflow.add(OrdinaryComponent.new(:other, :data))

    for base <- [
          reusable,
          Workflow.from_log(Workflow.build_log(reusable)),
          Workflow.from_events(Workflow.build_log(reusable))
        ] do
      {completed, _} = Workflow.execute(base, :value)
      assert Workflow.raw_productions(completed, :other) == [:value]
      assert Workflow.raw_productions(completed, :consumer) == [:value]
    end

    readded = Workflow.add(removed, inner)
    assert Map.has_key?(readded.mapped.batch_members, inner.component.hash)
    rebuilt = Workflow.from_log(Workflow.build_log(readded))
    assert rebuilt.mapped.batch_members == readded.mapped.batch_members
    standalone = Workflow.new() |> Workflow.add(inner) |> Workflow.remove_component(:inner)
    refute Batch.present?(standalone)
    assert Workflow.get_component(standalone, :member) == nil
  end

  test "removal preserves indexes for independent Batches and rejects owned internal removal" do
    one = Runic.batch(OrdinaryComponent.new(:one_member, :data), name: :one)
    two = Runic.batch(OrdinaryComponent.new(:two_member, :data), name: :two)

    merged =
      Workflow.merge(Workflow.new() |> Workflow.add(one), Workflow.new() |> Workflow.add(two))

    assert map_size(merged.mapped.batch_members) == 2

    assert_raise ArgumentError, ~r/remove owning Batch :one/, fn ->
      Workflow.remove_component(merged, {:one, :fan_out})
    end

    remaining = Workflow.remove_component(merged, :one)
    assert Map.keys(remaining.mapped.batch_members) == [two.component.hash]

    assert Workflow.from_log(Workflow.build_log(remaining)).mapped.batch_members ==
             remaining.mapped.batch_members

    {completed, _} = Workflow.execute(remaining, [1])
    [id] = Batch.invocations(completed, two)
    assert {:ok, [%{value: 1}]} = Batch.outcomes(completed, two, id)
  end

  test "unrelated preparation and item scope do not call FanOut ancestry lookup at depth 1500" do
    batch = Runic.batch(OrdinaryComponent.new(:member, :data), name: :batch)
    node = OrdinaryComponent.new(:unrelated, :data)
    workflow = Workflow.new() |> Workflow.add(batch) |> Workflow.add(node)

    for depth <- [10, 1500] do
      {workflow, fact} =
        Enum.reduce(1..depth, {workflow, Fact.new(value: 0)}, fn _, {workflow, parent} ->
          workflow = Workflow.log_fact(workflow, parent)
          {workflow, Fact.new(value: 0, ancestry: {node.hash, parent.hash})}
        end)

      assert count_origin_calls(fn ->
               {:ok, runnable} = Invokable.prepare(node, workflow, fact)
               assert runnable.context.batch == nil
               assert Batch.item_scope(workflow, node, fact) == nil
             end) == 0

      source = Fact.new(value: Batch.input([1], :parent), ancestry: {node.hash, fact.hash})
      member_workflow = workflow |> Workflow.log_fact(fact) |> Workflow.log_fact(source)
      item = Fact.new(value: 1, ancestry: {batch.fan_out.hash, source.hash})
      item = %{item | meta: Batch.item_metadata(batch.fan_out, source, 0, item.hash)}

      assert count_origin_calls(fn ->
               {:ok, member} = Invokable.prepare(batch.component, member_workflow, item)
               assert member.context.batch.parent == :parent
               assert Batch.item_scope(member_workflow, batch.component, item) == item.hash
             end) == 1
    end

    {prepared, _} =
      Workflow.new() |> Workflow.add(batch) |> Workflow.execute(Batch.input([], :parent))

    assert Map.has_key?(prepared.mapped.batch_members, batch.component.hash)
  end

  test "a large parent occurs once in prepared custom and Step views without replacing user runtime keys" do
    parent = Map.new(1..1000, &{&1, &1}) |> Map.put(:offset, 7)

    for member <- [
          OrdinaryComponent.new(:member, :data),
          Runic.step(fn value -> value + context(:batch).parent.offset end, name: :member)
        ] do
      batch = Runic.batch(member, name: :batch)

      workflow =
        Workflow.new()
        |> Workflow.add(batch)
        |> Workflow.put_run_context(%{_global: %{batch: :user_value}})
        |> Workflow.plan_eagerly(Batch.input([1], parent))
        |> Workflow.react()

      {_, [runnable]} = Workflow.prepare_for_dispatch(workflow)
      assert runnable.context.batch.parent == parent
      assert runnable.context.run_context.batch == :user_value
      refute Map.has_key?(runnable.context.meta_context, :batch)
      without_parent = %{runnable.context | batch: Map.put(runnable.context.batch, :parent, nil)}

      assert :erts_debug.flat_size(runnable.context) - :erts_debug.flat_size(without_parent) ==
               :erts_debug.flat_size(parent)

      context = SingleOutput.Context.from_runnable(runnable)
      assert context.batch.parent == parent
      assert context.runtime.batch == :user_value
      executed = Workflow.execute_runnable(runnable)
      assert executed.result.value == if(is_struct(member, Workflow.Step), do: 8, else: 1)
    end
  end

  test "nested parent is explicit and does not inherit the outer parent" do
    inner = Runic.batch(OrdinaryComponent.new(:member, :data), name: :inner)
    outer = Runic.batch(inner, name: :outer)

    workflow =
      Workflow.new()
      |> Workflow.add(outer)
      |> Workflow.put_run_context(%{_global: %{observer: self()}})

    {completed, _} =
      Workflow.execute(
        workflow,
        Batch.input([[1], Batch.input([2], :inner_parent)], :outer_parent)
      )

    assert_receive {:work, :member, %{batch: %{parent: nil}}}
    assert_receive {:work, :member, %{batch: %{parent: :inner_parent}}}
    [id] = Batch.invocations(completed, outer)

    assert {:ok, [%{value: %{parent: nil}}, %{value: %{parent: :inner_parent}}]} =
             Batch.outcomes(completed, outer, id)
  end

  for mode <- [:lazy, :hybrid], snapshot? <- [false, true] do
    @tag mode: mode, snapshot?: snapshot?
    test "Batch #{mode} resume rejects before Worker creation with snapshot #{snapshot?}", ctx do
      runner = runner(if(ctx.snapshot?, do: Runic.TestSupport.SnapshotTailStore, else: nil))
      _ = Runner.get_store(runner)

      workflow =
        Workflow.new()
        |> Workflow.add(Runic.batch(OrdinaryComponent.new(:member, :data), name: :batch))

      {:ok, _} = Runner.start_workflow(runner, :resume, workflow, executor: :inline)
      {:ok, id} = Runner.start_execution(runner, :resume, [])
      {:ok, _} = Runner.await_execution(runner, :resume, id)

      if ctx.snapshot? do
        {store, state} = Runner.get_store(runner)
        {:ok, saved} = Runner.get_workflow(runner, :resume)
        {:ok, %{event_cursor: cursor}} = Runner.persistence_status(runner, :resume)
        :ok = store.save_snapshot(:resume, cursor, Runner.encode_snapshot(saved), state)
      end

      :ok = Runner.stop(runner, :resume)

      assert {:error, {:unsupported_batch_rehydration, mode}} =
               Runner.resume(runner, :resume, rehydration: ctx.mode)

      assert mode == ctx.mode
      assert Runner.lookup(runner, :resume) == nil
    end
  end

  test "ordinary FanOut preserves enumeration exceptions while Batch contains its input failure" do
    fan_out = %Workflow.FanOut{
      hash: Runic.Identity.derive(:component_definition, [:fan_out]),
      name: :fan_out
    }

    workflow = Workflow.new() |> Workflow.add_step(fan_out)
    value = Stream.map([1], fn _ -> raise "enumeration failed" end)

    fact =
      Fact.new(
        hash: 100,
        payload_digest: Runic.Identity.derive(:payload, [:stream]),
        content_digest: Runic.Identity.derive(:fact_content, [:stream]),
        value: value
      )

    {:ok, runnable} = Invokable.prepare(fan_out, workflow, fact)

    assert_raise RuntimeError, "enumeration failed", fn ->
      Invokable.execute(fan_out, runnable)
    end

    batch = Runic.batch(OrdinaryComponent.new(:member, :data), name: :batch)
    workflow = Workflow.new() |> Workflow.add(batch)
    {:ok, runnable} = Invokable.prepare(batch.fan_out, workflow, Fact.new(value: :invalid))

    assert %{status: :failed, error: %ArgumentError{}} =
             Invokable.execute(batch.fan_out, runnable)
  end

  defp assert_error(
         :pid_exit,
         {:exit, {:noproc, {GenServer, :call, [server, :ping, 5000]}}},
         server,
         _
       ),
       do: :ok

  defp assert_error(:key_error, %KeyError{term: %{f: f}}, _, _), do: assert(is_function(f))
  defp assert_error(:opaque, %URI{}, _, _), do: :ok
  defp assert_error(:reference, {:ref_error, ref}, _, ref), do: :ok
  defp assert_error(:function, fun, _, _), do: assert(is_function(fun))

  defp assert_error(
         kind,
         {:hook_error, {:hook_exception, %FunctionClauseError{args: [pid, fun]}, _}},
         _,
         _
       )
       when kind in [:before_hook, :after_hook], do: assert(is_pid(pid) and is_function(fun))

  defp runner(store \\ nil) do
    name = :"batch_opus_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, [name: name] ++ if(store, do: [store: store], else: [])})
    name
  end

  defp count_origin_calls(fun) do
    parent = self()

    worker =
      spawn(fn ->
        receive do
          :run ->
            fun.()
            send(parent, :prepared)
            receive do: (:stop -> :ok)
        end
      end)

    :erlang.trace_pattern({Workflow.FanOut, :origin, 2}, true, [:local])
    :erlang.trace(worker, true, [:call, :arity, {:tracer, self()}])
    send(worker, :run)
    assert_receive :prepared, 3000
    delivered = :erlang.trace_delivered(worker)
    assert_receive {:trace_delivered, ^worker, ^delivered}, 3000
    :erlang.trace(worker, false, [:call])
    :erlang.trace_pattern({Workflow.FanOut, :origin, 2}, false, [:local])
    send(worker, :stop)
    drain_calls(worker, 0)
  end

  defp drain_calls(worker, count) do
    receive do
      {:trace, ^worker, :call, {Workflow.FanOut, :origin, 2}} -> drain_calls(worker, count + 1)
    after
      0 -> count
    end
  end
end
