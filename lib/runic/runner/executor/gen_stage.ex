defmodule Runic.Runner.Executor.GenStage do
  @moduledoc """
  GenStage-based executor providing demand-driven dispatch with back-pressure.

  Uses a GenStage Producer + Consumer pool architecture. The Producer buffers
  work items and Consumers pull them on demand, providing natural back-pressure
  that prevents the Worker from overwhelming available compute.

  Each consumer processes one work item at a time (`max_demand: 1`). The number
  of consumers controls the concurrency level. Work items that arrive when all
  consumers are busy are buffered in the Producer until demand is available.

  ## Options

    * `:max_demand` — number of concurrent consumers (default: `System.schedulers_online()`)
    * `:buffer_size` — producer event buffer size (default: `:infinity`)

  ## Architecture

  ```
  Worker (caller)
      │ dispatch/3 → cast to Producer
      ▼
  GenStage.Producer (buffers {handle, work_fn, caller} events)
      │
      ├──────────────────┤
      ▼                  ▼
  Consumer 1         Consumer N
  (execute work_fn)  (execute work_fn)
      │                  │
      └──── send {handle, result} / {:DOWN, handle, ...} to caller ────┘
  ```

  ## Message Contract

  Preserves the standard Executor message contract:

    * `{handle, result}` — sent to caller on successful completion
    * `{:DOWN, handle, :process, pid, reason}` — sent to caller on failure

  Failures are caught inside the consumer via `try/catch`, so individual work
  item failures do not crash the consumer process.

  Requires the `:gen_stage` dependency. Raises at init if not available.
  """

  @behaviour Runic.Runner.Executor

  @impl true
  def init(opts) do
    unless Code.ensure_loaded?(GenStage) do
      raise RuntimeError, """
      The GenStage executor requires the :gen_stage dependency.
      Add {:gen_stage, "~> 1.2"} to your mix.exs deps.
      """
    end

    max_demand = Keyword.get(opts, :max_demand, System.schedulers_online())
    buffer_size = Keyword.get(opts, :buffer_size, :infinity)

    {:ok, producer} =
      Runic.Runner.Executor.GenStage.Producer.start_link(buffer_size: buffer_size)

    consumers =
      for _ <- 1..max_demand do
        {:ok, pid} =
          Runic.Runner.Executor.GenStage.Consumer.start_link(producer: producer)

        pid
      end

    {:ok, %{producer: producer, consumers: consumers}}
  end

  @impl true
  def dispatch(work_fn, _opts, %{producer: producer} = state) do
    handle = make_ref()
    caller = self()

    Runic.Runner.Executor.GenStage.Producer.enqueue(
      producer,
      {handle, work_fn, caller}
    )

    {handle, state}
  end

  @impl true
  def cleanup(%{consumers: consumers, producer: producer}) do
    for pid <- consumers, Process.alive?(pid) do
      GenServer.stop(pid, :normal, 5_000)
    end

    if Process.alive?(producer) do
      GenServer.stop(producer, :normal, 5_000)
    end

    :ok
  end
end
