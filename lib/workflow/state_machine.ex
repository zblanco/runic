defmodule Runic.Workflow.StateMachine do
  defstruct [
    :name,
    # literal or function to return first state to act on
    :init,
    :reducer,
    :reactors,
    :workflow
  ]
end
