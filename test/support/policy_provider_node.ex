defmodule Runic.Test.PolicyProviderNode do
  @moduledoc false

  defstruct [:name, :hash, :policy]
end

defimpl Runic.Workflow.PolicyProvider, for: Runic.Test.PolicyProviderNode do
  def scheduler_policy(%{policy: policy}), do: policy
end
