defimpl Runic.Identity.Projectable, for: Runic.Examples.LocalValue do
  def identity_document(value) do
    %{codec: :example_local_term, digest: value.digest}
  end
end
