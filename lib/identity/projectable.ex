defprotocol Runic.Identity.Projectable do
  @moduledoc """
  Projects a value into a portable, canonical identity document.

  Custom components opt in explicitly. Live structs and compiled functions are
  never hashed implicitly as portable definitions.
  """

  @fallback_to_any true

  @spec identity_document(t()) :: term()
  def identity_document(value)
end
