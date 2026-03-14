defmodule Runic.Runner.Scheduler.ChainBatching do
  @moduledoc """
  Scheduler strategy that batches linear chains into Promises.

  Delegates to `Runic.Runner.PromiseBuilder` for chain detection. Linear
  chains of runnables are grouped into Promise dispatch units; runnables
  that don't form chains are dispatched individually.

  ## Options

    * `:min_chain_length` — minimum chain length to form a Promise (default: 2)
  """

  @behaviour Runic.Runner.Scheduler

  alias Runic.Runner.PromiseBuilder

  @impl true
  def init(opts) do
    {:ok, %{min_chain_length: Keyword.get(opts, :min_chain_length, 2)}}
  end

  @impl true
  def plan_dispatch(workflow, runnables, state) do
    {promises, standalone} =
      PromiseBuilder.build_promises(workflow, runnables, min_chain_length: state.min_chain_length)

    units =
      Enum.map(promises, &{:promise, &1}) ++
        Enum.map(standalone, &{:runnable, &1})

    {units, state}
  end
end
