defimpl Runic.Identity.Projectable, for: Any do
  def identity_document(value) do
    raise Protocol.UndefinedError,
      protocol: Runic.Identity.Projectable,
      value: value,
      description: "the value has no portable Runic identity projection"
  end
end
