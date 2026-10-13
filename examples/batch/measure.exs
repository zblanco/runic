# Run from the repository root: MIX_ENV=test mix run examples/batch/measure.exs
unless Code.ensure_loaded?(Runic.Examples.Batch.Adjustment) do
  Code.require_file("adjustment.ex", __DIR__)
  Code.require_file("adjustment_component.ex", __DIR__)
end

alias Runic.Workflow
alias Runic.Workflow.Batch

batch = Runic.batch(Runic.Examples.Batch.Adjustment.new(:price), name: :prices)
parent = Map.new(1..1000, &{&1, &1}) |> Map.put(:adjustment, 3)

workflow =
  Workflow.new()
  |> Workflow.add(batch)
  |> Workflow.plan_eagerly(Batch.input([10, 20, 30], parent))
  |> Workflow.react()

{_, runnables} = Workflow.prepare_for_dispatch(workflow)
items = Workflow.facts(workflow) |> Enum.filter(&Map.has_key?(&1.meta, :runic_batch))
owner = self()

# Keep the received context live while measuring its destination process.
process_bytes = fn context ->
  {pid, ref} =
    spawn_monitor(fn ->
      receive do
        {:measure, value} ->
          :erlang.garbage_collect()

          send(
            owner,
            {:memory, self(), Process.info(self(), :memory), :erts_debug.flat_size(value)}
          )

          receive do: (:stop -> :erlang.phash2(value))
      end
    end)

  send(pid, {:measure, context})

  receive do
    {:memory, ^pid, {:memory, bytes}, words} ->
      send(pid, :stop)
      receive do: ({:DOWN, ^ref, :process, ^pid, :normal} -> :ok)
      {bytes, words}
  end
end

baseline = process_bytes.(%{})
workers = Enum.map(runnables, &process_bytes.(&1.context))

IO.inspect(
  %{
    parent_etf_bytes: :erlang.external_size(parent),
    item_facts_etf_bytes: :erlang.external_size(items),
    destination_baseline_bytes: elem(baseline, 0),
    destination_worker_bytes: Enum.map(workers, &elem(&1, 0)),
    destination_context_flat_words: Enum.map(workers, &elem(&1, 1))
  },
  label: "Stored item data and worker context transfer"
)
