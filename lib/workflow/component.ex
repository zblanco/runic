defprotocol Runic.Component do
  @moduledoc """
  Protocol defining common behaviour of Runic components such as reflection, sub components or how the can be composed with others.
  """

  # @doc """
  # Get a sub component of a component by name.
  # """
  # def get_component(component, sub_component_name)

  # @doc """
  # Get the sub component from the workflow by name.
  # """
  # def get_component(component, workflow, sub_component_name)

  @doc """
  List all connectable sub-components of a component.
  """
  def components(component)

  @doc """
  List compatible sub-components with the other component.
  """
  def connectables(component, other_component)

  @doc """
  Check if a component can be connected to another component.
  """
  def connectable?(component, other_component)

  def connect(component, to, workflow)

  @doc """
  Returns the source AST for building a component.
  """
  def source(component)

  def hash(component)

  @doc """
  Returns the nimble_options schema for component inputs.
  Schema is nested within subcomponent keys (e.g., :step, :condition, :fan_out).
  """
  def inputs(component)

  @doc """
  Returns the nimble_options schema for component outputs.
  Schema is nested within subcomponent keys (e.g., :step, :reaction, :leaf).
  """
  def outputs(component)

  # def remove(component, workflow)
end

# Type compatibility helper functions for Component protocol
defmodule Runic.Component.TypeCompatibility do
  @moduledoc false

  def types_compatible?(producer_type, consumer_type) do
    case {producer_type, consumer_type} do
      # Any type is compatible with anything
      {:any, _} ->
        true

      {_, :any} ->
        true

      # Exact type match
      {same, same} ->
        true

      # Lists are compatible if their element types are compatible
      {{:list, producer_elem}, {:list, consumer_elem}} ->
        types_compatible?(producer_elem, consumer_elem)

      # One_of types - check if there's overlap or compatibility
      {{:one_of, producer_opts}, {:one_of, consumer_opts}} ->
        # If any option in producer matches any option in consumer
        Enum.any?(producer_opts, fn p_opt ->
          Enum.any?(consumer_opts, fn c_opt -> types_compatible?(p_opt, c_opt) end)
        end)

      # One_of producer can match a specific consumer type
      {{:one_of, producer_opts}, consumer_type} ->
        Enum.any?(producer_opts, fn opt -> types_compatible?(opt, consumer_type) end)

      # Specific producer type can match one_of consumer
      {producer_type, {:one_of, consumer_opts}} ->
        Enum.any?(consumer_opts, fn opt -> types_compatible?(producer_type, opt) end)

      # Custom types - be optimistic and assume compatibility
      {{:custom, _, _, _}, _} ->
        true

      {_, {:custom, _, _, _}} ->
        true

      # Default to false for unhandled cases
      _ ->
        false
    end
  end

  def schemas_compatible?(producer_outputs, consumer_inputs) do
    # Find matching subcomponent keys and check type compatibility
    producer_keys = Keyword.keys(producer_outputs)
    consumer_keys = Keyword.keys(consumer_inputs)

    # Look for any matching keys with compatible types
    Enum.any?(producer_keys, fn p_key ->
      Enum.any?(consumer_keys, fn c_key ->
        # For now, keys don't need to match exactly - be lenient
        p_schema = Keyword.get(producer_outputs, p_key, [])
        c_schema = Keyword.get(consumer_inputs, c_key, [])

        p_type = Keyword.get(p_schema, :type, :any)
        c_type = Keyword.get(c_schema, :type, :any)

        types_compatible?(p_type, c_type)
      end)
    end)
  end
end

