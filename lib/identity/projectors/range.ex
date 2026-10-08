defimpl Runic.Identity.Projectable, for: Range do
  def identity_document(range) do
    %{first: range.first, last: range.last, step: range.step}
  end
end
