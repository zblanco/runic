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

  `identity_mode` and `local_scope` describe the input and retained meta source Facts, not another runtime
  context system. A native local callback receives bare data. To pass it to a
  nested workflow, explicitly pass these fields to `Workflow.execute/3`.
  """

  @type t :: %__MODULE__{
          identity_mode: :portable | :local,
          local_scope: Runic.Workflow.LocalScope.t() | nil,
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
    identity_mode: :portable,
    local_scope: nil,
    runtime: %{},
    meta: %{},
    input_metadata: %{}
  ]

  @doc false
  def from_runnable(runnable) do
    local =
      runnable.context
      |> Runic.Workflow.CausalContext.data_parents(runnable.input_fact)
      |> Enum.find(&(Map.get(&1, :identity_mode, :portable) == :local))

    %__MODULE__{
      runtime: runnable.context.run_context,
      identity_mode: if(local, do: :local, else: :portable),
      local_scope: if(local, do: local.local_scope),
      meta: runnable.context.meta_context,
      input_metadata: runnable.input_fact.meta,
      runnable_id: runnable.id,
      activation_id: runnable.activation_id,
      attempt_id: runnable.attempt_id,
      attempt_number: runnable.attempt_number
    }
  end
end