defimpl Runic.Component, for: Runic.Workflow.Map do
  alias Runic.Workflow
  alias Runic.Workflow.Root
  alias Runic.Workflow.Step
  # alias Runic.Workflow.Join

  def connect(
        %Runic.Workflow.Map{
          pipeline: pipeline_workflow
        } = map,
        to,
        workflow
      ) do
    fan_out_step =
      pipeline_workflow.graph
      |> Graph.out_neighbors(Workflow.root())
      |> List.first()

    wrk =
      workflow
      |> Workflow.add_step(to, fan_out_step)
      |> Workflow.register_component(map)
      |> Workflow.draw_connection(map, fan_out_step, :component_of, properties: %{kind: :fan_out})

    wrk =
      pipeline_workflow.graph
      |> Graph.edges()
      |> Enum.reduce(wrk, fn
        %{v1: %Root{}, v2: _fan_out}, wrk ->
          wrk

        %{v1: v1, v2: %Step{} = step, label: :flow}, wrk ->
          wrk =
            wrk
            |> Workflow.add_step(v1, step)
            |> Workflow.register_component(step)
            |> Workflow.draw_connection(step, step, :component_of, properties: %{kind: :step})

          if is_leaf?(wrk.graph, step) do
            Workflow.draw_connection(wrk, map, step, :component_of, properties: %{kind: :leaf})
          else
            wrk
          end

        # %{v1: %Runic.Workflow.FanOut{} = fan_out, v2: %Runic.Workflow.Map{} = nested_map} = edge, wrk ->

        #   Workflow.add(wrk, nested_map, to: fan_out.hash)

        %{v1: _v1, v2: %Runic.Workflow.Map{} = nested_map} = edge, wrk ->
          wrk = Map.put(wrk, :graph, Graph.add_edge(wrk.graph, edge))

          # Get the nested map's fan_out step
          nested_fan_out_step =
            nested_map.pipeline.graph
            |> Graph.out_neighbors(Workflow.root())
            |> List.first()

          wrk
          |> Workflow.register_component(nested_map)
          |> Workflow.draw_connection(nested_map, nested_fan_out_step, :component_of,
            properties: %{kind: :fan_out}
          )

        %{v1: _, v2: _} = edge, wrk ->
          # for non-components such as joins, just add the edge
          %Workflow{wrk | graph: Graph.add_edge(wrk.graph, edge)}
      end)

    %Workflow{
      wrk
      | mapped: %{
          workflow.mapped
          | mapped_paths:
              MapSet.union(workflow.mapped.mapped_paths, map.pipeline.mapped.mapped_paths)
        },
        components: Map.merge(wrk.components, map.pipeline.components),
        build_log: wrk.build_log ++ map.pipeline.build_log
    }
  end

  defp is_leaf?(g, v), do: g |> Graph.out_edges(v, by: :flow) |> Enum.count() == 0

  def get_component(%Runic.Workflow.Map{components: components}, sub_component_name) do
    Map.get(components, sub_component_name)
  end

  def get_component(
        %Runic.Workflow.Map{} = map,
        %Workflow{} = workflow,
        kind
      ) do
    case Graph.out_edges(workflow.graph, Map.get(workflow.graph.vertices, map.hash),
           by: :component_of,
           where: fn edge ->
             edge.properties[:kind] == kind
           end
         )
         |> List.first() do
      %{v2: component} -> component
      nil -> nil
    end
  end

  def connectables(%Runic.Workflow.Map{} = map, other_component) do
    # Filter components based on compatibility
    map
    |> components()
    |> Enum.filter(fn {_name, component} ->
      connectable?(component, other_component)
    end)
  end

  def components(%Runic.Workflow.Map{components: components}) do
    Keyword.new(components)
  end

  def connectable?(component, other_component) do
    # Use schema-based compatibility checking
    producer_outputs = outputs(component)
    consumer_inputs = Runic.Component.inputs(other_component)

    Runic.Component.TypeCompatibility.schemas_compatible?(producer_outputs, consumer_inputs)
  end

  def source(%Runic.Workflow.Map{closure: %Runic.Closure{} = closure}) do
    closure.source
  end

  def source(%Runic.Workflow.Map{closure: nil}) do
    nil
  end

  def hash(map) do
    map.hash
  end

  def inputs(%Runic.Workflow.Map{inputs: nil}) do
    # Default schema for maps without user-defined inputs
    [
      fan_out: [
        type: :any,
        doc: "Input data to be distributed across the map pipeline"
      ]
    ]
  end

  def inputs(%Runic.Workflow.Map{inputs: user_inputs}) do
    user_inputs
  end

  def outputs(%Runic.Workflow.Map{outputs: nil}) do
    [
      leaf: [
        type: {:custom, Runic.Components, :enumerable_type, []},
        doc: "Output result from a Runic map operation, typically a list of processed items"
      ]
    ]
  end

  def outputs(%Runic.Workflow.Map{outputs: user_outputs}) do
    user_outputs
  end

  # def remove(%Runic.Workflow.Map{pipeline: map_wrk} = map, workflow) do
  #   # for vertices in the map workflow, remove them but only if they're not also involved in separate components

  #   map_wrk.graph
  #   |> Graph.vertices()
  #   |> Enum.reduce(workflow, fn vertex, wrk ->
  #     case Graph.out_edges(wrk.graph, vertex) do

  #     end
  #   end)
  # end
