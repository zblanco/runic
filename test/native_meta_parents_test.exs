defmodule Runic.NativeMetaParentsTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  require Runic
  alias Runic.{Runner, Workflow}
  alias Runic.Workflow.{Fact, Invokable, LocalBoundary, LocalFactError, Runnable}
  alias Runic.TestSupport.{NativeMetaNode, FailingStore, RemoteProfileExecutor}

  defp history(value) do
    acc = Runic.accumulator(0, fn x, _ -> x end, name: :source)
    wf = Workflow.new() |> Workflow.add(acc)
    wf = %{wf | graph: Multigraph.delete_edge(wf.graph, Workflow.root(), acc, :flow)}
    root = Fact.local(value)
    state = Fact.child(root, value: value, ancestry: {acc.hash, root.hash})

    {wf
     |> Workflow.log_fact(root)
     |> Workflow.log_fact(state)
     |> Workflow.draw_connection(acc, state, :state_produced, weight: 1), state}
  end

  defp reader(:step, :state_of), do: Runic.step(fn _ -> state_of(:source) end, name: :reader)

  defp reader(:step, :latest_value_of),
    do: Runic.step(fn _ -> latest_value_of(:source) end, name: :reader)

  defp reader(:step, :all_values_of),
    do: Runic.step(fn _ -> all_values_of(:source) end, name: :reader)

  defp reader(:single, kind), do: NativeMetaNode.new(kind)

  defp reader(:rule, :state_of) do
    Runic.rule name: :reader do
      given(value: _v)
      then(fn _ -> state_of(:source) end)
    end
  end

  defp reader(:rule, :latest_value_of) do
    Runic.rule name: :reader do
      given(value: _v)
      then(fn _ -> latest_value_of(:source) end)
    end
  end

  defp reader(:rule, :all_values_of) do
    Runic.rule name: :reader do
      given(value: _v)
      then(fn _ -> all_values_of(:source) end)
    end
  end

  defp reader_node(wf, %{reaction_hash: hash}), do: Map.fetch!(wf.graph.vertices, hash)
  defp reader_node(_, node), do: node

  defp add_reader(history, %Workflow.Step{} = step) do
    wf = Workflow.add(history, step)

    Enum.reduce(step.meta_refs, wf, fn ref, wf ->
      if ref.kind == :context,
        do: wf,
        else: Workflow.draw_meta_ref_edge(wf, step, Workflow.get_component!(wf, ref.target), ref)
    end)
  end

  defp add_reader(history, node), do: Workflow.add(history, node)

  defp outputs(wf, node),
    do:
      Enum.filter(
        Workflow.productions(wf),
        &match?({hash, _} when hash == node.hash, &1.ancestry)
      )

  for kind <- [:state_of, :latest_value_of, :all_values_of], type <- [:step, :rule, :single] do
    test "#{type} #{kind} retains native parents in caller-owned and persistent execution" do
      {history, source} = history(41)
      reader = reader(unquote(type), unquote(kind))
      wf = add_reader(history, reader)
      node = reader_node(wf, reader)
      {completed, execution} = Workflow.execute(wf, 7)
      assert execution.failures == []
      assert [output] = outputs(completed, node)
      assert output.identity_mode == :local
      assert output.local_scope == source.local_scope
      assert output.value == if(unquote(kind) == :all_values_of, do: [41], else: 41)
      assert {:error, %LocalFactError{}} = LocalBoundary.check(output, :output)

      backend = start_supervised!(FailingStore)
      runner = :"native_meta_store_#{System.unique_integer([:positive])}"
      start_supervised!({Runner, name: runner, store: FailingStore, store_opts: [agent: backend]})
      {:ok, worker} = Runner.start_workflow(runner, :reader, wf, owner: self())
      before = FailingStore.data(backend).calls
      {:ok, id} = Runner.start_execution(runner, :reader, 7)
      assert {:ok, result} = Runner.await_execution(runner, :reader, id)
      assert result.failures == []
      assert {:ok, completed} = Runner.get_workflow(runner, :reader)
      assert [output] = outputs(completed, node)
      assert output.identity_mode == :local
      assert output.local_scope == source.local_scope

      assert {:error, {:persistence_failed, %LocalFactError{}}} =
               Runner.checkpoint(runner, :reader)

      writes = Enum.drop(FailingStore.data(backend).calls, length(before))
      assert LocalBoundary.check(writes, :writes) == :ok

      refute Enum.any?(writes, fn
               {:save_fact, {hash, _}} -> hash == output.hash
               {:save_payload, {digest, _}} -> digest == output.payload_digest
               _ -> false
             end)

      assert Process.alive?(worker)
      assert :ok = Runner.cancel(runner, :reader)
    end

    test "#{type} #{kind} blocks remote dispatch for local source values" do
      {history, _} = history(self())
      reader = reader(unquote(type), unquote(kind))
      wf = add_reader(history, reader)
      node = reader_node(wf, reader)
      {:ok, prepared} = Invokable.prepare(node, wf, Fact.new(value: 7))
      assert prepared.context.meta_parents != []
      assert {:error, %LocalFactError{}} = Runnable.for_remote(prepared)

      # A Rule also has portable binding/condition work. Send only the reader
      # to the remote executor so those valid dispatches cannot hide this guard.
      hash = node.hash

      wf =
        Workflow.set_scheduler_policies(wf, [
          {fn candidate -> candidate.hash == hash end,
           %{executor: RemoteProfileExecutor, executor_opts: [observer: self()]}}
        ])

      runner = :"native_meta_remote_#{System.unique_integer([:positive])}"
      start_supervised!({Runner, name: runner})

      {:ok, worker} =
        Runner.start_workflow(runner, :reader, wf, owner: self(), persistence: :disabled)

      {:ok, id} = Runner.start_execution(runner, :reader, 7)
      assert {:ok, result} = Runner.await_execution(runner, :reader, id)
      assert [%{error: %LocalFactError{}}] = result.failures
      refute_received :remote_dispatch_called
      assert Process.alive?(worker)
    end

    test "#{type} #{kind} rejects incompatible meta scopes before hooks and callbacks" do
      {history, _} = history(41)
      reader = reader(unquote(type), unquote(kind))
      wf = add_reader(history, reader)
      node = reader_node(wf, reader)
      observer = self()

      wf = %{
        wf
        | before_hooks:
            Map.put(wf.before_hooks, node.hash, [
              fn _, _ ->
                send(observer, :meta_callback)
                :ok
              end
            ])
      }

      {_wf, result} = Workflow.execute(wf, 7, identity_mode: :local)
      assert [%{error: %ArgumentError{}}] = result.failures
      refute_received :meta_callback
    end
  end

  test "Rule where-read parents survive its portable binding and reaction" do
    {history, source} = history(41)

    rule =
      Runic.rule name: :reader do
        given(value: v)
        where(state_of(:source) > 0)
        then(fn %{value: v} -> v end)
      end

    wf = Workflow.add(history, rule)
    {completed, result} = Workflow.execute(wf, 7)
    assert result.failures == []
    assert [output] = outputs(completed, reader_node(wf, rule))
    assert output.value == 7
    assert output.identity_mode == :local
    assert output.local_scope == source.local_scope
  end

  test "run context and count getters do not become value parents" do
    {history, _} = history(41)
    step = Runic.step(fn _ -> context(:offset) + fact_count(:source) end, name: :reader)

    wf =
      history
      |> add_reader(step)
      |> Workflow.put_run_context(%{reader: %{offset: 2, observer: self()}})

    {:ok, runnable} = Invokable.prepare(step, wf, Fact.new(value: 7))
    assert runnable.context.meta_parents == []
    {completed, result} = Workflow.execute(wf, 7)
    assert result.failures == []
    assert [output] = outputs(completed, step)
    assert output.identity_mode == :portable
  end

  test "all-values checks every returned Fact but latest-value checks only the selected Fact" do
    {history, _} = history(41)
    source = Workflow.get_component!(history, :source)
    root = Fact.local(42)
    state = Fact.child(root, value: 42, ancestry: {source.hash, root.hash})

    history =
      history
      |> Workflow.log_fact(root)
      |> Workflow.log_fact(state)
      |> Workflow.draw_connection(source, state, :state_produced, weight: 2)

    {_wf, rejected} = Workflow.execute(add_reader(history, reader(:step, :all_values_of)), 7)
    assert [%{error: %ArgumentError{}}] = rejected.failures
    step = reader(:step, :latest_value_of)
    {wf, accepted} = Workflow.execute(add_reader(history, step), 7)
    assert accepted.failures == []
    assert [output] = outputs(wf, step)
    assert output.value in [41, 42]

    selected =
      Enum.find(Workflow.facts(history), &(&1.value == output.value and not is_nil(&1.ancestry)))

    assert output.local_scope == selected.local_scope
  end

  test "a single Runnable remote check includes its captured policy" do
    step = Runic.step(fn x -> x end, name: :portable)

    wf =
      Runic.workflow(steps: [step])
      |> Workflow.set_scheduler_policies([
        {:portable, %{retry_if: {__MODULE__, :retry_resource, [Fact.local(7)]}}}
      ])

    runner = :"native_policy_remote_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner})

    {:ok, _} =
      Runner.start_workflow(runner, :policy, wf,
        owner: self(),
        persistence: :disabled,
        executor: RemoteProfileExecutor,
        executor_opts: [observer: self()]
      )

    {:ok, id} = Runner.start_execution(runner, :policy, 7)
    assert {:ok, result} = Runner.await_execution(runner, :policy, id)
    assert [%{error: %LocalFactError{}}] = result.failures
    refute_received :remote_dispatch_called
  end
end
