defmodule Runic.FactBoundaryConsumersTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  require Runic

  alias Runic.Examples.LocalValue
  alias Runic.{Runner, Workflow}
  alias Runic.TestSupport.{FactBoundaryStore, FailingStore, OrdinaryComponent}
  alias Runic.Workflow.Execution

  test "a Store data gate rejects local facts before the backend write" do
    backend = start_supervised!(FailingStore)
    runner = :"fact_store_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Runner, name: runner, store: FactBoundaryStore, store_opts: [agent: backend]}
    )

    workflow = Runic.workflow(steps: [Runic.step(fn input -> input end, name: :echo)])

    assert {:ok, worker} =
             Runner.start_workflow(runner, :local, workflow,
               owner: self(),
               dispatch_mode: :manual,
               checkpoint_strategy: :manual
             )

    calls_before_input = FailingStore.data(backend).calls
    assert :ok = Runner.run(runner, :local, LocalValue.new(URI.parse("/local")))
    assert {:error, {:persistence_failed, error}} = Runner.checkpoint(runner, :local)

    assert %{
             field: :events,
             path: [:events, index, :value],
             reason: {:unsupported, :local_identity},
             retry: false
           } = error

    assert is_integer(index)
    assert FailingStore.data(backend).calls == calls_before_input
    assert {:error, {:persistence_failed, ^error}} = Runner.stop(runner, :local)
    assert Process.alive?(worker)
    assert :ok = Runner.cancel(runner, :local)
  end

  test "a consumer validates fresh keys and live resources before Runner resume" do
    runner = :"fact_resume_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner})

    lookup =
      Runic.step(fn key -> Agent.get(context(:cache), &Map.fetch!(&1, key)) end, name: :lookup)

    workflow = Runic.workflow(steps: [lookup])

    assert {:ok, _worker} =
             Runner.start_workflow(runner, :lookup, workflow,
               owner: self(),
               dispatch_mode: :manual
             )

    assert :ok = Runner.run(runner, :lookup, "key")
    assert :ok = Runner.stop(runner, :lookup)

    {store, state} = Runner.get_store(runner)
    assert {:ok, events} = store.stream(:lookup, state)
    restored = Workflow.from_events(Enum.to_list(events))
    assert restored.run_context == %{}
    observer = self()

    resume = fn fresh ->
      with :ok <- Workflow.validate_run_context(restored, fresh),
           cache <- Map.get(Map.get(fresh, :lookup, %{}), :cache),
           true <- is_pid(cache) and Process.alive?(cache) do
        Runner.resume(runner, :lookup,
          owner: observer,
          run_context: fresh,
          hooks: [on_idle: fn _ -> send(observer, :resumed_idle) end]
        )
      else
        false -> {:error, :cache_unavailable}
        error -> error
      end
    end

    assert {:error, %{lookup: [:cache]}} = resume.(%{})
    assert {:error, :cache_unavailable} = resume.(%{lookup: %{cache: nil}})
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}
    assert {:error, :cache_unavailable} = resume.(%{lookup: %{cache: dead}})
    assert Runner.lookup(runner, :lookup) == nil

    cache = start_supervised!({Agent, fn -> %{"key" => %{found: true}} end})
    assert {:ok, _worker} = resume.(%{lookup: %{cache: cache}})
    assert_receive :resumed_idle, 1_000
    assert {:ok, [%{found: true}]} = Runner.get_results(runner, :lookup)
  end

  test "a SingleOutput callback validates resources not declared as context references" do
    workflow = Workflow.new() |> Workflow.add(OrdinaryComponent.new(:cache, :cache))
    assert :ok = Workflow.validate_run_context(workflow, %{})
    {workflow, failed} = Workflow.execute(workflow, "key")
    assert Execution.outputs(failed) == []
    assert [%{error: :cache_unavailable}] = failed.failures

    cache = start_supervised!({Agent, fn -> %{"key" => %{found: true}} end})

    {_workflow, completed} =
      Workflow.execute(workflow, "key", run_context: %{cache: %{cache: cache}})

    assert Execution.outputs(completed) == [%{found: true}]
  end
end
