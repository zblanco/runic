defprotocol Runic.Component do
  @moduledoc """
  Protocol defining common behaviour of Runic components such as reflection, sub components or how the can be composed with others.
  """

  @doc """
  Get a sub component of a component by name.
  """
  def get_component(component, sub_component_name)

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

  # def remove(component, workflow)
end

defimpl Runic.Component, for: Runic.Workflow.Map do
  alias Runic.Workflow
  alias Runic.Workflow.Root

  def connect(
        %Runic.Workflow.Map{
          pipeline: pipeline_workflow,
          components: %{fan_out: fan_out} = components
        },
        to,
        workflow
      ) do
    wrk =
      workflow
      # only add top level fanout in cases with nested map expressions
      |> Workflow.add_step(to, fan_out)

    wrk =
      pipeline_workflow.graph
      |> Graph.edges()
      |> Enum.reduce(wrk, fn
        %{v1: %Root{}, v2: _fan_out}, wrk ->
          wrk

        %{v1: v1, v2: v2}, wrk ->
          Workflow.add_step(wrk, v1, v2)
      end)

    Enum.reduce(components, wrk, fn {name, component}, wrk ->
      Map.put(wrk, :components, Map.put(wrk.components, name, component))
    end)
  end

  def get_component(%Runic.Workflow.Map{components: components}, sub_component_name) do
    Map.get(components, sub_component_name)
  end

  def connectables(%Runic.Workflow.Map{} = map, _other_component) do
    components(map)
  end

  def components(%Runic.Workflow.Map{components: components}) do
    Keyword.new(components)
  end

  def connectable?(_component, _other_component) do
    true
  end

  def source(%Runic.Workflow.Map{source: source}) do
    source
  end

  def hash(map) do
    map.hash
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

  def connect(reduce, %Runic.Workflow.Map{components: components}, workflow) do
    wrk =
      workflow
      |> Workflow.add_step(components.leaf, reduce.fan_in)
      |> Workflow.draw_connection(components.fan_out, reduce.fan_in, :fan_in)

    path_to_fan_out =
      wrk.graph
      |> Graph.get_shortest_path(components.fan_out, reduce.fan_in)

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
    map = Workflow.get_component!(workflow, mapped)

    wrk =
      workflow
      |> Workflow.add_step(step, reduce.fan_in)
      |> Workflow.draw_connection(map.components.fan_out, reduce.fan_in, :fan_in)

    path_to_fan_out =
      wrk.graph
      |> Graph.get_shortest_path(map.components.fan_out, reduce.fan_in)

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

  def connect(reduce, to, workflow) do
    Workflow.add_step(workflow, to, reduce.fan_in)
  end

  def get_component(%Runic.Workflow.Reduce{fan_in: fan_in}, _kind) do
    fan_in
  end

  def components(reduce) do
    [fan_in: reduce]
  end

  def connectables(reduce, _other_component) do
    components(reduce)
  end

  def connectable?(_reduce, other_component) do
    case other_component do
      %Workflow.Map{} -> true
      %Workflow.Step{} -> true
      _otherwise -> false
    end
  end

  def source(reduce) do
    reduce.source
  end

  def hash(reduce) do
    reduce.hash
  end
end

defimpl Runic.Component, for: Runic.Workflow.Step do
  alias Runic.Workflow

  def components(step) do
    [step: step]
  end

  def connect(step, to, workflow) when is_list(to) do
    join =
      to
      |> Enum.map(& &1.hash)
      |> Workflow.Join.new()

    workflow
    |> Workflow.add_step(to, join)
    |> Workflow.add_step(join, step)
  end

  def connect(step, to, workflow) do
    Workflow.add_step(workflow, to, step)
  end

  def get_component(step, _kind) do
    step
  end

  def connectables(step, _other_component) do
    components(step)
  end

  def connectable?(_step, _other_component) do
    true
  end

  def source(step) do
    step.source
  end

  def hash(step) do
    step.hash
  end
end

defimpl Runic.Component, for: Runic.Workflow.Rule do
  alias Runic.Workflow
  alias Runic.Workflow.Step
  alias Runic.Workflow.Map
  alias Runic.Workflow.Reduce

  def connect(rule, _to, workflow) do
    Workflow.merge(workflow, rule.workflow)
  end

  def get_component(rule, :reaction) do
    rule.workflow.components |> Elixir.Map.values() |> List.first()
  end

  def components(rule) do
    [reaction: rule]
  end

  def connectables(rule, _other_component) do
    components(rule)
  end

  def connectable?(_rule, component) do
    case component do
      %Step{} -> true
      %Map{} -> true
      %Reduce{} -> true
      %Workflow{} -> true
      _otherwise -> false
    end
  end

  def source(rule) do
    rule.source
  end

  def hash(rule) do
    Runic.Workflow.Components.fact_hash(rule.source)
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

  def connectables(state_machine, _other_component) do
    components(state_machine)
  end

  def connectable?(_state_machine, _other_component) do
    true
  end

  def source(state_machine) do
    state_machine.source
  end

  def hash(state_machine) do
    state_machine.hash
  end
end
