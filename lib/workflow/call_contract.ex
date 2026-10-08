defmodule Runic.Workflow.CallContract do
  @moduledoc false

  alias Runic.Workflow.Components

  @version 1
  @styles [:zero_arity, :single_input, :positional, :input_and_context]

  @type style :: :zero_arity | :single_input | :positional | :input_and_context

  @type t :: %__MODULE__{
          version: pos_integer(),
          style: style(),
          authored_arity: non_neg_integer(),
          compiled_arity: non_neg_integer(),
          input_order: list(atom() | non_neg_integer()),
          binding_refs: list(map())
        }

  @enforce_keys [:version, :style, :authored_arity, :compiled_arity, :input_order]
  defstruct [
    :version,
    :style,
    :authored_arity,
    :compiled_arity,
    :input_order,
    binding_refs: []
  ]

  @doc false
  @spec compile(map()) :: t()
  def compile(step) when is_map(step) do
    work = Map.fetch!(step, :work)
    compiled_arity = Components.arity_of(work)
    meta_refs = Map.get(step, :meta_refs, [])
    contextual? = meta_refs != []
    authored_arity = if contextual?, do: max(compiled_arity - 1, 0), else: compiled_arity

    style =
      cond do
        contextual? -> :input_and_context
        authored_arity == 0 -> :zero_arity
        authored_arity == 1 -> :single_input
        true -> :positional
      end

    %__MODULE__{
      version: @version,
      style: style,
      authored_arity: authored_arity,
      compiled_arity: compiled_arity,
      input_order: input_order(Map.get(step, :inputs), authored_arity),
      binding_refs: normalize_binding_refs(meta_refs)
    }
    |> validate!()
  end

  @doc false
  @spec for_step(map()) :: t()
  def for_step(step) when is_map(step) do
    case Map.get(step, :call_contract) do
      %__MODULE__{} = contract -> validate!(contract)
      nil -> compile(step)
      contract -> raise ArgumentError, "invalid step call contract: #{inspect(contract)}"
    end
  end

  @doc false
  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = contract) do
    unless contract.version == @version do
      raise ArgumentError,
            "unsupported call contract version #{inspect(contract.version)}; expected #{@version}"
    end

    unless contract.style in @styles do
      raise ArgumentError, "unsupported call contract style: #{inspect(contract.style)}"
    end

    unless is_integer(contract.authored_arity) and contract.authored_arity >= 0 and
             is_integer(contract.compiled_arity) and contract.compiled_arity >= 0 do
      raise ArgumentError, "call contract arities must be non-negative integers"
    end

    unless is_list(contract.input_order) and
             Enum.all?(contract.input_order, &(is_atom(&1) or (is_integer(&1) and &1 >= 0))) do
      raise ArgumentError,
            "call contract input order must contain atom port names or positional indexes"
    end

    unless is_list(contract.binding_refs) and Enum.all?(contract.binding_refs, &is_map/1) do
      raise ArgumentError, "call contract binding refs must be data maps"
    end

    validate_style_shape!(contract)

    contract
  end

  defp validate_style_shape!(%__MODULE__{
         style: :zero_arity,
         authored_arity: 0,
         compiled_arity: 0
       }),
       do: :ok

  defp validate_style_shape!(%__MODULE__{
         style: :single_input,
         authored_arity: 1,
         compiled_arity: 1
       }),
       do: :ok

  defp validate_style_shape!(%__MODULE__{
         style: :positional,
         authored_arity: arity,
         compiled_arity: arity
       })
       when arity > 1,
       do: :ok

  defp validate_style_shape!(%__MODULE__{
         style: :input_and_context,
         authored_arity: 1,
         compiled_arity: 2
       }),
       do: :ok

  defp validate_style_shape!(contract) do
    raise ArgumentError,
          "call contract style #{inspect(contract.style)} is inconsistent with authored arity #{contract.authored_arity} and compiled arity #{contract.compiled_arity}"
  end

  defp input_order(_inputs, 0), do: []

  defp input_order(nil, 1), do: [:in]

  defp input_order(nil, arity) do
    Enum.to_list(0..(arity - 1))
  end

  defp input_order(inputs, _arity) when is_list(inputs) do
    cond do
      Keyword.keyword?(inputs) -> Keyword.keys(inputs)
      Enum.all?(inputs, &is_atom/1) -> inputs
      true -> raise ArgumentError, "step inputs must contain named ports, got: #{inspect(inputs)}"
    end
  end

  defp input_order(inputs, _arity) do
    raise ArgumentError, "step inputs must be a keyword list, got: #{inspect(inputs)}"
  end

  defp normalize_binding_refs(meta_refs) do
    Enum.map(meta_refs, fn ref ->
      %{
        kind: Map.fetch!(ref, :kind),
        target: Map.get(ref, :target),
        context_key: Map.get(ref, :context_key),
        field_path: Map.get(ref, :field_path, [])
      }
    end)
  end
end