end

defimpl Runic.Component, for: Runic.Workflow.Reduce do
  alias Runic.Workflow

  def connect(reduce, %Runic.Workflow.Map{} = map, workflow) do
    map_leaf = Workflow.get_component!(workflow, {map.name, :leaf}) |> List.first()

    if is_nil(map_leaf) do
      raise ArgumentError,
            "Cannot connect reduce to map #{map.name} because it has no leaf component. Ensure the map has a leaf component defined."
    end

    map_fan_out = Workflow.get_component!(workflow, {map.name, :fan_out}) |> List.first()

    wrk =
      workflow
      |> Workflow.draw_connection(map_leaf, reduce.fan_in, :flow)
      |> Workflow.register_component(reduce)
      |> Workflow.draw_connection(reduce, reduce.fan_in, :component_of,
        properties: %{kind: :fan_in}
      )
      |> Workflow.draw_connection(map_fan_out, reduce.fan_in, :fan_in)

    path_to_fan_out =
      wrk.graph
      |> Graph.get_shortest_path(map_fan_out, reduce.fan_in)

    wrk
    |> Map.put(
      :mapped,
      Map.put(
        wrk.mapped,
        :mapped_paths,
        Enum.reduce(path_to_fan_out, wrk.mapped.mapped_paths, fn node, mapset ->
          MapSet.put(mapset, node.hash)
        end)
      )
    )
  end

  def connect(%{fan_in: %{map: mapped}} = reduce, %Workflow.Step{} = step, workflow)
      when not is_nil(mapped) do
    map_fanout = Workflow.get_component!(workflow, {mapped, :fan_out}) |> List.first()

    wrk =
      workflow
      |> Workflow.add_step(step, reduce.fan_in)
      |> Workflow.register_component(reduce)
      |> Workflow.draw_connection(map_fanout, reduce.fan_in, :fan_in)
      |> Workflow.draw_connection(reduce, reduce.fan_in, :component_of,
        properties: %{kind: :fan_in}
      )

    path_to_fan_out =
      wrk.graph
      |> Graph.get_shortest_path(map_fanout, reduce.fan_in)

    wrk
    |> Map.put(
      :mapped,
      Map.put(
        wrk.mapped,
        :mapped_paths,
        Enum.reduce(path_to_fan_out, wrk.mapped.mapped_paths, fn node, mapset ->
          MapSet.put(mapset, node.hash)
        end)
      )
    )
  end

  def connect(reduce, to, workflow) when is_list(to) do
    join =
      to
      |> Enum.map(& &1.hash)
      |> Workflow.Join.new()

    workflow
    |> Workflow.add_step(to, join)
    |> Workflow.add_step(reduce.fan_in, join)
    |> Workflow.register_component(reduce)
    |> Workflow.draw_connection(reduce, reduce.fan_in, :component_of,
      properties: %{kind: :fan_in}
    )
  end

  def connect(reduce, to, workflow) do
    workflow
    |> Workflow.add_step(to, reduce.fan_in)
    |> Workflow.register_component(reduce)
    |> Workflow.draw_connection(reduce, reduce.fan_in, :component_of,
      properties: %{kind: :fan_in}
    )
  end

  def get_component(%Runic.Workflow.Reduce{fan_in: fan_in}, _kind) do
    fan_in
  end

  def get_component(%Runic.Workflow.Reduce{fan_in: fan_in}, _workflow, _kind) do
    fan_in
  end

  def components(reduce) do
    [fan_in: reduce.fan_in]
  end

  def connectables(reduce, other_component) do
    # Filter components based on compatibility
    reduce
    |> components()
    |> Enum.filter(fn {_name, component} ->
      connectable?(component, other_component)
    end)
  end

  def connectable?(reduce, other_component) do
    # Use schema-based compatibility checking with structural fallback
    producer_outputs = outputs(reduce)
    consumer_inputs = Runic.Component.inputs(other_component)

    schema_compatible =
      Runic.Component.TypeCompatibility.schemas_compatible?(producer_outputs, consumer_inputs)

    # Fallback to structural compatibility for known component types
    structural_compatible =
      case other_component do
        %Workflow.Map{} -> true
        %Workflow.Step{} -> true
        _otherwise -> false
      end

    schema_compatible or structural_compatible
  end

  def source(%Runic.Workflow.Reduce{closure: %Runic.Closure{} = closure}) do
    closure.source
  end

  def source(%Runic.Workflow.Reduce{closure: nil}) do
    nil
  end

  def hash(reduce) do
    reduce.hash
  end

  def inputs(%Runic.Workflow.Reduce{inputs: nil}) do
    # Default schema for reduces without user-defined inputs
    [
      fan_in: [
        type: {:custom, Runic.Components, :enumerable_type, []},
        doc: "Enumerable of values to be reduced"
      ]
    ]
  end

  def inputs(%Runic.Workflow.Reduce{inputs: user_inputs}) do
    user_inputs
  end

  def outputs(%Runic.Workflow.Reduce{outputs: nil}) do
    # Default schema for reduces without user-defined outputs
    [
      fan_in: [
        type: :any,
        doc: "Reduced value produced by the Runic.reduce operation"
      ]
    ]
  end

  def outputs(%Runic.Workflow.Reduce{outputs: user_outputs}) do
    user_outputs
  end
