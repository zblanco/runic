defmodule Runic.Workflow.StateMachine do
  defstruct [
    :name,
    # literal or function to return first state to act on
    :init,
    :reducer,
    :reactors,
    :workflow,
    :source,
    :hash
  ]

  def last_known_state(accumulator, workflow) do
    state =
      workflow.graph
      |> Graph.out_edges(accumulator)
      |> Enum.filter(&(&1.label == :state_produced))
      |> List.first(%{})
      |> Map.get(:v2)

    init_state = accumulator.init

    unless is_nil(state) do
      state
      |> Map.get(:value)
      |> invoke_init()
    else
      invoke_init(init_state)
    end
  end

  defp invoke_init(init) when is_function(init), do: init.()
  defp invoke_init(init), do: init
end
