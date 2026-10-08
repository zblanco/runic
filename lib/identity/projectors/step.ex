defimpl Runic.Identity.Projectable, for: Runic.Workflow.Step do
  alias Runic.Identity.Projectable

  def identity_document(step) do
    %{
      kind: :step,
      version: 1,
      executable: executable_document(step),
      call_contract: struct_document(step.call_contract),
      inputs: step.inputs,
      outputs: step.outputs,
      meta_requirements: step.meta_refs
    }
  end

  defp executable_document(%{closure: %Runic.Closure{} = closure}) do
    Projectable.identity_document(closure)
  end

  defp executable_document(step) do
    %{local_work_digest: step.work_hash || Runic.Workflow.Components.work_hash(step.work)}
  end

  defp struct_document(nil), do: nil
  defp struct_document(%_{} = value), do: Map.from_struct(value)
  defp struct_document(value), do: value
end