end

defimpl Runic.Component, for: Runic.Workflow.Step do
  alias Runic.Workflow
  alias Runic.Workflow.Reduce

  def components(step) do
    [step: step]
  end

  def connect(step, to, workflow) when is_list(to) do
    join =
      to
      |> Enum.map(fn
        %Reduce{fan_in: fan_in} -> fan_in.hash
        other -> other.hash
      end)
      |> Workflow.Join.new()

    wrk =
      Enum.reduce(to, workflow, fn
        %Reduce{fan_in: fan_in}, wrk -> Workflow.add_step(wrk, fan_in, join)
        other, wrk -> Workflow.add_step(wrk, other, join)
      end)

    wrk
    |> Workflow.add_step(join, step)
    |> Workflow.draw_connection(step, step, :component_of, properties: %{kind: :step})
    |> Workflow.register_component(step)
  end

  def connect(step, %Runic.Workflow.Rule{} = rule, workflow) do
    reaction = Map.get(workflow.graph.vertices, rule.reaction_hash)

    workflow
    |> Workflow.add_step(reaction, step)
    |> Workflow.draw_connection(step, step, :component_of, properties: %{kind: :step})
    |> Workflow.register_component(step)
  end

  def connect(step, to, workflow) do
    workflow
    |> Workflow.add_step(to, step)
    |> Workflow.draw_connection(step, step, :component_of, properties: %{kind: :step})
    |> Workflow.register_component(step)
  end

  def get_component(step, _kind) do
    step
  end

  def connectables(step, other_component) do
    # Filter components based on compatibility
    step
    |> components()
    |> Enum.filter(fn {_name, component} ->
      connectable?(component, other_component)
    end)
  end

  def connectable?(step, other_component) do
    # Use schema-based compatibility checking
    producer_outputs = outputs(step)
    consumer_inputs = Runic.Component.inputs(other_component)

    Runic.Component.TypeCompatibility.schemas_compatible?(producer_outputs, consumer_inputs)
  end

  def source(%Runic.Workflow.Step{closure: %Runic.Closure{} = closure}) do
    closure.source
  end

  def source(%Runic.Workflow.Step{closure: nil}) do
    nil
  end

  def hash(step) do
    step.hash
  end

  def inputs(%Runic.Workflow.Step{inputs: nil}) do
    # Default schema for steps without user-defined inputs
    [
      step: [
        type: :any,
        doc: "Input value to be processed by the step function"
      ]
    ]
  end

  def inputs(%Runic.Workflow.Step{inputs: user_inputs}) do
    user_inputs
  end

  def outputs(%Runic.Workflow.Step{outputs: nil}) do
    # Default schema for steps without user-defined outputs
    [
      step: [
        type: :any,
        doc: "Output value produced by the step function"
      ]
    ]
  end

  def outputs(%Runic.Workflow.Step{outputs: user_outputs}) do
    user_outputs
  end
