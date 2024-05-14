defprotocol Runic.Transmutable do
  @moduledoc """
  The Component protocol is implemented by datastructures which know how to become a Runic Workflow
    by implementing the `transmute/1` transformation.
  """
  @fallback_to_any true
  def transmute(component)
end

defimpl Runic.Transmutable, for: List do
  alias Runic.Workflow

  def transmute([first_flowable | remaining_flowables]) do
    Enum.reduce(remaining_flowables, Runic.Transmutable.transmute(first_flowable), fn flowable,
                                                                                      wrk ->
      Workflow.merge(wrk, Runic.Transmutable.transmute(flowable))
    end)
  end
end

defimpl Runic.Transmutable, for: Runic.Workflow do
  def transmute(wrk), do: wrk
end

defimpl Runic.Transmutable, for: Runic.Workflow.Rule do
  def transmute(rule) do
    rule.workflow |> Map.put(:components, Map.put(rule.workflow.components, rule.name, rule))
  end
end

defimpl Runic.Transmutable, for: Runic.Workflow.Step do
  alias Runic.Workflow
  require Runic

  def transmute(step),
    do: step.hash |> to_string() |> Workflow.new() |> Workflow.add_step(step)
end

defimpl Runic.Transmutable, for: Tuple do
  alias Runic.Workflow.Rule

  def transmute({:fn, _meta, _clauses} = quoted_anonymous_function) do
    Runic.Transmutable.transmute(Rule.new(quoted_anonymous_function))
  end
end

defimpl Runic.Transmutable, for: Function do
  alias Runic.Workflow

  def transmute(fun) do
    fun |> Function.info(:name) |> elem(1) |> Workflow.new() |> Workflow.add_step(fun)
  end
end

defimpl Runic.Transmutable, for: Any do
  alias Runic.Workflow

  def transmute(anything_else) do
    work = fn _anything -> anything_else end

    work
    |> Runic.Workflow.Components.work_hash()
    |> to_string()
    |> Workflow.new()
    |> Workflow.add_step(work)
  end
end

defimpl Runic.Transmutable, for: Runic.Workflow.StateMachine do
  def transmute(%Runic.Workflow.StateMachine{} = fsm) do
    fsm.workflow |> Map.put(:components, Map.put(fsm.workflow.components, fsm.name, fsm))
  end
end
