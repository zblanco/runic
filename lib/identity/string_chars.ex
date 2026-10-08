defimpl String.Chars, for: Runic.Identity do
  def to_string(identity), do: Runic.Identity.to_string(identity)
end
