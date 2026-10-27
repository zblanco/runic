defmodule Runic.Runner.ScopedFactStoreTest do
  use ExUnit.Case, async: true

  require Runic
  alias Runic.Runner
  alias Runic.TestSupport.ScopedFactStore
  alias Runic.Workflow.Events.FactProduced

  setup do
    store = start_supervised!(ScopedFactStore)
    runner = :"scoped_fact_runner_#{System.unique_integer([:positive])}"

    start_supervised!({Runner, name: runner, store: ScopedFactStore, store_opts: [agent: store]})

    %{runner: runner, store: store}
  end

  test "uses workflow-scoped Store state for execution and recovery", ctx do
    parent = self()
    increment = Runic.step(fn value -> value + 1 end, name: :increment)
    workflow = Runic.workflow(steps: [increment])

    assert {:ok, _worker} =
             Runner.start_workflow(ctx.runner, :scoped, workflow,
               checkpoint_strategy: :manual,
               hooks: [on_idle: fn _state -> send(parent, :idle) end]
             )

    assert :ok = Runner.run(ctx.runner, :scoped, 10)
    assert_receive :idle, 5_000
    assert :ok = Runner.checkpoint(ctx.runner, :scoped)

    data = ScopedFactStore.data(ctx.store)
    fact_events = Enum.filter(data.events.scoped, &is_struct(&1, FactProduced))

    assert fact_events != []
    assert Enum.all?(fact_events, &is_nil(&1.value))
    assert Enum.all?(Map.keys(data.facts), &match?({:scoped, _hash}, &1))

    assert :ok = Runner.stop(ctx.runner, :scoped, persist: false)
    assert {:ok, _worker} = Runner.resume(ctx.runner, :scoped)
    assert {:ok, results} = Runner.get_results(ctx.runner, :scoped)
    assert 11 in results
  end
end
