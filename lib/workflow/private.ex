defmodule Runic.Workflow.Private do
  @moduledoc false
  # Internal implementation functions for Runic.Workflow.
  # These are not part of the public API and may change without notice.

  alias Runic.Workflow
  alias Runic.Workflow.Root
  alias Runic.Workflow.Step
  alias Runic.Workflow.Condition
  alias Runic.Workflow.Fact
  alias Runic.Workflow.Rule
  alias Runic.Workflow.FanOut
  alias Runic.Workflow.FanIn
  alias Runic.Workflow.Join
  alias Runic.Workflow.Invokable
  alias Runic.Component

  # =============================================================================
  # Graph wiring / component registration
  # =============================================================================

  def root(), do: %Root{}

  def register_component(%Workflow{} = workflow, component) do
    hash = Component.hash(component)

    workflow =
      %Workflow{
        workflow
        | components: Map.put(workflow.components, component.name, hash)
      }

    case component do
      %Runic.Workflow.Map{components: map_components, name: map_name}
      when not is_nil(map_components) ->
        Enum.reduce(map_components, workflow, fn {sub_name, sub_component}, acc ->
          case sub_name do
            :fan_out ->
              components = Map.put(acc.components, {map_name, :fan_out}, sub_component.hash)
              %Workflow{acc | components: components}

            _ ->
              acc
          end
        end)

      _ ->
        workflow
    end
  end

  def maybe_put_component(
        %Workflow{components: components} = workflow,
        %FanOut{name: name} = step
      ) do
    %Workflow{
      workflow
      | components: Map.put(components, name, step)
    }
  end

  def maybe_put_component(
        %Workflow{components: components} = workflow,
        %{name: name} = step
      ) do
    %Workflow{
      workflow
      | components: Map.put(components, name, step)
    }
  end

  def maybe_put_component(%Workflow{} = workflow, %FanIn{map: nil}) do
    workflow
  end

  def maybe_put_component(%Workflow{} = workflow, %{} = _step), do: workflow

  def draw_connection(%Workflow{graph: g} = wrk, node_1, node_2, connection, opts \\ []) do
    opts = Keyword.put(opts, :label, connection)
    %Workflow{wrk | graph: Graph.add_edge(g, node_1, node_2, opts)}
  end

  def add_dependent_steps(workflow, {parent_step, dependent_steps}) do
    Enum.reduce(dependent_steps, workflow, fn
      {[_step | _] = parent_steps, dependent_steps}, wrk ->
        wrk =
          Enum.reduce(parent_steps, wrk, fn step, wrk ->
            Workflow.add(wrk, step, to: parent_step)
          end)

        join =
          parent_steps
          |> Enum.map(& &1.hash)
          |> Join.new()

        wrk = add_step(wrk, parent_steps, join)

        add_dependent_steps(wrk, {join, dependent_steps})

      {%Join{} = step, _dependent_steps} = parent_and_children, wrk ->
        wrk = add_step(wrk, parent_step, step)
        add_dependent_steps(wrk, parent_and_children)

      {step, _dependent_steps} = parent_and_children, wrk ->
        wrk = Workflow.add(wrk, step, to: parent_step)
        add_dependent_steps(wrk, parent_and_children)

      step, wrk ->
        Workflow.add(wrk, step, to: parent_step)
    end)
  end

  def add_step(%Workflow{} = workflow, child_step) when is_function(child_step) do
    add_step(workflow, %Root{}, Step.new(work: child_step))
  end

  def add_step(%Workflow{} = workflow, child_step) do
    add_step(workflow, %Root{}, child_step)
  end

  def add_step(%Workflow{graph: g} = workflow, %Root{}, %Condition{} = child_step) do
    %Workflow{
      workflow
      | graph:
          g
          |> Graph.add_vertex(child_step, child_step.hash)
          |> Graph.add_edge(%Root{}, child_step, label: :flow, weight: 0)
    }
  end

  def add_step(%Workflow{graph: g} = workflow, %Root{}, %{} = child_step) do
    %Workflow{
      workflow
      | graph:
          g
          |> Graph.add_vertex(child_step, child_step.hash)
          |> Graph.add_edge(%Root{}, child_step, label: :flow, weight: 0)
    }
  end

  def add_step(
        %Workflow{} = workflow,
        %{} = parent_step,
        {child_step, grand_child_steps}
      ) do
    Enum.reduce(
      grand_child_steps,
      add_step(workflow, parent_step, child_step),
      fn grand_child_step, wrk -> add_step(wrk, child_step, grand_child_step) end
    )
  end

  def add_step(
        %Workflow{} = workflow,
        {%FanOut{}, [%Step{} = map_step]},
        child_step
      ) do
    add_step(workflow, map_step, child_step)
  end

  def add_step(%Workflow{graph: g} = workflow, %{} = parent_step, %{} = child_step) do
    %Workflow{
      workflow
      | graph:
          g
          |> Graph.add_vertex(child_step, to_string(child_step.hash))
          |> Graph.add_edge(parent_step, child_step, label: :flow, weight: 0)
    }
  end

  def add_step(%Workflow{} = workflow, parent_steps, %{} = child_step)
      when is_list(parent_steps) do
    Enum.reduce(parent_steps, workflow, fn parent_step, wrk ->
      add_step(wrk, parent_step, child_step)
    end)
  end

  def add_step(%Workflow{} = workflow, parent_step_name, child_step)
      when is_atom(parent_step_name) or is_binary(parent_step_name) do
    add_step(workflow, Workflow.get_component!(workflow, parent_step_name), child_step)
  end

  def add_rule(
        %Workflow{} = workflow,
        %Rule{} = rule
      ) do
    Workflow.add(workflow, rule)
  end

  def mark_runnable_as_ran(%Workflow{graph: graph} = workflow, step, fact) do
    graph =
      case Graph.update_labelled_edge(graph, fact, step, connection_for_activatable(step),
             label: :ran
           ) do
        %Graph{} = graph -> graph
        {:error, :no_such_edge} -> graph
      end

    %Workflow{
      workflow
      | graph: graph
    }
  end

  def satisfied_condition_hashes(%Workflow{graph: graph}, %Fact{} = fact) do
    for %Graph.Edge{} = edge <- Graph.out_edges(graph, fact, by: :satisfied),
        do: edge.v2.hash
  end

  def matches(%Workflow{graph: graph}) do
    for %Graph.Edge{} = edge <- Graph.edges(graph, by: [:matchable, :satisfied]) do
      edge.v2
    end
  end

  def log_fact(%Workflow{graph: graph} = wrk, %Fact{} = fact) do
    %Workflow{
      wrk
      | graph: Graph.add_vertex(graph, fact)
    }
  end

  # =============================================================================
  # Hooks
  # =============================================================================

  def add_before_hooks(%Workflow{} = workflow, nil), do: workflow

  def add_before_hooks(%Workflow{} = workflow, hooks) do
    %Workflow{
      workflow
      | before_hooks:
          Enum.reduce(hooks, workflow.before_hooks, fn
            {name, hook}, acc when is_function(hook, 3) ->
              node = resolve_component_to_node(workflow, name)
              node_hash = node.hash
              hooks_for_component = Map.get(acc, node_hash, [])
              Map.put(acc, node_hash, Enum.reverse([hook | hooks_for_component]))

            {name, hooks}, acc when is_list(hooks) ->
              node = resolve_component_to_node(workflow, name)
              node_hash = node.hash
              hooks_for_component = Map.get(acc, node_hash, [])
              Map.put(acc, node_hash, hooks ++ hooks_for_component)
          end)
    }
  end

  def add_after_hooks(%Workflow{} = workflow, nil), do: workflow

  def add_after_hooks(%Workflow{} = workflow, hooks) do
    %Workflow{
      workflow
      | after_hooks:
          Enum.reduce(hooks, workflow.after_hooks, fn
            {name, hook}, acc when is_function(hook, 3) ->
              node = resolve_component_to_node(workflow, name)
              node_hash = node.hash
              hooks_for_component = Map.get(acc, node_hash, [])
              Map.put(acc, node_hash, Enum.reverse([hook | hooks_for_component]))

            {name, hooks}, acc when is_list(hooks) ->
              node = resolve_component_to_node(workflow, name)
              node_hash = node.hash
              hooks_for_component = Map.get(acc, node_hash, [])
              Map.put(acc, node_hash, hooks ++ hooks_for_component)
          end)
    }
  end

  def run_before_hooks(%Workflow{} = workflow, %{hash: hash} = step, input_fact) do
    case get_before_hooks(workflow, hash) do
      nil ->
        workflow

      hooks ->
        Enum.reduce(hooks, workflow, fn hook, wrk -> hook.(step, wrk, input_fact) end)
    end
  end

  def run_before_hooks(%Workflow{} = workflow, _step, _input_fact), do: workflow

  def run_after_hooks(%Workflow{} = workflow, %{hash: hash} = step, output_fact) do
    case get_after_hooks(workflow, hash) do
      nil ->
        workflow

      hooks ->
        Enum.reduce(hooks, workflow, fn hook, wrk -> hook.(step, wrk, output_fact) end)
    end
  end

  def run_after_hooks(%Workflow{} = workflow, _step, _input_fact), do: workflow

  def get_hooks(%Workflow{before_hooks: before, after_hooks: after_hooks}, node_hash) do
    {Map.get(before, node_hash, []), Map.get(after_hooks, node_hash, [])}
  end

  # =============================================================================
  # Private hook helpers
  # =============================================================================

  defp resolve_component_to_node(%Workflow{} = workflow, {component_name, sub_component_kind}) do
    Workflow.get_component(workflow, {component_name, sub_component_kind}) |> List.first()
  end

  defp resolve_component_to_node(%Workflow{} = workflow, component_name)
       when is_atom(component_name) or is_binary(component_name) do
    Workflow.get_component!(workflow, component_name)
  end

  defp resolve_component_to_node(%Workflow{graph: g}, hash) when is_integer(hash) do
    Map.get(g.vertices, hash)
  end

  defp get_before_hooks(%Workflow{} = workflow, hash) do
    Map.get(workflow.before_hooks, hash)
  end

  defp get_after_hooks(%Workflow{} = workflow, hash) do
    Map.get(workflow.after_hooks, hash)
  end

  # =============================================================================
  # Three-phase internals / planning
  # =============================================================================

  def prepare_next_runnables(%Workflow{} = workflow, node, fact) do
    workflow
    |> Workflow.next_steps(node)
    |> Enum.reduce(workflow, fn step, wrk ->
      draw_connection(wrk, fact, step, connection_for_activatable(step))
    end)
  end

  @doc false
  def prepare_next_generation(%Workflow{} = workflow, %Fact{}), do: workflow

  def prepare_next_generation(%Workflow{} = workflow, [%Fact{} | _] = _facts),
    do: workflow

  @doc false
  def causal_generation(%Workflow{} = workflow, %Fact{} = fact) do
    Workflow.ancestry_depth(workflow, fact) + 1
  end

  def next_runnables(
        %Workflow{} = wrk,
        %Fact{ancestry: {parent_step_hash, _parent_fact}} = fact
      ) do
    wrk =
      unless Graph.has_vertex?(wrk.graph, fact) do
        log_fact(wrk, fact)
      else
        wrk
      end

    parent_step = Map.get(wrk.graph.vertices, parent_step_hash)

    next_step_hashes =
      wrk
      |> Workflow.next_steps(parent_step)
      |> Enum.map(& &1.hash)

    for %Graph.Edge{} = edge <-
          Enum.flat_map(next_step_hashes, &Graph.out_edges(wrk.graph, &1, by: :runnable)) do
      {Map.get(wrk.graph.vertices, edge.v2), edge.v1}
    end
  end

  def next_runnables(%Workflow{graph: graph}, raw_fact) do
    for %Graph.Edge{} = edge <- Graph.out_edges(graph, root(), by: :flow) do
      {edge.v1, Fact.new(value: raw_fact)}
    end
  end

  # =============================================================================
  # Meta expression support
  # =============================================================================

  def build_getter_fn(%{kind: :state_of, field_path: _field_path}) do
    fn workflow, target ->
      target_node = resolve_target_node(workflow, target)

      case target_node do
        %Runic.Workflow.Accumulator{} = acc ->
          get_accumulator_state(workflow, acc)

        %{state_hash: _, init: _} = stateful_node ->
          last_known_state(workflow, stateful_node)

        _ ->
          nil
      end
    end
  end

  def build_getter_fn(%{kind: :step_ran?}) do
    fn workflow, target ->
      target_node = resolve_target_node(workflow, target)

      if target_node do
        workflow.graph
        |> Graph.out_edges(target_node, by: :ran)
        |> Enum.any?()
      else
        false
      end
    end
  end

  def build_getter_fn(%{kind: :fact_count}) do
    fn workflow, target ->
      target_node = resolve_target_node(workflow, target)

      if target_node do
        workflow.graph
        |> Graph.out_edges(target_node, by: [:produced, :state_produced, :reduced])
        |> length()
      else
        0
      end
    end
  end

  def build_getter_fn(%{kind: :latest_value_of, field_path: field_path}) do
    fn workflow, target ->
      target_node = resolve_target_node(workflow, target)

      if target_node do
        latest_fact =
          workflow.graph
          |> Graph.out_edges(target_node, by: [:produced, :state_produced, :reduced])
          |> Enum.max_by(
            fn edge ->
              case edge.v2 do
                %Fact{} = fact -> Workflow.ancestry_depth(workflow, fact)
                _ -> 0
              end
            end,
            fn -> nil end
          )

        case latest_fact do
          %{v2: %Fact{value: value}} -> extract_field_path(value, field_path)
          _ -> nil
        end
      else
        nil
      end
    end
  end

  def build_getter_fn(%{kind: :latest_fact_of}) do
    fn workflow, target ->
      target_node = resolve_target_node(workflow, target)

      if target_node do
        workflow.graph
        |> Graph.out_edges(target_node, by: [:produced, :state_produced, :reduced])
        |> Enum.max_by(
          fn edge ->
            case edge.v2 do
              %Fact{} = fact -> Workflow.ancestry_depth(workflow, fact)
              _ -> 0
            end
          end,
          fn -> nil end
        )
        |> case do
          %{v2: %Fact{} = fact} -> fact
          _ -> nil
        end
      else
        nil
      end
    end
  end

  def build_getter_fn(%{kind: :all_values_of}) do
    fn workflow, target ->
      target_node = resolve_target_node(workflow, target)

      if target_node do
        workflow.graph
        |> Graph.out_edges(target_node, by: [:produced, :state_produced, :reduced])
        |> Enum.map(fn edge ->
          case edge.v2 do
            %Fact{value: value} -> value
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
      else
        []
      end
    end
  end

  def build_getter_fn(%{kind: :all_facts_of}) do
    fn workflow, target ->
      target_node = resolve_target_node(workflow, target)

      if target_node do
        workflow.graph
        |> Graph.out_edges(target_node, by: [:produced, :state_produced, :reduced])
        |> Enum.map(fn edge ->
          case edge.v2 do
            %Fact{} = fact -> fact
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
      else
        []
      end
    end
  end

  def build_getter_fn(_unknown), do: fn _workflow, _target -> nil end

  def draw_meta_ref_edge(%Workflow{} = workflow, from, to, meta_ref) do
    getter_fn = build_getter_fn(meta_ref)

    properties =
      meta_ref
      |> Map.put(:getter_fn, getter_fn)

    draw_connection(workflow, from, to, :meta_ref, properties: properties)
  end

  def prepare_meta_context(%Workflow{graph: graph} = workflow, node) do
    node_vertex =
      case node do
        %{hash: hash} -> hash
        _ -> node
      end

    graph
    |> Graph.out_edges(node_vertex, by: :meta_ref)
    |> Enum.reduce(%{}, fn edge, acc ->
      properties = edge.properties || %{}
      getter_fn = Map.get(properties, :getter_fn)
      context_key = Map.get(properties, :context_key)
      target = edge.v2

      if getter_fn && context_key do
        value = getter_fn.(workflow, target)
        Map.put(acc, context_key, value)
      else
        acc
      end
    end)
  end

  # =============================================================================
  # last_known_state
  # =============================================================================

  def last_known_state(%Workflow{} = workflow, state_reaction) do
    accumulator = Map.get(workflow.graph.vertices, state_reaction.state_hash)

    state_from_memory =
      for edge <- Graph.out_edges(workflow.graph, accumulator),
          edge.label == :state_produced do
        edge
      end
      |> List.first(%{})
      |> Map.get(:v2)

    init_state =
      workflow.graph.vertices
      |> Map.get(state_reaction.state_hash)
      |> Map.get(:init)

    unless is_nil(state_from_memory) do
      state_from_memory
      |> Map.get(:value)
      |> invoke_init()
    else
      invoke_init(init_state)
    end
  end

  # =============================================================================
  # Shared helpers (used by moved functions and also callable from Workflow)
  # =============================================================================

  @doc false
  def connection_for_activatable(step) do
    Invokable.match_or_execute(step)
    |> case do
      :match -> :matchable
      :execute -> :runnable
    end
  end

  # =============================================================================
  # Private helpers only used by moved functions
  # =============================================================================

  defp invoke_init(init) when is_function(init), do: init.()
  defp invoke_init(init), do: init

  defp resolve_target_node(workflow, target) do
    case target do
      hash when is_integer(hash) ->
        Map.get(workflow.graph.vertices, hash)

      name when is_atom(name) ->
        Workflow.get_component(workflow, name)

      %{hash: _} = node ->
        node

      _ ->
        nil
    end
  end

  defp get_accumulator_state(
         %Workflow{graph: graph} = _workflow,
         %Runic.Workflow.Accumulator{} = acc
       ) do
    state_produced_edges =
      graph
      |> Graph.out_edges(acc, by: :state_produced)

    case state_produced_edges do
      [] ->
        invoke_init(acc.init)

      edges ->
        edges
        |> Enum.max_by(fn edge -> edge.weight || 0 end, fn -> nil end)
        |> case do
          nil -> invoke_init(acc.init)
          edge -> Map.get(edge.v2, :value)
        end
    end
  end

  defp extract_field_path(value, []), do: value
  defp extract_field_path(nil, _path), do: nil

  defp extract_field_path(value, [field | rest]) when is_map(value) do
    extract_field_path(Map.get(value, field), rest)
  end

  defp extract_field_path(_value, _path), do: nil
end
