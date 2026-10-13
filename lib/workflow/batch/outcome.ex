defmodule Runic.Workflow.Batch.Outcome do
  @moduledoc """
  One ordered item outcome. Raw terminal errors remain available in `error`.

  Failure identity uses the accepted activation, attempt, status, and error kind.
  It does not encode arbitrary raw error fields or prove their portability.
  Store and transport adapters must validate the raw value for their own profile.
  Completed data retains the normal canonical payload rules.
  """
  @enforce_keys [:id, :batch_id, :index, :status]
  defstruct [:id, :batch_id, :index, :status, :value, :error, :activation_id, :attempt_id]

  @doc false
  def failure_occurrence(outcome) do
    %{
      status: outcome.status,
      activation_id: outcome.activation_id,
      attempt_id: outcome.attempt_id,
      error_kind: error_kind(outcome.error)
    }
  end

  defp error_kind(%{__exception__: true, __struct__: module}), do: {:exception, module}
  defp error_kind(%module{}), do: {:struct, module}

  defp error_kind(error)
       when is_tuple(error) and tuple_size(error) > 0 and is_atom(elem(error, 0)),
       do: {:tag, elem(error, 0)}

  defp error_kind(_), do: :term
end

defimpl Runic.Identity.Projectable, for: Runic.Workflow.Batch.Outcome do
  def identity_document(outcome) do
    fields = Map.from_struct(outcome)

    projected =
      if outcome.status in [:failed, :skipped],
        do:
          fields
          |> Map.delete(:error)
          |> Map.put(
            :failure_occurrence,
            Runic.Workflow.Batch.Outcome.failure_occurrence(outcome)
          ),
        else: fields

    %{version: 2, fields: projected}
  end
end
