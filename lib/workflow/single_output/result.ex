defmodule Runic.Workflow.SingleOutput.Result do
  @moduledoc """
  Explicit output or failure from a `Runic.Workflow.SingleOutput` callback.

  `value/2` treats its argument as data, including error-shaped tuples.
  `failure/1` asks the execution policy to handle a failed attempt. These
  interpretations apply only to opted-in callbacks, never to ordinary Step
  return values.

  Output metadata is an explicit replacement, not an automatic merge with the
  input metadata. Select the application namespaces you want to propagate.
  The `:runic` namespace is reserved for native coordination and cannot be set
  here. Runtime context is never automatically copied into an output.
  """

  @type t :: %__MODULE__{
          status: :value | :failure,
          value: term(),
          error: term(),
          metadata: map()
        }
  @enforce_keys [:status]
  defstruct [:status, :value, :error, metadata: %{}]

  @doc "Returns successful data with optional application `:metadata`."
  @spec value(term(), keyword()) :: t()
  def value(value, opts \\ []) do
    opts = Keyword.validate!(opts, metadata: %{})
    metadata = Keyword.fetch!(opts, :metadata)
    validate_metadata!(metadata)
    %__MODULE__{status: :value, value: value, metadata: metadata}
  end

  @doc "Returns an explicit attempt failure, retaining the consumer's error."
  @spec failure(term()) :: t()
  def failure(reason), do: %__MODULE__{status: :failure, error: reason}

  @doc false
  def validate_metadata!(metadata) when is_map(metadata) and not is_struct(metadata) do
    if Map.has_key?(metadata, :runic) do
      raise ArgumentError, "SingleOutput metadata cannot set the reserved :runic namespace"
    end

    :ok
  end

  def validate_metadata!(_), do: raise(ArgumentError, "SingleOutput metadata must be a map")
end
