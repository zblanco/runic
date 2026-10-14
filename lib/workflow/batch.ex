defmodule Runic.Workflow.Batch do
  @moduledoc """
  A collection boundary for ordinary components and nested batches.

  `new/2` accepts a Step or any component using `SingleOutput`, plus another
  Batch. Other readiness, state, and multiple-output contracts are rejected.
  Runic owns FanOut/FanIn wiring, item occurrence identities, empty completion,
  and ordered outcomes. Members must have separate definitions within one
  workflow. Repeated invocations reuse the same graph through `Workflow.execute/3`
  or `Runner.start_execution/4`. Raw Fact planning retains its existing deduplication.
  It uses the existing execution and failure policies.

  Supply a list or `input/2`. Each invocation is identified by the FanOut
  activation, so repeated values and nested batches have separate identities.
  `SingleOutput.Context.batch` supplies item coordinates and parent data.
  Steps can use `context(:batch)`. Parent data is stored on the source Fact;
  it is copied into each prepared callback context by default. A custom
  SingleOutput member can set `batch_parent: false` to keep only coordinates.

  A terminal `:skip` policy permits collection of a skipped outcome. A `:halt`
  failure stops new admission in the existing execution scope. Admitted work
  can finish, but a partial batch has no completed Result. Result conversion
  and external effect order remain consumer responsibilities.

  Full-value event replay and native snapshots retain accepted item progress.
  Recovered unresolved work can repeat external effects. Lazy/hybrid replay,
  remote progress, portable journals, and loss of unacknowledged results are
  outside this batch contract. Existing Map/Reduce full build-log recovery
  limits remain separate; Batch has its own reconstructable definition.
  """
  alias Runic.{Component, Identity, Workflow}
  alias Runic.Workflow.{Components, Fact, FanIn, FanOut, Runnable, SingleOutput, Private}
  alias Runic.Workflow.Batch.{Input, Outcome, Result, Terminal}
  alias Runic.Workflow.Events.{FanInCompleted, MapReduceTracked, RunnableActivated}

  defstruct [:hash, :name, :component, :fan_out, :fan_in]

  @doc """
  Constructs a batch for one supported component.

  The batch name must differ from all owned member names, including nested
  batch, FanOut, and FanIn names. A name conflict raises `ArgumentError`.
  """
  def new(component, opts \\ []) do
    unless match?(%__MODULE__{}, component) or SingleOutput.supported?(component) do
      raise ArgumentError, "batch members must use SingleOutput or be nested batches"
    end

    unless Component.impl_for(component),
      do: raise(ArgumentError, "batch member must implement Runic.Component")

    name = Keyword.get(opts, :name, "#{component.name}_batch")

    unless is_atom(name) or is_binary(name),
      do: raise(ArgumentError, "batch name must be an atom or string")

    if name in owned_names(component),
      do: raise(ArgumentError, "batch name #{inspect(name)} conflicts with an owned member")

    hash = Identity.derive(:component_definition, [:batch, name, component.hash])
    fan_out_hash = Identity.derive(:component_definition, [hash, :fan_out])
    fan_in_hash = Identity.derive(:component_definition, [hash, :fan_in])

    %__MODULE__{
      name: name,
      hash: hash,
      component: component,
      fan_out: %FanOut{hash: fan_out_hash, name: "#{name}.fan_out", batch: fan_in_hash},
      fan_in: %FanIn{hash: fan_in_hash, name: "#{name}.fan_in", batch: fan_out_hash}
    }
  end

  defp owned_names(%__MODULE__{} = batch) do
    [batch.name, batch.fan_out.name, batch.fan_in.name | owned_names(batch.component)]
  end

  defp owned_names(component), do: [component.name]

  @doc false
  def definition_source(batch) do
    component = batch.component
    closure = Map.get(component, :closure)

    definition = %Workflow.ComponentAdded{
      name: component.name,
      hash: component.hash,
      closure: closure,
      source: Component.source(component),
      bindings: if(closure, do: closure.bindings, else: Map.get(component, :bindings, %{})),
      input_ports: Map.get(component, :inputs),
      output_ports: Map.get(component, :outputs)
    }

    quote do
      Runic.Workflow.Batch.new(
        Runic.Workflow.Batch.rebuild_member(unquote(Macro.escape(definition))),
        name: unquote(batch.name)
      )
    end
  end

  @doc false
  def rebuild_member(%Workflow.ComponentAdded{} = definition) do
    Workflow.from_log([definition]) |> Workflow.get_component!(definition.name)
  end

  @doc "Builds an input with shared parent data. Items must be a proper list."
  def input(items, parent \\ nil) when is_list(items) do
    if List.improper?(items), do: raise(ArgumentError, "batch items must be a proper list")
    %Input{items: items, parent: parent}
  end

  @doc false
  def items(%Input{items: items}), do: validate_items(items)
  def items(items), do: validate_items(items)

  defp validate_items(items) when is_list(items) do
    if List.improper?(items), do: raise(ArgumentError, "batch items must be a proper list")
    items
  end

  defp validate_items(_), do: raise(ArgumentError, "batch items must be a proper list")
  defp parent(%Input{parent: parent}), do: parent
  defp parent(_), do: nil

  @doc false
  def id(fan_out, source), do: Runnable.runnable_id(fan_out, source)

  @doc false
  def item_metadata(fan_out, source, index, item_id) do
    %{
      runic_batch: %{
        id: id(fan_out, source),
        index: index,
        item_id: item_id,
        source_fact_id: source.hash
      }
    }
  end

  @doc false
  def context(workflow, node, fact, include_parent? \\ true) do
    case lookup_item(workflow, node, fact) do
      {source, _fan_out, _item, coordinates} ->
        if include_parent?,
          do: Map.put(coordinates, :parent, parent(workflow.graph.vertices[source].value)),
          else: coordinates

      nil ->
        nil
    end
  end

  defp lookup_item(workflow, node, %{ancestry: {producer, source}, hash: item, meta: meta}) do
    case {Map.get(Map.get(workflow.mapped, :batch_members, %{}), Components.vertex_id_of(node)),
          Map.get(meta, :runic_batch)} do
      {%{fan_out: ^producer}, %{source_fact_id: ^source, item_id: ^item} = coordinates} ->
        {source, producer, item, coordinates}

      _ ->
        nil
    end
  end

  defp lookup_item(_workflow, _node, _fact), do: nil

  @doc "Lists locally accepted batch invocation identities."
  def invocations(workflow, batch) do
    for %{v1: source} <- Multigraph.in_edges(workflow.graph, batch.fan_out, by: :ran),
        do: id(batch.fan_out, source)
  end

  @doc """
  Returns ordered item observations for one invocation, including a partial batch.

  A `:pending` item has no accepted terminal result. `:uncertain` means an
  executor loss was observed for that item. Both can repeat on explicit recovery.
  This observation does not acknowledge the Store or choose a failure policy.
  """
  def outcomes(workflow, batch, batch_id) do
    with source when not is_nil(source) <-
           Enum.find_value(Multigraph.in_edges(workflow.graph, batch.fan_out, by: :ran), fn %{
                                                                                              v1:
                                                                                                source
                                                                                            } ->
             if id(batch.fan_out, source) == batch_id, do: source
           end) do
      completed =
        Enum.find_value(Multigraph.out_edges(workflow.graph, batch.fan_in, by: :reduced), fn %{
                                                                                               v2:
                                                                                                 fact
                                                                                             } ->
          if fact.value.id == batch_id, do: fact.value.outcomes
        end)

      if completed do
        {:ok, completed}
      else
        leaf =
          case batch.component do
            %__MODULE__{fan_in: leaf} -> leaf
            node -> node
          end

        seen = Map.get(workflow.mapped, {source.hash, leaf.hash}, %{})

        items =
          for %{v2: fact} <- Multigraph.out_edges(workflow.graph, batch.fan_out, by: :fan_out),
              elem(fact.ancestry, 1) == source.hash,
              do: fact

        uncertain =
          Enum.flat_map(workflow.runnable_events, fn
            %Workflow.ExecutionUncertain{members: members} ->
              Enum.map(members || [], & &1.input_fact_id)

            _ ->
              []
          end)

        observations =
          items
          |> Enum.sort_by(& &1.meta.runic_batch.index)
          |> Enum.map(fn item ->
            coordinates = item.meta.runic_batch

            case Map.get(seen, item.hash) do
              %Outcome{} = outcome ->
                outcome

              nil ->
                %Outcome{
                  id: item.hash,
                  batch_id: batch_id,
                  index: coordinates.index,
                  status:
                    if(
                      Enum.any?(
                        uncertain,
                        &descendant?(workflow, workflow.graph.vertices[&1], item.hash)
                      ),
                      do: :uncertain,
                      else: :pending
                    )
                }

              result_hash ->
                %Outcome{
                  id: item.hash,
                  batch_id: batch_id,
                  index: coordinates.index,
                  status: :completed,
                  value: workflow.graph.vertices[result_hash].value
                }
            end
          end)

        {:ok, observations}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  @doc false
  def item_scope(workflow, node, fact) do
    case Map.get(Map.get(workflow.mapped, :batch_members, %{}), Components.vertex_id_of(node)) do
      %{collector: fan_out, member: producer} ->
        case fact.ancestry do
          {^producer, item} ->
            case Map.get(workflow.graph.vertices, item) do
              %{
                hash: ^item,
                ancestry: {^fan_out, source},
                meta: %{runic_batch: %{item_id: ^item, source_fact_id: metadata_source}}
              }
              when metadata_source == source ->
                item

              _ ->
                nil
            end

          _ ->
            nil
        end

      _ ->
        case lookup_item(workflow, node, fact) do
          {_source, _fan_out, item, _coordinates} -> item
          _ -> nil
        end
    end
  end

  @doc false
  def provides_context?(workflow, node, :batch) do
    match?(
      %{fan_out: _},
      Map.get(Map.get(workflow.mapped, :batch_members, %{}), Components.vertex_id_of(node))
    ) and
      SingleOutput.supported?(node)
  end

  def provides_context?(_workflow, _node, _key), do: false

  @doc false
  def descendant?(_workflow, %{hash: hash}, hash), do: true

  def descendant?(workflow, %{ancestry: {_producer, parent}}, boundary) do
    descendant?(workflow, workflow.graph.vertices[parent], boundary)
  end

  def descendant?(_workflow, _fact, _boundary), do: false

  @doc false
  def merge_definitions(workflow, %Workflow{} = other) do
    definitions =
      Map.merge(
        Map.get(workflow.mapped, :batch_definitions, %{}),
        Map.get(other.mapped, :batch_definitions, %{})
      )

    put_definitions(workflow, definitions)
  end

  def merge_definitions(workflow, _other), do: workflow

  defp put_definitions(workflow, definitions) when map_size(definitions) == 0 do
    %{
      workflow
      | mapped: Map.drop(workflow.mapped, [:batch_definitions, :batch_members, :batch_sources])
    }
  end

  defp put_definitions(workflow, definitions) do
    members =
      Enum.reduce(definitions, %{}, fn {_hash, batch}, index ->
        entry = %{owner: batch.hash, fan_out: batch.fan_out.hash}
        index = Map.put(index, batch.component.hash, entry)

        member =
          case batch.component do
            %__MODULE__{} = nested -> nested.fan_in.hash
            node -> node.hash
          end

        index =
          Map.put(index, batch.fan_in.hash, %{collector: batch.fan_out.hash, member: member})

        case batch.component do
          %__MODULE__{} = nested -> Map.put(index, nested.fan_out.hash, entry)
          _ -> index
        end
      end)

    %{
      workflow
      | mapped:
          workflow.mapped
          |> Map.put(:batch_definitions, definitions)
          |> Map.put(:batch_members, members)
          |> Map.put(:batch_sources, true)
    }
  end

  @doc false
  def present?(workflow), do: map_size(Map.get(workflow.mapped, :batch_definitions, %{})) > 0

  @doc false
  def assert_removable!(workflow, components) when is_list(components),
    do: Enum.each(components, &assert_removable!(workflow, &1))

  def assert_removable!(workflow, component) do
    definitions = Map.get(workflow.mapped, :batch_definitions, %{})

    owner =
      Enum.find_value(definitions, fn {_hash, batch} ->
        if batch.component.hash == component.hash or
             (batch.hash != component.hash and
                component.hash in [batch.fan_out.hash, batch.fan_in.hash]),
           do: batch
      end)

    if owner do
      root = root_owner(definitions, owner)

      raise ArgumentError,
            "remove owning Batch #{inspect(root.name)} instead of owned member #{inspect(component.name)}"
    end

    :ok
  end

  defp root_owner(definitions, batch) do
    case Enum.find_value(definitions, fn {_hash, parent} ->
           if parent.component.hash == batch.hash, do: parent
         end) do
      nil -> batch
      owner -> root_owner(definitions, owner)
    end
  end

  @doc false
  def remove(workflow, batch) do
    hashes = owned_hashes(batch) |> MapSet.new()
    parents = Multigraph.in_edges(workflow.graph, batch.fan_out, by: :flow) |> Enum.map(& &1.v1)
    children = Multigraph.out_edges(workflow.graph, batch.fan_in, by: :flow) |> Enum.map(& &1.v2)

    graph =
      Workflow.rewire_removed(workflow, parents, children).graph
      |> Multigraph.delete_vertices(Enum.map(hashes, &workflow.graph.vertices[&1]))

    definitions =
      Map.get(workflow.mapped, :batch_definitions, %{})
      |> Map.reject(fn {hash, _} -> MapSet.member?(hashes, hash) end)

    mapped =
      Map.reject(workflow.mapped, fn
        {{:fan_out_for_batch, _}, fan_out} -> MapSet.member?(hashes, fan_out)
        {key, _} when is_tuple(key) -> Enum.any?(Tuple.to_list(key), &MapSet.member?(hashes, &1))
        _ -> false
      end)

    mapped = Map.update(mapped, :mapped_paths, MapSet.new(), &MapSet.difference(&1, hashes))

    components =
      Map.reject(workflow.components, fn {_name, value} ->
        hash = if is_map(value) and Map.has_key?(value, :hash), do: value.hash, else: value
        MapSet.member?(hashes, hash)
      end)

    event = %Workflow.ComponentRemoved{name: batch.name, hash: batch.hash}

    %{
      workflow
      | graph: graph,
        components: components,
        mapped: mapped,
        before_hooks: Map.drop(workflow.before_hooks, MapSet.to_list(hashes)),
        after_hooks: Map.drop(workflow.after_hooks, MapSet.to_list(hashes)),
        build_log: [event | workflow.build_log]
    }
    |> put_definitions(definitions)
    |> validate!()
  end

  defp owned_hashes(batch) do
    member =
      case batch.component do
        %__MODULE__{} = nested -> owned_hashes(nested)
        node -> [node.hash]
      end

    [batch.hash, batch.fan_out.hash, batch.fan_in.hash | member]
  end

  @doc false
  def validate!(workflow) do
    definitions = Map.get(workflow.mapped, :batch_definitions, %{})
    owners = Enum.group_by(Map.values(definitions), & &1.component.hash)

    Enum.each(owners, fn {_member, batches} ->
      if length(batches) != 1,
        do: raise(ArgumentError, "batch members cannot have multiple owners")
    end)

    Enum.each(definitions, fn {_hash, batch} ->
      {entry, exit} =
        case batch.component do
          %__MODULE__{} = nested -> {nested.fan_out, nested.fan_in}
          node -> {node, node}
        end

      parents =
        for edge <- Multigraph.in_edges(workflow.graph, entry, by: :flow),
            do: workflow.graph.vertex_identifier.(edge.v1)

      children =
        for edge <- Multigraph.out_edges(workflow.graph, exit, by: :flow), do: edge.v2.hash

      if Enum.uniq(parents) != [batch.fan_out.hash] or Enum.uniq(children) != [batch.fan_in.hash] do
        raise ArgumentError, "batch member nodes cannot have links outside their owner"
      end
    end)

    put_definitions(workflow, definitions)
  end

  @doc false
  def connect(batch, parent_node, workflow) do
    if Map.has_key?(workflow.graph.vertices, batch.component.hash) do
      raise ArgumentError, "batch member nodes must have separate definitions within one workflow"
    end

    definitions = Map.get(workflow.mapped, :batch_definitions, %{}) |> Map.put(batch.hash, batch)

    workflow = put_definitions(workflow, definitions)

    workflow =
      workflow
      |> Workflow.add_step(parent_node, batch.fan_out)
      |> Workflow.register_component(batch)
      |> Workflow.draw_connection(batch, batch.fan_out, :component_of,
        properties: %{kind: :fan_out}
      )
      |> Workflow.draw_connection(batch, batch.fan_in, :component_of,
        properties: %{kind: :output, ports: [:out]}
      )

    workflow =
      Component.connect(batch.component, batch.fan_out, workflow)
      |> Workflow.draw_connection(batch, batch.component, :component_of,
        properties: %{kind: :member}
      )

    leaf =
      case batch.component do
        %__MODULE__{fan_in: fan_in} -> fan_in
        node -> node
      end

    workflow
    |> Workflow.add_step(leaf, batch.fan_in)
    |> Workflow.draw_connection(batch.fan_out, batch.fan_in, :fan_in)
  end

  @doc false
  def terminal(%{mapped: mapped} = workflow, _runnable)
      when not is_map_key(mapped, :batch_sources), do: workflow

  def terminal(workflow, %Runnable{node: node, input_fact: fact} = runnable) do
    boundary =
      case node do
        %FanOut{batch: collector} when not is_nil(collector) -> workflow.graph.vertices[collector]
        _ -> node
      end

    collectors =
      for %{v2: %FanIn{batch: batch} = collector} <-
            Multigraph.out_edges(workflow.graph, boundary, by: :flow),
          not is_nil(batch),
          do: collector

    Enum.reduce(collectors, workflow, fn collector, wf ->
      case lookup_item(wf, node, fact) do
        {source, fan_out, item, metadata} when fan_out == collector.batch ->
          outcome = %Outcome{
            id: item,
            batch_id: metadata.id,
            index: metadata.index,
            status: runnable.status,
            error: runnable.error,
            activation_id: Runnable.activation_id(runnable),
            attempt_id:
              Identity.derive(:attempt, [
                Runnable.activation_id(runnable),
                runnable.attempt_number || 0
              ])
          }

          event = %Terminal{source: source, step: boundary.hash, item: item, outcome: outcome}
          wf = Workflow.apply_event(wf, event)
          {wf, derived} = finish(wf, collector, source, boundary.hash)
          buffer(wf, [event | derived])

        _ ->
          wf
      end
    end)
  end

  @doc false
  def finish(workflow, fan_in, source, step_hash) do
    expected_key = {source, fan_in.batch}
    seen_key = {source, step_hash}
    expected = Map.get(workflow.mapped, expected_key, []) |> Enum.reverse()
    seen = Map.get(workflow.mapped, seen_key, %{})
    complete? = Map.get(workflow.mapped, {:fan_in_completed, source, fan_in.hash}, false)

    if not complete? and Enum.all?(expected, &Map.has_key?(seen, &1)) do
      source_fact = workflow.graph.vertices[source]
      fan_out = workflow.graph.vertices[fan_in.batch]

      outcomes =
        Enum.map(expected, fn item ->
          case Map.fetch!(seen, item) do
            %Outcome{} = outcome ->
              outcome

            result_hash ->
              metadata = workflow.graph.vertices[item].meta.runic_batch

              %Outcome{
                id: item,
                batch_id: metadata.id,
                index: metadata.index,
                status: :completed,
                value: workflow.graph.vertices[result_hash].value
              }
          end
        end)

      result = %Result{
        id: id(fan_out, source_fact),
        parent: parent(source_fact.value),
        outcomes: outcomes
      }

      result_fact = Fact.new(value: result, ancestry: {fan_in.hash, source})

      event = %FanInCompleted{
        fan_in_hash: fan_in.hash,
        source_fact_hash: source,
        result_fact_hash: result_fact.hash,
        result_value: result,
        result_ancestry: result_fact.ancestry,
        expected_key: expected_key,
        seen_key: seen_key,
        weight: Workflow.ancestry_depth(workflow, source_fact) + 1
      }

      workflow = Workflow.apply_event(workflow, event)

      tracking =
        case FanOut.origin(workflow, source_fact) do
          {outer_source, outer_fan_out, outer_item} ->
            [
              %MapReduceTracked{
                source_fact_hash: outer_source,
                fan_out_hash: outer_fan_out,
                fan_out_fact_hash: outer_item,
                step_hash: fan_in.hash,
                result_fact_hash: result_fact.hash
              }
            ]

          _ ->
            []
        end

      activations =
        for next <- Workflow.next_steps(workflow, fan_in),
            do: %RunnableActivated{
              fact_hash: result_fact.hash,
              node_hash: next.hash,
              activation_kind: Private.connection_for_activatable(next)
            }

      events = [event | tracking ++ activations]
      workflow = Enum.reduce(tracking ++ activations, workflow, &Workflow.apply_event(&2, &1))
      {workflow, events}
    else
      {workflow, []}
    end
  end

  defp buffer(workflow, events) do
    if workflow.emit_events,
      do: %{workflow | uncommitted_events: Enum.reverse(events) ++ workflow.uncommitted_events},
      else: workflow
  end
end

defimpl Runic.Component, for: Runic.Workflow.Batch do
  alias Runic.Workflow.Batch
  defdelegate connect(batch, parent, workflow), to: Batch
  def connectable?(_, _), do: true
  defdelegate source(batch), to: Batch, as: :definition_source

  def hash(batch), do: batch.hash
  def inputs(_), do: [in: [type: :any]]
  def outputs(_), do: [out: [type: :any]]
end

defimpl Runic.Transmutable, for: Runic.Workflow.Batch do
  def transmute(batch), do: to_workflow(batch)
  def to_workflow(batch), do: Runic.Workflow.new() |> Runic.Workflow.add(batch)
  def to_component(batch), do: batch
end
