defmodule Runic.NativeFactStoreTest do
  use ExUnit.Case, async: false
  alias Runic.Runner.Store.{ETS, Mnesia}
  alias Runic.Workflow.{Fact, LocalFactError}
  alias Runic.Workflow.Events.FactProduced

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
      assert :ok = module.save_fact(portable.hash, portable.value, state)
      assert {:ok, 7} = module.load_fact(portable.hash, state)
    end
  end
end
