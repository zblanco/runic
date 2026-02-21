defmodule Runic.Workflow.RunnableCompleted do
  @moduledoc """
  Event recording that a runnable completed execution successfully.

  Fields:

  - `duration_ms` — wall-clock execution time in milliseconds (monotonic)
  - `attempt` — zero-based attempt index (0 = first try, 1 = first retry, etc.)
  - `result_fact` — the `%Fact{}` produced by the step
  """

  @type t :: %__MODULE__{
          runnable_id: term(),
          node_hash: non_neg_integer(),
          result_fact: Runic.Workflow.Fact.t(),
          completed_at: integer(),
          attempt: non_neg_integer(),
          duration_ms: non_neg_integer()
        }

  defstruct [
    :runnable_id,
    :node_hash,
    :result_fact,
    :completed_at,
    :attempt,
    :duration_ms
  ]
end
