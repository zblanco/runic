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

  `stream/2` must always return the full event stream for a workflow. Stores
  that support cursor-aware or windowed replay can additionally implement
  `stream/3` with options.

  Supported `stream/3` options:

    * `:after_cursor` — exclusive lower bound. `after_cursor: 10` returns
      events with sequence/cursor greater than `10`.
    * `:limit` — optional maximum number of events to return. Adapters may
      ignore this when their backing stream does not support bounded reads.
    * `:batch_size` — optional page-size hint for stores that fetch event rows
      in batches.

  `stream/3` should be a superset of `stream/2`: calling it with an empty
  option list should return the full stream. Adapters should ignore unknown
  options they do not support.

  ## Legacy Semantics (Snapshot)

  The `save/3` and `load/2` callbacks persist the full workflow log as a
  snapshot. These remain the required baseline interface for backward
  compatibility. Stores that only implement `save/load` continue to work
  unchanged.

  ## Optional Capabilities

  - **Snapshots** (`save_snapshot/4`, `load_snapshot/2`): Point-in-time
    workflow snapshots for faster recovery (replay from snapshot + events
    after cursor instead of full replay).
  - **Fact storage** (`save_fact/3`, `load_fact/2`): Content-addressed fact
    value storage for hybrid rehydration without loading all values into memory.
  - **Payload storage** (`save_payload/3`, `load_payload/2`): Immutable encoded
    payload bytes keyed by a `:payload` `Runic.Identity`.
  """

  @type workflow_id :: term()
  @type event :: struct()
  @type cursor :: non_neg_integer()
  @type log :: [struct()]
  @type state :: term()
  @type stream_opts :: [
          after_cursor: cursor(),
          limit: pos_integer(),
          batch_size: pos_integer()
        ]

  # Core (required) — snapshot-based
  @callback init_store(opts :: keyword()) :: {:ok, state()} | {:error, term()}
  @callback save(workflow_id(), log(), state()) :: :ok | {:error, term()}
  @callback load(workflow_id(), state()) :: {:ok, log()} | {:error, :not_found | term()}

  # Stream semantics (optional — event-sourced)
  @callback append(workflow_id(), events :: [event()], state()) ::
              {:ok, cursor()} | {:error, term()}
  @callback stream(workflow_id(), state()) ::
              {:ok, Enumerable.t()} | {:error, :not_found | term()}
  @callback stream(workflow_id(), state(), stream_opts()) ::
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

  @callback save_payload(Runic.Identity.t(), encoded_payload :: binary(), state()) ::
              :ok | {:error, term()}
  @callback load_payload(Runic.Identity.t(), state()) ::
              {:ok, binary()} | {:error, :not_found | term()}

  # Lifecycle (optional)
  @callback checkpoint(workflow_id(), log(), state()) :: :ok | {:error, term()}
  @callback delete(workflow_id(), state()) :: :ok | {:error, term()}
  @callback list(state()) :: {:ok, [workflow_id()]} | {:error, term()}
  @callback exists?(workflow_id(), state()) :: boolean()

  @optional_callbacks [
    append: 3,
    stream: 2,
    stream: 3,
    save_snapshot: 4,
    load_snapshot: 2,
    save_fact: 3,
    load_fact: 2,
    save_payload: 3,
    load_payload: 2,
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

  @doc """
  Returns true if the store module supports option-aware stream replay.
  """
  @spec supports_stream_options?(module()) :: boolean()
  def supports_stream_options?(store_mod) do
    function_exported?(store_mod, :stream, 3)
  end

  @doc """
  Returns true if the store module supports snapshot save/load semantics.
  """
  @spec supports_snapshots?(module()) :: boolean()
  def supports_snapshots?(store_mod) do
    function_exported?(store_mod, :save_snapshot, 4) and
      function_exported?(store_mod, :load_snapshot, 2)
  end
end
