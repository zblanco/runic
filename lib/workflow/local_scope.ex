defmodule Runic.Workflow.LocalScope do
  @moduledoc """
  An explicit identity scope for facts used in one live VM.

  New roots get a new scope. Pass the same scope explicitly to reuse a local
  session, including nested calls. This is not a resource owner or a lease.
  A PID, port, callback, or reference can stop being usable within the scope.
  Local scopes cannot be saved, resumed, or sent to another VM.
  """
  @enforce_keys [:vm, :token]
  defstruct [:vm, :token]
  @on_load :init_vm
  @vm_key {__MODULE__, :vm_token}

  @type t :: %__MODULE__{vm: <<_::256>>, token: reference()}

  @doc false
  def init_vm do
    # Preserve the token across code reloads, but never across VM restarts.
    # A PID alone is insufficient: an unnamed VM can reuse the init PID.
    if :persistent_term.get(@vm_key, nil) == nil,
      do: :persistent_term.put(@vm_key, :crypto.strong_rand_bytes(32))

    :ok
  end

  @spec new() :: t()
  def new, do: %__MODULE__{vm: :persistent_term.get(@vm_key), token: make_ref()}

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{vm: vm, token: token}),
    do: vm == :persistent_term.get(@vm_key) and is_reference(token) and node(token) == node()

  def valid?(_), do: false

  @doc false
  def validate!(scope) do
    unless valid?(scope), do: raise(ArgumentError, "local fact scope must belong to this live VM")
    scope
  end
end