end

defimpl Runic.Component, for: Runic.Workflow.Rule do
  alias Runic.Workflow
  alias Runic.Workflow.Step
  alias Runic.Workflow.Reduce

  def connect(rule, to, workflow) when to in [nil, %Runic.Workflow.Root{}] do
    wrk = Workflow.merge(workflow, rule.workflow)

    condition = Map.get(rule.workflow.graph.vertices, rule.condition_hash)
    reaction = Map.get(rule.workflow.graph.vertices, rule.reaction_hash)

    wrk
    |> Workflow.register_component(rule)
    |> Workflow.draw_connection(rule, reaction, :component_of, properties: %{kind: :reaction})
    |> Workflow.draw_connection(rule, condition, :component_of, properties: %{kind: :condition})
  end

  def connect(rule, to, workflow) do
    condition = Map.get(rule.workflow.graph.vertices, rule.condition_hash)
    reaction = Map.get(rule.workflow.graph.vertices, rule.reaction_hash)

    workflow
    |> Workflow.add_step(to, condition)
    |> Workflow.add_step(condition, reaction)
    |> Workflow.register_component(rule)
    |> Workflow.draw_connection(rule, reaction, :component_of, properties: %{kind: :reaction})
    |> Workflow.draw_connection(rule, condition, :component_of, properties: %{kind: :condition})
  end

  def get_component(rule, :reaction) do
    Map.get(rule.workflow.graph.vertices, rule.reaction_hash)
  end

  def get_component(rule, :condition) do
    Map.get(rule.workflow.graph.vertices, rule.condition_hash)
  end

  def components(rule) do
    condition = Map.get(rule.workflow.graph.vertices, rule.condition_hash)
    reaction = Map.get(rule.workflow.graph.vertices, rule.reaction_hash)

    [condition: condition, reaction: reaction]
  end

  def connectables(rule, other_component) do
    # Filter components based on compatibility
    rule
    |> components()
    |> Enum.filter(fn {_name, component} ->
      connectable?(component, other_component)
    end)
  end

  def connectable?(rule, other_component) do
    # Use schema-based compatibility checking with structural fallback
    producer_outputs = outputs(rule)
    consumer_inputs = Runic.Component.inputs(other_component)

    schema_compatible =
      Runic.Component.TypeCompatibility.schemas_compatible?(producer_outputs, consumer_inputs)

    # Fallback to structural compatibility for known component types
    structural_compatible =
      case other_component do
        %Step{} -> true
        %Runic.Workflow.Map{} -> true
        %Reduce{} -> true
        %Workflow{} -> true
        _otherwise -> false
      end

    schema_compatible or structural_compatible
  end

  def source(%Runic.Workflow.Rule{closure: %Runic.Closure{} = closure}) do
    closure.source
  end

  def source(%Runic.Workflow.Rule{closure: nil}) do
    nil
  end

  def hash(rule) do
    rule.hash
  end

  def inputs(%Runic.Workflow.Rule{inputs: nil}) do
    # Default schema for rules without user-defined inputs
    [
      condition: [
        type: :any,
        doc: "Input value to be evaluated by the rule condition"
      ]
    ]
  end

  def inputs(%Runic.Workflow.Rule{inputs: user_inputs}) do
    user_inputs
  end

  def outputs(%Runic.Workflow.Rule{outputs: nil}) do
    # Default schema for rules without user-defined outputs
    [
      reaction: [
        type: :any,
        doc: "Output value produced by the rule reaction when condition matches"
      ]
    ]
  end

  def outputs(%Runic.Workflow.Rule{outputs: user_outputs}) do
    user_outputs
  end
