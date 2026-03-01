defmodule Runic.Runner.Promise do
  @moduledoc """
  A batched execution unit that groups runnables for optimized dispatch.

  Promises enable the scheduler to dispatch multiple runnables as a single
  task, reducing process spawn overhead.

  ## Strategies

    * `:sequential` — runnables execute one after another within a single Task.
      Each step sees the updated workflow state from the previous step. Used for
      linear chains (e.g., `a → b → c`).

    * `:parallel` — runnables execute concurrently via `Flow` (or `Task.async_stream`
      as fallback). All runnables are independent — no intermediate state sharing.
      Used for fan-out batches of independent runnables.

  ## Failure Semantics

  **Sequential:** partial commit — if runnable N fails, runnables 1..N-1
  are committed, the failed runnable is returned for error handling, and
  runnables N+1..end are skipped.

  **Parallel:** all runnables execute independently. Individual failures are
  caught and returned as failed runnables in the result list. Succeeded
  runnables are committed normally.

  ## Observability

  Promise telemetry events are emitted in addition to per-runnable events:

    * `[:runic, :runner, :promise, :start]` — promise dispatched
    * `[:runic, :runner, :promise, :stop]` — promise completed or partially failed
  """

  @type t :: %__MODULE__{
          id: reference(),
          runnables: [Runic.Workflow.Runnable.t()],
          node_hashes: MapSet.t(),
          strategy: :sequential | :parallel,
          status: :pending | :resolving | :resolved | :failed,
          results: [Runic.Workflow.Runnable.t()],
          checkpoint_boundary: boolean(),
          flow_opts: keyword()
        }

  defstruct [
    :id,
    :runnables,
    :node_hashes,
    strategy: :sequential,
    status: :pending,
    results: [],
    checkpoint_boundary: false,
    flow_opts: []
  ]

  @doc """
  Creates a new Promise from a list of runnables.

  The `node_hashes` set is used by the scheduler to skip dispatch
  for runnables whose nodes are already covered by an in-flight Promise.

  ## Options

    * `:node_hashes` — pre-computed MapSet of node hashes (default: derived from runnables)
    * `:strategy` — `:sequential` or `:parallel` (default: `:sequential`)
    * `:checkpoint_boundary` — whether this promise is a checkpoint boundary (default: `false`)
    * `:flow_opts` — options for parallel resolution via Flow (default: `[]`):
      * `:stages` — number of Flow stages (default: `min(count, schedulers_online)`)
      * `:max_demand` — Flow max_demand per stage (default: `1`)
  """
  @spec new([Runic.Workflow.Runnable.t()], keyword()) :: t()
  def new(runnables, opts \\ []) do
    node_hashes =
      Keyword.get_lazy(opts, :node_hashes, fn ->
        runnables
        |> Enum.map(& &1.node.hash)
        |> MapSet.new()
      end)

    %__MODULE__{
      id: make_ref(),
      runnables: runnables,
      node_hashes: node_hashes,
      strategy: Keyword.get(opts, :strategy, :sequential),
      checkpoint_boundary: Keyword.get(opts, :checkpoint_boundary, false),
      flow_opts: Keyword.get(opts, :flow_opts, [])
    }
  end
end
