defmodule Runic.Workflow.Batch.Terminal do
  @moduledoc false
  defstruct [:source, :step, :item, :outcome]
end

defimpl Runic.Workflow.EventApplicator, for: Runic.Workflow.Batch.Terminal do
  def apply(event, workflow) do
    key = {event.source, event.step}
    seen = Map.get(workflow.mapped, key, %{}) |> Map.put(event.item, event.outcome)
    %{workflow | mapped: Map.put(workflow.mapped, key, seen)}
  end
end
