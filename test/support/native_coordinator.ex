defmodule Runic.TestSupport.NativeCoordinator do
  @moduledoc false
  use Runic.Workflow.SingleOutput
  defstruct [:hash, :observer, name: :coordinator, mode: :declared]

  def new(mode, observer),
    do: %__MODULE__{
      mode: mode,
      observer: observer,
      hash: Runic.Identity.digest(:component_definition, {:native_coordinator, mode})
    }

  def run(_, _, _), do: Runic.Workflow.SingleOutput.Result.value(:waiting)
end

defimpl Runic.Workflow.CoordinatorParents, for: Runic.TestSupport.NativeCoordinator do
  def parents(%{mode: :unsupported}, _, _), do: :unsupported
  def parents(%{mode: :invalid_return}, _, _), do: :bad_contract_return
  def parents(%{mode: :invalid_list}, _, _), do: {:ok, :bad_contract_list}
  def parents(%{mode: :invalid_parent}, _, _), do: {:ok, [42]}

  def parents(%{mode: :declared}, workflow, _),
    do: {:ok, List.wrap(Map.get(workflow.mapped, :native_coord_parent))}

  def parents(_, _, _), do: {:ok, []}
end

defimpl Runic.Workflow.Coordinator, for: Runic.TestSupport.NativeCoordinator do
  alias Runic.Workflow.Fact

  def finalize(node, workflow, runnable) do
    send(node.observer, :custom_finalize)

    case node.mode do
      :argument_error ->
        raise ArgumentError, "unrelated coordinator bug"

      :scope_error ->
        Fact.child([Fact.local(1), Fact.local(2)], value: :conflict)

      _ ->
        parents = [
          runnable.input_fact | List.wrap(Map.get(workflow.mapped, :native_coord_parent))
        ]

        result =
          Fact.child(parents, value: :combined, ancestry: {node.hash, runnable.input_fact.hash})

        event = Runic.Workflow.Events.FactProduced.new(result, producer_label: :produced)
        {Runic.Workflow.apply_event(workflow, event), [event]}
    end
  end
end
