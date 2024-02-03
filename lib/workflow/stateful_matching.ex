defprotocol Runic.Workflow.StatefulMatching do
  @moduledoc """
  Defines a contract implemented by match phase flowables for whom require an accumulator to have produced state
  to match against.

  Returns the hash of the state flowable the match node depends on.
  """
  def matches_on(stateful_matching_flowable)
end

defimpl Runic.Workflow.StatefulMatching,
  for: [Runic.Workflow.StateCondition, Runic.Workflow.MemoryAssertion] do
  def matches_on(%{state_hash: state_hash}) do
    state_hash
  end
end