end

defimpl Runic.Component, for: Runic.Workflow.StateMachine do
  alias Runic.Workflow.MemoryAssertion
  alias Runic.Workflow
  alias Runic.Workflow.Accumulator
  alias Runic.Workflow.Step
  alias Runic.Workflow.Root

  def connect(state_machine, %Root{}, workflow) do
    state_machine.workflow.graph
    |> Graph.edges(by: :flow)
    |> Enum.reduce(workflow, fn edge, wrk ->
      %Workflow{wrk | graph: Graph.add_edge(wrk.graph, edge)}
    end)
    |> Map.put(:components, Map.merge(state_machine.workflow.components, workflow.components))
  end

  def connect(state_machine, to, workflow) do
    accumulator =
      state_machine.workflow.graph
      |> Graph.vertices()
      |> Enum.find(&match?(%Accumulator{}, &1))

    wrk = Workflow.add_step(workflow, to, accumulator)

    state_machine.workflow.graph
    |> Graph.edges(by: :flow)
    |> Enum.reduce(wrk, fn edge, wrk ->
      case edge do
        %{v2: v2, v1: v1} = edge
        when is_struct(v2, StateReaction) or is_struct(v2, MemoryAssertion) or
               (is_struct(v1, StateReaction) or is_struct(v1, MemoryAssertion)) ->
          %Workflow{wrk | graph: Graph.add_edge(wrk.graph, edge)}

        _otherwise ->
          wrk
      end
    end)
  end

  # def connect(state_machine, to, workflow) do
  #   wrk = Runic.transmute(state_machine)

  #   # create a memory assertion to ensure that the state machine only reacts to facts producted by `to` parent step

  #   # put memory assertion in conjunction with state conditions

  #   # attach rewritten tree to root of into workflow

  #   memory_assertion_fun_ast =
  #     quote do
  #       fn
  #         _workflow, %Fact{ancestry: {parent_step_hash, _pfh}} ->
  #           parent_step_hash == unquote(to.hash)

  #         _workflow, _ ->
  #           false
  #       end
  #     end

  #   memory_assertion =
  #     MemoryAssertion.new(
  #       memory_assertion: fn
  #         _workflow, %Fact{ancestry: {parent_step_hash, _pfh}} ->
  #           parent_step_hash == to.hash

  #         _workflow, _ ->
  #           false
  #       end,
  #       hash: Runic.Workflow.Components.fact_hash(memory_assertion_fun_ast)
  #     )

  #   wrk =
  #     wrk
  #     |> Workflow.add_step(memory_assertion)

  #   wrk.graph
  #   |> Graph.edges(by: :flow)
  #   |> Enum.reduce(workflow, fn
  #     %Graph.Edge{v1: %Root{}, v2: %StateCondition{} = v2}, acc ->
  #       conjunction =
  #         Workflow.Conjunction.new([
  #           v2,
  #           memory_assertion
  #         ])

  #       next_accumulators =
  #         Workflow.next_steps(wrk, v2)

  #       acc =
  #         acc
  #         |> Workflow.add_step(v2)
  #         |> Workflow.add_step(v2, conjunction)
  #         |> Workflow.add_step(memory_assertion, conjunction)

  #       Enum.reduce(next_accumulators, acc, fn
  #         next_acc, acc ->
  #           Workflow.add_step(acc, conjunction, next_acc)
  #       end)

  #     %Graph.Edge{v1: %StateCondition{}, v2: %Accumulator{}}, acc ->
  #       acc

  #     %Graph.Edge{} = edge, acc ->
  #       g = Graph.add_edge(acc.graph, edge)
  #       %Workflow{acc | graph: g}
  #   end)
  #   |> Map.put(:components, Map.merge(wrk.components, workflow.components))
  # end

  def get_component(state_machine, :reducer) do
    state_machine.workflow.graph
    |> Graph.vertices()
    |> Enum.filter(&match?(%Runic.Workflow.Accumulator{}, &1))
    |> List.first()
  end

  def components(state_machine) do
    vertices = state_machine.workflow.graph |> Graph.vertices()

    [
      reactors: vertices |> Enum.filter(&match?(%Step{}, &1)),
      accumulator: vertices |> Enum.filter(&match?(%Accumulator{}, &1)) |> List.first()
    ]
  end

  def connectables(state_machine, other_component) do
    # Filter components based on compatibility
    state_machine
    |> components()
    |> Enum.filter(fn {_name, component} ->
      connectable?(component, other_component)
    end)
  end

  def connectable?(state_machine, other_component) do
    # Use schema-based compatibility checking
    producer_outputs = outputs(state_machine)
    consumer_inputs = Runic.Component.inputs(other_component)

    Runic.Component.TypeCompatibility.schemas_compatible?(producer_outputs, consumer_inputs)
  end

  def source(state_machine) do
    state_machine.source
  end

  def hash(state_machine) do
    state_machine.hash
  end

  def inputs(%Runic.Workflow.StateMachine{inputs: nil}) do
    # Default schema for state machines without user-defined inputs
    [
      reactors: [
        type: {:list, :any},
        doc: "Input events or data to trigger state transitions"
      ]
    ]
  end

  def inputs(%Runic.Workflow.StateMachine{inputs: user_inputs}) do
    user_inputs
  end

  def outputs(%Runic.Workflow.StateMachine{outputs: nil}) do
    # Default schema for state machines without user-defined outputs
    [
      accumulator: [
        type: :any,
        doc: "Current state value maintained by the state machine"
      ]
    ]
  end

  def outputs(%Runic.Workflow.StateMachine{outputs: user_outputs}) do
    user_outputs
  end
