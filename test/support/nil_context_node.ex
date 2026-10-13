defmodule Runic.TestSupport.NilContextNode do
  @moduledoc false
  defstruct [:hash, name: :nil_context]
end

defimpl Runic.Workflow.Invokable, for: Runic.TestSupport.NilContextNode do
  alias Runic.Workflow.{Fact, Runnable}
  def match_or_execute(_), do: :execute
  def prepare(node, _, input), do: {:ok, Runnable.new(node, input, nil)}

  def execute(node, runnable) do
    output =
      Fact.child(runnable.input_fact,
        value: runnable.input_fact.value + 1,
        ancestry: {node.hash, runnable.input_fact.hash}
      )

    event = Runic.Workflow.Events.FactProduced.new(output, producer_label: :produced)

    consumed = %Runic.Workflow.Events.ActivationConsumed{
      fact_hash: runnable.input_fact.hash,
      node_hash: node.hash,
      from_label: :runnable
    }

    Runnable.complete(runnable, output, [event, consumed])
  end

  def invoke(node, workflow, input), do: Runic.Workflow.invoke(workflow, node, input)
end
