defmodule Runic.NativeFactModeTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  require Runic

  alias Runic.Identity.{Canonical, CanonicalError}
  alias Runic.{Runner, Workflow}
  alias Runic.TestSupport.{FailingStore, OrdinaryComponent, RemoteProfileExecutor}

  alias Runic.Workflow.{
    Execution,
    Fact,
    Facts,
    FactResolver,
    Invokable,
    LocalBoundary,
    LocalFactError,
    LocalScope,
    Runnable
  }

  alias Runic.Workflow.Events.Serializer

  test "local facts carry live terms directly and portable construction stays strict" do
    port = Port.open({:spawn_executable, System.find_executable("cat")}, [:binary])

    try do
      value = %{
        pid: self(),
        ref: make_ref(),
        callback: fn x -> x end,
        port: port,
        nested: {URI.parse("/local"), [self()]}
      }

      fact = Fact.local(value)
      assert fact.value == value
      assert fact.identity_mode == :local
      assert LocalScope.valid?(fact.local_scope)
      assert fact.id.scheme == :local_sha256
      assert fact.payload_digest.scheme == :local_sha256
      assert String.starts_with?(to_string(fact.id), "runic:local_sha256:")
      assert_raise CanonicalError, fn -> Fact.new(value: value) end
      assert_raise CanonicalError, fn -> Canonical.encode!(fact.id) end
    after
      Port.close(port)
    end
  end

  test "scope controls local identity and children cannot silently become portable" do
    scope = LocalScope.new()
    parent = Fact.local(self(), local_scope: scope)
    same = Fact.local(self(), local_scope: scope)
    other = Fact.local(self())
    assert parent.payload_digest == same.payload_digest
    refute parent.payload_digest == other.payload_digest
    child = Fact.child(parent, value: 7, ancestry: {:step, parent.hash})
    assert child.identity_mode == :local
    assert child.local_scope == scope
    assert child.value == 7
    assert_raise ArgumentError, fn -> Fact.child(parent, value: 7, identity_mode: :portable) end
    assert_raise ArgumentError, fn -> Fact.child([parent, other], value: 7) end
    assert_raise CanonicalError, fn -> Fact.new(value: 7, ancestry: {:step, parent.hash}) end
    assert_raise ArgumentError, fn -> Fact.local(7, local_scope: %{scope | vm: self()}) end
    portable = Fact.new(value: 7)
    assert_raise ArgumentError, fn -> Fact.local(7, payload_digest: portable.payload_digest) end
  end

  test "explicit in-memory replay refuses a foreign VM scope" do
    scope = LocalScope.new()
    fact = Fact.local(7, local_scope: scope)
    foreign = %{fact | local_scope: %{scope | vm: :crypto.strong_rand_bytes(32)}}
    event = Runic.Workflow.Events.FactProduced.new(foreign, producer_label: :input)
    assert_raise LocalFactError, fn -> Workflow.from_events([event], nil, allow_local: true) end
  end

  test "legacy portable snapshots without the new Fact fields still run" do
    first = Runic.step(fn value -> value end, name: :first)
    last = Runic.step(fn value -> value + 1 end, name: :last)
    wf = Runic.workflow(steps: [{first, [last]}]) |> Workflow.react(5)

    graph =
      Enum.reduce(Workflow.facts(wf), wf.graph, fn fact, graph ->
        legacy = Map.drop(fact, [:identity_mode, :local_scope])
        %{graph | vertices: Map.put(graph.vertices, fact.hash, legacy)}
      end)

    snapshot = Runner.encode_snapshot(%{wf | graph: graph})
    assert {:ok, restored} = Runner.decode_snapshot(snapshot)
    completed = Workflow.react_until_satisfied(restored)
    assert 6 in Workflow.raw_productions(completed)
    old = Enum.find(Workflow.facts(restored), &(not Map.has_key?(&1, :identity_mode)))
    assert Facts.to_ref(old).identity_mode == :portable
  end

  for scheduler <- [Runic.Runner.Scheduler.FlowBatch, Runic.Runner.Scheduler.ChainBatching] do
    test "native batching and remote rejection with #{scheduler}" do
      runner = :"native_batch_#{System.unique_integer([:positive])}"
      start_supervised!({Runner, name: runner})
      a = Runic.step(fn x -> x end, name: :a)
      b = Runic.step(fn _ -> 7 end, name: :b)

      definition =
        if unquote(scheduler == Runic.Runner.Scheduler.FlowBatch),
          do: Runic.workflow(steps: [a, b]),
          else: Runic.workflow(steps: [{a, [b]}])

      opts = [min_batch_size: 2, min_chain_length: 2]

      {:ok, _} =
        Runner.start_workflow(runner, :local, definition,
          owner: self(),
          persistence: :disabled,
          scheduler: unquote(scheduler),
          scheduler_opts: opts
        )

      {:ok, id} = Runner.start_execution(runner, :local, self(), identity_mode: :local)
      assert {:ok, completed} = Runner.await_execution(runner, :local, id)
      assert self() in Execution.outputs(completed)
      assert 7 in Execution.outputs(completed)

      {:ok, _} =
        Runner.start_workflow(runner, :remote, definition,
          owner: self(),
          persistence: :disabled,
          scheduler: unquote(scheduler),
          scheduler_opts: opts,
          executor: RemoteProfileExecutor,
          executor_opts: [observer: self()]
        )

      {:ok, id} = Runner.start_execution(runner, :remote, self(), identity_mode: :local)
      assert {:ok, rejected} = Runner.await_execution(runner, :remote, id)
      assert rejected.failures != []
      assert Enum.all?(rejected.failures, &match?(%LocalFactError{}, &1.error))
      refute_received :remote_dispatch_called
    end
  end

  for async <- [false, true] do
    test "native Steps receive bare values and retain scalar scope with async #{async}" do
      step =
        Runic.step(fn %{callback: callback, input: input} -> callback.(input) end, name: :call)

      scalar = Runic.step(fn _ -> 7 end, name: :scalar)
      definition = Runic.workflow(steps: [{step, [scalar]}])
      input = %{callback: fn pid -> pid end, input: self()}

      {wf, execution} =
        Workflow.execute(definition, input, identity_mode: :local, async: unquote(async))

      assert Execution.outputs(execution) == [self(), 7]
      assert execution.failures == []
      facts = Workflow.facts(wf)
      assert Enum.all?(facts, &(&1.identity_mode == :local))
      assert facts |> Enum.map(& &1.local_scope) |> Enum.uniq() |> length() == 1
      [output] = Workflow.productions(wf, :scalar)

      assert {:error, %LocalFactError{path: [:output, :identity_mode]}} =
               LocalBoundary.check(output, :output)

      {_new, portable} =
        Workflow.execute(Runic.workflow(steps: [Runic.step(fn x -> x end)]), output.value)

      assert Execution.outputs(portable) == [7]
    end
  end

  test "SingleOutput callbacks need no wrapper and can explicitly share scope with a nested call" do
    definition = Workflow.new() |> Workflow.add(OrdinaryComponent.new(:call, :native_callback))

    {_, execution} =
      Workflow.execute(definition, %{callback: fn x -> x end, input: self()},
        identity_mode: :local
      )

    assert Execution.outputs(execution) == [self()]
    nested = Workflow.new() |> Workflow.add(OrdinaryComponent.new(:nested, :native_nested))
    {wf, execution} = Workflow.execute(nested, self(), identity_mode: :local, async: true)

    assert [%{value: pid, task_scope: task_scope, outer_task_scope: task_scope}] =
             Execution.outputs(execution)

    assert pid == self()
    assert is_pid(task_scope)
    assert wf |> Workflow.facts() |> Enum.all?(&(&1.identity_mode == :local))
  end

  test "repeated equal local inputs get distinct occurrences in a reusable graph" do
    scope = LocalScope.new()
    definition = Runic.workflow(steps: [Runic.step(fn x -> x end)])
    {wf, first} = Workflow.execute(definition, self(), identity_mode: :local, local_scope: scope)
    {wf, second} = Workflow.execute(wf, self(), identity_mode: :local, local_scope: scope)
    refute first.id == second.id
    refute first.input_fact_id == second.input_fact_id
    roots = Enum.filter(Workflow.facts(wf), &is_nil(&1.ancestry))
    assert length(roots) == 2
    assert roots |> Enum.map(& &1.payload_digest) |> Enum.uniq() |> length() == 1
  end

  test "a native Rule binding and reaction keep local scope" do
    rule =
      Runic.rule name: :choose do
        given(value: v)
        where(is_pid(v))
        then(fn %{value: v} -> {v, 7} end)
      end

    {wf, execution} =
      Workflow.execute(Runic.workflow(rules: [rule]), self(), identity_mode: :local)

    assert execution.failures == []
    assert {self(), 7} in Workflow.raw_productions(wf)
    assert Enum.all?(Workflow.facts(wf), &(&1.identity_mode == :local))
  end

  test "native fan-out and reduction keep the scope and raw values" do
    map = Runic.map(fn pid -> pid end, name: :echo)
    reduce = Runic.reduce(0, fn _pid, count -> count + 1 end, name: :count)
    wf = Workflow.new() |> Workflow.add(map) |> Workflow.add(reduce, to: :echo)
    {wf, execution} = Workflow.execute(wf, [self(), self()], identity_mode: :local)
    assert execution.failures == []
    assert 2 in Workflow.raw_productions(wf)
    assert Enum.all?(Workflow.facts(wf), &(&1.identity_mode == :local))
  end

  test "a Join retains the scope of all branches" do
    a = Runic.step(fn x -> {x, :a} end, name: :a)
    b = Runic.step(fn x -> {x, :b} end, name: :b)
    joined = Runic.step(fn a, b -> [a, b] end, name: :joined)
    definition = Runic.workflow(steps: [a, b, {[a, b], [joined]}])
    {wf, execution} = Workflow.execute(definition, self(), identity_mode: :local)
    assert execution.failures == []
    assert [{self(), :a}, {self(), :b}] in Workflow.raw_productions(wf, :joined)
    assert Enum.all?(Workflow.facts(wf), &(&1.identity_mode == :local))
  end

  test "local accumulator state needs an explicit shared session across calls" do
    scope = LocalScope.new()
    acc = Runic.accumulator([], fn value, state -> [value | state] end, name: :history)
    definition = Workflow.new() |> Workflow.add(acc)
    {wf, first} = Workflow.execute(definition, self(), identity_mode: :local, local_scope: scope)
    assert first.failures == []
    {wf, second} = Workflow.execute(wf, self(), identity_mode: :local, local_scope: scope)
    assert second.failures == []
    assert [self(), self()] in Workflow.raw_productions(wf)
    {_wf, conflict} = Workflow.execute(wf, self(), identity_mode: :local)
    assert [%{error: %ArgumentError{}}] = conflict.failures
  end

  test "local events can replay explicitly in this VM but cannot be serialized or recovered" do
    definition = Runic.workflow(steps: [Runic.step(fn x -> x end)])

    wf =
      Workflow.react_until_satisfied(Workflow.enable_event_emission(definition), self(),
        identity_mode: :local
      )

    events = Workflow.event_log(wf)
    assert_raise LocalFactError, fn -> Workflow.from_events(events) end
    replay = Workflow.from_events(events, nil, allow_local: true)
    assert Workflow.raw_productions(replay) == [self()]
    assert Enum.all?(Workflow.facts(replay), &(&1.identity_mode == :local))
    assert_raise LocalFactError, fn -> Serializer.to_binary(events) end
    assert {:error, %LocalFactError{}} = Serializer.from_binary(:erlang.term_to_binary(events))
    assert_raise LocalFactError, fn -> Runner.encode_snapshot(wf) end
    snapshot = :erlang.term_to_binary({:runic_workflow_snapshot, 1, wf})
    assert {:error, %LocalFactError{}} = Runner.decode_snapshot(snapshot)
    ref = wf |> Workflow.facts() |> hd() |> Facts.to_ref()
    assert ref.identity_mode == :local
    assert {:error, %LocalFactError{}} = FactResolver.resolve(ref, nil)
  end

  test "Worker rejects native events before any optional value write or append" do
    backend = start_supervised!(FailingStore)
    runner = :"native_persist_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner, store: FailingStore, store_opts: [agent: backend]})
    definition = Runic.workflow(steps: [Runic.step(fn x -> x end)])

    {:ok, worker} =
      Runner.start_workflow(runner, :local, definition, owner: self(), dispatch_mode: :manual)

    before = FailingStore.data(backend).calls
    :ok = Runner.run(runner, :local, Fact.local(7))

    assert {:error, {:persistence_failed, %LocalFactError{field: :events}}} =
             Runner.checkpoint(runner, :local)

    assert FailingStore.data(backend).calls == before
    assert {:error, {:persistence_failed, %LocalFactError{}}} = Runner.stop(runner, :local)
    assert Process.alive?(worker)
    :ok = Runner.cancel(runner, :local)
  end

  test "an explicit non-persistent Worker runs native facts and keeps Store acknowledgement separate" do
    backend = start_supervised!(FailingStore)
    runner = :"native_disabled_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner, store: FailingStore, store_opts: [agent: backend]})
    definition = Runic.workflow(steps: [Runic.step(fn x -> x end)])

    {:ok, _} =
      Runner.start_workflow(runner, :local, definition, owner: self(), persistence: :disabled)

    {:ok, id} = Runner.start_execution(runner, :local, self(), identity_mode: :local)
    assert {:ok, execution} = Runner.await_execution(runner, :local, id)
    assert Execution.outputs(execution) == [self()]
    assert execution.persistence.status == :not_managed
    assert FailingStore.data(backend).calls == []
    assert {:error, :persistence_disabled} = Runner.checkpoint(runner, :local)
    assert :ok = Runner.stop(runner, :local)
  end

  test "a declared remote executor is not called for local facts, including scalars" do
    runner = :"native_remote_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner})
    definition = Runic.workflow(steps: [Runic.step(fn x -> x end)])

    {:ok, _} =
      Runner.start_workflow(runner, :local, definition,
        owner: self(),
        persistence: :disabled,
        executor: RemoteProfileExecutor,
        executor_opts: [observer: self()]
      )

    {:ok, id} = Runner.start_execution(runner, :local, 7, identity_mode: :local)
    assert {:ok, failed} = Runner.await_execution(runner, :local, id)
    assert [%{error: %LocalFactError{field: :dispatch}}] = failed.failures
    refute_received :remote_dispatch_called
    assert :ok = Runner.continue(runner, :local)
    {:ok, id} = Runner.start_execution(runner, :local, 7)
    assert {:ok, success} = Runner.await_execution(runner, :local, id)
    assert Execution.outputs(success) == [7]
    assert_receive :remote_dispatch_called
    root = Fact.local(7)
    node = Runic.step(fn x -> x end)
    {:ok, runnable} = Invokable.prepare(node, Runic.workflow(steps: [node]), root)
    assert {:error, %LocalFactError{}} = Runnable.for_remote(runnable)
  end

  test "Runner.run accepts a raw native input through its options" do
    observer = self()
    runner = :"native_run_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner})
    definition = Runic.workflow(steps: [Runic.step(fn value -> value end)])

    {:ok, _} =
      Runner.start_workflow(runner, :local, definition,
        owner: observer,
        persistence: :disabled,
        hooks: [on_idle: fn _ -> send(observer, :native_run_idle) end]
      )

    assert :ok = Runner.run(runner, :local, self(), identity_mode: :local)
    assert_receive :native_run_idle, 1_000
    assert {:ok, [pid]} = Runner.get_results(runner, :local)
    assert pid == self()
  end

  test "native cancellation still stops active work that traps exits" do
    runner = :"native_cancel_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner})

    step =
      Runic.step(fn %{reply_to: reply} ->
        Process.flag(:trap_exit, true)
        send(reply, {:native_started, self()})
        receive do: (:release -> 7)
      end)

    {:ok, worker} =
      Runner.start_workflow(runner, :local, Runic.workflow(steps: [step]),
        owner: self(),
        persistence: :disabled
      )

    {:ok, _} = Runner.start_execution(runner, :local, %{reply_to: self()}, identity_mode: :local)
    assert_receive {:native_started, task}, 1_000
    task_ref = Process.monitor(task)
    worker_ref = Process.monitor(worker)
    assert :ok = Runner.cancel(runner, :local)
    assert_receive {:DOWN, ^task_ref, :process, ^task, _}, 1_000
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 1_000
    refute Process.alive?(task)
  end

  test "local fallback output retains the native mode" do
    step = Runic.step(fn _ -> raise "expected" end, name: :fallback)

    {wf, execution} =
      Workflow.execute(Runic.workflow(steps: [step]), self(),
        identity_mode: :local,
        scheduler_policies: [{:fallback, %{fallback: fn _, _ -> {:value, 7} end}}]
      )

    assert Execution.outputs(execution) == [7]
    assert Enum.all?(Workflow.productions(wf), &(&1.identity_mode == :local))
  end

  test "a non-persistent Worker cannot be recovered from its empty Store" do
    runner = :"native_resume_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner})
    definition = Runic.workflow(steps: [Runic.step(fn x -> x end)])

    {:ok, worker} =
      Runner.start_workflow(runner, :local, definition, owner: self(), persistence: :disabled)

    {:ok, id} = Runner.start_execution(runner, :local, self(), identity_mode: :local)
    assert {:ok, _} = Runner.await_execution(runner, :local, id)
    ref = Process.monitor(worker)
    assert :ok = Runner.stop(runner, :local)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 1_000
    assert {:error, :not_found} = Runner.resume(runner, :local)
  end

  test "recovery rejects a raw local event stream before it starts a Worker" do
    backend = start_supervised!(FailingStore)
    runner = :"native_raw_resume_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner, store: FailingStore, store_opts: [agent: backend]})
    definition = Runic.workflow(steps: [Runic.step(fn x -> x end)])

    wf =
      Workflow.react_until_satisfied(Workflow.enable_event_emission(definition), self(),
        identity_mode: :local
      )

    # A deliberately unsafe legacy adapter bypasses normal write guards.
    assert {:ok, _} = FailingStore.append(:local, Workflow.event_log(wf), backend)
    assert {:error, %LocalFactError{}} = Runner.resume(runner, :local)
    assert Runner.lookup(runner, :local) == nil
  end

  test "local failure does not poison a later portable execution" do
    definition =
      Runic.workflow(
        steps: [
          Runic.step(fn
            {:fail, callback} -> callback.()
            {:ok, value} -> value
          end)
        ]
      )

    {wf, failure} =
      Workflow.execute(definition, {:fail, fn -> raise "expected" end}, identity_mode: :local)

    assert failure.failures != []
    {_wf, success} = Workflow.execute(wf, {:ok, 7})
    assert Execution.outputs(success) == [7]
  end
end
