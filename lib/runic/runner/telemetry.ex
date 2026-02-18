defmodule Runic.Runner.Telemetry do
  @moduledoc """
  Telemetry event definitions for Runic.Runner.

  All events are emitted under the `[:runic, :runner, ...]` prefix.

  ## Event Groups

  ### Workflow Events
    * `[:runic, :runner, :workflow, :start]` — workflow started
    * `[:runic, :runner, :workflow, :stop]` — workflow completed
    * `[:runic, :runner, :workflow, :exception]` — workflow exception

  ### Runnable Events
    * `[:runic, :runner, :runnable, :start]` — runnable dispatched
    * `[:runic, :runner, :runnable, :stop]` — runnable completed
    * `[:runic, :runner, :runnable, :exception]` — runnable failed

  ### Store Events
    * `[:runic, :runner, :store, :start]` — store operation started
    * `[:runic, :runner, :store, :stop]` — store operation completed
    * `[:runic, :runner, :store, :exception]` — store operation failed
  """

  @workflow_start [:runic, :runner, :workflow, :start]
  @workflow_stop [:runic, :runner, :workflow, :stop]
  @workflow_exception [:runic, :runner, :workflow, :exception]

  @runnable_start [:runic, :runner, :runnable, :start]
  @runnable_stop [:runic, :runner, :runnable, :stop]
  @runnable_exception [:runic, :runner, :runnable, :exception]

  @store_start [:runic, :runner, :store, :start]
  @store_stop [:runic, :runner, :store, :stop]
  @store_exception [:runic, :runner, :store, :exception]

  @doc """
  Wraps a workflow lifecycle operation in a telemetry span.

  Emits `[:runic, :runner, :workflow, :start]` and
  `[:runic, :runner, :workflow, :stop]` (or `:exception`).
  """
  def workflow_span(metadata, fun) do
    :telemetry.span([:runic, :runner, :workflow], metadata, fn ->
      result = fun.()
      {result, metadata}
    end)
  end

  @doc """
  Emits a workflow lifecycle event.

  ## Event Types

    * `:start` — workflow started
    * `:stop` — workflow completed (includes duration measurement)
  """
  def workflow_event(:start, metadata) do
    :telemetry.execute(@workflow_start, %{system_time: System.system_time()}, metadata)
  end

  def workflow_event(:stop, measurements, metadata) do
    :telemetry.execute(@workflow_stop, measurements, metadata)
  end

  @doc """
  Emits a runnable lifecycle event.

  ## Event Types

    * `:dispatch` — runnable dispatched for execution
    * `:complete` — runnable completed successfully
    * `:exception` — runnable failed
  """
  def runnable_event(:dispatch, metadata) do
    :telemetry.execute(@runnable_start, %{system_time: System.system_time()}, metadata)
  end

  def runnable_event(:exception, metadata) do
    :telemetry.execute(@runnable_exception, %{}, metadata)
  end

  @doc """
  Emits a runnable completion event with measurements.
  """
  def runnable_event(:complete, measurements, metadata) do
    :telemetry.execute(@runnable_stop, measurements, metadata)
  end

  @doc """
  Wraps a store operation in a telemetry span.

  Emits `[:runic, :runner, :store, :start]` and
  `[:runic, :runner, :store, :stop]` (or `:exception`).
  """
  def store_span(operation, metadata, fun) do
    :telemetry.span(
      [:runic, :runner, :store],
      Map.put(metadata, :operation, operation),
      fn ->
        result = fun.()
        {result, metadata}
      end
    )
  end

  @doc """
  Returns all telemetry event names emitted by the Runner.

  Useful for `:telemetry.list_handlers/1` and handler setup.
  """
  def event_names do
    [
      @workflow_start,
      @workflow_stop,
      @workflow_exception,
      @runnable_start,
      @runnable_stop,
      @runnable_exception,
      @store_start,
      @store_stop,
      @store_exception
    ]
  end
end
