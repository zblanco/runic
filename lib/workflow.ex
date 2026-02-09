defmodule Runic.Workflow do
  @moduledoc """
  Runtime evaluation engine for Runic workflows.

  Runic Workflows are used to compose many branching steps, rules and accumulations/reductions
  at runtime for lazy or eager evaluation. You can think of Runic Workflows as a recipe of rules
  that when fed a stream of facts may react.

  ## Quick Start

      require Runic
      alias Runic.Workflow

      workflow = Runic.workflow(
        steps: [
          {Runic.step(fn x -> x + 1 end, name: :add),
           [Runic.step(fn x -> x * 2 end, name: :double)]}
        ]
      )

      workflow
      |> Workflow.react_until_satisfied(5)
      |> Workflow.raw_productions()
      # => [12]

  ## Three-Phase Execution Model

  All workflow evaluation uses a three-phase execution model that enables parallel execution
  and external scheduler integration:

  1. **Prepare** - Extract minimal context from the workflow into `%Runnable{}` structs
  2. **Execute** - Run node work functions in isolation (can be parallelized)
  3. **Apply** - Reduce results back into the workflow

  ### Basic Execution

  For simple use cases, use `react/2` for a single cycle or `react_until_satisfied/3`
  to run to completion:

      # Single cycle
      workflow = Workflow.react(workflow, input)

      # Run to completion (recommended for simple use)
      workflow = Workflow.react_until_satisfied(workflow, input)

  ### Parallel Execution

  Enable parallel execution for I/O-bound or CPU-intensive workflows:

      workflow = Workflow.react_until_satisfied(workflow, input,
        async: true,
        max_concurrency: 8,
        timeout: :infinity
      )

  ### External Scheduler Integration

  For custom schedulers, worker pools, or distributed execution, use the low-level
  three-phase APIs directly:

      # Phase 1: Prepare runnables for dispatch
      workflow = Workflow.plan_eagerly(workflow, input)
      {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

      # Phase 2: Execute (dispatch to worker pool, external service, etc.)
      executed = Task.async_stream(runnables, fn runnable ->
        Runic.Workflow.Invokable.execute(runnable.node, runnable)
      end, timeout: :infinity)

      # Phase 3: Apply results back to workflow
      workflow = Enum.reduce(executed, workflow, fn {:ok, runnable}, wrk ->
        Workflow.apply_runnable(wrk, runnable)
      end)

      # Continue if more work is available
      if Workflow.is_runnable?(workflow), do: # repeat...

  Key APIs for external scheduling:

  - `prepare_for_dispatch/1` - Returns `{workflow, [%Runnable{}]}` for dispatch
  - `apply_runnable/2` - Applies a completed runnable back to the workflow
  - `Invokable.execute/2` - Executes a runnable in isolation (no workflow access)

  ## Workflow Composition

  Workflows can be composed together using `merge/2` or by adding components with `add/3`:

      # Merge two workflows
      combined = Workflow.merge(workflow1, workflow2)

      # Add components dynamically
      workflow = Workflow.new()
        |> Workflow.add(step1)
        |> Workflow.add(step2, to: :step1)
        |> Workflow.add(join_step, to: [:branch_a, :branch_b])

  Any component implementing the `Runic.Transmutable` protocol can be merged into a workflow.

  ## Introspection APIs

  Query workflow structure and state:

      # List all components by type
      Workflow.steps(workflow)       # All Step structs
      Workflow.conditions(workflow)  # All Condition structs

      # Get components by name
      Workflow.get_component(workflow, :my_step)

      # Query execution state
      Workflow.is_runnable?(workflow)     # Any work pending?
      Workflow.next_runnables(workflow)   # List of {node, fact} pairs

      # Traverse workflow structure
      Workflow.next_steps(workflow, parent_step)  # Children of a step

  ## Result Extraction

  Extract results after workflow execution:

      # Raw values (most common)
      Workflow.raw_productions(workflow)           # All leaf outputs
      Workflow.raw_productions(workflow, :step_name)  # From specific component

      # Full Fact structs with ancestry
      Workflow.productions(workflow)

      # All facts including inputs
      Workflow.facts(workflow)

  ## Serialization

  Serialize workflows for persistence and visualization:

      # Build log for persistence
      log = Workflow.build_log(workflow)
      serialized = :erlang.term_to_binary(log)

      # Rebuild from log
      workflow = Workflow.from_log(:erlang.binary_to_term(serialized))

      # Visualization formats
      Workflow.to_mermaid(workflow)      # Mermaid flowchart
      Workflow.to_dot(workflow)          # Graphviz DOT format
      Workflow.to_cytoscape(workflow)    # Cytoscape.js JSON
      Workflow.to_edgelist(workflow)     # Edge list tuples

  ## When to Use Runic Workflows

  Runic Workflows are intended for use cases where your program is built or modified at runtime.
  They are useful for:

  - Complex data-dependent pipelines
  - Expert systems and rule engines
  - User-defined logical systems (low-code tools, DSLs)
  - Dynamic workflow composition at runtime

  If your model can be expressed in advance with compiled code using the usual control flow
  and concurrency tools available in Elixir/Erlang, Runic Workflows may not be necessary.
  There are performance trade-offs of doing more compilation and evaluation at runtime.

  See the [Cheatsheet](cheatsheet.html) and [Usage Rules](usage-rules.html) guides for more.
  """
  require Logger
  alias Runic.Closure
  alias Runic.Workflow.ReactionOccurred
  alias Runic.Component
  alias Runic.Transmutable
  alias Runic.Workflow.Components
  alias Runic.Workflow.Root
  alias Runic.Workflow.Step
  alias Runic.Workflow.Condition
  alias Runic.Workflow.Fact
  alias Runic.Workflow.Rule
  alias Runic.Workflow.Join
  alias Runic.Workflow.Invokable
  alias Runic.Workflow.ComponentAdded
  alias Runic.Workflow.ReactionOccurred
  alias Runic.Workflow.Runnable
  alias Runic.Workflow.Private

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

  @doc """
  Creates an empty workflow with no components.

  ## Example

      iex> alias Runic.Workflow
      iex> workflow = Workflow.new()
      iex> workflow.__struct__
      Runic.Workflow
  """
  def new(), do: new([])

  @doc """
  Constructs a new Runic Workflow with the given name or parameters.

  ## Examples

      iex> alias Runic.Workflow
      iex> workflow = Workflow.new(:my_workflow)
      iex> workflow.name
      :my_workflow
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
  def root(), do: Private.root()

  @doc """
  Adds a component to the workflow, connecting it to the parent step or root if no parent is specified.

  ## Examples

      iex> require Runic
      iex> alias Runic.Workflow
      iex> step = Runic.step(fn x -> x + 1 end, name: :add_one)
      iex> workflow = Workflow.new() |> Workflow.add(step)
      iex> Workflow.get_component(workflow, :add_one) |> Map.get(:name)
      :add_one

      iex> require Runic
      iex> alias Runic.Workflow
      iex> s1 = Runic.step(fn x -> x + 1 end, name: :first)
      iex> s2 = Runic.step(fn x -> x * 2 end, name: :second)
      iex> workflow = Workflow.new() |> Workflow.add(s1) |> Workflow.add(s2, to: :first)
      iex> workflow |> Workflow.react_until_satisfied(5) |> Workflow.raw_productions() |> Enum.sort()
      [6, 12]

  When `:to` is a list of parent names, a Join is created so the dependent step
  waits for all parents to produce facts before running:

      require Runic
      alias Runic.Workflow

      a_step = Runic.step(fn x -> x + 1 end, name: :a)
      b_step = Runic.step(fn x -> x * 2 end, name: :b)
      sum_step = Runic.step(fn a, b -> a + b end, name: :sum)

      workflow =
        Workflow.new()
        |> Workflow.add(a_step)
        |> Workflow.add(b_step)
        |> Workflow.add(sum_step, to: [:a, :b])

      result =
        workflow
        |> Workflow.react_until_satisfied(5)
        |> Workflow.raw_reactions()

      6 in result  # :a produced 5 + 1
      10 in result # :b produced 5 * 2
      16 in result # :sum produced 6 + 10
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
    end
  end

  defp do_add_component(%__MODULE__{} = workflow, component, parent, opts) do
    should_log = Keyword.get(opts, :log, true)

    case {component, parent} do
      {%{__struct__: struct}, %Root{}} ->
        if struct not in Components.component_impls() do
          transmuted = Transmutable.to_component(component)
          do_add_component(workflow, transmuted, parent, opts)
        else
          workflow = Component.connect(component, parent, workflow)

          if should_log do
            append_build_log(workflow, component, parent)
          else
            workflow
          end
        end

      {%{__struct__: struct} = component, _parent} ->
        if struct not in Components.component_impls() do
          transmuted = Transmutable.to_component(component)
          do_add_component(workflow, transmuted, parent, opts)
        else
          workflow = Component.connect(component, parent, workflow)

          if should_log do
            append_build_log(workflow, component, parent)
          else
            workflow
          end
        end

      _otherwise ->
        transmuted = Transmutable.to_component(component)
        do_add_component(workflow, transmuted, parent, opts)
    end
  end

  @doc """
  Adds a component to the workflow and returns the updated workflow along with
  the `%ComponentAdded{}` events produced.

  This is useful for event-sourced workflow construction where you need to
  capture the events for later replay via `apply_events/2`.

  ## Example

      require Runic
      alias Runic.Workflow

      step = Runic.step(fn x -> x + 1 end, name: :add_one)
      {workflow, events} = Workflow.add_with_events(Workflow.new(), step)

      # Events can rebuild the same workflow
      rebuilt = Workflow.apply_events(Workflow.new(), events)
  """
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
  Returns a list of `%ComponentAdded{}` events for serialization and recovery.

  Use with `from_log/1` to persist and rebuild workflows.

  ## Example

      require Runic
      alias Runic.Workflow

      step = Runic.step(fn x -> x * 2 end, name: :double)
      workflow = Workflow.new() |> Workflow.add(step)

      # Get the build log for serialization
      log = Workflow.build_log(workflow)
      serialized = :erlang.term_to_binary(log)

      # Later, rebuild from log
      restored_log = :erlang.binary_to_term(serialized)
      restored = Workflow.from_log(restored_log)

  ## Returns

  A list of `%ComponentAdded{}` events in order of addition, each containing
  the closure needed to rebuild the component.
  """
  def build_log(wrk) do
    # BFS reduce the graph following only flow edges and accumulate into a list of ComponentAdded events
    # Or accumulate connections of added components in graph by keeping the source with a `component_of` edge to invokables.
    Enum.reverse(wrk.build_log)
  end

  @doc """
  Applies a single `%ComponentAdded{}` event to the workflow, adding the
  component described by the event.

  Part of the event sourcing system — use with events captured from
  `add_with_events/2` or `build_log/1` to reconstruct a workflow incrementally.
  """
  def apply_event(%__MODULE__{} = wrk, %ComponentAdded{} = event) do
    component = component_from_added(event)

    add(wrk, component, to: event.to)
  end

  @doc """
  Applies a list of `%ComponentAdded{}` events to the workflow.

  Batch version of `apply_event/2`. Events are applied in order via `Enum.reduce/3`.

  ## Example

      require Runic
      alias Runic.Workflow

      step1 = Runic.step(fn x -> x + 1 end, name: :add_one)
      step2 = Runic.step(fn x -> x * 2 end, name: :double)

      {workflow, events1} = Workflow.add_with_events(Workflow.new(), step1)
      {_workflow, events2} = Workflow.add_with_events(workflow, step2, to: :add_one)

      rebuilt = Workflow.apply_events(Workflow.new(), events1 ++ events2)
  """
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

  ## Examples

      require Runic
      alias Runic.Workflow

      step = Runic.step(fn x -> x * 2 end, name: :double)
      workflow = Workflow.new() |> Workflow.add(step)
      log = Workflow.build_log(workflow)

      restored = Workflow.from_log(log)
      restored |> Workflow.react_until_satisfied(5) |> Workflow.raw_productions()
      # => [10]
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
        # Rebuild getter_fn for :meta_ref edges during restoration
        properties = restore_meta_ref_properties(ro.reaction, ro.properties)

        reaction_edge =
          Graph.Edge.new(
            ro.from,
            ro.to,
            label: ro.reaction,
            weight: ro.weight,
            properties: properties
          )

        %__MODULE__{
          wrk
          | graph: Graph.add_edge(wrk.graph, reaction_edge)
        }
    end)
  end

  # Rebuild getter_fn for :meta_ref edges during from_log restoration
  # The getter_fn was stripped during serialization and must be rebuilt
  defp restore_meta_ref_properties(:meta_ref, properties) when is_map(properties) do
    getter_fn = build_getter_fn(properties)
    Map.put(properties, :getter_fn, getter_fn)
  end

  defp restore_meta_ref_properties(_label, properties), do: properties

  defp build_eval_env() do
    require Runic
    import Runic, warn: false
    alias Runic.Workflow, warn: false
    __ENV__
  end

  @doc """
  Returns the complete event log combining `build_log/1` and reaction events.

  The returned list contains `%ComponentAdded{}` events followed by
  `%ReactionOccurred{}` events, providing a full serializable snapshot of
  the workflow structure and execution state. Use with `from_log/1` to
  persist and restore both the workflow definition and its runtime state.

  ## Example

      require Runic
      alias Runic.Workflow

      workflow = Runic.workflow(steps: [Runic.step(fn x -> x + 1 end, name: :add)])
      ran = Workflow.react_until_satisfied(workflow, 5)

      log = Workflow.log(ran)
      restored = Workflow.from_log(log)
  """
  def log(wrk) do
    build_log(wrk) ++ reactions_occurred(wrk)
  end

  defp reactions_occurred(%__MODULE__{graph: g}) do
    reaction_edge_kinds =
      Map.keys(g.edge_index)
      |> Enum.reject(&(&1 == :flow))

    for %Graph.Edge{} = edge <-
          Graph.edges(g, by: reaction_edge_kinds) do
      # Strip getter_fn from :meta_ref edges - it cannot be serialized
      # and will be rebuilt during from_log restoration
      properties = strip_getter_fn_for_serialization(edge.label, edge.properties)

      %ReactionOccurred{
        from: edge.v1,
        to: edge.v2,
        reaction: edge.label,
        weight: edge.weight,
        properties: properties
      }
    end
  end

  # Strip getter_fn from :meta_ref edge properties for serialization
  # The getter_fn is rebuilt during from_log restoration using build_getter_fn/1
  defp strip_getter_fn_for_serialization(:meta_ref, properties) when is_map(properties) do
    Map.delete(properties, :getter_fn)
  end

  defp strip_getter_fn_for_serialization(_label, properties), do: properties

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
  def register_component(workflow, component), do: Private.register_component(workflow, component)

  @doc """
  Returns a map of all registered components in the workflow by the registered component name.

  ## Examples

      iex> require Runic
      iex> alias Runic.Workflow
      iex> workflow = Runic.workflow(steps: [
      ...>   Runic.step(fn x -> x + 1 end, name: :add),
      ...>   Runic.step(fn x -> x * 2 end, name: :mult)
      ...> ])
      iex> components = Workflow.components(workflow)
      iex> is_map(components)
      true
      iex> Map.keys(components) |> Enum.sort()
      [:add, :mult]
  """
  def components(%__MODULE__{} = workflow) do
    Map.new(workflow.components, fn {name, hash} ->
      {name, Map.get(workflow.graph.vertices, hash)}
    end)
  end

  @doc """
  Returns a keyword list of sub-components of the given component by kind.

  ## Examples

      iex> require Runic
      iex> alias Runic.Workflow
      iex> rule = Runic.rule(fn x when x > 0 -> :positive end, name: :pos_check)
      iex> workflow = Workflow.new() |> Workflow.add(rule)
      iex> subs = Workflow.sub_components(workflow, :pos_check)
      iex> Keyword.keys(subs) |> Enum.sort()
      [:condition, :reaction]
  """
  def sub_components(%__MODULE__{} = workflow, component_name) do
    component = get_component(workflow, component_name)

    workflow.graph
    |> Graph.out_edges(component, by: :component_of)
    |> Enum.map(fn edge -> {edge.properties.kind, edge.v2} end)
  end

  @doc """
  Returns a list of components in the workflow graph that are compatible for
  connection with the given component.

  Compatibility is determined by matching arity and requiring the vertex to
  implement the `Component` protocol. Accepts a component name or struct.
  """
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

  @doc """
  Checks whether a component can be connected at a given point in the workflow.

  When called with `to: component_name`, validates that the target component
  exists, arities match, and the components are connectable per the `Component`
  protocol. Returns `:ok` on success or `{:error, reason}` on failure.

  The 2-arity version (no `:to` option) always returns `:ok`, since any
  component can be added to the workflow root.
  """
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

  @doc false
  def add_before_hooks(workflow, hooks), do: Private.add_before_hooks(workflow, hooks)
  @doc false
  def add_after_hooks(workflow, hooks), do: Private.add_after_hooks(workflow, hooks)

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

  @doc """
  Attaches a hook function to be run before a given component step.

  The hook is a 3-arity function receiving `(step, workflow, input_fact)` and
  must return the (possibly modified) workflow.

  ## Example

      workflow
      |> Workflow.attach_before_hook(:my_step, fn step, workflow, input_fact ->
        IO.inspect(input_fact, label: "Input fact")
        workflow
      end)
  """
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
  def run_before_hooks(workflow, step, input_fact),
    do: Private.run_before_hooks(workflow, step, input_fact)

  @doc false
  def run_after_hooks(workflow, step, output_fact),
    do: Private.run_after_hooks(workflow, step, output_fact)

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
  def add_step(workflow, child_step), do: Private.add_step(workflow, child_step)

  @doc """
  Adds a dependent step to some other step in a workflow by name.

  The dependent step is fed signed facts produced by the parent step during a reaction.

  Adding dependent steps is the most low-level way of building a dataflow execution graph as it assumes no conditional, branching logic.

  If you're just building a pipeline, dependent steps can be sufficient, however you might want Rules for conditional branching logic.
  """
  def add_step(workflow, parent_step, child_step),
    do: Private.add_step(workflow, parent_step, child_step)

  @doc """
  Adds a list of rules to the workflow root.

  Each rule is added via `add/2`. Passing `nil` is a no-op.

  ## Example

      require Runic
      alias Runic.Workflow

      rules = [
        Runic.rule(fn x when x > 0 -> :positive end, name: :pos),
        Runic.rule(fn x when x < 0 -> :negative end, name: :neg)
      ]

      workflow = Workflow.new() |> Workflow.add_rules(rules)
  """
  def add_rules(workflow, nil), do: workflow

  def add_rules(workflow, rules) do
    Enum.reduce(rules, workflow, fn %Rule{} = rule, wrk ->
      add(wrk, rule)
    end)
  end

  @doc """
  Adds a batch of steps to the workflow, supporting pipelines and joins.

  Accepts a list where each element is one of:

    - `%Step{}` — added directly to the workflow root
    - `{%Step{}, dependent_steps}` — a pipeline: the parent step is added to root,
      then dependent steps are connected downstream
    - `{[%Step{}, ...], dependent_steps}` — multiple parent steps joined: all parents
      are added to root, a `Join` node is created, and dependents follow the join

  Passing `nil` is a no-op.

  ## Example

      require Runic
      alias Runic.Workflow

      workflow = Workflow.new() |> Workflow.add_steps([
        {Runic.step(fn x -> x + 1 end, name: :add),
         [Runic.step(fn x -> x * 2 end, name: :double)]}
      ])
  """
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

  @doc false
  def add_dependent_steps(workflow, parent_and_deps),
    do: Private.add_dependent_steps(workflow, parent_and_deps)

  def maybe_put_component(workflow, step), do: Private.maybe_put_component(workflow, step)

  def get_named_vertex(%__MODULE__{graph: g, mapped: mapped}, name) do
    hash = Map.get(mapped, name)
    g.vertices |> Map.get(hash)
  end

  @doc """
  Retrieves a component from the workflow by name.

  Returns the component struct or `nil` if not found.

  ## Examples

      iex> require Runic
      iex> alias Runic.Workflow
      iex> workflow = Runic.workflow(steps: [Runic.step(fn x -> x * 2 end, name: :double)])
      iex> step = Workflow.get_component(workflow, :double)
      iex> step.name
      :double

  ## Subcomponent Access

  For composite components like rules, access subcomponents with a tuple:

      # Get the condition of a rule
      Workflow.get_component(workflow, {:my_rule, :condition})

      # Get the reaction of a rule
      Workflow.get_component(workflow, {:my_rule, :reaction})
  """
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

  @doc """
  Retrieves a component from the workflow by name, raising if not found.

  Same as `get_component/2` but raises `KeyError` if no component matches.

  ## Example

      step = Workflow.get_component!(workflow, :my_step)
  """
  def get_component!(wrk, name) do
    get_component(wrk, name) || raise(KeyError, "No component found with name #{name}")
  end

  @doc """
  Retrieves a component from the workflow by name, returning an ok/error tuple.

  Returns `{:ok, component}` if found, or `{:error, :no_component_by_name}` if
  no component is registered with the given name.

  ## Example

      iex> require Runic
      iex> alias Runic.Workflow
      iex> workflow = Workflow.new() |> Workflow.add(Runic.step(fn x -> x end, name: :identity))
      iex> {:ok, step} = Workflow.fetch_component(workflow, :identity)
      iex> step.name
      :identity
      iex> Workflow.fetch_component(workflow, :nonexistent)
      {:error, :no_component_by_name}
  """
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
  Returns the child steps connected via dataflow edges from a parent step.

  Useful for traversing the workflow graph structure.

  ## Example

      require Runic
      alias Runic.Workflow

      workflow = Runic.workflow(steps: [
        {Runic.step(fn x -> x + 1 end, name: :add),
         [Runic.step(fn x -> x * 2 end, name: :double)]}
      ])

      add_step = Workflow.get_component(workflow, :add)
      [double_step] = Workflow.next_steps(workflow, add_step)
      double_step.name  # => :double
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

  @doc false
  def add_rule(workflow, rule), do: Private.add_rule(workflow, rule)

  @doc """
  Merges the second workflow into the first, maintaining the name of the first.

  All root-level components from `workflow2` are connected to the root of `workflow`,
  making them siblings to the existing root components.

  ## Examples

      iex> require Runic
      iex> alias Runic.Workflow
      iex> w1 = Runic.workflow(steps: [Runic.step(fn x -> x + 1 end, name: :add)])
      iex> w2 = Runic.workflow(steps: [Runic.step(fn x -> x * 2 end, name: :mult)])
      iex> merged = Workflow.merge(w1, w2)
      iex> merged |> Workflow.react_until_satisfied(5) |> Workflow.raw_productions() |> Enum.sort()
      [6, 10]

  ## Merging Other Types

  Any value implementing the `Runic.Transmutable` protocol can be merged:

      workflow = Workflow.merge(workflow, rule)
      workflow = Workflow.merge(workflow, step)

  ## Use Cases

  - Combining modular workflow fragments at runtime
  - Building workflows dynamically from configuration
  - Composing reusable workflow templates
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
  Lists all `%Step{}` structs in the workflow.

  Useful for introspecting workflow structure.

  ## Example

      iex> require Runic
      iex> alias Runic.Workflow
      iex> workflow = Runic.workflow(steps: [
      ...>   Runic.step(fn x -> x + 1 end, name: :add),
      ...>   Runic.step(fn x -> x * 2 end, name: :mult)
      ...> ])
      iex> steps = Workflow.steps(workflow)
      iex> length(steps)
      2
      iex> Enum.map(steps, & &1.name) |> Enum.sort()
      [:add, :mult]
  """
  def steps(%__MODULE__{graph: g}) do
    Enum.filter(Graph.vertices(g), &match?(%Step{}, &1))
  end

  @doc """
  Lists all `%Condition{}` structs in the workflow.

  Conditions are the "left-hand side" predicates of rules.

  ## Example

      require Runic
      alias Runic.Workflow

      workflow = Runic.workflow(rules: [
        Runic.rule(fn x when x > 0 -> :positive end)
      ])

      [condition] = Workflow.conditions(workflow)
  """
  def conditions(%__MODULE__{graph: g}) do
    Enum.filter(Graph.vertices(g), &match?(%Condition{}, &1))
  end

  @doc false
  def satisfied_condition_hashes(workflow, fact),
    do: Private.satisfied_condition_hashes(workflow, fact)

  @spec raw_reactions(Runic.Workflow.t()) :: list(any())
  @doc """
  Returns raw (output value) side effects of the workflow - i.e. facts resulting from the execution of a Runic.Step

  ## Examples

      iex> require Runic
      iex> alias Runic.Workflow
      iex> workflow = Runic.workflow(steps: [Runic.step(fn x -> x * 2 end)])
      iex> workflow |> Workflow.react(5) |> Workflow.raw_reactions() |> Enum.sort()
      [5, 10]
  """
  def raw_reactions(%__MODULE__{} = wrk) do
    wrk
    |> reactions()
    |> Enum.map(& &1.value)
  end

  @spec reactions(Runic.Workflow.t()) :: list(Runic.Workflow.Fact.t())
  @doc """
  Returns raw (output value) side effects of the workflow - i.e. facts resulting from the execution of a Runic.Step

  ## Examples

      iex> require Runic
      iex> alias Runic.Workflow
      iex> workflow = Runic.workflow(steps: [Runic.step(fn x -> x * 2 end)])
      iex> facts = workflow |> Workflow.react(5) |> Workflow.reactions()
      iex> Enum.map(facts, & &1.value) |> Enum.sort()
      [5, 10]
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
  Returns all `%Fact{}` structs produced by the workflow.

  Unlike `raw_productions/1`, this returns the full Fact structs including
  ancestry information for causal tracing. Does not include input facts.

  ## Example

      iex> require Runic
      iex> alias Runic.Workflow
      iex> workflow = Runic.workflow(steps: [Runic.step(fn x -> x * 2 end)])
      iex> [fact] = workflow |> Workflow.react(5) |> Workflow.productions()
      iex> fact.value
      10
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

  ## Examples

      iex> require Runic
      iex> alias Runic.Workflow
      iex> workflow = Runic.workflow(steps: [Runic.step(fn x -> x * 2 end, name: :double)])
      iex> [fact] = workflow |> Workflow.react(5) |> Workflow.productions(:double)
      iex> fact.value
      10
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

  ## Examples

      iex> require Runic
      iex> alias Runic.Workflow
      iex> workflow = Runic.workflow(steps: [
      ...>   Runic.step(fn x -> x + 1 end, name: :add),
      ...>   Runic.step(fn x -> x * 2 end, name: :mult)
      ...> ])
      iex> pbc = workflow |> Workflow.react(5) |> Workflow.productions_by_component()
      iex> is_map(pbc)
      true
      iex> Map.keys(pbc) |> Enum.sort()
      [:add, :mult]
  """
  def productions_by_component(%__MODULE__{components: components} = wrk) do
    Map.new(components, fn {name, component} ->
      productions = productions(wrk, component)

      {name, productions}
    end)
  end

  @doc """
  Returns the raw values from all produced facts.

  This is the most common way to extract results from a workflow.
  Returns unwrapped values without the `%Fact{}` struct metadata.

  ## Example

      iex> require Runic
      iex> alias Runic.Workflow
      iex> workflow = Runic.workflow(steps: [Runic.step(fn x -> x * 2 end)])
      iex> workflow |> Workflow.react(5) |> Workflow.raw_productions()
      [10]

  ## By Component Name

      iex> require Runic
      iex> alias Runic.Workflow
      iex> workflow = Runic.workflow(
      ...>   steps: [Runic.step(fn x -> x * 2 end, name: :double)]
      ...> )
      iex> workflow |> Workflow.react(5) |> Workflow.raw_productions(:double)
      [10]
  """
  def raw_productions(%__MODULE__{graph: graph}) do
    for %Graph.Edge{} = edge <-
          Graph.edges(graph, by: [:produced, :state_produced, :state_initiated, :reduced]) do
      edge.v2.value
    end
  end

  @doc """
  Returns a map of component name to raw production values for all components.

  Like `raw_productions/1` but grouped by component name.

  ## Example

      require Runic
      alias Runic.Workflow

      workflow = Runic.workflow(
        steps: [
          {Runic.step(fn x -> x + 1 end, name: "step 1"),
           [Runic.step(fn x -> x + 2 end, name: "step 2")]}
        ]
      )

      %{"step 1" => [2], "step 2" => [4]} =
        workflow
        |> Workflow.react_until_satisfied(1)
        |> Workflow.raw_productions_by_component()
  """
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
  Returns all facts in the workflow, including inputs and productions.

  Unlike `productions/1`, this includes input facts which have `ancestry: nil`.
  Useful for tracing the full causal chain of workflow execution.

  ## Example

      iex> require Runic
      iex> alias Runic.Workflow
      iex> workflow = Runic.workflow(steps: [Runic.step(fn x -> x * 2 end)])
      iex> facts = workflow |> Workflow.react(5) |> Workflow.facts()
      iex> length(facts)
      2
      iex> Enum.map(facts, & &1.value) |> Enum.sort()
      [5, 10]

  ## Ancestry

  - Input facts have `ancestry: nil`
  - Produced facts have `ancestry: {producer_hash, parent_fact_hash}`
  """
  def facts(%__MODULE__{graph: graph}) do
    for v <- Graph.vertices(graph), match?(%Fact{}, v), do: v
  end

  @doc false
  def matches(workflow), do: Private.matches(workflow)

  @doc """
  Executes a single reaction cycle using the three-phase model.

  This function advances the workflow by one "generation" - executing all currently
  runnable steps/rules. Use `react_until_satisfied/3` to run to completion.

  ## Basic Usage

      iex> require Runic
      iex> alias Runic.Workflow
      iex> workflow = Runic.workflow(steps: [Runic.step(fn x -> x * 2 end)])
      iex> workflow = Workflow.react(workflow, 5)
      iex> Workflow.raw_productions(workflow)
      [10]

  ## Options

  - `:async` - When `true`, executes runnables in parallel using `Task.async_stream`.
    Useful for I/O-bound workflows. Default: `false` (serial execution)
  - `:max_concurrency` - Maximum parallel tasks when `async: true`. Default: `System.schedulers_online()`
  - `:timeout` - Timeout for each task when `async: true`. Default: `:infinity`

  ## Parallel Execution

      workflow = Workflow.react(workflow, 5, async: true, max_concurrency: 4)
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
  Executes a single reaction cycle with the given input value.

  Plans through the match phase and executes one cycle of runnables.
  Commonly used with a raw value to start workflow processing.

  ## Options

  - `:async` - When `true`, executes runnables in parallel. Default: `false`
  - `:max_concurrency` - Maximum parallel tasks when `async: true`
  - `:timeout` - Timeout for each task when `async: true`
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
  Executes the workflow until no more runnables remain.

  Iteratively calls `react/2` until all reachable nodes have been executed.
  This is the recommended way to fully evaluate a workflow pipeline.

  ## Basic Usage

      iex> require Runic
      iex> alias Runic.Workflow
      iex> workflow = Runic.workflow(
      ...>   steps: [
      ...>     {Runic.step(fn x -> x + 1 end, name: :add_one),
      ...>      [Runic.step(fn x -> x * 2 end, name: :double)]}
      ...>   ]
      ...> )
      iex> results = workflow |> Workflow.react_until_satisfied(5) |> Workflow.raw_productions()
      iex> Enum.sort(results)
      [6, 12]

  ## Options

  - `:async` - When `true`, executes runnables in parallel. Default: `false`
  - `:max_concurrency` - Maximum parallel tasks when `async: true`
  - `:timeout` - Timeout for each task when `async: true`

  ## Warning

  Workflows that don't terminate (e.g., hooks that continuously add steps) will
  cause infinite loops. For non-terminating workflows, use `react/2` in a
  controlled loop with exit conditions.

  ## Best For

  - IEx/REPL experimentation
  - Scripts and notebooks
  - Testing workflows
  - Simple batch processing

  For production use with complex scheduling needs, consider `prepare_for_dispatch/1`
  with a custom scheduler process.
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

  @doc """
  Removes all `%Fact{}` vertices and generation integers from the workflow graph.

  This clears the workflow's accumulated memory while preserving its structure
  (steps, rules, conditions, and flow edges). Useful for long-running workflows
  to free memory between processing batches.

  ## Example

      require Runic
      alias Runic.Workflow

      workflow = Runic.workflow(steps: [Runic.step(fn x -> x + 1 end)])
      workflow = Workflow.react(workflow, 5)

      # Facts exist after reaction
      refute Enum.empty?(Workflow.facts(workflow))

      # Purge clears them
      workflow = Workflow.purge_memory(workflow)
      assert Enum.empty?(Workflow.facts(workflow))
  """
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

  ## Examples

      iex> require Runic
      iex> alias Runic.Workflow
      iex> workflow = Runic.workflow(steps: [Runic.step(fn x -> x * 2 end, name: :double)])
      iex> workflow = Workflow.plan(workflow, 5)
      iex> Workflow.is_runnable?(workflow)
      true
      iex> workflow |> Workflow.react() |> Workflow.raw_productions()
      [10]
  """
  def plan(%__MODULE__{} = wrk, %Fact{} = fact) do
    invoke(wrk, root(), fact)
  end

  def plan(%__MODULE__{} = wrk, raw_fact) do
    plan(wrk, Fact.new(value: raw_fact))
  end

  @doc """
  `plan/1` will, for all next left hand side / match phase runnables activate and prepare next match runnables.

  ## Examples

      iex> require Runic
      iex> alias Runic.Workflow
      iex> rule = Runic.rule(fn x when x > 0 -> :positive end, name: :pos)
      iex> workflow = Runic.workflow(rules: [rule])
      iex> workflow = Workflow.plan(workflow, 5)
      iex> workflow = Workflow.plan(workflow)
      iex> Workflow.is_runnable?(workflow)
      true
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

  ## Examples

      iex> require Runic
      iex> alias Runic.Workflow
      iex> workflow = Runic.workflow(steps: [
      ...>   {Runic.step(fn x -> x + 1 end, name: :add),
      ...>    [Runic.step(fn x -> x * 2 end, name: :double)]}
      ...> ])
      iex> workflow = Workflow.react_until_satisfied(workflow, 5)
      iex> Workflow.is_runnable?(workflow)
      false
      iex> workflow = Workflow.plan_eagerly(workflow)
      iex> Workflow.is_runnable?(workflow)
      true
  """
  def plan_eagerly(%__MODULE__{graph: graph} = workflow) do
    # Find all produced facts that don't have pending activations
    # Also exclude facts that have :ran edges - those have already been processed
    new_productions =
      for edge <- Graph.edges(graph, by: [:produced, :state_produced, :reduced]),
          fact = edge.v2,
          is_struct(fact, Fact),
          Enum.empty?(Graph.out_edges(graph, fact, by: [:runnable, :matchable, :ran])) do
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

  ## Examples

      iex> require Runic
      iex> alias Runic.Workflow
      iex> rule = Runic.rule(fn x when x > 0 -> :positive end, name: :pos)
      iex> workflow = Runic.workflow(rules: [rule])
      iex> workflow = Workflow.plan_eagerly(workflow, 5)
      iex> Workflow.is_runnable?(workflow)
      true
      iex> workflow |> Workflow.react() |> Workflow.raw_productions()
      [:positive]
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

  ## Examples

      require Runic
      alias Runic.Workflow
      alias Runic.Workflow.Fact

      step = Runic.step(fn x -> x * 2 end, name: :double)
      workflow = Workflow.new() |> Workflow.add(step)
      fact = Fact.new(value: 5)

      workflow = Workflow.invoke(workflow, Workflow.root(), fact)
      Workflow.is_runnable?(workflow)
      # => true
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

  @doc """
  Executes the Invokable protocol for runnable.

  ## Examples

      require Runic
      alias Runic.Workflow
      alias Runic.Workflow.Invokable

      step = Runic.step(fn x -> x * 2 end, name: :double)
      workflow = Workflow.new() |> Workflow.add(step)
      workflow = Workflow.plan_eagerly(workflow, 5)

      [runnable | _] = Workflow.prepared_runnables(workflow)
      executed = Workflow.execute_runnable(runnable)
      executed.status
      # => :completed
  """
  def execute_runnable(%Runnable{} = runnable) do
    Invokable.execute(runnable.node, runnable)
  end

  @doc false
  @deprecated "Use causal_depth/2 or ancestry_depth/2 instead"
  def causal_generation(%__MODULE__{} = workflow, %Fact{} = fact) do
    Private.causal_generation(workflow, fact)
  end

  @doc """
  Executes the Invokable protocol for a runnable step and fact and returns all newly caused events produced by the invokation.

  This API is intended to enable durable execution of long running workflows by returning events that can be persisted elsewhere
  so the workflow state can be rebuilt with `from_log/1`.

  ## Examples

      require Runic
      alias Runic.Workflow
      alias Runic.Workflow.Fact

      step = Runic.step(fn x -> x * 2 end, name: :double)
      workflow = Workflow.new() |> Workflow.add(step)
      fact = Fact.new(value: 5)

      {workflow, events} = Workflow.invoke_with_events(workflow, Workflow.root(), fact)
      is_list(events)
      # => true
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

  ## Examples

      require Runic
      alias Runic.Workflow
      alias Runic.Workflow.Fact

      step = Runic.step(fn x -> x * 2 end, name: :double)
      workflow = Workflow.new() |> Workflow.add(step)
      fact = Fact.new(value: 5)
      workflow = Workflow.react(workflow, fact)
      events = Workflow.events_produced_since(workflow, fact)
      length(events) > 0
      # => true
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

  @doc """
  Returns `true` if the workflow has pending work (runnable or matchable nodes).

  Use this in scheduler loops to determine when to stop processing.

  ## Example

      iex> require Runic
      iex> alias Runic.Workflow
      iex> workflow = Runic.workflow(steps: [Runic.step(fn x -> x * 2 end)])
      iex> Workflow.is_runnable?(workflow)
      false
      iex> workflow = Workflow.plan_eagerly(workflow, 5)
      iex> Workflow.is_runnable?(workflow)
      true
      iex> workflow = Workflow.react(workflow)
      iex> Workflow.is_runnable?(workflow)
      false
  """
  @spec is_runnable?(Runic.Workflow.t()) :: boolean()
  def is_runnable?(%__MODULE__{graph: graph}) do
    not Enum.empty?(Graph.edges(graph, by: [:runnable, :matchable]))
  end

  @doc """
  Returns a list of `{node, fact}` pairs ready for activation in the next cycle.

  All runnables returned are independent and can be executed in parallel.
  This is a low-level API for custom schedulers. For most use cases, prefer
  `prepare_for_dispatch/1` which returns fully prepared `%Runnable{}` structs.

  ## Example

      runnables = Workflow.next_runnables(workflow)
      # => [{%Step{name: :add}, %Fact{value: 5}}, ...]
  """
  def next_runnables(%__MODULE__{graph: graph}) do
    for %Graph.Edge{} = edge <- Graph.edges(graph, by: [:runnable, :matchable]) do
      {edge.v2, edge.v1}
    end
  end

  def next_runnables(workflow, fact_or_raw), do: Private.next_runnables(workflow, fact_or_raw)

  @doc false
  def log_fact(workflow, fact), do: Private.log_fact(workflow, fact)

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
               Private.draw_connection(
                 wrk,
                 relevant_state_produced_fact,
                 node.hash,
                 Private.connection_for_activatable(node)
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
  def prepare_next_generation(%__MODULE__{} = workflow, %Fact{} = fact),
    do: Private.prepare_next_generation(workflow, fact)

  def prepare_next_generation(%__MODULE__{} = workflow, [%Fact{} | _] = facts),
    do: Private.prepare_next_generation(workflow, facts)

  @doc false
  def draw_connection(workflow, node_1, node_2, connection, opts \\ []),
    do: Private.draw_connection(workflow, node_1, node_2, connection, opts)

  @doc false
  def mark_runnable_as_ran(workflow, step, fact),
    do: Private.mark_runnable_as_ran(workflow, step, fact)

  @doc false
  def prepare_next_runnables(workflow, node, fact),
    do: Private.prepare_next_runnables(workflow, node, fact)

  @doc false
  def last_known_state(workflow, state_reaction),
    do: Private.last_known_state(workflow, state_reaction)

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
  Returns the causal depth of a fact by walking its ancestry chain.

  Alias for `ancestry_depth/2`. For facts without ancestry (root inputs), returns 0.

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
  def get_hooks(workflow, node_hash), do: Private.get_hooks(workflow, node_hash)

  # =============================================================================
  # Three-Phase Execution API (Phase 4 & 5)
  # =============================================================================

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

  # =============================================================================
  # Serialization API
  # =============================================================================

  @doc """
  Serializes the workflow to Mermaid flowchart format.

  Returns a string that can be rendered by Mermaid.js.

  ## Options

  - `:direction` - Flow direction: `:TB` (default), `:LR`, `:BT`, `:RL`
  - `:include_memory` - Include causal reaction edges (default: `false`)
  - `:title` - Optional title comment

  ## Examples

      iex> workflow |> Workflow.to_mermaid()
      "flowchart TB\\n    ..."

      iex> workflow |> Workflow.to_mermaid(direction: :LR, include_memory: true)
      "flowchart LR\\n    ..."
  """
  @spec to_mermaid(t(), Keyword.t()) :: String.t()
  def to_mermaid(%__MODULE__{} = workflow, opts \\ []) do
    Runic.Workflow.Serializers.Mermaid.serialize(workflow, opts)
  end

  @doc """
  Serializes causal reactions as a Mermaid sequence diagram.

  Shows how facts flow through steps and produce new facts over time.
  Best used after workflow execution to visualize the causal chain.

  ## Example

      iex> workflow |> Workflow.plan_eagerly(input) |> Workflow.react() |> Workflow.to_mermaid_sequence()
      "sequenceDiagram\\n    ..."
  """
  @spec to_mermaid_sequence(t(), Keyword.t()) :: String.t()
  def to_mermaid_sequence(%__MODULE__{} = workflow, opts \\ []) do
    Runic.Workflow.Serializers.Mermaid.serialize_causal(workflow, opts)
  end

  @doc """
  Serializes the workflow to DOT (Graphviz) format.

  Returns a string that can be rendered with Graphviz tools.

  ## Example

      iex> dot = Workflow.to_dot(workflow)
      iex> File.write!("workflow.dot", dot)
  """
  @spec to_dot(t(), Keyword.t()) :: String.t()
  def to_dot(%__MODULE__{} = workflow, opts \\ []) do
    Runic.Workflow.Serializers.DOT.serialize(workflow, opts)
  end

  @doc """
  Serializes the workflow to Cytoscape.js element JSON format.

  Returns a list of node and edge elements compatible with Cytoscape.js
  and Kino.Cytoscape in Livebook.

  ## Example

      iex> elements = Workflow.to_cytoscape(workflow)
      iex> Kino.Cytoscape.new(elements)
  """
  @spec to_cytoscape(t(), Keyword.t()) :: list(map())
  def to_cytoscape(%__MODULE__{} = workflow, opts \\ []) do
    Runic.Workflow.Serializers.Cytoscape.serialize(workflow, opts)
  end

  @doc """
  Serializes the workflow to an edgelist format.

  Returns a list of `{from, to, label}` tuples by default.

  ## Options

  - `:format` - `:tuples` (default) or `:string`
  - `:include_memory` - Include causal edges (default: `false`)

  ## Examples

      iex> Workflow.to_edgelist(workflow)
      [{:root, :step1, :flow}, {:step1, :step2, :flow}]

      iex> Workflow.to_edgelist(workflow, format: :string)
      "root -> step1 [flow]\\nstep1 -> step2 [flow]"
  """
  @spec to_edgelist(t(), Keyword.t()) :: list(tuple()) | String.t()
  def to_edgelist(%__MODULE__{} = workflow, opts \\ []) do
    Runic.Workflow.Serializers.Edgelist.serialize(workflow, opts)
  end

  # =============================================================================
  # Meta Expression Support
  # =============================================================================

  @doc """
  Prepares meta context for a node by traversing its `:meta_ref` edges.

  Each `:meta_ref` edge has a `getter_fn` in its properties that extracts
  the needed value from the workflow. This function executes all getter functions
  and builds a map of context_key => value pairs.

  ## Example

      # For a Condition with state_of(:cart_accumulator) in its where clause
      meta_context = prepare_meta_context(workflow, condition)
      # => %{cart_accumulator_state: %{total: 150, items: [...]}}
  """
  @spec prepare_meta_context(t(), struct()) :: map()
  def prepare_meta_context(workflow, node), do: Private.prepare_meta_context(workflow, node)

  @doc """
  Returns the list of components that a node depends on via `:meta_ref` edges.

  This is useful for understanding what state a rule or step will read during
  execution, and for validation/visualization.

  ## Example

      deps = meta_dependencies(workflow, my_rule_condition)
      # => [%Accumulator{name: :cart_state, ...}]
  """
  @spec meta_dependencies(t(), struct()) :: list(struct())
  def meta_dependencies(%__MODULE__{graph: graph} = _workflow, node) do
    node_vertex =
      case node do
        %{hash: hash} -> hash
        _ -> node
      end

    graph
    |> Graph.out_edges(node_vertex, by: :meta_ref)
    |> Enum.map(fn edge ->
      case edge.v2 do
        %{hash: hash} ->
          Map.get(graph.vertices, hash, edge.v2)

        hash when is_integer(hash) ->
          Map.get(graph.vertices, hash)

        _ ->
          edge.v2
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Returns the list of nodes that depend on a component via `:meta_ref` edges.

  This is the inverse of `meta_dependencies/2` - it shows what nodes will
  read this component's state.

  ## Example

      dependents = meta_dependents(workflow, cart_accumulator)
      # => [%Condition{...}, %Step{...}]
  """
  @spec meta_dependents(t(), struct()) :: list(struct())
  def meta_dependents(%__MODULE__{graph: graph} = _workflow, node) do
    node_vertex =
      case node do
        %{hash: hash} -> hash
        _ -> node
      end

    graph
    |> Graph.in_edges(node_vertex, by: :meta_ref)
    |> Enum.map(fn edge ->
      case edge.v1 do
        %{hash: hash} ->
          Map.get(graph.vertices, hash, edge.v1)

        hash when is_integer(hash) ->
          Map.get(graph.vertices, hash)

        _ ->
          edge.v1
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Builds a getter function for a meta reference based on its kind.

  The getter function has signature `(workflow, target) -> value` and is
  stored in the `:meta_ref` edge properties for use during the prepare phase.

  ## Supported Kinds

  - `:state_of` - Returns the last known state of an Accumulator/StateMachine
  - `:step_ran?` - Returns boolean indicating if step has run
  - `:fact_count` - Returns count of facts produced by a component
  - `:latest_value` - Returns the most recent value produced
  - `:latest_fact` - Returns the most recent fact produced
  - `:all_values` - Returns all values produced as a list
  - `:all_facts` - Returns all facts produced as a list
  """
  @spec build_getter_fn(map()) :: (t(), term() -> term())
  def build_getter_fn(meta_ref), do: Private.build_getter_fn(meta_ref)

  @doc """
  Creates a `:meta_ref` edge from a node to its meta expression target.

  This is called during `Component.connect/3` when a node has meta references.
  The edge stores the getter function and context key for use during prepare.

  ## Example

      workflow = draw_meta_ref_edge(
        workflow,
        condition.hash,
        accumulator.hash,
        %{kind: :state_of, field_path: [:total], context_key: :cart_total}
      )
  """
  @spec draw_meta_ref_edge(t(), term(), term(), map()) :: t()
  def draw_meta_ref_edge(workflow, from, to, meta_ref),
    do: Private.draw_meta_ref_edge(workflow, from, to, meta_ref)
end