end

defimpl Runic.Component, for: Runic.Workflow.Accumulator do
  alias Runic.Workflow

  def components(accumulator) do
    [accumulator: accumulator]
  end

  def connect(accumulator, to, workflow) when is_list(to) do
    join =
      to
      |> Enum.map(& &1.hash)
      |> Workflow.Join.new()

    workflow
    |> Workflow.add_step(to, join)
    |> Workflow.add_step(join, accumulator)
    |> Workflow.draw_connection(accumulator, accumulator, :component_of,
      properties: %{kind: :accumulator}
    )
  end

  def connect(accumulator, to, workflow) do
    workflow
    |> Workflow.add_step(to, accumulator)
    |> Workflow.draw_connection(accumulator, accumulator, :component_of,
      properties: %{kind: :accumulator}
    )
    |> Workflow.register_component(accumulator)
  end

  def get_component(accumulator, _kind) do
    accumulator
  end

  def connectables(accumulator, other_component) do
    # Filter components based on compatibility
    accumulator
    |> components()
    |> Enum.filter(fn {_name, component} ->
      connectable?(component, other_component)
    end)
  end

  def connectable?(accumulator, other_component) do
    # Use schema-based compatibility checking
    producer_outputs = outputs(accumulator)
    consumer_inputs = Runic.Component.inputs(other_component)

    Runic.Component.TypeCompatibility.schemas_compatible?(producer_outputs, consumer_inputs)
  end

  def source(%Runic.Workflow.Accumulator{closure: %Runic.Closure{} = closure}) do
    closure.source
  end

  def source(%Runic.Workflow.Accumulator{closure: nil}) do
    nil
  end

  def hash(accumulator) do
    accumulator.hash
  end

  def inputs(%Runic.Workflow.Accumulator{inputs: nil}) do
    # Default schema for accumulators without user-defined inputs
    [
      accumulator: [
        type: :any,
        doc: "Input value to be accumulated with the current state"
      ]
    ]
  end

  def inputs(%Runic.Workflow.Accumulator{inputs: user_inputs}) do
    user_inputs
  end

  def outputs(%Runic.Workflow.Accumulator{outputs: nil}) do
    # Default schema for accumulators without user-defined outputs
    [
      accumulator: [
        type: :any,
        doc: "Accumulated value after applying the reducer function"
      ]
    ]
  end

  def outputs(%Runic.Workflow.Accumulator{outputs: user_outputs}) do
    user_outputs
  end
