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
  alias Runic.Closure
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
          # name -> component hash
          components: map(),
          # node_hash -> list(hook_functions)
          before_hooks: map(),
          after_hooks: map(),
          # hash of parent fact for fan_out -> path_to_fan_in e.g. [fan_out, step1, step2, fan_in]
          mapped: map(),
          # input_fact_hash -> MapSet.new([produced_facts])
          inputs: map()
        }

  @type runnable() :: {fun(), term()}

  defstruct name: nil,
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
  def new(name) when is_binary(name) or is_atom(name) do
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

  @doc """
  Adds a component to the workflow, connecting it to the parent step or root if no parent is specified.
  """
  def add(%__MODULE__{} = workflow, component, opts \\ []) do
    case opts[:to] do
      nil ->
        # If no parent is specified, we assume the component is a root step
        parent_step = root()
        do_add_component(workflow, component, parent_step, opts)

      {component_name, _component_kind} = name
      when is_atom(component_name) or is_binary(component_name) ->
        parent_step = get_component!(workflow, name) |> List.first()

        do_add_component(workflow, component, parent_step, opts)

      component_name when is_atom(component_name) or is_binary(component_name) ->
        parent_step = get_component!(workflow, component_name)
        do_add_component(workflow, component, parent_step, opts)

      hash when is_integer(hash) ->
        parent_step = get_by_hash(workflow, hash)
        do_add_component(workflow, component, parent_step, opts)

      %{} = parent_step ->
        do_add_component(workflow, component, parent_step, opts)

      parent_steps when is_list(parent_steps) ->
        parent_steps = Enum.map(parent_steps, &get_component!(workflow, &1))

        do_add_component(workflow, component, parent_steps, opts)

        # join =
        #   parent_steps
        #   |> Enum.map(& &1.hash)
        #   |> Join.new()

        # Enum.reduce(parent_steps, workflow, fn parent_step, acc ->
        #   acc = add_step(acc, parent_step, join)
        #   do_add_component(acc, component, join, opts)
        # end)
    end
  end

  defp do_add_component(%__MODULE__{} = workflow, component, parent, opts) do
    should_log = Keyword.get(opts, :log, true)

    case {component, parent} do
      {%{__struct__: struct}, %Root{}} ->
        if struct not in Components.component_impls() do
          workflow = add_step(workflow, parent, component)

          if should_log do
            append_build_log(workflow, component, parent)
          else
            workflow
          end
        else
          workflow = Component.connect(component, parent, workflow)

          if should_log do
            append_build_log(workflow, component, parent)
          else
            workflow
          end
        end

      {%{__struct__: _struct} = component, _parent} ->
        workflow = Component.connect(component, parent, workflow)

        if should_log do
          append_build_log(workflow, component, parent)
        else
          workflow
        end

      _otherwise ->
        raise ArgumentError,
              "Cannot add component #{inspect(component)} to #{inspect(parent)} in workflow, it does not implement Runic.Component protocol."
    end
  end

  def add_with_events(%__MODULE__{} = workflow, component, opts \\ []) do
    to = opts[:to]

    parent_step =
      if not is_nil(to) do
        get_component(workflow, to) ||
          get_by_hash(workflow, to) ||
          root()
      else
        root()
      end

    events = build_events(component, to)

    workflow =
      component
      |> Component.connect(parent_step, workflow)
      |> append_build_log(events)

    # |> maybe_put_component(component)

    {workflow, events}
  end

  defp build_events(component, parents) when is_list(parents) do
    Enum.reduce(parents, [], fn parent, events ->
      events ++ build_events(component, parent)
    end)
  end

  defp build_events(component, %{name: name}) do
    build_events(component, name)
  end

  defp build_events(component, parent) do
    closure = Map.get(component, :closure)

    [
      %ComponentAdded{
        closure: closure,
        name: component.name,
        to: parent,
        # Backward compatibility: also set source/bindings for old deserialization
        source: Component.source(component),
        bindings: if(closure, do: closure.bindings, else: %{})
      }
    ]
  end

  defp append_build_log(%__MODULE__{build_log: bl} = workflow, events) when is_list(events) do
    %__MODULE__{
      workflow
      | build_log: bl ++ events
    }
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
    # Use new closure field if available, otherwise fall back to old format
    event =
      case Map.get(component, :closure) do
        %Closure{} = closure ->
          %ComponentAdded{
            closure: closure,
            name: component.name,
            to: parent
          }

        nil ->
          # Backward compatibility: use old source + bindings format
          %ComponentAdded{
            source: Component.source(component),
            name: component.name,
            to: parent,
            bindings: Map.get(component, :bindings, %{})
          }
      end

    %__MODULE__{
      workflow
      | build_log: [event | bl]
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

  def apply_event(%__MODULE__{} = wrk, %ComponentAdded{} = event) do
    component = component_from_added(event)

    add(wrk, component, to: event.to)
  end

  def apply_events(%__MODULE__{} = wrk, events) when is_list(events) do
    Enum.reduce(events, wrk, fn event, acc ->
      apply_event(acc, event)
    end)
  end

  defp component_from_added(
         %ComponentAdded{source: source, bindings: bindings, closure: closure} = event
       ) do
    component =
      cond do
        # New format: use closure if available
        not is_nil(closure) ->
          {comp, _} = Closure.eval(closure)
          comp

        # Old format: source + bindings with __caller_context__
        not is_nil(source) ->
          component_from_source_and_bindings(source, bindings)

        # Fallback: shouldn't happen
        true ->
          raise "ComponentAdded event has neither closure nor source"
      end

    component
    |> Map.put(:name, event.name)
  end

  # Backward compatibility: evaluate source with old __caller_context__ approach
  defp component_from_source_and_bindings(source, bindings) do
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

    component
  end

  @doc """
  Rebuilds a workflow from a list of `%ComponentAdded{}` and/or `%ReactionOccurred{}` events.
  """
  def from_log(events) do
    Enum.reduce(events, new(), fn
      %ComponentAdded{} = event, wrk ->
        component = component_from_added(event)

        # Add the component to the workflow
        add(wrk, component, to: event.to)

      %ReactionOccurred{reaction: :generation}, wrk ->
        # Skip legacy generation edges - generation counters removed
        wrk

      %ReactionOccurred{} = ro, wrk ->
        reaction_edge =
          Graph.Edge.new(
            ro.from,
            ro.to,
            label: ro.reaction,
            weight: ro.weight,
            properties: ro.properties
          )

        %__MODULE__{
          wrk
          | graph: Graph.add_edge(wrk.graph, reaction_edge)
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

  @doc false
  def register_component(%__MODULE__{} = workflow, component) do
    hash = Component.hash(component)

    workflow =
      %__MODULE__{
        workflow
        | components: Map.put(workflow.components, component.name, hash)
      }

    # For Map components, also register their sub-components with proper namespacing
    case component do
      %Runic.Workflow.Map{components: map_components, name: map_name}
      when not is_nil(map_components) ->
        Enum.reduce(map_components, workflow, fn {sub_name, sub_component}, acc ->
          case sub_name do
            :fan_out ->
              # Register fan_out as {map_name, :fan_out}
              components = Map.put(acc.components, {map_name, :fan_out}, sub_component.hash)
              %__MODULE__{acc | components: components}

            _ ->
              acc
          end
        end)

      _ ->
        workflow
    end
  end

  @doc """
  Returns a map of all registered components in the workflow by the registered component name.
  """
  def components(%__MODULE__{} = workflow) do
    Map.new(workflow.components, fn {name, hash} ->
      {name, Map.get(workflow.graph.vertices, hash)}
    end)
  end

  @doc """
  Returns a keyword list of sub-components of the given component by kind.
  """
  def sub_components(%__MODULE__{} = workflow, component_name) do
    component = get_component(workflow, component_name)

    workflow.graph
    |> Graph.out_edges(component, by: :component_of)
    |> Enum.map(fn edge -> {edge.properties.kind, edge.v2} end)
  end

  # extend with I/O contract checks
  def connectables(%__MODULE__{} = wrk, name)
      when is_binary(name) or is_atom(name) or is_tuple(name) do
    component = get_component(wrk, name)

    connectables(wrk, component)
  end

  def connectables(%__MODULE__{graph: g} = _wrk, %{} = component) do
    impls = Components.component_impls()

    arity = Components.arity_of(component)

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
    :ok
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

  def add_after_hooks(%__MODULE__{} = workflow, nil), do: workflow

  def add_after_hooks(%__MODULE__{} = workflow, hooks) do
    %__MODULE__{
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

  defp resolve_component_to_node(%__MODULE__{} = workflow, {component_name, sub_component_kind}) do
    get_component(workflow, {component_name, sub_component_kind}) |> List.first()
  end

  defp resolve_component_to_node(%__MODULE__{} = workflow, component_name)
       when is_atom(component_name) or is_binary(component_name) do
    get_component!(workflow, component_name)
  end

  defp resolve_component_to_node(%__MODULE__{} = workflow, hash) when is_integer(hash) do
    get_by_hash(workflow, hash)
  end

  def attach_before_hook(%__MODULE__{} = workflow, component_name, hook)
      when is_function(hook, 3) do
    node = resolve_component_to_node(workflow, component_name)
    node_hash = node.hash
    hooks_for_component = Map.get(workflow.before_hooks, node_hash, [])

    %__MODULE__{
      workflow
      | before_hooks:
          Map.put(
            workflow.before_hooks,
            node_hash,
            Enum.reverse([hook | hooks_for_component])
          )
    }
  end

  @doc """
  Attaches a hook function to be run after a given component step.

  ## Examples

  ```
  workflow
  |> Workflow.attach_after_hook("my_component", fn step, workflow, output_fact ->
    IO.inspect(output_fact, label: "Output fact")
    IO.inspect(step, label: "Step")
    workflow
  end)
  ```
  """
  def attach_after_hook(%__MODULE__{} = workflow, component_name, hook)
      when is_function(hook, 3) do
    node = resolve_component_to_node(workflow, component_name)
    node_hash = node.hash
    hooks_for_component = Map.get(workflow.after_hooks, node_hash, [])

    %__MODULE__{
      workflow
      | after_hooks:
          Map.put(
            workflow.after_hooks,
            node_hash,
            Enum.reverse([hook | hooks_for_component])
          )
    }
  end

  @doc false
  def run_before_hooks(%__MODULE__{} = workflow, %{hash: hash} = step, input_fact) do
    case get_before_hooks(workflow, hash) do
      nil ->
        workflow

      hooks ->
        Enum.reduce(hooks, workflow, fn hook, wrk -> hook.(step, wrk, input_fact) end)
    end
  end

  def run_before_hooks(%__MODULE__{} = workflow, _step, _input_fact), do: workflow

  def run_after_hooks(%__MODULE__{} = workflow, %{hash: hash} = step, output_fact) do
    case get_after_hooks(workflow, hash) do
      nil ->
        workflow

      hooks ->
        Enum.reduce(hooks, workflow, fn hook, wrk -> hook.(step, wrk, output_fact) end)
    end
  end

  def run_after_hooks(%__MODULE__{} = workflow, _step, _input_fact), do: workflow

  @doc """
  Applies a list of hook apply functions to the workflow.

  This is used during the apply phase to execute deferred workflow
  modifications returned by hooks during the execute phase.

  ## Example

      workflow
      |> Workflow.apply_hook_fns(before_apply_fns)
      |> do_main_apply_logic()
      |> Workflow.apply_hook_fns(after_apply_fns)
  """
  @spec apply_hook_fns(t(), [function()]) :: t()
  def apply_hook_fns(%__MODULE__{} = workflow, apply_fns) when is_list(apply_fns) do
    Enum.reduce(apply_fns, workflow, fn apply_fn, wrk -> apply_fn.(wrk) end)
  end

  def apply_hook_fns(%__MODULE__{} = workflow, nil), do: workflow

  defp get_before_hooks(%__MODULE__{} = workflow, hash) do
    Map.get(workflow.before_hooks, hash)
  end

  defp get_after_hooks(%__MODULE__{} = workflow, hash) do
    Map.get(workflow.after_hooks, hash)
  end

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
      add(wrk, rule)
    end)
  end

  def add_steps(workflow, steps) when is_list(steps) do
    # root level pass
    Enum.reduce(steps, workflow, fn
      %Step{} = step, wrk ->
        add(wrk, step)

      {[_step | _] = parent_steps, dependent_steps}, wrk ->
        wrk =
          Enum.reduce(parent_steps, wrk, fn step, wrk ->
            # add_step(wrk, step)
            add(wrk, step)
          end)

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
            add(wrk, step, to: parent_step)
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

  def maybe_put_component(%__MODULE__{} = workflow, %{} = _step), do: workflow

  def get_named_vertex(%__MODULE__{graph: g, mapped: mapped}, name) do
    hash = Map.get(mapped, name)
    g.vertices |> Map.get(hash)
  end

  def get_component(
        %__MODULE__{} = wrk,
        {component_name, subcomponent_kind_or_name}
      ) do
    cmp = get_component(wrk, component_name)

    for edge <-
          Graph.out_edges(wrk.graph, cmp,
            by: :component_of,
            where: fn edge ->
              edge.properties[:kind] == subcomponent_kind_or_name or
                Map.get(edge.v2, :name) == subcomponent_kind_or_name
            end
          ) do
      edge.v2
    end
  end

  def get_component(%__MODULE__{} = wrk, %{name: name}) do
    get_component(wrk, name)
  end

  # def get_component(%__MODULE__{components: components}, names) when is_list(names) do
  #   Enum.map(names, fn name -> Map.get(components, name) end)
  # end
  def get_component(%__MODULE__{} = workflow, names) when is_list(names) do
    Enum.map(names, &get_component(workflow, &1))
  end

  def get_component(
        %__MODULE__{components: components, graph: g},
        component_name
      ) do
    component_hash = Map.get(components, component_name)
    Map.get(g.vertices, component_hash)
  end

  # def get_component(%__MODULE__{components: components}, name) do
  #   Map.get(components, name)
  # end

  def get_component!(wrk, name) do
    get_component(wrk, name) || raise(KeyError, "No component found with name #{name}")
  end

  def fetch_component(%__MODULE__{} = wrk, %{name: name}) do
    fetch_component(wrk, name)
  end

  def fetch_component(%__MODULE__{components: components} = wrk, name) do
    case Map.fetch(components, name) do
      :error ->
        {:error, :no_component_by_name}

      {:ok, cmp_hash} ->
        component = Map.get(wrk.graph.vertices, cmp_hash)
        {:ok, component}
    end
  end

  @doc """
  The next outgoing dataflow steps from a given `parent_step`.
  """
  def next_steps(%__MODULE__{graph: g}, parent_step) do
    next_steps(g, parent_step)
  end

  def next_steps(%Graph{} = g, parent_steps) when is_list(parent_steps) do
    Enum.flat_map(parent_steps, fn parent_step ->
      next_steps(g, parent_step)
    end)
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
  def merge(%__MODULE__{} = workflow, %__MODULE__{} = workflow2) do
    Component.connect(workflow2, %Root{}, workflow)
  end

  # def merge(
  #       %__MODULE__{graph: g1, components: c1, mapped: m1} = workflow,
  #       %__MODULE__{graph: g2, components: c2, mapped: m2} = _workflow2
  #     ) do
  #   merged_graph =
  #     Graph.Reducers.Bfs.reduce(g2, g1, fn
  #       %Root{} = root, g ->
  #         out_edges = Enum.uniq(Graph.out_edges(g, root) ++ Graph.out_edges(g2, root))

  #         g =
  #           Enum.reduce(out_edges, Graph.add_vertex(g, root), fn edge, g ->
  #             Graph.add_edge(g, edge)
  #           end)

  #         {:next, g}

  #       generation, g when is_integer(generation) ->
  #         out_edges = Enum.uniq(Graph.out_edges(g, generation) ++ Graph.out_edges(g2, generation))

  #         g =
  #           g
  #           |> Graph.add_vertex(generation)
  #           |> Graph.add_edges(out_edges)

  #         {:next, g}

  #       v, g ->
  #         g = Graph.add_vertex(g, v, v.hash)

  #         out_edges = Enum.uniq(Graph.out_edges(g, v) ++ Graph.out_edges(g2, v))

  #         g =
  #           Enum.reduce(out_edges, g, fn
  #             %{v1: %Fact{} = _fact_v1, v2: _v2, label: :generation} = memory2_edge, mem ->
  #               Graph.add_edge(mem, memory2_edge)

  #             %{v1: %Fact{} = fact_v1, v2: v2, label: label} = memory2_edge, mem
  #             when label in [:matchable, :runnable, :ran] ->
  #               out_edge_labels_of_into_mem_for_edge =
  #                 mem
  #                 |> Graph.out_edges(fact_v1)
  #                 |> Enum.filter(&(&1.v2 == v2))
  #                 |> MapSet.new(& &1.label)

  #               cond do
  #                 label in [:matchable, :runnable] and
  #                     MapSet.member?(out_edge_labels_of_into_mem_for_edge, :ran) ->
  #                   mem

  #                 label == :ran and
  #                     MapSet.member?(out_edge_labels_of_into_mem_for_edge, :runnable) ->
  #                   Graph.update_labelled_edge(mem, fact_v1, v2, :runnable, label: :ran)

  #                 true ->
  #                   Graph.add_edge(mem, memory2_edge)
  #               end

  #             %{v1: _v1, v2: _v2} = memory2_edge, mem ->
  #               Graph.add_edge(mem, memory2_edge)
  #           end)

  #         {:next, g}
  #     end)

  #   %__MODULE__{
  #     workflow
  #     | graph: merged_graph,
  #       components: Map.merge(c1, c2),
  #       mapped:
  #         Enum.reduce(m1, m2, fn
  #           {:mapped_paths, mapset}, acc ->
  #             Map.put(acc, :mapped_paths, MapSet.union(acc.mapped_paths, mapset))

  #           {k, v}, acc ->
  #             Map.put(
  #               acc,
  #               k,
  #               [v | acc[k] || []]
  #               |> List.flatten()
  #               |> Enum.reject(&is_nil/1)
  #               |> Enum.reverse()
  #               |> Enum.uniq()
  #             )
  #         end)
  #   }
  # end

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
  def productions(%__MODULE__{} = wrk, component_name)
      when is_atom(component_name) or is_binary(component_name) do
    cmp = get_component(wrk, component_name)

    productions(wrk, cmp)
  end

  def productions(%__MODULE__{} = wrk, component) do
    wrk.graph
    |> Graph.out_edges(component, by: :component_of)
    |> Enum.flat_map(fn %{v2: invokable} ->
      for edge <-
            Graph.out_edges(wrk.graph, invokable,
              by: [:produced, :state_produced, :state_initiated, :reduced]
            ) do
        edge.v2
      end
    end)
  end

  @doc """
  Returns all facts produced in the workflow so far by component name and sub component.

  Returns a map where each key is the name of the component and the value is a list of facts produced by that component.
  """
  def productions_by_component(%__MODULE__{components: components} = wrk) do
    Map.new(components, fn {name, component} ->
      productions = productions(wrk, component)

      {name, productions}
    end)
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

  def raw_productions_by_component(%__MODULE__{components: components} = wrk) do
    Map.new(components, fn {name, component} ->
      productions = raw_productions(wrk, component)

      {name, productions}
    end)
  end

  def raw_productions(%__MODULE__{} = wrk, component_name)
      when is_atom(component_name) or is_binary(component_name) do
    cmp = get_component(wrk, component_name)

    raw_productions(wrk, cmp)
  end

  def raw_productions(%__MODULE__{} = wrk, component) do
    wrk.graph
    |> Graph.out_edges(component, by: :component_of)
    |> Enum.flat_map(fn %{v2: invokable} ->
      for edge <-
            Graph.out_edges(wrk.graph, invokable,
              by: [:produced, :state_produced, :state_initiated, :reduced]
            ) do
        edge.v2.value
      end
    end)
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
  Executes a single reaction cycle using the three-phase model.

  Uses `prepare_for_dispatch/1` to prepare runnables, executes them, and applies results back.

  ## Options

  - `:async` - When `true`, executes runnables in parallel using `Task.async_stream`. 
    Useful for I/O-bound workflows. Default: `false` (serial execution)
  - `:max_concurrency` - Maximum parallel tasks when `async: true`. Default: `System.schedulers_online()`
  - `:timeout` - Timeout for each task when `async: true`. Default: `:infinity`

  ## Example

      workflow = Workflow.react(workflow)
      workflow = Workflow.react(workflow, async: true, max_concurrency: 4)
  """
  @spec react(t(), keyword()) :: t()
  def react(workflow, opts \\ [])

  def react(%__MODULE__{} = workflow, opts) when is_list(opts) do
    if is_runnable?(workflow) do
      {workflow, runnables} = prepare_for_dispatch(workflow)

      if Keyword.get(opts, :async, false) do
        execute_runnables_async(workflow, runnables, opts)
      else
        execute_runnables_serial(workflow, runnables)
      end
    else
      workflow
    end
  end

  def react(%__MODULE__{} = wrk, %Fact{ancestry: nil} = fact) do
    react(wrk, fact, [])
  end

  def react(%__MODULE__{} = wrk, raw_fact) when not is_list(raw_fact) do
    react(wrk, Fact.new(value: raw_fact), [])
  end

  @doc """
  Plans eagerly through the match phase then executes a single cycle of right hand side runnables.

  ## Options

  - `:async` - When `true`, executes runnables in parallel. Default: `false`
  - `:max_concurrency` - Maximum parallel tasks when `async: true`
  - `:timeout` - Timeout for each task when `async: true`

  ## Example

      iex> workflow = Workflow.new()
      ...> workflow |> Workflow.add_step(fn fact -> fact end) |> Workflow.react("hello") |> Workflow.reactions()
      [%Fact{value: "hello"}]
  """
  @spec react(t(), Fact.t() | term(), keyword()) :: t()
  def react(%__MODULE__{} = wrk, %Fact{ancestry: nil} = fact, opts) do
    wrk
    |> invoke(root(), fact)
    |> react(opts)
  end

  def react(%__MODULE__{} = wrk, raw_fact, opts) do
    react(wrk, Fact.new(value: raw_fact), opts)
  end

  defp execute_runnables_serial(workflow, runnables) do
    runnables
    |> Enum.map(fn runnable -> Invokable.execute(runnable.node, runnable) end)
    |> Enum.reduce(workflow, fn executed, wrk -> apply_runnable(wrk, executed) end)
  end

  defp execute_runnables_async(workflow, runnables, opts) do
    max_concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online())
    timeout = Keyword.get(opts, :timeout, :infinity)

    runnables
    |> Task.async_stream(
      fn runnable -> Invokable.execute(runnable.node, runnable) end,
      max_concurrency: max_concurrency,
      timeout: timeout
    )
    |> Enum.reduce(workflow, fn
      {:ok, executed}, wrk ->
        apply_runnable(wrk, executed)

      {:exit, reason}, wrk ->
        Logger.warning("Async execution failed: #{inspect(reason)}")
        wrk
    end)
  end

  @doc """
  Cycles eagerly through runnables resulting from the input fact until satisfied.

  Eagerly runs through the planning / match phase as does `react/2` but also eagerly executes
  subsequent phases of runnables until satisfied (nothing new to react to i.e. all
  terminating leaf nodes have been traversed to and executed) resulting in a fully satisfied agenda.

  `react_until_satisfied/2` is good for nested step -> [child_step_1, child_step2, ...] dependencies
  where the goal is to get to the results at the end of the pipeline of steps.

  Careful, react_until_satisfied can evaluate infinite loops if the expressed workflow will not terminate.

  If your goal is to evaluate some non-terminating program to some finite number of generations - wrapping
  `react/2` in a process that can track workflow evaluation livecycles until desired is recommended.

  ## Options

  - `:async` - When `true`, executes runnables in parallel. Default: `false`
  - `:max_concurrency` - Maximum parallel tasks when `async: true`
  - `:timeout` - Timeout for each task when `async: true`

  ## Example

      workflow = Workflow.react_until_satisfied(workflow, input)
      workflow = Workflow.react_until_satisfied(workflow, input, async: true)
  """
  @spec react_until_satisfied(t(), Fact.t() | term(), keyword()) :: t()
  def react_until_satisfied(workflow, fact_or_value \\ nil, opts \\ [])

  def react_until_satisfied(%__MODULE__{} = workflow, nil, opts) do
    do_react_until_satisfied(workflow, is_runnable?(workflow), opts)
  end

  def react_until_satisfied(%__MODULE__{} = wrk, %Fact{ancestry: nil} = fact, opts) do
    wrk
    |> react(fact, opts)
    |> react_until_satisfied(nil, opts)
  end

  def react_until_satisfied(%__MODULE__{} = wrk, raw_fact, opts) do
    react_until_satisfied(wrk, Fact.new(value: raw_fact), opts)
  end

  defp do_react_until_satisfied(%__MODULE__{} = workflow, true = _is_runnable?, opts) do
    workflow
    |> react(opts)
    |> then(fn wrk -> do_react_until_satisfied(wrk, is_runnable?(wrk), opts) end)
  end

  defp do_react_until_satisfied(%__MODULE__{} = workflow, false = _is_runnable?, _opts),
    do: workflow

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
  Eagerly plans through all produced facts in the workflow that haven't yet activated
  subsequent runnables.

  This is useful for after a workflow has already been ran and satisfied without runnables
  and you want to continue preparing reactions in the workflow from output facts.

  Finds facts via `:produced` edges that don't have pending `:runnable` or `:matchable` edges.
  """
  def plan_eagerly(%__MODULE__{graph: graph} = workflow) do
    # Find all produced facts that don't have pending activations
    new_productions =
      for edge <- Graph.edges(graph, by: [:produced, :state_produced, :reduced]),
          fact = edge.v2,
          is_struct(fact, Fact),
          Enum.empty?(Graph.out_edges(graph, fact, by: [:runnable, :matchable])) do
        fact
      end
      |> Enum.uniq()

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
  Executes the Invokable protocol for a runnable step and fact using the three-phase model.

  This is a lower level API than as with the react or plan functions intended for process based
  scheduling and execution of workflows.

  The three-phase execution model:
  1. **Prepare** - Extract minimal context from workflow, build a `%Runnable{}`
  2. **Execute** - Run the node's work function in isolation
  3. **Apply** - Reduce results back into the workflow

  See `invoke_with_events/2` for a version that returns events produced by the invokation that can be
  persisted incrementally as the workflow is executed for durable execution of long running workflows.
  """
  def invoke(%__MODULE__{} = wrk, step, fact) do
    case Invokable.prepare(step, wrk, fact) do
      {:ok, runnable} ->
        executed = Invokable.execute(step, runnable)
        apply_runnable(wrk, executed)

      {:skip, reducer_fn} ->
        reducer_fn.(wrk)

      {:defer, reducer_fn} ->
        reducer_fn.(wrk)
    end
  end

  @doc false
  @deprecated "Use causal_depth/2 or ancestry_depth/2 instead"
  def causal_generation(%__MODULE__{} = workflow, %Fact{} = fact) do
    # Backward compatibility: returns depth + 1 to match old behavior
    ancestry_depth(workflow, fact) + 1
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

  Uses ancestry-based causal ordering. Returns events with depth greater than
  the reference fact's depth, scoped to the same causal root.
  """
  def events_produced_since(
        %__MODULE__{graph: graph} = wrk,
        %Fact{} = fact
      ) do
    ref_depth = ancestry_depth(wrk, fact)
    ref_root = root_ancestor_hash(wrk, fact)

    reaction_labels = [
      :produced,
      :state_produced,
      :reduced,
      :satisfied,
      :state_initiated,
      :fan_out,
      :joined
    ]

    Graph.edges(graph,
      by: reaction_labels,
      where: fn edge -> edge.weight > ref_depth end
    )
    |> Enum.filter(fn edge ->
      # Only include facts from the same causal chain
      case edge.v2 do
        %Fact{} = produced_fact ->
          root_ancestor_hash(wrk, produced_fact) == ref_root

        _ ->
          true
      end
    end)
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
    not Enum.empty?(Graph.edges(graph, by: [:runnable, :matchable]))
  end

  @doc """
  Returns a list of the next {node, fact} i.e "runnable" pairs ready for activation in the next cycle.

  All Runnables returned are independent and can be run in parallel then fed back into the Workflow
  without wait or delays to get the same results.
  """
  def next_runnables(%__MODULE__{graph: graph}) do
    for %Graph.Edge{} = edge <- Graph.edges(graph, by: [:runnable, :matchable]) do
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
      | graph: Graph.add_vertex(graph, fact)
    }
  end

  defp maybe_prepare_next_generation_from_state_accumulations(
         %__MODULE__{graph: graph} = workflow
       ) do
    # Find all state_produced facts by walking :state_produced edges from accumulators
    state_produced_facts_by_ancestor =
      for edge <- Graph.edges(graph, by: :state_produced) do
        edge.v2
      end
      |> Enum.reduce(%{}, fn %{ancestry: {accumulator_hash, _}} = state_produced_fact, acc ->
        # Keep the latest state fact for each accumulator
        existing = Map.get(acc, accumulator_hash)

        if is_nil(existing) or
             ancestry_depth(workflow, state_produced_fact) > ancestry_depth(workflow, existing) do
          Map.put(acc, accumulator_hash, state_produced_fact)
        else
          acc
        end
      end)

    stateful_matching_impls = stateful_matching_impls()
    state_produced_fact_ancestors = Map.keys(state_produced_facts_by_ancestor)

    unless Enum.empty?(state_produced_facts_by_ancestor) do
      Graph.Reducers.Bfs.reduce(graph, workflow, fn
        node, wrk ->
          if is_struct(node) and node.__struct__ in stateful_matching_impls do
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
  end

  defp stateful_matching_impls do
    case Runic.Workflow.StatefulMatching.__protocol__(:impls) do
      {:consolidated, impls} -> impls
      :not_consolidated -> []
    end
  end

  @doc false
  @deprecated "Generation counters removed; use ancestry_depth/2 for causal ordering"
  def prepare_next_generation(%__MODULE__{} = workflow, %Fact{}), do: workflow

  def prepare_next_generation(%__MODULE__{} = workflow, [%Fact{} | _] = _facts),
    do: workflow

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

  @doc """
  Computes the causal depth of a fact by walking its ancestry chain.

  Replaces generation counter for causal ordering. A fact with no ancestry
  (root input) has depth 0. Each causal step adds 1 to the depth.

  ## Examples

      iex> ancestry_depth(workflow, root_fact)
      0

      iex> ancestry_depth(workflow, fact_after_two_steps)
      2
  """
  @spec ancestry_depth(t(), Fact.t()) :: non_neg_integer()
  def ancestry_depth(%__MODULE__{}, %Fact{ancestry: nil}), do: 0

  def ancestry_depth(%__MODULE__{graph: graph} = workflow, %Fact{
        ancestry: {_producer_hash, parent_fact_hash}
      }) do
    case Map.get(graph.vertices, parent_fact_hash) do
      %Fact{} = parent_fact ->
        1 + ancestry_depth(workflow, parent_fact)

      nil ->
        1
    end
  end

  @doc """
  Returns the causal depth of a fact, preferring ancestry-based computation.

  This is the new API that replaces `causal_generation/2`. It computes depth
  by walking the ancestry chain rather than relying on generation edge weights.

  For facts without ancestry (root inputs), returns 0.

  ## Examples

      iex> causal_depth(workflow, root_fact)
      0

      iex> causal_depth(workflow, produced_fact)
      3  # produced after 3 causal steps
  """
  @spec causal_depth(t(), Fact.t()) :: non_neg_integer()
  def causal_depth(%__MODULE__{} = workflow, %Fact{} = fact) do
    ancestry_depth(workflow, fact)
  end

  @doc """
  Finds the root ancestor fact hash for a given fact.

  Walks the ancestry chain until it finds a fact with `ancestry: nil` (root input).
  Returns the hash of that root fact, or the fact's own hash if it is a root.

  ## Examples

      iex> root_ancestor_hash(workflow, root_fact)
      123456  # root_fact.hash

      iex> root_ancestor_hash(workflow, deeply_nested_fact)
      123456  # hash of the original root input
  """
  @spec root_ancestor_hash(t(), Fact.t()) :: integer() | nil
  def root_ancestor_hash(%__MODULE__{}, %Fact{ancestry: nil, hash: hash}), do: hash

  def root_ancestor_hash(%__MODULE__{graph: graph} = workflow, %Fact{
        ancestry: {_producer_hash, parent_fact_hash}
      }) do
    case Map.get(graph.vertices, parent_fact_hash) do
      %Fact{} = parent_fact ->
        root_ancestor_hash(workflow, parent_fact)

      nil ->
        nil
    end
  end

  @doc """
  Gets the hooks for a given node hash.

  Returns a tuple of {before_hooks, after_hooks} for use in CausalContext.
  """
  @spec get_hooks(t(), integer()) :: {list(), list()}
  def get_hooks(%__MODULE__{before_hooks: before, after_hooks: after_hooks}, node_hash) do
    {Map.get(before, node_hash, []), Map.get(after_hooks, node_hash, [])}
  end

  # =============================================================================
  # Three-Phase Execution API (Phase 4 & 5)
  # =============================================================================

  alias Runic.Workflow.Runnable

  @doc """
  Returns a list of prepared `%Runnable{}` structs ready for execution.

  This is the three-phase version of `next_runnables/1`. Each runnable contains
  everything needed to execute independently of the workflow.

  ## Three-Phase Execution Model

  1. **Prepare** - This function calls `Invokable.prepare/3` for each pending node
  2. **Execute** - Call `Invokable.execute/2` on each runnable (can be parallelized)
  3. **Apply** - Call `runnable.apply_fn.(workflow)` to reduce results back

  ## Returns

  A list of `%Runnable{}` structs with status `:pending`, ready for `execute/2`.
  Nodes that return `{:skip, _}` or `{:defer, _}` from prepare are handled immediately
  and not included in the returned list.

  ## Example

      runnables = Workflow.prepared_runnables(workflow)
      executed = Enum.map(runnables, &Invokable.execute(&1.node, &1))
      workflow = Enum.reduce(executed, workflow, &Workflow.apply_runnable(&2, &1))
  """
  @spec prepared_runnables(t()) :: [Runnable.t()]
  def prepared_runnables(%__MODULE__{graph: graph} = workflow) do
    for %Graph.Edge{} = edge <- Graph.edges(graph, by: [:runnable, :matchable]),
        node = edge.v2,
        fact = edge.v1,
        runnable <- prepare_node(workflow, node, fact) do
      runnable
    end
  end

  defp prepare_node(workflow, node, fact) do
    case Invokable.prepare(node, workflow, fact) do
      {:ok, runnable} -> [runnable]
      {:skip, _reducer_fn} -> []
      {:defer, _reducer_fn} -> []
    end
  end

  @doc """
  Prepares all available runnables for external dispatch.

  Returns `{workflow, [%Runnable{}]}` where the workflow may have been updated
  by skip/defer reducers, and the runnables list contains nodes ready for execution.

  This is designed for external schedulers that want to dispatch execution
  to worker pools or distributed systems.

  ## Example

      {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

      # Dispatch to worker pool (can be parallel)
      executed = Task.async_stream(runnables, fn r ->
        Invokable.execute(r.node, r)
      end, timeout: :infinity)

      # Apply results back
      workflow = Enum.reduce(executed, workflow, fn {:ok, r}, w ->
        Workflow.apply_runnable(w, r)
      end)
  """
  @spec prepare_for_dispatch(t()) :: {t(), [Runnable.t()]}
  def prepare_for_dispatch(%__MODULE__{graph: graph} = workflow) do
    Graph.edges(graph, by: [:runnable, :matchable])
    |> Enum.reduce({workflow, []}, fn %Graph.Edge{v2: node, v1: fact}, {wrk, runnables} ->
      case Invokable.prepare(node, wrk, fact) do
        {:ok, runnable} ->
          {wrk, [runnable | runnables]}

        {:skip, reducer_fn} ->
          {reducer_fn.(wrk), runnables}

        {:defer, reducer_fn} ->
          {reducer_fn.(wrk), runnables}
      end
    end)
    |> then(fn {wrk, runnables} -> {wrk, Enum.reverse(runnables)} end)
  end

  @doc """
  Applies a completed runnable back to the workflow.

  Called by schedulers after receiving execution results. The runnable's
  `apply_fn` is invoked to reduce results into the workflow state.

  ## Parameters

  - `workflow` - The current workflow state
  - `runnable` - A runnable with status `:completed` or `:failed`

  ## Returns

  Updated workflow with the runnable's effects applied.

  ## Example

      executed = Invokable.execute(runnable.node, runnable)
      workflow = Workflow.apply_runnable(workflow, executed)
  """
  @spec apply_runnable(t(), Runnable.t()) :: t()
  def apply_runnable(%__MODULE__{} = workflow, %Runnable{status: :completed, apply_fn: apply_fn})
      when is_function(apply_fn, 1) do
    apply_fn.(workflow)
  end

  def apply_runnable(%__MODULE__{} = workflow, %Runnable{status: :skipped, apply_fn: apply_fn})
      when is_function(apply_fn, 1) do
    apply_fn.(workflow)
  end

  def apply_runnable(%__MODULE__{} = workflow, %Runnable{status: :failed} = runnable) do
    handle_failed_runnable(workflow, runnable)
  end

  def apply_runnable(%__MODULE__{} = workflow, %Runnable{status: :pending}) do
    workflow
  end

  defp handle_failed_runnable(%__MODULE__{} = workflow, %Runnable{
         node: node,
         input_fact: fact,
         error: error
       }) do
    Logger.warning("Runnable failed for node #{inspect(node)} with error: #{inspect(error)}")
    mark_runnable_as_ran(workflow, node, fact)
  end
end
