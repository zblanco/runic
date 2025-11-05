defprotocol Runic.Transmutable do
  @moduledoc """
  The Transmutable protocol is implemented by datastructures which know how to become a Runic Workflow
    or Component through transformations.
  """
  @fallback_to_any true

  @doc """
  DEPRECATED: Use to_workflow/1 instead.
  Converts a component to a Runic Workflow.
  """
  def transmute(component)

  @doc """
  Converts a component to a Runic Workflow.
  """
  def to_workflow(component)

  @doc """
  Converts user data to a Runic component.
  """
  def to_component(component)
end

defimpl Runic.Transmutable, for: List do
  alias Runic.Workflow

  def transmute(list), do: to_workflow(list)

  def to_workflow([first_flowable | remaining_flowables]) do
    Enum.reduce(remaining_flowables, Runic.Transmutable.to_workflow(first_flowable), fn flowable,
                                                                                        wrk ->
      Workflow.merge(wrk, Runic.Transmutable.to_workflow(flowable))
    end)
  end

  def to_component(list) when is_list(list) do
    # Convert list to a composite workflow component
    case list do
      [single_item] ->
        Runic.Transmutable.to_component(single_item)

      multiple_items ->
        # Create a list processor step
        Runic.Workflow.Step.new(
          work: fn _input -> Enum.map(multiple_items, &Runic.Transmutable.to_component/1) end,
          name: "list_processor"
        )
    end
  end
end

defimpl Runic.Transmutable, for: Runic.Workflow do
  def transmute(wrk), do: wrk
  def to_workflow(wrk), do: wrk

  def to_component(wrk) do
    # Workflows can't be converted directly to components
    # Return the first component from the workflow if available
    case wrk.components |> Map.values() |> List.first() do
      nil -> raise ArgumentError, "Cannot convert empty workflow to component"
      component -> component
    end
  end
end

defimpl Runic.Transmutable, for: Runic.Workflow.Rule do
  def transmute(rule), do: to_workflow(rule)

  def to_workflow(rule) do
    rule.workflow |> Map.put(:components, Map.put(rule.workflow.components, rule.name, rule))
  end

  def to_component(rule), do: rule
end

defimpl Runic.Transmutable, for: Runic.Workflow.Step do
  alias Runic.Workflow
  require Runic

  def transmute(step), do: to_workflow(step)

  def to_workflow(step),
    do: step.hash |> to_string() |> Workflow.new() |> Workflow.add_step(step)

  def to_component(step), do: step
end

defimpl Runic.Transmutable, for: Tuple do
  alias Runic.Workflow.Rule

  def transmute(tuple), do: to_workflow(tuple)

  def to_workflow({:fn, _meta, _clauses} = quoted_anonymous_function) do
    Runic.Transmutable.to_workflow(Rule.new(quoted_anonymous_function))
  end

  def to_component({:fn, _meta, _clauses} = _quoted_anonymous_function) do
    # For AST, just create a rule with no closure (old format)
    Rule.new(closure: nil, arity: 1)
  end
end

defimpl Runic.Transmutable, for: Function do
  alias Runic.Workflow

  def transmute(fun), do: to_workflow(fun)

  def to_workflow(fun) do
    fun |> Function.info(:name) |> elem(1) |> Workflow.new() |> Workflow.add_step(fun)
  end

  def to_component(fun) do
    Runic.Workflow.Step.new(work: fun)
  end
end

defimpl Runic.Transmutable, for: Any do
  require Runic
  alias Runic.Workflow

  def transmute(anything_else), do: to_workflow(anything_else)

  def to_workflow(anything_else) do
    work = fn _anything -> anything_else end

    work
    |> Runic.Workflow.Components.work_hash()
    |> to_string()
    |> Workflow.new()
    |> Workflow.add_step(work)
  end

  def to_component(%{type: :map_reduce, mapper: mapper} = spec) do
    # Handle map-reduce component specification - create a Map struct
    name = Map.get(spec, :name, "map_reduce_component")

    # Create a simple pipeline workflow with just the mapper step
    pipeline_step = Runic.Workflow.Step.new(work: mapper)

    pipeline =
      Runic.Workflow.new()
      |> Runic.Workflow.add_step(pipeline_step)

    %Runic.Workflow.Map{
      name: name,
      hash: name |> to_string() |> :erlang.phash2(),
      pipeline: pipeline,
      components: %{},
      closure: nil,
      inputs: nil,
      outputs: nil
    }
  end

  def to_component(%{type: :custom_processor, function: fun, metadata: %{name: name}} = _spec) do
    # Handle custom processor with metadata
    Runic.Workflow.Step.new(work: fun, name: name)
  end

  def to_component(fun) when is_function(fun) do
    # Handle plain functions
    Runic.Workflow.Step.new(work: fun)
  end

  def to_component(anything_else) do
    # Fallback for other data
    Runic.Workflow.Step.new(work: fn _anything -> anything_else end)
  end
end

defimpl Runic.Transmutable, for: Runic.Workflow.StateMachine do
  def transmute(fsm), do: to_workflow(fsm)

  def to_workflow(%Runic.Workflow.StateMachine{} = fsm) do
    fsm.workflow |> Map.put(:components, Map.put(fsm.workflow.components, fsm.name, fsm))
  end

  def to_component(fsm), do: fsm
end
