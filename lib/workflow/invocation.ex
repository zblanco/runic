defmodule Runic.Workflow.Invocation do
  @moduledoc false

  alias Runic.Workflow.{CallContract, CausalContext}
  alias Runic.Workflow.Invocation.Plan

  @type context :: %{
          runtime: map(),
          meta: map(),
          effective: map()
        }

  @type bindings :: %{
          inputs: map(),
          sources: list(map()),
          meta: map(),
          refs: list(map())
        }

  @type t :: %__MODULE__{
          version: pos_integer(),
          value: term(),
          arguments: list(),
          context: context(),
          bindings: bindings(),
          contract: CallContract.t()
        }

  @enforce_keys [:value, :arguments, :context, :bindings, :contract]
  defstruct [:value, :arguments, :context, :bindings, :contract, version: 1]

  @doc false
  @spec plan(CallContract.t()) :: Plan.t()
  def plan(%CallContract{} = contract) do
    %Plan{contract: CallContract.validate!(contract)}
  end

  @doc false
  @spec materialize(Plan.t(), term(), CausalContext.t()) :: t()
  def materialize(
        %Plan{version: 1, contract: contract},
        value,
        %CausalContext{} = causal_context
      ) do
    contract = CallContract.validate!(contract)
    arguments = prepare_arguments(contract, value)
    effective_context = merge_context(causal_context.meta_context, causal_context.run_context)

    %__MODULE__{
      value: value,
      arguments: arguments,
      context: %{
        runtime: causal_context.run_context,
        meta: causal_context.meta_context,
        effective: effective_context
      },
      bindings: %{
        inputs: bind_inputs(contract.input_order, arguments),
        sources: source_bindings(causal_context.input_fact),
        meta: causal_context.meta_context,
        refs: contract.binding_refs
      },
      contract: contract
    }
  end

  def materialize(%Plan{version: version}, _value, %CausalContext{}) do
    raise ArgumentError, "unsupported invocation plan version: #{inspect(version)}"
  end

  @doc false
  @spec call(t(), function()) :: term()
  def call(%__MODULE__{version: 1, contract: contract} = invocation, work)
      when is_function(work) do
    contract = CallContract.validate!(contract)

    arguments =
      case contract.style do
        :zero_arity -> []
        :single_input -> [invocation.value]
        :positional -> invocation.arguments
        :input_and_context -> [invocation.value, invocation.context.effective]
      end

    apply(work, arguments)
  end

  def call(%__MODULE__{version: version}, work) when is_function(work) do
    raise ArgumentError, "unsupported invocation version: #{inspect(version)}"
  end

  defp prepare_arguments(%CallContract{style: :zero_arity}, _value), do: []

  defp prepare_arguments(%CallContract{style: style}, value)
       when style in [:single_input, :input_and_context],
       do: [value]

  defp prepare_arguments(%CallContract{style: :positional, authored_arity: arity}, value)
       when is_list(value) do
    if length(value) == arity do
      value
    else
      raise ArgumentError,
            "positional invocation expected #{arity} values, got #{length(value)}"
    end
  end

  defp prepare_arguments(%CallContract{style: :positional, authored_arity: arity}, value) do
    raise ArgumentError,
          "positional invocation expected a list of #{arity} values, got: #{inspect(value)}"
  end

  defp bind_inputs(input_order, arguments) do
    if length(input_order) == length(arguments) do
      Map.new(Enum.zip(input_order, arguments))
    else
      raise ArgumentError,
            "call contract declares #{length(input_order)} input bindings for #{length(arguments)} arguments"
    end
  end

  defp source_bindings(%{meta: %{runic: %{input_bindings: bindings}}})
       when is_list(bindings),
       do: bindings

  defp source_bindings(_input_fact), do: []

  defp merge_context(meta, run) when map_size(meta) == 0 and map_size(run) == 0, do: %{}
  defp merge_context(meta, run) when map_size(run) == 0, do: meta
  defp merge_context(meta, run) when map_size(meta) == 0, do: run
  defp merge_context(meta, run), do: Map.merge(run, meta)
end
