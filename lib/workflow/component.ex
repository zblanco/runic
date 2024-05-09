defprotocol Runic.Component do
  @moduledoc """
  The Component protocol is implemented by datastructures which know how to become a Runic Workflow
    by implementing the `to_workflow/1` transformation.
  """
  @fallback_to_any true
  def to_workflow(component)
end

defimpl Runic.Component, for: List do
  alias Runic.Workflow

  def to_workflow([first_flowable | remaining_flowables]) do
    Enum.reduce(remaining_flowables, Runic.Component.to_workflow(first_flowable), fn flowable,
                                                                                     wrk ->
      Workflow.merge(wrk, Runic.Component.to_workflow(flowable))
    end)
  end
end

defimpl Runic.Component, for: Runic.Workflow do
  def to_workflow(wrk), do: wrk
end

defimpl Runic.Component, for: Runic.Workflow.Rule do
  def to_workflow(rule) do
    rule.workflow |> Map.put(:components, Map.put(rule.workflow.components, rule.name, rule))
  end
end

defimpl Runic.Component, for: Runic.Workflow.Step do
  alias Runic.Workflow
  require Runic

  def to_workflow(step),
    do: step.hash |> to_string() |> Workflow.new() |> Workflow.add_step(step)
end

defimpl Runic.Component, for: Tuple do
  alias Runic.Workflow.Rule

  def to_workflow({:fn, _meta, _clauses} = quoted_anonymous_function) do
    Runic.Component.to_workflow(Rule.new(quoted_anonymous_function))
  end
end

defimpl Runic.Component, for: Function do
  alias Runic.Workflow

  def to_workflow(fun) do
    fun |> Function.info(:name) |> elem(1) |> Workflow.new() |> Workflow.add_step(fun)
  end
end

defimpl Runic.Component, for: Any do
  alias Runic.Workflow

  def to_workflow(anything_else) do
    work = fn _anything -> anything_else end

    work
    |> Runic.Workflow.Components.work_hash()
    |> to_string()
    |> Workflow.new()
    |> Workflow.add_step(work)
  end
end

defimpl Runic.Component, for: Runic.Workflow.StateMachine do
  def to_workflow(%Runic.Workflow.StateMachine{} = fsm) do
    fsm.workflow |> Map.put(:components, Map.put(fsm.workflow.components, fsm.name, fsm))
  end
end