end

defimpl Runic.Component, for: Runic.Workflow do
  alias Runic.Workflow
  alias Runic.Workflow.Fact

  def connect(%Workflow{} = child_workflow, parent_component, workflow) do
    new_graph =
      child_workflow.graph
      |> Graph.edges()
      |> Enum.reduce(workflow.graph, fn
        %{v1: %Runic.Workflow.Root{}, v2: _} = edge, g ->
          new_edge = %Graph.Edge{edge | v1: parent_component}
          Graph.add_edge(g, new_edge)

        # handle reaction memory edges to override with latest history
        %{v1: %Fact{} = fact_v1, v2: v2, label: label} = edge, g
        when label in [:matchable, :runnable, :ran] ->
          out_edge_labels_of_into_mem_for_edge =
            g
            |> Graph.out_edges(fact_v1)
            |> Enum.filter(&(&1.v2 == v2))
            |> MapSet.new(& &1.label)

          cond do
            label in [:matchable, :runnable] and
                MapSet.member?(out_edge_labels_of_into_mem_for_edge, :ran) ->
              g

            label == :ran and
                MapSet.member?(out_edge_labels_of_into_mem_for_edge, :runnable) ->
              Graph.update_labelled_edge(g, fact_v1, v2, :runnable, label: :ran)

            true ->
              Graph.add_edge(g, edge)
          end

        edge, g ->
          Graph.add_edge(g, edge)
      end)

    %Workflow{
      workflow
      | graph: new_graph,
        mapped: %{
          workflow.mapped
          | mapped_paths:
              MapSet.union(workflow.mapped.mapped_paths, child_workflow.mapped.mapped_paths)
        },
        before_hooks: Map.merge(workflow.before_hooks, child_workflow.before_hooks),
        after_hooks: Map.merge(workflow.after_hooks, child_workflow.after_hooks),
        components: Map.merge(workflow.components, child_workflow.components),
        inputs: Map.merge(workflow.inputs, child_workflow.inputs),
        build_log: workflow.build_log ++ child_workflow.build_log
    }
  end

  def get_component(%Workflow{} = workflow, sub_component_name) do
    Workflow.get_component(workflow, sub_component_name)
  end

  def get_component(%Workflow{} = workflow, %Workflow{}, sub_component_name) do
    get_component(workflow, sub_component_name)
  end

  def components(%Workflow{components: components}) do
    Enum.map(components, fn {name, _hash} -> {name, name} end)
  end

  def connectables(%Workflow{} = workflow, _other_component) do
    components(workflow)
  end

  def connectable?(%Workflow{}, _other_component), do: true

  def source(%Workflow{} = workflow) do
    quote do
      %Runic.Workflow{
        name: unquote(workflow.name),
        components: unquote(Macro.escape(workflow.components))
      }
    end
  end

  def hash(%Workflow{hash: hash}) when not is_nil(hash), do: hash

  def hash(%Workflow{} = workflow) do
    Runic.Workflow.Components.fact_hash(workflow)
  end

  def inputs(%Workflow{}), do: []

  def outputs(%Workflow{}), do: []
end

defimpl Runic.Component, for: Tuple do
  def connect({parent, children} = _pipeline, parent_component_in_workflow, workflow)
      when is_list(children) do
    # Connect the parent component to each child component
    wrk = Runic.Workflow.add_step(workflow, parent_component_in_workflow, parent)

    Enum.reduce(children, wrk, fn child, acc ->
      Runic.Component.connect(child, parent, acc)
    end)
  end

  def get_component(_tuple, _sub_component_name), do: nil
  def get_component(_tuple, _workflow, _sub_component_name), do: nil
  def components(_tuple), do: []
  def connectables(_tuple, _other_component), do: []
  def connectable?(_tuple, _other_component), do: false
  def source(tuple), do: Macro.escape(tuple)
  def inputs(_tuple), do: []
  def outputs(_tuple), do: []

  def hash(pipeline) do
    Runic.Workflow.Components.fact_hash(pipeline)
  end
end
