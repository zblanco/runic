defimpl Runic.Identity.Projectable, for: Runic.Workflow.ChildInvocation do
  def identity_document(request) do
    %{
      kind: :child_invocation,
      version: 1,
      target_hash: request.target.hash,
      target_name: request.target.name,
      input: request.input,
      output: request.output,
      input_ports: request.target.input_ports,
      output_ports: request.target.output_ports
    }
  end
end
