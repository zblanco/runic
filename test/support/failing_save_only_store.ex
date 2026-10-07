defmodule Runic.TestSupport.FailingSaveOnlyStore do
  @behaviour Runic.Runner.Store
  alias Runic.TestSupport.FailingStore

  @impl true
  defdelegate init_store(opts), to: FailingStore

  @impl true
  defdelegate save(id, log, state), to: FailingStore

  @impl true
  defdelegate load(id, state), to: FailingStore
end
