defmodule Runic.Runner.Store do
  @moduledoc """
  Behaviour for workflow persistence adapters.

  Adapters handle saving and loading workflow event logs for
  durability across process restarts.

  ## Stream Semantics (Event-Sourced)

  The preferred interface uses `append/3` and `stream/2` for incremental
  event persistence. Events are appended after each execution cycle and
  streamed on recovery to rebuild workflow state via `Workflow.from_events/1`.

  Stores that implement `append/3` and `stream/2` get automatic
  event-sourced checkpointing and recovery from the Worker.

  ## Legacy Semantics (Snapshot)

  The `save/3` and `load/2` callbacks persist the full workflow log as a
  snapshot. These remain the required baseline interface for backward
  compatibility. Stores that only implement `save/load` continue to work
  unchanged.

  ## Optional Capabilities

  - **Snapshots** (`save_snapshot/4`, `load_snapshot/3`): Point-in-time
    workflow snapshots for faster recovery (replay from snapshot + events
    after cursor instead of full replay).
  - **Fact storage** (`save_fact/3`, `load_fact/2`): Content-addressed fact
    value storage for hybrid rehydration without loading all values into memory.
  """

  @type workflow_id :: term()
  @type event :: struct()
  @type cursor :: non_neg_integer()
  @type log :: [struct()]
  @type state :: term()

  # Core (required) — snapshot-based
  @callback init_store(opts :: keyword()) :: {:ok, state()} | {:error, term()}
  @callback save(workflow_id(), log(), state()) :: :ok | {:error, term()}
  @callback load(workflow_id(), state()) :: {:ok, log()} | {:error, :not_found | term()}

  # Stream semantics (optional — event-sourced)
  @callback append(workflow_id(), events :: [event()], state()) ::
              {:ok, cursor()} | {:error, term()}
  @callback stream(workflow_id(), state()) ::
              {:ok, Enumerable.t()} | {:error, :not_found | term()}

  # Snapshot (optional — faster recovery with stream semantics)
  @callback save_snapshot(workflow_id(), cursor(), snapshot :: binary(), state()) ::
              :ok | {:error, term()}
  @callback load_snapshot(workflow_id(), state()) ::
              {:ok, {cursor(), binary()}} | {:error, :not_found | term()}

  # Fact-level storage (optional — hybrid rehydration)
  @callback save_fact(fact_hash :: term(), value :: term(), state()) ::
              :ok | {:error, term()}
  @callback load_fact(fact_hash :: term(), state()) ::
              {:ok, term()} | {:error, :not_found | term()}

  # Lifecycle (optional)
  @callback checkpoint(workflow_id(), log(), state()) :: :ok | {:error, term()}
  @callback delete(workflow_id(), state()) :: :ok | {:error, term()}
  @callback list(state()) :: {:ok, [workflow_id()]} | {:error, term()}
  @callback exists?(workflow_id(), state()) :: boolean()

  @optional_callbacks [
    append: 3,
    stream: 2,
    save_snapshot: 4,
    load_snapshot: 2,
    save_fact: 3,
    load_fact: 2,
    checkpoint: 3,
    delete: 2,
    list: 1,
    exists?: 2
  ]

  @doc """
  Returns true if the store module supports event-sourced stream semantics.
  """
  @spec supports_stream?(module()) :: boolean()
  def supports_stream?(store_mod) do
    function_exported?(store_mod, :append, 3) and function_exported?(store_mod, :stream, 2)
  end
end
