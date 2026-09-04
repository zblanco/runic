defimpl Runic.Identity.Projectable, for: Runic.Workflow.Condition do
  alias Runic.Identity.Projectable

  def identity_document(condition) do
    %{
      kind: :condition,
      version: 1,
      executable: executable_document(condition),
      arity: condition.arity,
      meta_requirements: condition.meta_refs
    }
  end

  defp executable_document(%{closure: %Runic.Closure{} = closure}) do
    Projectable.identity_document(closure)
  end

  defp executable_document(condition) do
    %{
      local_work_digest:
        condition.work_hash || Runic.Workflow.Components.work_hash(condition.work)
    }
  end
end
