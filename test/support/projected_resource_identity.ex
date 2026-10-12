defimpl Runic.Identity.Projectable, for: Runic.TestSupport.ProjectedResource do
  def identity_document(value), do: %{name: value.name}
end
