defmodule Runic.Workflow.RunnableFailed do
  @moduledoc """
  Event recording that a runnable failed permanently (retries exhausted).

  Fields:

  - `attempts` — total number of execution attempts (initial + retries)
  - `failure_action` — the `on_failure` action taken: `:halt` or `:skip`
  - `error` — the error term from the last failed attempt
  """

  @type t :: %__MODULE__{
          runnable_id: term(),
          node_hash: non_neg_integer(),
          error: term(),
          failed_at: integer(),
          attempts: non_neg_integer(),
          failure_action: :halt | :skip
        }

  defstruct [
    :runnable_id,
    :node_hash,
    :error,
    :failed_at,
    :attempts,
    :failure_action
  ]
end
