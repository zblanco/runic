defmodule Runic.TestSupport.FailingLegacyStore do
  @behaviour Runic.Runner.Store
  alias Runic.TestSupport.FailingStore

  @impl true
  defdelegate init_store(opts), to: FailingStore

  @impl true
  defdelegate save(id, log, state), to: FailingStore

  @impl true
  defdelegate load(id, state), to: FailingStore

  @impl true
  def checkpoint(id, log, state), do: FailingStore.save_log(:checkpoint, id, log, state)
end
