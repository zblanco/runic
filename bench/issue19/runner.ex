defmodule Runic.Bench.Issue19.Runner do
  @moduledoc false
  alias Runic.Workflow
  alias Runic.Bench.Issue19.Scenarios

  def run(config, instrument \\ false) do
    initial = Scenarios.build(config.case, config.coordination)
    inputs = Scenarios.inputs(config.case, config.n)

    stats = %{
      waves: 0,
      prepared: 0,
      fan_in_prepared: 0,
      max_prepared: 0,
      request_bytes: 0,
      response_bytes: 0,
      max_request_bytes: 0,
      request_flat_words: 0,
      max_context_words: 0,
      context_samples: MapSet.new()
    }

    {workflow, stats} =
      Enum.reduce(inputs, {initial, stats}, fn input, {workflow, stats} ->
        {done, stats} = loop(Workflow.plan_eagerly(workflow, input), config, stats, instrument, 0)
        Scenarios.verify!(done, config.case, input)
        {done, stats}
      end)

    %{stats | waves: stats.waves}
    |> Map.merge(%{
      facts: length(Workflow.facts(workflow)),
      edges: length(Multigraph.edges(workflow.graph)),
      mapped_entries: map_size(workflow.mapped),
      retained_external_bytes: if(instrument, do: :erlang.external_size(workflow), else: 0),
      result_ok: true
    })
  end

  defp loop(workflow, config, stats, instrument, idle) do
    if Workflow.is_runnable?(workflow) do
      if idle > 100, do: raise("dispatch did not make progress")

      {workflow, runnables} =
        case config.preparation do
          :eager -> Workflow.prepare_for_dispatch(workflow)
          :bounded -> apply(Workflow, :prepare_for_dispatch, [workflow, [limit: config.limit]])
        end

      stats = %{
        stats
        | waves: stats.waves + 1,
          prepared: stats.prepared + length(runnables),
          max_prepared: max(stats.max_prepared, length(runnables)),
          fan_in_prepared:
            stats.fan_in_prepared + Enum.count(runnables, &is_struct(&1.node, Workflow.FanIn))
      }

      stats = if instrument, do: Enum.reduce(runnables, stats, &request_stats/2), else: stats

      results =
        case config.execution do
          :inline ->
            Enum.map(runnables, &Workflow.execute_runnable/1)

          execution when execution in [:task, :peer_tcp] ->
            Task.async_stream(
              runnables,
              fn runnable ->
                case execution do
                  :task ->
                    Workflow.execute_runnable(runnable)

                  :peer_tcp ->
                    :peer.call(config.peer, Workflow, :execute_runnable, [runnable], 120_000)
                end
              end,
              max_concurrency: config.concurrency,
              timeout: :infinity,
              ordered: true
            )
            |> Stream.map(fn {:ok, result} -> result end)
        end

      {workflow, stats} =
        Enum.reduce(results, {workflow, stats}, fn result, {wf, st} ->
          st =
            if instrument,
              do: %{st | response_bytes: st.response_bytes + :erlang.external_size(result)},
              else: st

          {Workflow.apply_runnable(wf, result), st}
        end)

      loop(workflow, config, stats, instrument, if(runnables == [], do: idle + 1, else: 0))
    else
      {workflow, stats}
    end
  end

  defp request_stats(runnable, stats) do
    bytes = :erlang.external_size(runnable)
    # Sharing-aware size is expensive. Inspect one context per node and wave;
    # flat and encoded sizes still cover every actual envelope.
    sample_key = {runnable.node.hash, stats.waves}

    context_words =
      if MapSet.member?(stats.context_samples, sample_key),
        do: stats.max_context_words,
        else: max(stats.max_context_words, :erts_debug.size(runnable.context))

    %{
      stats
      | request_bytes: stats.request_bytes + bytes,
        max_request_bytes: max(stats.max_request_bytes, bytes),
        request_flat_words: stats.request_flat_words + :erts_debug.flat_size(runnable),
        max_context_words: context_words,
        context_samples: MapSet.put(stats.context_samples, sample_key)
    }
  end
end
