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
