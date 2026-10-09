defmodule Runic.TestSupport.TerminationGate do
  @moduledoc false
  use GenServer

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  @impl true
  def init(opts),
    do:
      {:ok,
       %{
         supervisor: Keyword.fetch!(opts, :supervisor),
         observer: Keyword.fetch!(opts, :observer),
         held: false
       }}

  @impl true
  def handle_call({:terminate_child, worker}, from, %{held: false} = state) do
    send(state.observer, {:termination_held, from, worker})
    {:noreply, %{state | held: true}}
  end

  def handle_call(request, _from, state) do
    {:reply, GenServer.call(state.supervisor, request, :infinity), state}
  end
end
