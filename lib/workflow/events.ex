defmodule Runic.Workflow.Events do
  @moduledoc """
  Barrel module for all workflow event types.

  Events are the primary mutation interface in the event-sourced workflow model.
  `Invokable.execute/2` produces events, and `Workflow.apply_event/2` folds them
  into the workflow graph as a pure function.
  """

  alias Runic.Workflow.Events.FactProduced
  alias Runic.Workflow.Events.ActivationConsumed
  alias Runic.Workflow.Events.RunnableActivated
  alias Runic.Workflow.Events.ConditionSatisfied
  alias Runic.Workflow.Events.MapReduceTracked
  alias Runic.Workflow.Events.StateInitiated
  alias Runic.Workflow.Events.JoinFactReceived
  alias Runic.Workflow.Events.JoinCompleted
  alias Runic.Workflow.Events.JoinEdgeRelabeled
  alias Runic.Workflow.Events.FanOutFactEmitted
  alias Runic.Workflow.Events.FanInCompleted

  @type event ::
          FactProduced.t()
          | ActivationConsumed.t()
          | RunnableActivated.t()
          | ConditionSatisfied.t()
          | MapReduceTracked.t()
          | StateInitiated.t()
          | JoinFactReceived.t()
          | JoinCompleted.t()
          | JoinEdgeRelabeled.t()
          | FanOutFactEmitted.t()
          | FanInCompleted.t()

  defdelegate fact_produced(), to: FactProduced, as: :__struct__
  defdelegate activation_consumed(), to: ActivationConsumed, as: :__struct__
  defdelegate runnable_activated(), to: RunnableActivated, as: :__struct__
  defdelegate condition_satisfied(), to: ConditionSatisfied, as: :__struct__
  defdelegate map_reduce_tracked(), to: MapReduceTracked, as: :__struct__
  defdelegate state_initiated(), to: StateInitiated, as: :__struct__
  defdelegate join_fact_received(), to: JoinFactReceived, as: :__struct__
  defdelegate join_completed(), to: JoinCompleted, as: :__struct__
  defdelegate join_edge_relabeled(), to: JoinEdgeRelabeled, as: :__struct__
  defdelegate fan_out_fact_emitted(), to: FanOutFactEmitted, as: :__struct__
  defdelegate fan_in_completed(), to: FanInCompleted, as: :__struct__
end
