defmodule Runic.Workflow.FanOut do
  @moduledoc """
  FanOut steps are part of a map operator that expands enumerable facts into separate facts.

  FanOut just splits input facts - separate steps as defined in the map expression will do the processing.
  """
  defstruct [:hash, :name]

  # Shared by ordinary-node preparation and FanIn. Ancestry coordinates are
  # present on lightweight references; locating a batch must not hydrate values.
  @doc false
  def origin(workflow, %{ancestry: {producer, parent}} = fact)
      when is_struct(fact, Runic.Workflow.Fact) or is_struct(fact, Runic.Workflow.FactRef) do
    case Map.get(workflow.graph.vertices, producer) do
      %__MODULE__{} -> {parent, producer, fact.hash}
      _ -> origin(workflow, Map.get(workflow.graph.vertices, parent))
    end
  end

  def origin(_workflow, _fact), do: nil
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
        {w, Enum.reverse(new_events, events_acc)}
      end)

    {wf, Enum.reverse(all_events)}
  end

  def activate_downstream(%Runic.Workflow.FanOut{}, %Workflow{} = wf, %Runnable{}), do: {wf, []}
end
