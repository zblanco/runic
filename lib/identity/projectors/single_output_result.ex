defimpl Runic.Identity.Projectable, for: Runic.Workflow.SingleOutput.Result do
  def identity_document(result) do
    %{
      kind: :single_output_result,
      version: 1,
      status: result.status,
      value: result.value,
      error: result.error,
      metadata: result.metadata
    }
  end
end
