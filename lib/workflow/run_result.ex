defmodule Runic.Workflow.RunResult do
  @moduledoc """
  Structured outcome returned by result-oriented workflow execution.

  `Runic.Workflow.react/2` and `react_until_satisfied/3` keep returning the
  updated workflow for compatibility. `Runic.Workflow.step/3` and
  `Runic.Workflow.run/3` return this struct when callers need execution status,
  cycle count, failed runnable details, and the final workflow together.
  """

  alias Runic.Workflow
  alias Runic.Workflow.Runnable

  defstruct [
    :workflow,
    :status,
    :cycles,
    :failed_runnable,
    :error,
    :events
  ]

  @type status :: :ok | :error | :max_cycles

  @type t :: %__MODULE__{
          workflow: Workflow.t(),
          status: status(),
          cycles: non_neg_integer(),
          failed_runnable: Runnable.t() | nil,
          error: term() | nil,
          events: [term()]
        }

  @doc false
  @spec new(Workflow.t(), status(), keyword()) :: t()
  def new(%Workflow{} = workflow, status, opts \\ []) when is_list(opts) do
    %__MODULE__{
      workflow: workflow,
      status: status,
      cycles: Keyword.get(opts, :cycles, 0),
      failed_runnable: Keyword.get(opts, :failed_runnable),
      error: Keyword.get(opts, :error),
      events: Keyword.get_lazy(opts, :events, fn -> Workflow.event_log(workflow) end)
    }
  end
end
