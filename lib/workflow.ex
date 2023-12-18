defmodule Runic.Workflow do
  @moduledoc """
  Runic Workflows are used to compose many branching steps, rules and accumuluations/reductions
  at runtime for lazy or eager evaluation.

  You can think of Runic Workflows as a recipe of rules that when fed a stream of facts may react.

  The Runic.Flowable protocol facilitates a `to_workflow` transformation so expressions like a
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
  alias Runic.Workflow.Components
  alias Runic.Workflow.Root
  alias Runic.Workflow.Step
  alias Runic.Workflow.Fact
  alias Runic.Workflow.Rule

  @type t() :: %__MODULE__{
          name: String.t(),
          graph: Graph.t(),
          hash: binary(),
          generations: integer(),
          components: map()
        }

  @type runnable() :: {fun(), term()}

  @typedoc """
  A discrimination network of conditions, and steps, built from composites such as rules and accumulations.
  """
  @type flow() :: Graph.t()

  defstruct name: nil,
            generations: 0,
            hash: nil,
            graph: nil,
            components: %{}

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
  def add_step(%__MODULE__{graph: g} = workflow, %Root{}, %{} = child_step) do
    %__MODULE__{
      workflow
      | graph:
          g
          |> Graph.add_vertex(child_step, child_step.hash)
          |> Graph.add_edge(%Root{}, child_step, label: :flow, weight: 0),
        components: Map.put(workflow.components, child_step.name, child_step.hash)
    }
  end

  def add_step(%__MODULE__{graph: g} = workflow, %{} = parent_step, %{} = child_step) do
    %__MODULE__{
      workflow
      | graph:
          g
          |> Graph.add_vertex(child_step, to_string(child_step.hash))
          |> Graph.add_edge(parent_step, child_step, label: :flow, weight: 0)
    }
  end

  def add_step(%__MODULE__{} = workflow, parent_steps, %{} = child_step)
      when is_list(parent_steps) do
    Enum.reduce(parent_steps, workflow, fn parent_step, wrk ->
      add_step(wrk, parent_step, child_step)
    end)
  end

  def add_step(%__MODULE__{} = workflow, parent_step_name, child_step) do
    add_step(workflow, get_step(workflow, parent_step_name), child_step)
  end

  defp get_step(%__MODULE__{components: components, graph: g}, name) do
    parent_step_hash = Map.get(components, name)

    Map.get(g.vertices, parent_step_hash)
  end

  @doc """
  The next outgoing dataflow steps from a given `parent_step`.
  """
  def next_steps(%__MODULE__{graph: g}, parent_step) do
    next_steps(g, parent_step)
  end

  def next_steps(%Graph{} = g, parent_step) do
    for v <- Graph.out_neighbors(g, parent_step), v.label == :flow, do: v
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
        %__MODULE__{graph: g1} = workflow,
        %__MODULE__{graph: g2} = _workflow2
      ) do
    merged_graph =
      Graph.Reducers.Bfs.reduce(g2, g1, fn
        v, g ->
          g = Graph.add_vertex(g, v, v.hash)

          out_edges = Enum.uniq(Graph.out_edges(g, v) ++ Graph.out_edges(g2, v))

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

                label == :ran and MapSet.member?(out_edge_labels_of_into_mem_for_edge, :runnable) ->
                  Graph.update_labelled_edge(mem, fact_v1, v2, :runnable, label: :ran)

                true ->
                  Graph.add_edge(mem, memory2_edge)
              end

            %{v1: _v1, v2: _v2} = memory2_edge, mem ->
              Graph.add_edge(mem, memory2_edge)
          end)
      end)

    %__MODULE__{
      workflow
      | graph: merged_graph
    }
  end

  defp edges_to_add(v, into_g, from_g) do
    (Graph.out_edges(into_g, v) ++ Graph.out_edges(from_g, v))
    |> Enum.uniq()
  end
end
