defprotocol Runic.Identity.Projectable do
  @moduledoc """
  Projects a value into a portable, canonical identity document.

  Custom components opt in explicitly. Live structs and compiled functions are
  never hashed implicitly as portable definitions.

  A portable identity document does not prove that every raw field in the
  source value is portable. Consumers that project local wrappers must reject
  those values at persistence and remote-dispatch boundaries. Keep transient
  resources in workflow run context. See the Fact boundaries guide.
  """

  @fallback_to_any true

  @spec identity_document(t()) :: term()
  def identity_document(value)
end
