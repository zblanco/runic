defmodule Runic.Workflow do
  @moduledoc """
  Runic Workflows are used to compose many branching steps, rules and accumuluations/reductions
  at runtime for lazy or eager evaluation.

  You can think of Runic Workflows as a recipe of rules that when fed a stream of facts may react.

  The Runic.Component protocol facilitates a `to_workflow` transformation so expressions like a
    Rule or an Accumulator may become a Workflow we can evaluate and compose with other workflows.

  Any Workflow can be merged into another Workflow and evaluated together. This gives us a lot of flexibility
  in expressing abstractions on top of Runic workflow constructs.

  Runic Workflows are intended for use cases where your program is built or modified at runtime. If model can be expressed in advance with compiled code using
  the usual control flow and concurrency tools available in Elixir/Erlang - Runic Workflows are not the tool
  to reach for. There are performance trade-offs of doing more compilation and evaluation at runtime.

  Runic Workflows are useful for building complex data dependent pipelines, expert systems, and user defined
  logical systems. If you do not need that level of dynamicism - Runic Workflows are not for you.

  A Runic Workflow supports lazy evaluation of both conditional (left hand side) and steps (right hand side).
  This allows a runtime implementation to distribute work to infrastructure specific to their needs
  independently of the model expressed. For example a Runic "Runner" implementation may want to use a Dynamically Supervised
  GenServer, with cluster-aware registration for a given workflow, then execute conditionals eagerly, but
  execute actual steps with side effects lazily as a GenStage pipeline with backpressure has availability.
  """
  alias Runic.Component
  alias Runic.Workflow.Components
  alias Runic.Workflow.Root
  alias Runic.Workflow.Step
  alias Runic.Workflow.Condition
  alias Runic.Workflow.Fact
  alias Runic.Workflow.Rule
  alias Runic.Workflow.Invokable

  @type t() :: %__MODULE__{
          name: String.t(),
          graph: Graph.t(),
          hash: binary(),
          generations: integer(),
          # name -> component struct
          components: map(),
          # name -> %{before: list(fun), after: list(fun)}
          hooks: map()
        }

  @type runnable() :: {fun(), term()}

  defstruct name: nil,
            generations: 0,
            hash: nil,
            graph: nil,
            components: %{},
            hooks: %{}

  def new(), do: new([])

  @doc """
  Constructs a new Runic Workflow.
  """
  def new(name) when is_binary(name) do
    new(name: name)
  end

  def new(params) when is_list(params) or is_map(params) do
    struct!(__MODULE__, params)
    |> Map.put(:graph, new_graph())
    |> Map.put_new(:name, Uniq.UUID.uuid4())
    # a map of name -> hash | g(hash --params (flow_edges()) --> hash)
    |> Map.put(:components, %{})
  end

  defp new_graph do
    Graph.new(vertex_identifier: &Components.vertex_id_of/1)
    |> Graph.add_vertex(root(), :root)
  end

  @doc false
  def root(), do: %Root{}

  @doc """
  Adds a step to the root of the workflow that is always evaluated with a new fact.
  """
  def add_step(%__MODULE__{} = workflow, child_step) when is_function(child_step) do
    add_step(workflow, %Root{}, Step.new(work: child_step))
  end

  def add_step(%__MODULE__{} = workflow, child_step) do
    add_step(workflow, %Root{}, child_step)
  end

  @doc """
  Adds a dependent step to some other step in a workflow by name.

  The dependent step is fed signed facts produced by the parent step during a reaction.

  Adding dependent steps is the most low-level way of building a dataflow execution graph as it assumes no conditional, branching logic.

  If you're just building a pipeline, dependent steps can be sufficient, however you might want Rules for conditional branching logic.
  """
  def add_step(%__MODULE__{graph: g} = workflow, %Root{}, %Condition{} = child_step) do
    %__MODULE__{
      workflow
      | graph:
          g
          |> Graph.add_vertex(child_step, child_step.hash)
          |> Graph.add_edge(%Root{}, child_step, label: :flow, weight: 0)
    }
  end

  def add_step(%__MODULE__{graph: g} = workflow, %Root{}, %{} = child_step) do
    %__MODULE__{
      workflow
      | graph:
          g
          |> Graph.add_vertex(child_step, child_step.hash)
          |> Graph.add_edge(%Root{}, child_step, label: :flow, weight: 0)
    }
    |> maybe_put_component(child_step)
  end

  def add_step(%__MODULE__{graph: g} = workflow, %{} = parent_step, %{} = child_step) do
    %__MODULE__{
      workflow
      | graph:
          g
          |> Graph.add_vertex(child_step, to_string(child_step.hash))
          |> Graph.add_edge(parent_step, child_step, label: :flow, weight: 0)
    }
    |> maybe_put_component(child_step)
  end

  def add_step(%__MODULE__{} = workflow, parent_steps, %{} = child_step)
      when is_list(parent_steps) do
    Enum.reduce(parent_steps, workflow, fn parent_step, wrk ->
      add_step(wrk, parent_step, child_step)
    end)
  end

  def add_step(%__MODULE__{} = workflow, parent_step_name, child_step) do
    add_step(workflow, get_component!(workflow, parent_step_name), child_step)
  end

  def maybe_put_component(%__MODULE__{} = workflow, %{name: name} = step) do
    Map.put(workflow, :components, Map.put(workflow.components, name, step))
  end

  def maybe_put_component(%__MODULE__{} = workflow, %{} = _step), do: workflow

  def get_component(%__MODULE__{components: components}, name) do
    Map.get(components, name)
  end

  def get_component!(wrk, name) do
    get_component(wrk, name) || raise(KeyError, "No component found with name #{name}")
  end

  def fetch_component(%__MODULE__{components: components}, name) do
    case Map.fetch(components, name) do
      :error -> {:error, :no_component_by_name}
      {:ok, component} -> {:ok, component}
    end
  end

  @doc """
  The next outgoing dataflow steps from a given `parent_step`.
  """
  def next_steps(%__MODULE__{graph: g}, parent_step) do
    next_steps(g, parent_step)
  end

  def next_steps(%Graph{} = g, parent_step) do
    for e <- Graph.out_edges(g, parent_step), e.label == :flow, do: e.v2
  end

  @doc """
  Adds a rule to the workflow. A rule's left hand side (condition) is a runnable which should return booleans.

  In some cases the condition is in multiple parts and some of the conditional clauses already exist as steps
  in which case we add the sub-clause(s) of the condition that don't exist as a dependent step to the conditions
  that do exist and add the reaction step to the sub-conditions.
  """
  def add_rule(
        %__MODULE__{} = workflow,
        %Rule{} = rule
      ) do
    workflow_of_rule = Runic.Component.to_workflow(rule)
    merge(workflow, workflow_of_rule)
  end

  @doc """
  Merges the second workflow into the first maintaining the name of the first.
  """
  def merge(
        %__MODULE__{graph: g1, components: c1} = workflow,
        %__MODULE__{graph: g2, components: c2} = _workflow2
      ) do
    merged_graph =
      Graph.Reducers.Bfs.reduce(g2, g1, fn
        %Root{} = root, g ->
          out_edges = Enum.uniq(Graph.out_edges(g, root) ++ Graph.out_edges(g2, root))

          g =
            Enum.reduce(out_edges, Graph.add_vertex(g, root), fn edge, g ->
              Graph.add_edge(g, edge)
            end)

          {:next, g}

        generation, g when is_integer(generation) ->
          {:next, Graph.add_vertex(g, generation)}

        v, g ->
          g = Graph.add_vertex(g, v, v.hash)

          out_edges = Enum.uniq(Graph.out_edges(g, v) ++ Graph.out_edges(g2, v))

          g =
            Enum.reduce(out_edges, g, fn
              %{v1: %Fact{} = _fact_v1, v2: _v2, label: :generation} = memory2_edge, mem ->
                Graph.add_edge(mem, memory2_edge)

              %{v1: %Fact{} = fact_v1, v2: v2, label: label} = memory2_edge, mem
              when label in [:matchable, :runnable, :ran] ->
                out_edge_labels_of_into_mem_for_edge =
                  mem
                  |> Graph.out_edges(fact_v1)
                  |> Enum.filter(&(&1.v2 == v2))
                  |> MapSet.new(& &1.label)

                cond do
                  label in [:matchable, :runnable] and
                      MapSet.member?(out_edge_labels_of_into_mem_for_edge, :ran) ->
                    mem

                  label == :ran and
                      MapSet.member?(out_edge_labels_of_into_mem_for_edge, :runnable) ->
                    Graph.update_labelled_edge(mem, fact_v1, v2, :runnable, label: :ran)

                  true ->
                    Graph.add_edge(mem, memory2_edge)
                end

              %{v1: _v1, v2: _v2} = memory2_edge, mem ->
                Graph.add_edge(mem, memory2_edge)
            end)

          {:next, g}
      end)

    %__MODULE__{
      workflow
      | graph: merged_graph,
      components: Map.merge(c1, c2)
    }
  end

  def merge(%__MODULE__{} = workflow, flowable) do
    merge(workflow, Component.to_workflow(flowable))
  end

  def merge(flowable_1, flowable_2) do
    merge(Component.to_workflow(flowable_1), Component.to_workflow(flowable_2))
  end

  @doc """
  Lists all steps in the workflow.
  """
  def steps(%__MODULE__{graph: g}) do
    Enum.filter(Graph.vertices(g), &match?(%Step{}, &1))
  end

  @doc """
  Lists all conditions in the workflow.
  """
  def conditions(%__MODULE__{graph: g}) do
    Enum.filter(Graph.vertices(g), &match?(%Condition{}, &1))
  end

  @doc false
  def satisfied_condition_hashes(%__MODULE__{graph: graph}, %Fact{} = fact) do
    for %Graph.Edge{} = edge <- Graph.out_edges(graph, fact),
        edge.label == :satisfied,
        do: edge.v2.hash
  end

  @spec raw_reactions(Runic.Workflow.t()) :: list(any())
  @doc """
  Returns raw (output value) side effects of the workflow - i.e. facts resulting from the execution of a Runic.Step
  """
  def raw_reactions(%__MODULE__{} = wrk) do
    wrk
    |> reactions()
    |> Enum.map(& &1.value)
  end

  @spec reactions(Runic.Workflow.t()) :: list(Runic.Workflow.Fact.t())
  @doc """
  Returns raw (output value) side effects of the workflow - i.e. facts resulting from the execution of a Runic.Step
  """
  def reactions(%__MODULE__{graph: graph}) do
    for %Graph.Edge{} = edge <- Graph.edges(graph),
        edge.label in [:produced, :ran] and
          (match?(%Fact{}, edge.v1) or match?(%Fact{}, edge.v2)),
        uniq: true do
      if(match?(%Fact{}, edge.v1), do: edge.v1, else: edge.v2)
    end
  end

  def productions(%__MODULE__{graph: graph}) do
    for %Graph.Edge{} = edge <- Graph.edges(graph),
        edge.label == :produced or edge.label == :state_produced or edge.label == :state_initiated do
      edge.v2
    end
  end

  def raw_productions(%__MODULE__{graph: graph}) do
    for %Graph.Edge{} = edge <- Graph.edges(graph),
        edge.label == :produced or edge.label == :state_produced do
      edge.v2.value
    end
  end

  @spec facts(Runic.Workflow.t()) :: list(Runic.Workflow.Fact.t())
  @doc """
  Lists facts produced in the workflow so far.
  """
  def facts(%__MODULE__{graph: graph}) do
    for v <- Graph.vertices(graph), match?(%Fact{}, v), do: v
  end

  @doc false
  def matches(%__MODULE__{graph: graph}) do
    for %Graph.Edge{} = edge <- Graph.edges(graph),
        edge.label == :matchable or edge.label == :satisfied do
      edge.v2
    end
  end

  @doc """
  Cycles eagerly through a prepared agenda in the match phase.
  """
  def react(%__MODULE__{generations: generations} = wrk) when generations > 0 do
    Enum.reduce(next_runnables(wrk), wrk, fn {node, fact}, wrk ->
      Invokable.invoke(node, wrk, fact)
    end)
  end

  @doc """
  Plans eagerly through the match phase then executes a single cycle of right hand side runnables.

  ### Example

  ```elixir

  workflow = Workflow.new()

  [%Fact{value: "hello"}] =
    workflow
    |> Workflow.add_step(fn fact -> fact end)
    |> Workflow.react("hello")
    |> Workflow.reactions()
  """
  def react(%__MODULE__{} = wrk, %Fact{ancestry: nil} = fact) do
    react(Invokable.invoke(root(), wrk, fact))
  end

  def react(%__MODULE__{} = wrk, raw_fact) do
    react(wrk, Fact.new(value: raw_fact))
  end

  @doc """
  Cycles eagerly through runnables resulting from the input fact.

  Eagerly runs through the planning / match phase as does `react/2` but also eagerly executes
  subsequent phases of runnables until satisfied (nothing new to react to i.e. all
  terminating leaf nodes have been traversed to and executed) resulting in a fully satisfied agenda.

  `react_until_satisfied/2` is good for nested step -> [child_step_1, child_step2, ...] dependencies
  where the goal is to get to the results at the end of the pipeline of steps.

  One should be careful about using react_until_satisfied with infinite loops as evaluation will not terminate.

  If your goal is to evaluate some non-terminating program to some finite number of generations - wrapping
  `react/2` in a process that can track workflow evaluation livecycles until desired is recommended.
  """
  def react_until_satisfied(%__MODULE__{} = wrk, %Fact{ancestry: nil} = fact) do
    wrk
    |> react(fact)
    |> react_until_satisfied()
  end

  def react_until_satisfied(%__MODULE__{} = wrk, raw_fact) do
    react_until_satisfied(wrk, Fact.new(value: raw_fact))
  end

  def react_until_satisfied(%__MODULE__{} = workflow) do
    do_react_until_satisfied(workflow, is_runnable?(workflow))
  end

  defp do_react_until_satisfied(%__MODULE__{} = workflow, true = _is_runnable?) do
    workflow =
      Enum.reduce(next_runnables(workflow), workflow, fn {node, fact} = _runnable, wrk ->
        Invokable.invoke(node, wrk, fact)
      end)

    do_react_until_satisfied(workflow, is_runnable?(workflow))
  end

  defp do_react_until_satisfied(%__MODULE__{} = workflow, false = _is_runnable?), do: workflow

  def purge_memory(%__MODULE__{} = wrk) do
    %__MODULE__{
      wrk
      | graph:
          Graph.Reducers.Bfs.reduce(wrk.graph, wrk.graph, fn
            %Fact{} = fact, g ->
              {:next, Graph.delete_vertex(g, fact)}

            generation, g when is_integer(generation) ->
              {:next, Graph.delete_vertex(g, generation)}

            _node, g ->
              {:next, g}
          end)
    }
  end

  @doc """
  For a new set of inputs, `plan/2` prepares the workflow agenda for the next set of reactions by
  matching through left-hand-side conditions in the workflow network.

  For an inference engine's match -> select -> execute phase, this is the match phase.

  Runic Workflow evaluation is forward chaining meaning from the root of the graph it starts
    by evaluating the direct children of the root node. If the workflow has any sort of
    conditions (from rules, etc) these conditions are prioritized in the agenda for the next cycle.

  Plan will always match through a single level of nodes and identify the next runnable activations
  available.
  """
  def plan(%__MODULE__{} = wrk, %Fact{} = fact) do
    Invokable.invoke(root(), wrk, fact)
  end

  def plan(%__MODULE__{} = wrk, raw_fact) do
    plan(wrk, Fact.new(value: raw_fact))
  end

  @doc """
  `plan/1` will, for all next left hand side / match phase runnables activate and prepare next match runnables.
  """
  def plan(%__MODULE__{} = wrk) do
    wrk
    |> maybe_prepare_next_generation_from_state_accumulations()
    |> next_match_runnables()
    |> Enum.reduce(wrk, fn {node, fact}, wrk ->
      Invokable.invoke(node, wrk, fact)
    end)
  end

  @doc """
  Invokes all left hand side / match-phase runnables in the workflow for a given input fact until all are satisfied.

  Upon calling plan_eagerly/2, the workflow will only have right hand side runnables left to execute that react or react_until_satisfied can execute.
  """
  def plan_eagerly(%__MODULE__{} = workflow, %Fact{} = input_fact) do
    workflow
    |> plan(input_fact)
    |> activate_through_possible_matches()
  end

  def plan_eagerly(%__MODULE__{} = wrk, raw_fact) do
    plan_eagerly(wrk, Fact.new(value: raw_fact))
  end

  defp activate_through_possible_matches(wrk) do
    activate_through_possible_matches(
      wrk,
      next_match_runnables(wrk),
      any_match_phase_runnables?(wrk)
    )
  end

  defp activate_through_possible_matches(
         wrk,
         next_match_runnables,
         _any_match_phase_runnables? = true
       ) do
    Enum.reduce(next_match_runnables, wrk, fn {node, fact}, wrk ->
      node
      |> Invokable.invoke(wrk, fact)
      |> activate_through_possible_matches()
    end)
  end

  defp activate_through_possible_matches(
         wrk,
         _match_runnables,
         _any_match_phase_runnables? = false
       ) do
    wrk
  end

  defp any_match_phase_runnables?(%__MODULE__{graph: graph, generations: generation}) do
    generation_fact = fact_for_generation(graph, generation)

    graph
    |> Graph.out_edges(generation_fact)
    |> Enum.any?(fn edge ->
      edge.label == :matchable
    end)
  end

  defp next_match_runnables(%__MODULE__{graph: graph, generations: generation}) do
    current_generation_facts = facts_for_generation(graph, generation)

    Enum.flat_map(current_generation_facts, fn current_generation_fact ->
      for %Graph.Edge{} = edge <- Graph.edges(graph),
          edge.label == :matchable do
        {edge.v2, current_generation_fact}
      end
    end)
  end

  defp fact_for_generation(graph, generation) do
    for %Graph.Edge{} = edge <- Graph.in_edges(graph, generation),
        edge.label == :generation do
      edge.v1
    end
    |> List.first()
  end

  defp facts_for_generation(graph, generation) do
    graph
    |> Graph.in_neighbors(generation)
  end

  @spec is_runnable?(Runic.Workflow.t()) :: boolean()
  def is_runnable?(%__MODULE__{graph: graph}) do
    graph
    |> Graph.edges()
    |> Enum.any?(fn edge ->
      edge.label == :runnable
    end)
  end

  @doc """
  Returns a list of the next {node, fact} i.e "runnable" pairs ready for activation in the next cycle.

  All Runnables returned are independent and can be run in parallel then fed back into the Workflow
  without wait or delays to get the same results.
  """
  def next_runnables(%__MODULE__{graph: graph}) do
    for %Graph.Edge{} = edge <- Graph.edges(graph),
        edge.label == :runnable do
      {edge.v2, edge.v1}
    end
  end

  def next_runnables(
        %__MODULE__{} = wrk,
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
      |> next_steps(parent_step)
      |> Enum.map(& &1.hash)

    for %Graph.Edge{} = edge <-
          Enum.flat_map(next_step_hashes, &Graph.out_edges(wrk.graph, &1)),
        edge.label == :runnable do
      {Map.get(wrk.graph.vertices, edge.v2), edge.v1}
    end
  end

  def next_runnables(%__MODULE__{graph: graph}, raw_fact) do
    for %Graph.Edge{} = edge <- Graph.out_edges(graph, root()),
        edge.label == :flow do
      {edge.v1, Fact.new(value: raw_fact)}
    end
  end

  def log_fact(%__MODULE__{graph: graph} = wrk, %Fact{} = fact) do
    %__MODULE__{
      wrk
      | graph:
          graph
          |> Graph.add_vertex(fact)
          |> Graph.add_edge(wrk.generations, fact, label: :generation)
    }
  end

  defp maybe_prepare_next_generation_from_state_accumulations(
         %__MODULE__{graph: graph, generations: generation} = workflow
       ) do
    # we need the last state produced fact for all accumulators from the current generation
    state_produced_facts_by_ancestor =
      for generation_edge <- Graph.out_edges(graph, generation),
          generation_edge.label == :generation do
        for connection <- Graph.in_edges(graph, generation_edge.v2),
            connection.label == :state_produced do
          connection.v2
        end
      end
      |> List.flatten()
      |> Enum.reduce(%{}, fn %{ancestry: {accumulator_hash, _}} = state_produced_fact, acc ->
        Map.put(acc, accumulator_hash, state_produced_fact)
      end)

    stateful_matching_impls = stateful_matching_impls()

    state_produced_fact_ancestors = Map.keys(state_produced_facts_by_ancestor)

    unless Enum.empty?(state_produced_facts_by_ancestor) do
      workflow = prepare_next_generation(workflow, Map.values(state_produced_facts_by_ancestor))

      Graph.Reducers.Bfs.reduce(graph, workflow, fn
        node, wrk when is_integer(node) ->
          {:next, wrk}

        node, wrk ->
          if node.__struct__ in stateful_matching_impls do
            state_hash = Runic.Workflow.StatefulMatching.matches_on(node)

            if state_hash in state_produced_fact_ancestors do
              relevant_state_produced_fact = Map.get(state_produced_facts_by_ancestor, state_hash)

              {:next,
               draw_connection(
                 wrk,
                 relevant_state_produced_fact,
                 node.hash,
                 connection_for_activatable(node)
               )}
            else
              {:next, wrk}
            end
          else
            {:next, wrk}
          end
      end)
    else
      workflow
    end

    # how to access relevant match nodes for the state produced facts?
    # ideally we want an edge between accumulators and match conditions that we can ignore in normal dataflow scenarios
    # we need to access the subset of an accumulator's match nodes quickly and without iteration over irrelevant flowables
  end

  defp stateful_matching_impls,
    do: Runic.Workflow.StatefulMatching.__protocol__(:impls) |> elem(1)

  @spec prepare_next_generation(Workflow.t(), Fact.t() | list(Fact.t())) :: Workflow.t()
  @doc false
  def prepare_next_generation(%__MODULE__{} = workflow, %Fact{} = fact) do
    next_generation = workflow.generations + 1

    workflow
    |> Map.put(:generations, next_generation)
    |> draw_connection(fact, next_generation, :generation)
  end

  def prepare_next_generation(%__MODULE__{} = workflow, [%Fact{} | _] = facts)
      when is_list(facts) do
    next_generation = workflow.generations + 1

    Enum.reduce(facts, Map.put(workflow, :generations, next_generation), fn fact, wrk ->
      draw_connection(wrk, fact, next_generation, :generation)
    end)
  end

  def draw_connection(%__MODULE__{graph: g} = wrk, node_1, node_2, connection) do
    %__MODULE__{wrk | graph: Graph.add_edge(g, node_1, node_2, label: connection)}
  end

  @doc false
  def mark_runnable_as_ran(%__MODULE__{graph: graph} = workflow, step, fact) do
    graph =
      case Graph.update_labelled_edge(graph, fact, step, connection_for_activatable(step),
             label: :ran
           ) do
        %Graph{} = graph -> graph
        {:error, :no_such_edge} -> graph
      end

    %__MODULE__{
      workflow
      | graph: graph
    }
  end

  @spec prepare_next_runnables(Workflow.t(), any(), Fact.t()) :: any
  @doc false
  def prepare_next_runnables(%__MODULE__{} = workflow, node, fact) do
    workflow
    |> next_steps(node)
    |> Enum.reduce(workflow, fn step, wrk ->
      draw_connection(wrk, fact, step, connection_for_activatable(step))
    end)
  end

  @doc false
  def last_known_state(%__MODULE__{} = workflow, state_reaction) do
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

  defp invoke_init(init) when is_function(init), do: init.()
  defp invoke_init(init), do: init

  # todo extend this concept into protocol more completely
  defp connection_for_activatable(step) do
    case Invokable.match_or_execute(step) do
      :match -> :matchable
      :execute -> :runnable
    end
  end

  # def component_of(
  #       %__MODULE__{} = wrk,
  #       parent_component_name,
  #       sub_component
  #     )
  #     when sub_component in @sub_components do
  #   Map.get(wrk.components, parent_component_name)
  # end
end
