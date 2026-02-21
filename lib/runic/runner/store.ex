defmodule Runic.Runner.Store do
  @moduledoc """
  Behaviour for workflow persistence adapters.

  Adapters handle saving and loading workflow event logs for
  durability across process restarts.
  """

  @type workflow_id :: term()
  @type log :: [struct()]
  @type state :: term()

  @callback init_store(opts :: keyword()) :: {:ok, state()} | {:error, term()}
  @callback save(workflow_id(), log(), state()) :: :ok | {:error, term()}
  @callback load(workflow_id(), state()) :: {:ok, log()} | {:error, :not_found | term()}
  @callback checkpoint(workflow_id(), log(), state()) :: :ok | {:error, term()}
  @callback delete(workflow_id(), state()) :: :ok | {:error, term()}
  @callback list(state()) :: {:ok, [workflow_id()]} | {:error, term()}
  @callback exists?(workflow_id(), state()) :: boolean()

  @optional_callbacks [checkpoint: 3, delete: 2, list: 1, exists?: 2]
end
