defmodule Runic.TestSupport.LegacyStore do
  @behaviour Runic.Runner.Store

  @impl Runic.Runner.Store
  defdelegate init_store(opts), to: Runic.Runner.Store.ETS

  @impl Runic.Runner.Store
  defdelegate save(workflow_id, log, state), to: Runic.Runner.Store.ETS

  @impl Runic.Runner.Store
  defdelegate load(workflow_id, state), to: Runic.Runner.Store.ETS
end
