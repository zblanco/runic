defmodule Runic.Workflow.Events do
  @moduledoc """
  Barrel module for all workflow event types.

  Events are the primary mutation interface in the event-sourced workflow model.
  `Invokable.execute/2` produces events, and `Workflow.apply_event/2` folds them
  into the workflow graph as a pure function.
  """

  alias Runic.Workflow.Events.FactProduced
  alias Runic.Workflow.Events.ActivationConsumed
  alias Runic.Workflow.Events.ActivationSuppressed
  alias Runic.Workflow.Events.RunnableActivated
  alias Runic.Workflow.Events.ConditionSatisfied
  alias Runic.Workflow.Events.MapReduceTracked
  alias Runic.Workflow.Events.StateInitiated
  alias Runic.Workflow.Events.JoinFactReceived
  alias Runic.Workflow.Events.JoinCompleted
  alias Runic.Workflow.Events.JoinEdgeRelabeled
  alias Runic.Workflow.Events.FanOutFactEmitted
  alias Runic.Workflow.Events.FanInCompleted
  alias Runic.Workflow.RetryScheduled

  @type event ::
          FactProduced.t()
          | ActivationConsumed.t()
          | ActivationSuppressed.t()
          | RunnableActivated.t()
          | ConditionSatisfied.t()
          | MapReduceTracked.t()
          | StateInitiated.t()
          | JoinFactReceived.t()
          | JoinCompleted.t()
          | JoinEdgeRelabeled.t()
          | FanOutFactEmitted.t()
          | FanInCompleted.t()
          | RetryScheduled.t()

  @doc "Returns a `Runic.Workflow.Events.FactProduced` struct with its default field values."
  defdelegate fact_produced(), to: FactProduced, as: :__struct__

  @doc "Returns a `Runic.Workflow.Events.ActivationConsumed` struct with its default field values."
  defdelegate activation_consumed(), to: ActivationConsumed, as: :__struct__

  @doc "Returns a `Runic.Workflow.Events.ActivationSuppressed` struct with its default field values."
  defdelegate activation_suppressed(), to: ActivationSuppressed, as: :__struct__

  @doc "Returns a `Runic.Workflow.Events.RunnableActivated` struct with its default field values."
  defdelegate runnable_activated(), to: RunnableActivated, as: :__struct__

  @doc "Returns a `Runic.Workflow.Events.ConditionSatisfied` struct with its default field values."
  defdelegate condition_satisfied(), to: ConditionSatisfied, as: :__struct__

  @doc "Returns a `Runic.Workflow.Events.MapReduceTracked` struct with its default field values."
  defdelegate map_reduce_tracked(), to: MapReduceTracked, as: :__struct__

  @doc "Returns a `Runic.Workflow.Events.StateInitiated` struct with its default field values."
  defdelegate state_initiated(), to: StateInitiated, as: :__struct__

  @doc "Returns a `Runic.Workflow.Events.JoinFactReceived` struct with its default field values."
  defdelegate join_fact_received(), to: JoinFactReceived, as: :__struct__

  @doc "Returns a `Runic.Workflow.Events.JoinCompleted` struct with its default field values."
  defdelegate join_completed(), to: JoinCompleted, as: :__struct__

  @doc "Returns a `Runic.Workflow.Events.JoinEdgeRelabeled` struct with its default field values."
  defdelegate join_edge_relabeled(), to: JoinEdgeRelabeled, as: :__struct__

  @doc "Returns a `Runic.Workflow.Events.FanOutFactEmitted` struct with its default field values."
  defdelegate fan_out_fact_emitted(), to: FanOutFactEmitted, as: :__struct__

  @doc "Returns a `Runic.Workflow.Events.FanInCompleted` struct with its default field values."
  defdelegate fan_in_completed(), to: FanInCompleted, as: :__struct__
end
