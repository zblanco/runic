defmodule Runic.NativeFactStoreTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true
  require Runic
  alias Runic.{Runner, Workflow}
  alias Runic.Runner.Store.{ETS, Mnesia}
  alias Runic.Workflow.{Fact, LocalFactError}
  alias Runic.Workflow.Events.FactProduced
  alias Runic.TestSupport.{FailingStore, FailingEventOnlyStore, FailingLegacyStore}

  for store <- [FailingStore, FailingEventOnlyStore, FailingLegacyStore] do
    test "#{store} sees no writes from a mixed batch with a local event last" do
      backend = start_supervised!(FailingStore)
      runner = :"native_mixed_store_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Runner, name: runner, store: unquote(store), store_opts: [agent: backend]}
      )

      definition = Runic.workflow(steps: [Runic.step(fn x -> x end)])

      {:ok, worker} =
        Runner.start_workflow(runner, :mixed, definition,
          owner: self(),
          dispatch_mode: :manual
        )

      before = FailingStore.data(backend).calls
      portable_event = FactProduced.new(Fact.new(value: 7), producer_label: :input)
      local_event = FactProduced.new(Fact.local(8), producer_label: :input)

      :sys.replace_state(worker, fn state ->
        if Runic.Runner.Store.supports_stream?(unquote(store)) do
          %{state | uncommitted_events: [portable_event, local_event]}
        else
          workflow =
            Enum.reduce(
              [portable_event, local_event],
              state.workflow,
              &Workflow.apply_event(&2, &1)
            )

          %{state | workflow: %{workflow | runnable_events: [portable_event, local_event]}}
        end
      end)

      assert {:error, {:persistence_failed, %LocalFactError{field: :events}}} =
               Runner.checkpoint(runner, :mixed)

      assert FailingStore.data(backend).calls == before
      assert Process.alive?(worker)
      assert :ok = Runner.cancel(runner, :mixed)
    end

    test "#{store} checks a local workflow key before persistence callbacks" do
      backend = start_supervised!(FailingStore)
      runner = :"native_key_store_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Runner, name: runner, store: unquote(store), store_opts: [agent: backend]}
      )

      # Empty definitions have no initial build write. Test the later write path.
      key = Fact.local(7).hash
      {:ok, worker} = Runner.start_workflow(runner, key, Workflow.new(), owner: self())
      before = FailingStore.data(backend).calls
      assert :ok = Runner.run(runner, key, 7)

      assert {:error, {:persistence_failed, %LocalFactError{field: :workflow_id}}} =
               Runner.checkpoint(runner, key)

      assert FailingStore.data(backend).calls == before
      assert Process.alive?(worker)
      assert :ok = Runner.cancel(runner, key)
    end
  end

  for store <- [ETS, Mnesia] do
    test "#{store} rejects native local facts at all write callbacks" do
      module = unquote(store)
      name = :"native_store_#{System.unique_integer([:positive])}"
      opts = [runner_name: name, disc_copies: false]
      start_supervised!({module, opts})
      {:ok, state} = module.init_store(opts)

      if unquote(store == Mnesia) do
        on_exit(fn ->
          Enum.each(
            [state.table, state.events_table, state.counters_table, state.facts_table],
            &:mnesia.delete_table/1
          )
        end)
      end

      fact = Fact.local(7)
      event = FactProduced.new(fact, producer_label: :input)

      for result <- [
            module.save(:local, [event], state),
            module.append(:local, [event], state),
            module.save_fact(fact.hash, fact.value, state),
            module.save_payload(fact.payload_digest, :erlang.term_to_binary(fact.value), state)
          ] do
        assert {:error, %LocalFactError{field: field, path: [_ | _]}} = result
        assert field in [:events, :fact]
      end

      assert {:error, :not_found} = module.stream(:local, state)
      assert {:error, :not_found} = module.load_fact(fact.hash, state)
      portable = Fact.new(value: 7)

      assert {:error, %LocalFactError{field: :workflow_id}} =
               module.save(fact.hash, [:portable], state)

      assert {:error, %LocalFactError{field: :workflow_id}} =
               module.append(fact.hash, [:portable], state)

      assert {:error, :not_found} = module.stream(fact.hash, state)
      assert {:error, :not_found} = module.load(fact.hash, state)
      assert :ok = module.save_fact(portable.hash, portable.value, state)
      assert {:ok, 7} = module.load_fact(portable.hash, state)
    end
  end
end
