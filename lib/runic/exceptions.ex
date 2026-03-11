defmodule Runic.UnresolvedReferenceError do
  @moduledoc """
  Raised when a component references another component that does not exist in the workflow.

  This typically occurs when adding a rule with meta expressions like `state_of(:counter)`
  before the `:counter` component has been added to the workflow.

  ## Example

      workflow = Workflow.new()
      
      # This will raise because :counter doesn't exist yet
      |> Workflow.add(rule_using_state_of_counter)
      
      # The accumulator should be added first
      |> Workflow.add(counter_accumulator)

  ## Solutions

  1. Add target components before adding rules that reference them
  2. Ensure component names match exactly (atoms are case-sensitive)
  3. For subcomponent references like `{:parent, :child}`, ensure both parent and child exist

  """

  defexception [:message, :component_name, :reference_kind, :target, :hint]

  @impl true
  def exception(opts) do
    component_name = Keyword.fetch!(opts, :component_name)
    reference_kind = Keyword.fetch!(opts, :reference_kind)
    target = Keyword.fetch!(opts, :target)
    hint = Keyword.get(opts, :hint)

    target_str = format_target(target)

    message =
      "Cannot add component #{inspect(component_name)} - " <>
        "meta reference #{reference_kind}(#{target_str}) targets component #{target_str} " <>
        "which does not exist in the workflow."

    message =
      if hint do
        message <> "\n\nHint: #{hint}"
      else
        message <>
          "\n\nHint: Add the #{target_str} component before adding this component."
      end

    %__MODULE__{
      message: message,
      component_name: component_name,
      reference_kind: reference_kind,
      target: target,
      hint: hint
    }
  end

  defp format_target({parent, child}), do: "{#{inspect(parent)}, #{inspect(child)}}"
  defp format_target(target), do: inspect(target)
end

defmodule Runic.IncompatiblePortError do
  @moduledoc """
  Raised when connecting two components with incompatible port contracts.

  This occurs when `Workflow.add/3` detects that a producer's output ports
  are not type-compatible with a consumer's input ports.

  ## Example

      require Runic
      alias Runic.Workflow

      int_step = Runic.step(fn x -> x + 1 end,
        name: :int_producer,
        outputs: [out: [type: :integer]]
      )

      string_consumer = Runic.step(fn x -> String.upcase(x) end,
        name: :string_consumer,
        inputs: [in: [type: :string]]
      )

      # This raises IncompatiblePortError
      Workflow.new()
      |> Workflow.add(int_step)
      |> Workflow.add(string_consumer, to: :int_producer)

  ## Solutions

  1. Ensure output types match expected input types
  2. Use `type: :any` for flexible ports
  3. Pass `validate: :off` to bypass validation during prototyping

  """

  defexception [:message, :producer, :consumer, :reasons]

  @impl true
  def exception(opts) do
    producer = Keyword.fetch!(opts, :producer)
    consumer = Keyword.fetch!(opts, :consumer)
    reasons = Keyword.fetch!(opts, :reasons)

    producer_name = component_name(producer)
    consumer_name = component_name(consumer)

    reason_lines =
      Enum.map_join(reasons, "\n", fn
        {:type_mismatch, p_type, c_type} ->
          "  - Type mismatch: producer outputs #{inspect(p_type)}, consumer expects #{inspect(c_type)}"

        {:unmatched_port, port_name, expected_type} ->
          "  - Required input port #{inspect(port_name)} (type: #{inspect(expected_type)}) has no compatible producer output"
      end)

    message =
      "Cannot connect #{inspect(consumer_name)} to #{inspect(producer_name)} — port contracts are incompatible:\n" <>
        reason_lines <>
        "\n\nHint: Use `validate: :off` to bypass port validation during prototyping."

    %__MODULE__{
      message: message,
      producer: producer,
      consumer: consumer,
      reasons: reasons
    }
  end

  defp component_name(%{name: name}) when not is_nil(name), do: name
  defp component_name(%{hash: hash}), do: hash
  defp component_name(other), do: inspect(other)
end
