defmodule Runic.NativeScopeAcceptanceTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  require Runic
  alias Runic.{Runner, Workflow}

  alias Runic.Workflow.{
    Fact,
    Invokable,
    Join,
    LocalBoundary,
    LocalFactError,
    LocalScope,
    RunnableFailed,
    RunnableDispatched,
    PolicyDriver,
    SchedulerPolicy
  }

  alias Runic.TestSupport.RemoteProfileExecutor

  defp join_definition do
    a = Runic.step(fn x -> x end, name: :a)
    b = Runic.step(fn x -> x end, name: :b)
    result = Runic.step(fn a, b -> [a, b] end, name: :result)
    wf = Runic.workflow(steps: [a, b, {[a, b], [result]}])
    {wf, Enum.find(Multigraph.vertices(wf.graph), &is_struct(&1, Join)), a, b}
  end

  for reverse <- [false, true] do
    test "direct Join preserves a local parent with portable arrival order #{reverse}" do
      {wf, join, a, b} = join_definition()
      local = Fact.local(:x)
      portable = Fact.new(value: :y)
      x = Fact.child(local, value: :x, ancestry: {a.hash, local.hash})
      y = Fact.child(portable, value: :y, ancestry: {b.hash, portable.hash})
      wf = wf |> Workflow.log_fact(x) |> Workflow.log_fact(y)
      arrivals = if unquote(reverse), do: [y, x], else: [x, y]
      completed = Enum.reduce(arrivals, wf, &Invokable.invoke(join, &2, &1))
      [output] = Workflow.productions(completed)
      assert output.value == [:x, :y]
      assert output.identity_mode == :local
      assert output.local_scope == local.local_scope
      assert {:error, %LocalFactError{}} = LocalBoundary.check(output, :output)
    end
  end

  test "caller-owned acceptance records a mixed-scope Join failure and runs no deferred hooks" do
    {wf, join, a, b} = join_definition()
    xroot = Fact.local(:x)
    yroot = Fact.local(:y)
    x = Fact.child(xroot, value: :x, ancestry: {a.hash, xroot.hash})
    y = Fact.child(yroot, value: :y, ancestry: {b.hash, yroot.hash})
    wf = wf |> Workflow.log_fact(x) |> Workflow.log_fact(y) |> Workflow.enable_event_emission()
    wf = Invokable.invoke(join, wf, x)
    {:ok, prepared} = Invokable.prepare(join, wf, y)

    {executed, lifecycle} =
      PolicyDriver.execute(prepared, SchedulerPolicy.default_policy(), emit_events: true)

    observer = self()

    executed = %{
      executed
      | hook_apply_fns: [
          fn workflow ->
            send(observer, :scope_hook)
            workflow
          end
        ]
    }

    {wf, accepted, events} = Workflow.accept_runnable(wf, executed, lifecycle)
    assert accepted.status == :failed
    assert %ArgumentError{} = accepted.error
    assert [%RunnableDispatched{}, %RunnableFailed{failure_action: :halt}] = events
    assert Workflow.productions(wf) == []
    refute_received :scope_hook
    assert %Workflow{} = Workflow.apply_runnable(wf, executed)
  end

  test "direct Join rejects different local scopes in either arrival order" do
    for reverse <- [false, true] do
      {wf, join, a, b} = join_definition()
      xroot = Fact.local(:x)
      yroot = Fact.local(:y)
      x = Fact.child(xroot, value: :x, ancestry: {a.hash, xroot.hash})
      y = Fact.child(yroot, value: :y, ancestry: {b.hash, yroot.hash})
      wf = wf |> Workflow.log_fact(x) |> Workflow.log_fact(y)
      arrivals = if reverse, do: [y, x], else: [x, y]
      rejected = Enum.reduce(arrivals, wf, &Invokable.invoke(join, &2, &1))
      assert Workflow.productions(rejected) == []
      assert Enum.any?(rejected.runnable_events, &is_struct(&1, RunnableFailed))
    end
  end

  test "overlapping native Runner inputs fail Join acceptance without stopping the Worker" do
    observer = self()

    a =
      Runic.step(
        fn input ->
          if input.n == 2 do
            send(input.reply, {:held, :a2, self()})
            receive do: (:release -> :ok)
          end

          {:a, input.n}
        end,
        name: :a
      )

    b =
      Runic.step(
        fn input ->
          if input.n == 1 do
            send(input.reply, {:held, :b1, self()})
            receive do: (:release -> :ok)
          end

          {:b, input.n}
        end,
        name: :b
      )

    result = Runic.step(fn a, b -> {a, b} end, name: :result)
    wf = Runic.workflow(steps: [a, b, {[a, b], [result]}])
    runner = :"native_overlap_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner})

    {:ok, worker} =
      Runner.start_workflow(runner, :local, wf,
        owner: observer,
        persistence: :disabled,
        hooks: [
          on_complete: fn executed, _, _ ->
            if executed.node.name == :a and executed.input_fact.value.n == 1,
              do: send(observer, :a1_accepted)
          end,
          on_failed: fn executed, error, _ ->
            if is_struct(executed.node, Join), do: send(observer, {:join_rejected, error})
          end
        ]
      )

    ref = Process.monitor(worker)
    assert :ok = Runner.run(runner, :local, %{n: 1, reply: observer}, identity_mode: :local)
    assert_receive {:held, :b1, _}, 1_000
    assert_receive :a1_accepted, 1_000
    assert :ok = Runner.run(runner, :local, %{n: 2, reply: observer}, identity_mode: :local)
    assert_receive {:held, :a2, _}, 1_000
    assert_receive {:join_rejected, %ArgumentError{}}, 1_000
    assert Process.alive?(worker)
    assert {:error, :admission_stopped} = Runner.start_execution(runner, :local, 7)
    refute_received {:DOWN, ^ref, :process, ^worker, _}
    assert :ok = Runner.cancel(runner, :local)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 1_000
  end

  test "direct accumulator rejects scopes before calling its reducer" do
    observer = self()

    acc =
      Runic.accumulator(
        [],
        fn value, state ->
          send(observer, :state_reducer)
          [value | state]
        end,
        name: :history
      )

    wf = Workflow.new() |> Workflow.add(acc)
    wf = Invokable.invoke(acc, wf, Fact.local(1))
    assert_receive :state_reducer
    before = Workflow.productions(wf, :history)
    rejected = Invokable.invoke(acc, wf, Fact.local(2))
    refute_received :state_reducer
    assert Workflow.productions(rejected, :history) == before
    {:ok, prepared} = Invokable.prepare(acc, wf, Fact.local(3))
    executed = Invokable.execute(acc, prepared)
    assert executed.status == :failed
    assert %ArgumentError{} = executed.error
    refute_received :state_reducer
  end

  for scheduler <- [Runic.Runner.Scheduler.ChainBatching, Runic.Runner.Scheduler.FlowBatch] do
    test "#{scheduler} rejects a portable Promise with local workflow history" do
      a = Runic.step(fn x -> x end, name: :a)
      b = Runic.step(fn x -> x end, name: :b)

      definition =
        if unquote(scheduler == Runic.Runner.Scheduler.FlowBatch),
          do: Runic.workflow(steps: [a, b]),
          else: Runic.workflow(steps: [{a, [b]}])

      {history, _} = Workflow.execute(definition, self(), identity_mode: :local)
      runner = :"native_remote_history_#{System.unique_integer([:positive])}"
      start_supervised!({Runner, name: runner})

      {:ok, _} =
        Runner.start_workflow(runner, :remote, history,
          owner: self(),
          persistence: :disabled,
          scheduler: unquote(scheduler),
          scheduler_opts: [min_chain_length: 2, min_batch_size: 2],
          executor: RemoteProfileExecutor,
          executor_opts: [observer: self()]
        )

      {:ok, id} = Runner.start_execution(runner, :remote, 7)
      assert {:ok, rejected} = Runner.await_execution(runner, :remote, id)
      assert rejected.failures != []
      assert Enum.all?(rejected.failures, &match?(%LocalFactError{}, &1.error))
      refute_received :remote_dispatch_called
    end
  end

  test "malformed local input admission leaves the Worker alive" do
    runner = :"native_bad_admission_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner})
    wf = Runic.workflow(steps: [Runic.step(fn x -> x end)])

    {:ok, worker} =
      Runner.start_workflow(runner, :local, wf, owner: self(), persistence: :disabled)

    fact = Fact.local(7)
    invalid = %{fact | local_scope: nil}

    assert {:error, %LocalFactError{reason: :missing_local_scope}} =
             Runner.run(runner, :local, invalid)

    assert {:error, %ArgumentError{}} =
             Runner.start_execution(runner, :local, 7,
               identity_mode: :local,
               local_scope: %LocalScope{vm: <<0::256>>, token: make_ref()}
             )

    assert Process.alive?(worker)
  end

  test "direct and prepared FanIn reject conflicting sister scopes before reducer or hooks" do
    observer = self()

    fan_out = %Workflow.FanOut{
      hash: Runic.Identity.digest(:component_definition, :scope_fan_out),
      name: :fan_out
    }

    item = Runic.step(fn x -> x end, name: :item)

    collector = %Workflow.FanIn{
      hash: Runic.Identity.digest(:component_definition, :scope_fan_in),
      name: :collector,
      init: fn ->
        send(observer, :fan_in_init)
        []
      end,
      reducer: fn x, acc ->
        send(observer, :fan_in_reduce)
        [x | acc]
      end
    }

    wf =
      Workflow.new()
      |> Workflow.add_step(fan_out)
      |> Workflow.add(item, to: fan_out)
      |> Workflow.add_step(item, collector)
      |> Workflow.draw_connection(fan_out, collector, :fan_in)
      |> Workflow.attach_before_hook(collector.hash, fn _, workflow, _ ->
        send(observer, :fan_in_before)
        workflow
      end)
      |> Workflow.attach_after_hook(collector.hash, fn _, workflow, _ ->
        send(observer, :fan_in_after)
        workflow
      end)

    root = Fact.local([1, 2])
    first = Fact.child(root, value: 1, ancestry: {fan_out.hash, root.hash})

    second =
      Fact.child(root,
        value: 2,
        ancestry: {fan_out.hash, root.hash},
        causal_ancestry:
          Workflow.FactAncestry.from_legacy({fan_out.hash, root.hash}, output_index: 1)
      )

    a = Fact.child(first, value: 1, ancestry: {item.hash, first.hash})
    b = Fact.local(2, ancestry: {item.hash, second.hash})
    wf = Enum.reduce([root, first, second, a, b], wf, &Workflow.log_fact(&2, &1))

    wf = %{
      wf
      | mapped:
          Map.merge(wf.mapped, %{
            {root.hash, fan_out.hash} => [second.hash, first.hash],
            {root.hash, item.hash} => %{first.hash => a.hash, second.hash => b.hash}
          })
    }

    direct = Invokable.invoke(collector, wf, a)
    assert Workflow.productions(direct) == []
    assert Enum.any?(direct.runnable_events, &is_struct(&1, RunnableFailed))
    {:ok, prepared} = Invokable.prepare(collector, wf, a)
    executed = Invokable.execute(collector, prepared)
    {_wf, accepted, _} = Workflow.accept_runnable(wf, executed)
    assert accepted.status == :failed

    assert %ArgumentError{message: "cannot combine facts from different local scopes"} =
             accepted.error

    refute_received :fan_in_before
    refute_received :fan_in_after
    refute_received :fan_in_init
    refute_received :fan_in_reduce
  end
end
