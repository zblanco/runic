defmodule Runic.Workflow.Join do
  alias Runic.Workflow.Components
  defstruct [:hash, :joins]

  def new(joins) when is_list(joins) do
    %__MODULE__{joins: joins, hash: Components.fact_hash(joins)}
  end
end

defimpl Runic.Workflow.Coordinator, for: Runic.Workflow.Join do
  alias Runic.Workflow
  alias Runic.Workflow.Fact
  alias Runic.Workflow.Runnable
  alias Runic.Workflow.Private
  alias Runic.Workflow.Events.JoinCompleted
  alias Runic.Workflow.Events.JoinEdgeRelabeled

  def finalize(%Runic.Workflow.Join{} = join, %Workflow{} = wf, %Runnable{
        input_fact: fact,
        context: ctx
      }) do
    join_order_weights =
      join.joins
      |> Enum.with_index()
      |> Map.new()

    joined_edges =
      wf.graph
      |> Multigraph.in_edges(join)
      |> Enum.filter(&(&1.label == :joined))
      |> Enum.filter(Workflow.join_input_filter(wf, join, fact))

    satisfied_by_parent =
      joined_edges
      |> Enum.reduce(%{}, fn edge, acc ->
        parent_hash = elem(edge.v1.ancestry, 0)

        if Map.has_key?(join_order_weights, parent_hash) and not Map.has_key?(acc, parent_hash) do
          Map.put(acc, parent_hash, edge.v1)
        else
          acc
        end
      end)

    can_complete = map_size(satisfied_by_parent) >= length(join.joins)

    if can_complete do
      contributions = Enum.map(join.joins, &Map.fetch!(satisfied_by_parent, &1))
      collected_values = Enum.map(contributions, & &1.value)

      join_fact = Fact.new(value: collected_values, ancestry: {join.hash, fact.hash})

      wf = Workflow.run_before_hooks(wf, join, fact)

      completion_event = %JoinCompleted{
        join_hash: join.hash,
        result_fact_hash: join_fact.hash,
        result_value: join_fact.value,
        result_ancestry: join_fact.ancestry,
        contribution_fact_hashes: Enum.map(contributions, & &1.hash),
        weight: ctx.ancestry_depth + 1
      }

      relabel_events =
        joined_edges
        |> Enum.map(fn edge ->
          %JoinEdgeRelabeled{
            fact_hash: edge.v1.hash,
            join_hash: join.hash,
            from_label: :joined,
            to_label: :join_satisfied
          }
        end)

      derived_events = [completion_event | relabel_events]

      wf = Enum.reduce(derived_events, wf, fn event, w -> Workflow.apply_event(w, event) end)
      wf = Workflow.run_after_hooks(wf, join, join_fact)

      # Record delivery as well as completion, so a checkpoint with pending
      # consumers has the same frontier after replay.
      {wf, activation_events} = Private.activate_downstream_with_events(wf, join, join_fact)
      {wf, derived_events ++ activation_events}
    else
      {wf, []}
    end
  end
end
