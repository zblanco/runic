defmodule Runic.Workflow.FanOut do
  @moduledoc """
  FanOut steps are part of a map operator that expands enumerable facts into separate facts.

  FanOut just splits input facts - separate steps as defined in the map expression will do the processing.
  """
  defstruct [:hash, :name]
end

defimpl Runic.Workflow.Activator, for: Runic.Workflow.FanOut do
  alias Runic.Workflow
  alias Runic.Workflow.Runnable
  alias Runic.Workflow.Private
  alias Runic.Workflow.Events.RunnableActivated

  def activate_downstream(%Runic.Workflow.FanOut{} = fan_out, %Workflow{} = wf, %Runnable{
        result: emitted_facts
      })
      when is_list(emitted_facts) do
    next = Workflow.next_steps(wf, fan_out)

    {wf, all_events} =
      Enum.reduce(emitted_facts, {wf, []}, fn fact, {w, events_acc} ->
        new_events =
          Enum.map(next, fn step ->
            %RunnableActivated{
              fact_hash: fact.hash,
              node_hash: step.hash,
              activation_kind: Private.connection_for_activatable(step)
            }
          end)

        w = Enum.reduce(new_events, w, fn event, w2 -> Workflow.apply_event(w2, event) end)
        {w, events_acc ++ new_events}
      end)

    {wf, all_events}
  end

  def activate_downstream(%Runic.Workflow.FanOut{}, %Workflow{} = wf, %Runnable{}), do: {wf, []}
end
