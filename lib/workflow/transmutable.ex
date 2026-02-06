defprotocol Runic.Transmutable do
  @moduledoc """
  Protocol for converting data structures into Runic workflows or components.

  The `Transmutable` protocol enables natural integration of domain-specific data structures
  into Runic workflows. Any data type that implements this protocol can be converted to a
  `%Runic.Workflow{}` or a Runic component (Step, Rule, etc.).

  ## Protocol Functions

  | Function | Purpose |
  |----------|---------|
  | `transmute/1` | *Deprecated* - use `to_workflow/1` instead |
  | `to_workflow/1` | Converts data to a `%Runic.Workflow{}` |
  | `to_component/1` | Converts data to a Runic component (Step, Rule, etc.) |

  ## Built-in Implementations

  | Type | `to_workflow/1` Behavior | `to_component/1` Behavior |
  |------|-------------------------|--------------------------|
  | `Runic.Workflow` | Returns itself | Extracts first component or raises |
  | `Runic.Workflow.Rule` | Wraps rule in workflow | Returns the rule |
  | `Runic.Workflow.Step` | Wraps step in workflow | Returns the step |
  | `Runic.Workflow.StateMachine` | Wraps FSM in workflow | Returns the FSM |
  | `Function` | Creates workflow with function as step | Creates Step wrapping the function |
  | `List` | Merges transmuted elements | Recursively converts elements |
  | `Tuple` (AST) | Creates Rule from quoted function | Creates Rule from AST |
  | `Any` | Creates workflow with constant step | Creates Step returning the value |

  ## Usage

      require Runic
      alias Runic.Transmutable

      # Convert a function to workflow
      fn_workflow = Transmutable.to_workflow(fn x -> x * 2 end)

      # Convert a rule to workflow
      rule = Runic.rule(fn x when x > 0 -> :positive end)
      rule_workflow = Transmutable.to_workflow(rule)

      # Convert a list of components to merged workflow
      components = [
        Runic.step(fn x -> x + 1 end),
        Runic.step(fn x -> x * 2 end)
      ]
      merged_workflow = Transmutable.to_workflow(components)

      # Use the Runic.transmute/1 macro for convenient conversion
      workflow = Runic.transmute(fn x -> x * 2 end)

  ## Integration with Workflow.merge/2

  The `Transmutable` protocol integrates with `Workflow.merge/2`:

      workflow = Runic.Workflow.new()

      # Merge a rule (transmuted to workflow first)
      rule = Runic.rule(fn x when x > 0 -> :positive end)
      workflow = Workflow.merge(workflow, rule)

      # Merge a function directly
      workflow = Workflow.merge(workflow, fn x -> x * 2 end)

  ## Implementing Custom Transmutable

      defmodule MyApp.DataProcessor do
        defstruct [:name, :transform_fn]
      end

      defimpl Runic.Transmutable, for: MyApp.DataProcessor do
        alias Runic.Workflow

        def transmute(processor), do: to_workflow(processor)

        def to_workflow(%MyApp.DataProcessor{} = processor) do
          step = Runic.Workflow.Step.new(
            work: processor.transform_fn,
            name: processor.name
          )

          Workflow.new(name: processor.name)
          |> Workflow.add_step(step)
          |> Map.put(:components, %{processor.name => processor})
        end

        def to_component(%MyApp.DataProcessor{} = processor) do
          Runic.Workflow.Step.new(
            work: processor.transform_fn,
            name: processor.name
          )
        end
      end

  See the [Protocols Guide](protocols.html) for more details and examples.
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

defimpl Runic.Transmutable, for: Runic.Workflow.Condition do
  alias Runic.Workflow

  def transmute(condition), do: to_workflow(condition)

  def to_workflow(condition) do
    Workflow.new(to_string(condition.hash))
    |> Workflow.add(condition)
  end

  def to_component(condition), do: condition
end

defimpl Runic.Transmutable, for: Runic.Workflow.StateMachine do
  def transmute(fsm), do: to_workflow(fsm)

  def to_workflow(%Runic.Workflow.StateMachine{} = fsm) do
    fsm.workflow |> Map.put(:components, Map.put(fsm.workflow.components, fsm.name, fsm))
  end

  def to_component(fsm), do: fsm
end
