defmodule Runic.Workflow.SingleOutput.Context do
  @moduledoc """
  Read-only execution information for a single-output callback.

  `runtime` is the existing component-scoped Runic runtime context; `meta`
  contains prepared graph/context expression bindings. `input_metadata` is
  the input Fact's metadata. The remaining fields identify this activation
  and its current attempt, including retries. No graph, hooks, or collection
  bookkeeping is exposed.

  This is a transient callback view, not a saved component definition or a
  portable dispatch envelope. Do not retain resources from it in outputs or
  captured bindings. Resume must supply fresh runtime resources as usual.
  """

  @type t :: %__MODULE__{
          runtime: map(),
          meta: map(),
          input_metadata: map(),
          runnable_id: term(),
          activation_id: term(),
          attempt_id: term(),
          attempt_number: non_neg_integer()
        }
  defstruct [
    :runnable_id,
    :activation_id,
    :attempt_id,
    :attempt_number,
    runtime: %{},
    meta: %{},
    input_metadata: %{}
  ]

  @doc false
  def from_runnable(runnable) do
    %__MODULE__{
      runtime: runnable.context.run_context,
      meta: runnable.context.meta_context,
      input_metadata: runnable.input_fact.meta,
      runnable_id: runnable.id,
      activation_id: runnable.activation_id,
      attempt_id: runnable.attempt_id,
      attempt_number: runnable.attempt_number
    }
  end
end
