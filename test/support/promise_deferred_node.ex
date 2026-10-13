defmodule Runic.TestSupport.PromiseDeferredNode do
  defstruct [:hash, :name]
end

defimpl Runic.Workflow.Invokable, for: Runic.TestSupport.PromiseDeferredNode do
  def match_or_execute(_), do: :execute
  def prepare(_, _, _), do: {:defer, &Function.identity/1}
  def execute(_, _), do: raise("deferred node must not execute")
  def invoke(_, workflow, _), do: workflow
end
