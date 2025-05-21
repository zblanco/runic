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
  require Logger
  alias Runic.Workflow.ReactionOccurred
  alias Runic.Component
  alias Runic.Workflow.FanOut
  alias Runic.Transmutable
  alias Runic.Workflow.Components
  alias Runic.Workflow.Root
  alias Runic.Workflow.Step
  alias Runic.Workflow.Condition
  alias Runic.Workflow.Fact
  alias Runic.Workflow.Rule
  alias Runic.Workflow.FanIn
  alias Runic.Workflow.Join
  alias Runic.Workflow.Invokable
  alias Runic.Workflow.ComponentAdded
  alias Runic.Workflow.ReactionOccurred

  @type t() :: %__MODULE__{
          name: String.t(),
          graph: Graph.t(),
          hash: binary(),
          generations: integer(),
          # name -> component struct
          components: map(),
          # name -> %{before: list(fun), after: list(fun)}
          before_hooks: map(),
          after_hooks: map(),
          # hash of parent fact for fan_out -> path_to_fan_in e.g. [fan_out, step1, step2, fan_in]
          mapped: map(),
          # generation -> list(input_fact_hash)
          # or input_fact_hash -> MapSet.new([produced_facts])
          inputs: map()
        }

  @type runnable() :: {fun(), term()}

  defstruct name: nil,
            generations: 0,
            hash: nil,
            graph: nil,
            components: %{},
            before_hooks: %{},
            after_hooks: %{},
            mapped: %{},
            build_log: [],
            inputs: %{}

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
    |> Map.put(:components, %{})
    |> Map.put(:before_hooks, %{})
    |> Map.put(:after_hooks, %{})
    |> Map.put(:build_log, [])
    |> Map.put(:inputs, %{})
    |> Map.put(:mapped, %{mapped_paths: MapSet.new()})
  end

  defp new_graph do
    Graph.new(
      vertex_identifier: &Components.vertex_id_of/1,
      multigraph: true
    )
    |> Graph.add_vertex(root(), :root)
  end

  @doc false
  def root(), do: %Root{}

  def add(%__MODULE__{} = workflow, component, opts \\ []) do
    to = opts[:to]

    parent_step =
      if not is_nil(to) do
        get_component(workflow, to) ||
          get_by_hash(workflow, to) ||
          root()
      else
        root()
      end

    component
    |> Component.connect(parent_step, workflow)
    |> append_build_log(component, to)
    |> maybe_put_component(component)
  end

  defp append_build_log(%__MODULE__{} = workflow, component, %Root{} = parent) do
    do_append_build_log(workflow, component, parent)
  end

  defp append_build_log(%__MODULE__{} = workflow, component, parents) when is_list(parents) do
    Enum.reduce(parents, workflow, fn parent, wrk ->
      append_build_log(wrk, component, parent)
    end)
  end

  defp append_build_log(%__MODULE__{} = workflow, component, %{name: name}) do
    do_append_build_log(workflow, component, name)
  end

  defp append_build_log(%__MODULE__{} = workflow, component, to) do
    do_append_build_log(workflow, component, to)
  end

  defp do_append_build_log(%__MODULE__{build_log: bl} = workflow, component, parent) do
    %__MODULE__{
      workflow
      | build_log: [
          %ComponentAdded{
            source: Component.source(component),
            name: component.name,
            to: parent,
            bindings:
              Map.get(
                component,
                :bindings,
                %{}
              )
          }
          | bl
        ]
    }
  end

  @doc """
  Returns a list of serializeable `%ComponentAdded{}` events that can be used to rebuild the workflow using `from_log/1`.

  ## Examples

  ```elixir
  iex> workflow = Workflow.new()
  iex> workflow = Workflow.add(workflow, %Step{})
  iex> Workflow.build_log(workflow)
  > [%ComponentAdded{component: %Step{}}]
  ```
  """
  def build_log(wrk) do
    # BFS reduce the graph following only flow edges and accumulate into a list of ComponentAdded events
    # Or accumulate connections of added components in graph by keeping the source with a `component_of` edge to invokables.
    Enum.reverse(wrk.build_log)
  end

  @doc """
  Rebuilds a workflow from a list of `%ComponentAdded{}` and/or `%Fact{}` events.
  """
  def from_log(events) do
    Enum.reduce(events, new(), fn
      %ComponentAdded{source: source, to: to, bindings: bindings}, wrk ->
        caller_context = bindings[:__caller_context__]

        # Build evaluation environment
        {env, clean_bindings} =
          case caller_context do
            nil ->
              {build_eval_env(), bindings}

            %Macro.Env{context_modules: cms} = caller_context ->
              env =
                Enum.reduce(cms, caller_context, fn module, ctx ->
                  case Macro.Env.define_import(ctx, [], module) do
                    {:ok, new_ctx} ->
                      new_ctx

                    {:error, msg} ->
                      Logger.error(msg)
                  end
                end)
                |> Macro.Env.prune_compile_info()
                |> Code.env_for_eval()

              {env, Map.delete(bindings, :__caller_context__)}
          end

        # Convert bindings map to keyword list for evaluation
        binding_list = Map.to_list(clean_bindings)

        # Evaluate the source with bindings
        {component, _binding} = Code.eval_quoted(source, binding_list, env)

        # Add the component to the workflow
        add(wrk, component, to: to)

      %ReactionOccurred{} = ro, wrk ->
        reaction_edge =
          Graph.Edge.new(
            ro.from,
            ro.to,
            label: ro.reaction,
            weight: ro.weight,
            properties: ro.properties
          )

        generation =
          if(ro.reaction == :generation and ro.from > wrk.generations) do
            ro.from
          else
            wrk.generations
          end

        %__MODULE__{
          wrk
          | graph: Graph.add_edge(wrk.graph, reaction_edge),
            generations: generation
        }
    end)
  end

  defp build_eval_env() do
    require Runic
    import Runic, warn: false
    alias Runic.Workflow, warn: false
    __ENV__
  end

  def log(wrk) do
    build_log(wrk) ++ reactions_occurred(wrk)
  end

  defp reactions_occurred(%__MODULE__{graph: g}) do
    reaction_edge_kinds =
      Map.keys(g.edge_index)
      |> Enum.reject(&(&1 == :flow))

    for %Graph.Edge{} = edge <-
          Graph.edges(g, by: reaction_edge_kinds) do
      %ReactionOccurred{
        from: edge.v1,
        to: edge.v2,
        reaction: edge.label,
        weight: edge.weight,
        properties: edge.properties
      }
    end
  end

  # def replay(%__MODULE__{}, log) when is_list(log) do
  #   Enum.reduce(log, new(), fn
  #     %Fact{ancestry: nil} = input_fact, wrk ->
  #       parent_step = root()
  #       Invokable.replay(parent_step, wrk, input_fact)

  #     %Fact{} = fact, wrk ->
  #       {parent_step_hash, _} = fact.ancestry
  #       parent_step = get_by_hash(wrk, parent_step_hash)
  #       Invokable.replay(parent_step, wrk, fact)
  #   end)
  # end

  def components(%__MODULE__{} = workflow) do
    workflow.components
  end

  # extend with I/O contract checks
  def connectables(%__MODULE__{graph: g} = _wrk, %{} = step) do
    impls =
      case Component.__protocol__(:impls) do
        :not_consolidated -> []
        {:consolidated, impls} -> impls
      end

    arity = Components.arity_of(step)

    g
    |> Graph.vertices()
    |> Enum.filter(fn %{__struct__: module} = v ->
      v_arity = Components.arity_of(v)

      module in impls and
        v_arity == arity
    end)
  end

  def connectable?(wrk, component, to: component_name) do
    with {:ok, added_to} <- fetch_component(wrk, component_name),
         :ok <- arity_match(component, added_to),
         true <- Component.connectable?(component, added_to) do
      :ok
    else
      false -> {:error, :not_connectable}
      otherwise -> otherwise
    end
  end

  def connectable?(wrk, component, []) do
    connectable?(wrk, component)
  end

  def connectable?(_wrk, _component) do
    true
  end

  defp arity_match(component, add_to_component) do
    if Components.arity_of(component) == Components.arity_of(add_to_component) do
      :ok
    else
      {:error, :arity_mismatch}
    end
  end

  def add_before_hooks(%__MODULE__{} = workflow, nil), do: workflow

  def add_before_hooks(%__MODULE__{} = workflow, hooks) do
    %__MODULE__{
      workflow
      | before_hooks:
          Enum.reduce(hooks, workflow.before_hooks, fn
            {name, hook}, acc when is_function(hook, 3) ->
              hooks_for_component = Map.get(acc, name, [])
              Map.put(acc, name, Enum.reverse([hook | hooks_for_component]))

            {name, hooks}, acc when is_list(hooks) ->
              hooks_for_component = Map.get(acc, name, [])
              Map.put(acc, name, hooks ++ hooks_for_component)
          end)
    }
  end

  def add_after_hooks(%__MODULE__{} = workflow, nil), do: workflow

  def add_after_hooks(%__MODULE__{} = workflow, hooks) do
    %__MODULE__{
      workflow
      | after_hooks:
          Enum.reduce(hooks, workflow.after_hooks, fn
            {name, hook}, acc when is_function(hook, 3) ->
              hooks_for_component = Map.get(acc, name, [])
              Map.put(acc, name, Enum.reverse([hook | hooks_for_component]))

            {name, hooks}, acc when is_list(hooks) ->
              hooks_for_component = Map.get(acc, name, [])
              Map.put(acc, name, hooks ++ hooks_for_component)
          end)
    }
  end

  def attach_before_hook(%__MODULE__{} = workflow, component_name, hook)
      when is_function(hook, 3) do
    hooks_for_component = Map.get(workflow.before_hooks, component_name, [])

    %__MODULE__{
      workflow
      | before_hooks:
          Map.put(
            workflow.before_hooks,
            component_name,
            Enum.reverse([hook | hooks_for_component])
          )
    }
  end

  def attach_after_hook(%__MODULE__{} = workflow, component_name, hook)
      when is_function(hook, 3) do
    hooks_for_component = Map.get(workflow.after_hooks, component_name, [])

    %__MODULE__{
      workflow
      | after_hooks:
          Map.put(
            workflow.after_hooks,
            component_name,
            Enum.reverse([hook | hooks_for_component])
          )
    }
  end

  defp run_before_hooks(%__MODULE__{} = workflow, %{name: name} = step, input_fact) do
    case Map.get(workflow.before_hooks, name) do
      nil ->
        workflow

      hooks ->
        Enum.reduce(hooks, workflow, fn hook, wrk -> hook.(step, wrk, input_fact) end)
    end
  end

  defp run_before_hooks(%__MODULE__{} = workflow, _step, _input_fact), do: workflow

  def run_after_hooks(%__MODULE__{} = workflow, %{name: name} = step, output_fact) do
    case Map.get(workflow.after_hooks, name) do
      nil ->
        workflow

      hooks ->
        Enum.reduce(hooks, workflow, fn hook, wrk -> hook.(step, wrk, output_fact) end)
    end
  end

  def run_after_hooks(%__MODULE__{} = workflow, _step, _input_fact), do: workflow

  # def remove_component(%__MODULE__{} = workflow, component_name) do
  #   component = get_component(workflow, component_name)

  #   Component.remove(component, workflow)
  # end

  defp get_by_hash(%__MODULE__{graph: g}, %{hash: hash}) do
    Map.get(g.vertices, hash)
  end

  defp get_by_hash(%__MODULE__{graph: g}, hash) when is_integer(hash) do
    Map.get(g.vertices, hash)
  end

  defp get_by_hash(_, _hash) do
    nil
  end

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

  def add_step(
        %__MODULE__{} = workflow,
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
        %__MODULE__{} = workflow,
        {%FanOut{}, [%Step{} = map_step]},
        child_step
      ) do
    add_step(workflow, map_step, child_step)
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

  def add_step(%__MODULE__{} = workflow, parent_step_name, child_step)
      when is_atom(parent_step_name) or is_binary(parent_step_name) do
    add_step(workflow, get_component!(workflow, parent_step_name), child_step)
  end

  def add_rules(workflow, nil), do: workflow

  def add_rules(workflow, rules) do
    Enum.reduce(rules, workflow, fn %Rule{} = rule, wrk ->
      add_rule(wrk, rule)
    end)
  end

  def add_steps(workflow, steps) when is_list(steps) do
    # root level pass
    Enum.reduce(steps, workflow, fn
      %Step{} = step, wrk ->
        add(wrk, step)

      {[_step | _] = parent_steps, dependent_steps}, wrk ->
        wrk = Enum.reduce(parent_steps, wrk, fn step, wrk -> add_step(wrk, step) end)

        join =
          parent_steps
          |> Enum.map(& &1.hash)
          |> Join.new()

        wrk = add_step(wrk, parent_steps, join)

        add_dependent_steps(wrk, {join, dependent_steps})

      {step, _dependent_steps} = pipeline, wrk ->
        wrk = add(wrk, step)
        add_dependent_steps(wrk, pipeline)
    end)
  end

  def add_steps(workflow, nil), do: workflow

  def add_dependent_steps(workflow, {parent_step, dependent_steps}) do
    Enum.reduce(dependent_steps, workflow, fn
      {[_step | _] = parent_steps, dependent_steps}, wrk ->
        wrk =
          Enum.reduce(parent_steps, wrk, fn step, wrk ->
            add_step(wrk, parent_step, step)
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
        wrk = add(wrk, step, to: parent_step)
        add_dependent_steps(wrk, parent_and_children)

      step, wrk ->
        add(wrk, step, to: parent_step)
    end)
  end

  def maybe_put_component(
        %__MODULE__{components: components} = workflow,
        %FanOut{name: name} = step
      ) do
    %__MODULE__{
      workflow
      | components: Map.put(components, name, step)
    }
  end

  # def maybe_put_component(
  #       %__MODULE__{} = workflow,
  #       %{name: nil}
  #     ) do
  #   workflow
  # end

  def maybe_put_component(
        %__MODULE__{components: components} = workflow,
        %{name: name} = step
      ) do
    %__MODULE__{
      workflow
      | components: Map.put(components, name, step)
    }
  end

  def maybe_put_component(%__MODULE__{} = workflow, %FanIn{map: nil}) do
    workflow
  end

  # def maybe_put_component(
  #       %__MODULE__{graph: g} = workflow,
  #       %FanIn{map: name_of_map_expression} = step
  #     ) do
  #   fan_out =
  #     get_component!(workflow, name_of_map_expression)
  #     |> Map.get(:components)
  #     |> Map.get(:fan_out)

  #   %{workflow | graph: Graph.add_edge(g, fan_out, step, label: :reduced_by)}
  # end

  def maybe_put_component(%__MODULE__{} = workflow, %{} = _step), do: workflow

  def get_named_vertex(%__MODULE__{graph: g, mapped: mapped}, name) do
    hash = Map.get(mapped, name)
    g.vertices |> Map.get(hash)
  end

  @doc """
  Retrieves a sub component by name of the given kind allowing it to be connected to another component in a workflow.

  ## Examples

  ```elixir

  iex> Runic.Workflow.component_of(workflow, :my_state_machine, :reducer)

  > %Accumulator{}

  iex> Runic.Workflow.component_of(workflow, :my_map, :fan_out)

  > %FanOut{}

  iex> Runic.Workflow.component_of(workflow, :my_map, :leafs)

  > [%Step{}, %Step{}]
  ```
  """
  def component_of(workflow, component_name, kind) do
    workflow
    |> get_component(component_name)
    |> Component.get_component(kind)
  end

  def get_component(
        %__MODULE__{components: components},
        {component_name, subcomponent_kind_or_name}
      ) do
    component = Map.get(components, component_name)
    Component.get_component(component, subcomponent_kind_or_name)
  end

  def get_component(%__MODULE__{components: components}, %{name: name}) do
    Map.get(components, name)
  end

  def get_component(%__MODULE__{components: components}, names) when is_list(names) do
    Enum.map(names, fn name -> Map.get(components, name) end)
  end

  def get_component(%__MODULE__{components: components}, name) do
    Map.get(components, name)
  end

  def get_component!(wrk, name) do
    get_component(wrk, name) || raise(KeyError, "No component found with name #{name}")
  end

  def fetch_component(%__MODULE__{} = wrk, %{name: name}) do
    fetch_component(wrk, name)
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
    for e <- Graph.out_edges(g, parent_step, by: :flow), do: e.v2
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
    add(workflow, rule)
  end

  @doc """
  Merges the second workflow into the first maintaining the name of the first.
  """
  def merge(
        %__MODULE__{graph: g1, components: c1, mapped: m1} = workflow,
        %__MODULE__{graph: g2, components: c2, mapped: m2} = _workflow2
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
          out_edges = Enum.uniq(Graph.out_edges(g, generation) ++ Graph.out_edges(g2, generation))

          g =
            g
            |> Graph.add_vertex(generation)
            |> Graph.add_edges(out_edges)

          {:next, g}

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
        components: Map.merge(c1, c2),
        mapped:
          Enum.reduce(m1, m2, fn
            {:mapped_paths, mapset}, acc ->
              Map.put(acc, :mapped_paths, MapSet.union(acc.mapped_paths, mapset))

            {k, v}, acc ->
              Map.put(
                acc,
                k,
                [v | acc[k] || []]
                |> List.flatten()
                |> Enum.reject(&is_nil/1)
                |> Enum.reverse()
                |> Enum.uniq()
              )
          end)
    }
  end

  def merge(%__MODULE__{} = workflow, flowable) do
    merge(workflow, Transmutable.transmute(flowable))
  end

  def merge(flowable_1, flowable_2) do
    merge(Transmutable.transmute(flowable_1), Transmutable.transmute(flowable_2))
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
    for %Graph.Edge{} = edge <- Graph.out_edges(graph, fact, by: :satisfied),
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
    for %Graph.Edge{} = edge <-
          Graph.edges(
            graph,
            by: [:produced, :ran],
            where: fn edge -> match?(%Fact{}, edge.v1) or match?(%Fact{}, edge.v2) end
          ),
        uniq: true do
      if(match?(%Fact{}, edge.v1), do: edge.v1, else: edge.v2)
    end
  end

  @doc """
  Lists all facts produced in the workflow so far.

  Does not return input facts only facts generated as a result of the workflow execution.

  ## Examples

      iex> workflow = Workflow.new()
      ...> workflow |> Workflow.add(Runic.step(fn fact -> fact end)) |> Workflow.react("hello") |> Workflow.facts()
      [%Fact{value: "hello"}]
  """
  def productions(%__MODULE__{graph: graph}) do
    for %Graph.Edge{} = edge <-
          Graph.edges(graph, by: [:produced, :state_produced, :state_initiated, :reduced]) do
      edge.v2
    end
  end

  @doc """
  Returns all productions of a component or sub component by name.

  Many components are made up of sub components so this may return multiple facts for each part.
  """
  def productions(%__MODULE__{} = wrk, component_name) do
  end

  @doc """
  Returns all facts produced in the workflow so far by component name and sub component.

  Returns a map where each key is the name of the component and the value is a list of facts produced by that component.
  """
  def productions_by_component(%__MODULE__{graph: graph, components: components}) do
  end

  @doc """
  Lists all raw values of facts produced in the workflow so far.

  Does not return input fact values only those generated as a result of the workflow execution.

  ## Examples

      iex> workflow = Workflow.new()
      ...> workflow |> Workflow.add(Runic.step(fn fact -> fact end)) |> Workflow.react("hello") |> Workflow.raw_productions()
      ["hello"]
  """
  def raw_productions(%__MODULE__{graph: graph}) do
    for %Graph.Edge{} = edge <-
          Graph.edges(graph, by: [:produced, :state_produced, :state_initiated, :reduced]) do
      edge.v2.value
    end
  end

  def raw_productions(%__MODULE__{graph: graph}, component_name) do
  end

  def raw_productions_by_component(%__MODULE__{graph: graph}) do
  end

  @spec facts(Runic.Workflow.t()) :: list(Runic.Workflow.Fact.t())
  @doc """
  Lists facts processed in the workflow so far.

  Includes input facts with a `nil` ancestry and all facts generated as a result of the workflow execution.

  ## Examples

      iex> workflow = Workflow.new()
      ...> workflow |> Workflow.add(Runic.step(fn fact -> fact <> " world" end)) |> Workflow.react("hello") |> Workflow.facts()
      [%Fact{value: "hello", ancestry: nil}, %Fact{value: "hello world"}]
  """
  def facts(%__MODULE__{graph: graph}) do
    for v <- Graph.vertices(graph), match?(%Fact{}, v), do: v
  end

  @doc false
  def matches(%__MODULE__{graph: graph}) do
    for %Graph.Edge{} = edge <- Graph.edges(graph, by: [:matchable, :satisfied]) do
      edge.v2
    end
  end

  @doc """
  Cycles eagerly through a prepared agenda in the match phase and executes a single cycle of right hand side runnables.
  """
  def react(%__MODULE__{generations: generations} = wrk) when generations > 0 do
    Enum.reduce(next_runnables(wrk), wrk, fn {node, fact}, wrk ->
      invoke(wrk, node, fact)
    end)
  end

  @doc """
  Plans eagerly through the match phase then executes a single cycle of right hand side runnables.

  ## Example

      iex> workflow = Workflow.new()
      ...> workflow |> Workflow.add_step(fn fact -> fact end) |> Workflow.react("hello") |> Workflow.reactions()
      [%Fact{value: "hello"}]
  """
  def react(%__MODULE__{} = wrk, %Fact{ancestry: nil} = fact) do
    react(invoke(wrk, root(), fact))
  end

  def react(%__MODULE__{} = wrk, raw_fact) do
    react(wrk, Fact.new(value: raw_fact))
  end

  # def react_while(%__MODULE__{} = wrk, %Fact{ancestry: nil} = fact) do
  #   wrk
  #   |> react(fact)
  #   |> react_while()
  # end

  @doc """
  Cycles eagerly through runnables resulting from the input fact.

  Eagerly runs through the planning / match phase as does `react/2` but also eagerly executes
  subsequent phases of runnables until satisfied (nothing new to react to i.e. all
  terminating leaf nodes have been traversed to and executed) resulting in a fully satisfied agenda.

  `react_until_satisfied/2` is good for nested step -> [child_step_1, child_step2, ...] dependencies
  where the goal is to get to the results at the end of the pipeline of steps.

  Careful, react_until_satisfied can evaluate infinite loops if the expressed workflow will not terminate.

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
        invoke(wrk, node, fact)
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
    invoke(wrk, root(), fact)
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
      invoke(wrk, node, fact)
    end)
  end

  @doc """
  Eagerly plans through all output facts in the workflow produced in the previous generation to prepare the next set of runnables.

  This is useful for after a workflow has already been ran and satisfied without runnables and you want to continue
  preparing reactions in the workflow from the output facts of the previous run.
  """
  def plan_eagerly(%__MODULE__{} = workflow) do
    new_productions =
      for edge <-
            Graph.out_edges(workflow.graph, workflow.generations,
              by: :generation,
              where: fn edge ->
                Enum.empty?(Graph.out_edges(workflow.graph, edge.v2, by: [:runnable, :matchable]))
              end
            ) do
        edge.v2
      end

    Enum.reduce(new_productions, workflow, fn output_fact, wrk ->
      plan(wrk, output_fact)
    end)
    |> activate_through_possible_matches()
  end

  @doc """
  Invokes all left hand side / match-phase runnables in the workflow for a given input fact until all are satisfied.

  Upon calling plan_eagerly/2, the workflow will only have right hand side runnables left to execute that react or react_until_satisfied can execute.
  """
  def plan_eagerly(%__MODULE__{} = workflow, %Fact{ancestry: nil} = input_fact) do
    workflow
    |> plan(input_fact)
    |> activate_through_possible_matches()
  end

  def plan_eagerly(%__MODULE__{} = workflow, %Fact{ancestry: {_, _}} = produced_fact) do
    workflow
    |> plan(produced_fact)
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
      wrk
      |> invoke(node, fact)
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

  @doc """
  Executes the Invokable protocol for a runnable step and fact.

  This is a lower level API than as with the react or plan functions intended for process based
  scheduling and execution of workflows.

  See `invoke_with_events/2` for a version that returns events produced by the invokation that can be
  persisted incrementally as the workflow is executed for durable execution of long running workflows.
  """
  def invoke(%__MODULE__{} = wrk, step, fact) do
    wrk = run_before_hooks(wrk, step, fact)
    Invokable.invoke(step, wrk, fact)
  end

  @doc false
  def causal_generation(
        %__MODULE__{graph: graph},
        %Fact{ancestry: {_parent_step_hash, _parent_fact_hash}} = production_fact
      ) do
    graph
    |> Graph.edges(production_fact, by: [:produced, :state_produced, :state_initiated, :fan_out])
    |> hd()
    |> Map.get(:weight)

    +1
  end

  def causal_generation(
        %__MODULE__{graph: graph},
        %Fact{ancestry: nil} = input_fact
      ) do
    graph
    |> Graph.in_neighbors(input_fact)
    |> Enum.filter(&is_integer/1)
    |> hd()
  end

  @doc """
  Executes the Invokable protocol for a runnable step and fact and returns all newly caused events produced by the invokation.

  This API is intended to enable durable execution of long running workflows by returning events that can be persisted elsewhere
  so the workflow state can be rebuilt with `from_log/1`.
  """
  def invoke_with_events(%__MODULE__{} = wrk, step, fact) do
    wrk = invoke(wrk, step, fact)
    new_events = events_produced_since(wrk, fact)

    {wrk, new_events}
  end

  @doc """
  Returns all %ReactionOccurred{} events caused since the given fact.
  """
  def events_produced_since(
        %__MODULE__{} = wrk,
        %Fact{ancestry: {_parent_step_hash, _parent_fact_hash}} = fact
      ) do
    # return reaction edges transformed to %ReactionOccurred{} events that do not involve productions known since the given fact

    fact_generation =
      wrk.graph
      |> Graph.in_edges(fact, by: :produced)
      |> hd()
      |> Map.get(:weight)

    Graph.edges(wrk.graph,
      by: [
        :produced,
        :state_produced,
        :reduced,
        :satisfied,
        :state_initiated,
        :fan_out,
        :reduced,
        :joined
      ],
      where: fn edge -> edge.weight > fact_generation end
    )
    |> Enum.map(fn edge ->
      %ReactionOccurred{
        from: edge.v1,
        to: edge.v2,
        reaction: edge.label,
        weight: edge.weight,
        properties: edge.properties
      }
    end)
  end

  def events_produced_since(
        %__MODULE__{graph: graph},
        %Fact{ancestry: nil} = fact
      ) do
    # return reaction edges transformed to %ReactionOccurred{} events that do not involve productions known since the given fact

    fact_generation =
      graph
      |> Graph.in_edges(fact, by: :generation)
      |> hd()
      |> Map.get(:v1)

    Graph.edges(graph,
      by: [
        :produced,
        :state_produced,
        :reduced,
        :satisfied,
        :state_initiated,
        :fan_out,
        :reduced,
        :joined
      ],
      where: fn edge -> edge.weight > fact_generation end
    )
  end

  defp any_match_phase_runnables?(%__MODULE__{graph: graph}) do
    not Enum.empty?(Graph.edges(graph, by: :matchable))
  end

  defp next_match_runnables(%__MODULE__{graph: graph}) do
    for %{v1: fact, v2: step} <- Graph.edges(graph, by: :matchable) do
      {step, fact}
    end
  end

  @spec is_runnable?(Runic.Workflow.t()) :: boolean()
  def is_runnable?(%__MODULE__{graph: graph}) do
    not Enum.empty?(Graph.edges(graph, by: :runnable))
  end

  @doc """
  Returns a list of the next {node, fact} i.e "runnable" pairs ready for activation in the next cycle.

  All Runnables returned are independent and can be run in parallel then fed back into the Workflow
  without wait or delays to get the same results.
  """
  def next_runnables(%__MODULE__{graph: graph}) do
    for %Graph.Edge{} = edge <- Graph.edges(graph, by: :runnable) do
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
          Enum.flat_map(next_step_hashes, &Graph.out_edges(wrk.graph, &1, by: :runnable)) do
      {Map.get(wrk.graph.vertices, edge.v2), edge.v1}
    end
  end

  def next_runnables(%__MODULE__{graph: graph}, raw_fact) do
    for %Graph.Edge{} = edge <- Graph.out_edges(graph, root(), by: :flow) do
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
      for generation_edge <- Graph.out_edges(graph, generation, by: :generation) do
        for connection <- Graph.in_edges(graph, generation_edge.v2, by: :state_produced) do
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

  defp stateful_matching_impls do
    case Runic.Workflow.StatefulMatching.__protocol__(:impls) do
      {:consolidated, impls} -> impls
      :not_consolidated -> []
    end
  end

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

  def draw_connection(%__MODULE__{graph: g} = wrk, node_1, node_2, connection, opts \\ []) do
    opts = Keyword.put(opts, :label, connection)
    %__MODULE__{wrk | graph: Graph.add_edge(g, node_1, node_2, opts)}
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

  @spec prepare_next_runnables(Workflow.t(), any(), Fact.t()) :: Workflow.t()
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
end
