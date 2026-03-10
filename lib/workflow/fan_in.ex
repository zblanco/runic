defmodule Runic.Workflow.FanIn do
  @moduledoc """
  FanIn steps are part of a reduce operator that combines multiple facts into a single fact
  by applying the reducer function to return the accumulator with the parent.

  ## Options

  - `:mergeable` - When `true`, indicates this fan-in's reducer has CRDT-like
    properties (commutative, idempotent, associative) and is safe for parallel merge
    without ordering guarantees. Defaults to `false`.

  ## Runtime Context

  FanIn supports `meta_refs` for `context/1` when used as part of a reduce
  operation. The `has_meta_refs?/1` function indicates whether context
  references are present.
  """
  defstruct [:hash, :init, :reducer, :map, :name, mergeable: false, meta_refs: []]

  @doc """
  Returns whether this FanIn has meta references (e.g., `context/1`)
  that need to be resolved during the prepare phase.
  """
  def has_meta_refs?(%__MODULE__{meta_refs: meta_refs}), do: meta_refs != []
end

defimpl Runic.Workflow.Coordinator, for: Runic.Workflow.FanIn do
  alias Runic.Workflow
  alias Runic.Workflow.Fact
  alias Runic.Workflow.Runnable
  alias Runic.Workflow.Private
  alias Runic.Workflow.Events.ActivationConsumed
  alias Runic.Workflow.Events.FanInCompleted

  def finalize(
        %Runic.Workflow.FanIn{} = fan_in,
        %Workflow{} = wf,
        %Runnable{
          input_fact: fact,
          context: %{fan_in_context: %{mode: :fan_out_reduce} = fctx} = ctx
        }
      ) do
    completed_key = {:fan_in_completed, fctx.source_fact_hash, fan_in.hash}
    already_completed = Map.get(wf.mapped, completed_key, false)

    if already_completed do
      {wf, []}
    else
      expected_list = wf.mapped[fctx.expected_key] || []
      expected_set = MapSet.new(expected_list)
      seen_map = wf.mapped[fctx.seen_key] || %{}
      seen_set = MapSet.new(Map.keys(seen_map))

      ready =
        not Enum.empty?(expected_set) and
          MapSet.equal?(expected_set, seen_set)

      if ready do
        expected_in_order = Enum.reverse(expected_list)

        sister_fact_values =
          for origin <- expected_in_order do
            sister_hash = seen_map[origin]
            wf.graph.vertices[sister_hash].value
          end

        reduced_value = fan_in_reduce(sister_fact_values, fan_in.init.(), fan_in.reducer)
        reduced_fact = Fact.new(value: reduced_value, ancestry: {fan_in.hash, fact.hash})

        wf = Workflow.run_before_hooks(wf, fan_in, fact)

        sister_consumed_events =
          for origin <- expected_in_order,
              sister_hash = seen_map[origin],
              sister_fact = wf.graph.vertices[sister_hash],
              sister_fact != nil,
              sister_fact.hash != fact.hash do
            %ActivationConsumed{
              fact_hash: sister_fact.hash,
              node_hash: fan_in.hash,
              from_label: :runnable
            }
          end

        completion_event = %FanInCompleted{
          fan_in_hash: fan_in.hash,
          source_fact_hash: fctx.source_fact_hash,
          result_fact_hash: reduced_fact.hash,
          result_value: reduced_fact.value,
          result_ancestry: reduced_fact.ancestry,
          expected_key: fctx.expected_key,
          seen_key: fctx.seen_key,
          weight: ctx.ancestry_depth + 1
        }

        derived_events = sister_consumed_events ++ [completion_event]

        wf = Enum.reduce(derived_events, wf, fn event, w -> Workflow.apply_event(w, event) end)
        wf = Workflow.run_after_hooks(wf, fan_in, reduced_fact)

        # Activate downstream nodes with the reduced fact
        next = Workflow.next_steps(wf, fan_in)

        wf =
          Enum.reduce(next, wf, fn step, w ->
            Workflow.draw_connection(
              w,
              reduced_fact,
              step,
              Private.connection_for_activatable(step)
            )
          end)

        {wf, derived_events}
      else
        {wf, []}
      end
    end
  end

  # FanIn without fan_out_reduce context — no coordination needed
  def finalize(%Runic.Workflow.FanIn{}, %Workflow{} = wf, %Runnable{}) do
    {wf, []}
  end

  defp fan_in_reduce(enumerable, acc, reducer) do
    Enum.reduce_while(enumerable, acc, fn value, acc ->
      case reducer.(value, acc) do
        {:cont, new_acc} -> {:cont, new_acc}
        {:halt, new_acc} -> {:halt, new_acc}
        new_acc -> {:cont, new_acc}
      end
    end)
  end
end
