defmodule Runic.Examples.JidoAction do
  @moduledoc """
  Ordinary Jido Action example using Runic's single-output lifecycle.

  Load this and `component.ex` in a project with Jido Action V3 and this Runic
  revision. Native local facts supply bare input and inherit their mode through
  SingleOutput; no Jido fact wrapper or child-fact factory is needed here.
  Portable calls retain Jido's durability checks. Action schemas, output and
  effect validation remain in Jido. This is not a replacement Flow compiler.
  """
  use Runic.Workflow.SingleOutput

  alias Runic.Workflow.SingleOutput.Result

  defstruct [:hash, :name, :action]

  def new(instruction, opts \\ []) do
    opts = Keyword.validate!(opts, [:id, :name])
    instruction |> Jido.Exec.Node.Action.new(opts) |> from_action()
  end

  def from_action(%{flow: nil} = action) do
    %__MODULE__{
      name: action.name,
      action: action,
      hash:
        Runic.Identity.digest(
          :component_definition,
          {:jido_single_output_example, 1, Runic.Component.source(action)}
        )
    }
  end

  @impl true
  def run(node, input, context) do
    action = node.action.instruction.target

    metadata = %{
      action: action,
      action_name: action.name(),
      node_name: node.name,
      runnable_id: context.runnable_id,
      activation_id: context.activation_id,
      attempt_id: context.attempt_id,
      attempt: context.attempt_number
    }

    result =
      Jido.Exec.Telemetry.span(:action, metadata, fn ->
        with :ok <- validate_data(input, :input, context.identity_mode),
             :ok <- validate_data(context.input_metadata, :metadata, context.identity_mode),
             {:ok, value, effects} <-
               Jido.Exec.Node.Action.execute(
                 node.action,
                 input,
                 context.runtime,
                 context.input_metadata
               ),
             :ok <- validate_data(value, :output, context.identity_mode),
             :ok <- validate_data(effects, :effects, context.identity_mode) do
          {:ok, value, effects}
        end
      end)

    case result do
      {:ok, value, effects} ->
        # Effect interpretation and ordering remain Jido concerns. Runic merely
        # stores this application metadata; it does not deliver these requests.
        input_metadata = Map.delete(context.input_metadata, :runic)
        jido = Map.get(input_metadata, :jido, %{})
        jido = Map.put(jido, :effects, Map.get(jido, :effects, []) ++ effects)
        Result.value(value, metadata: Map.put(input_metadata, :jido, jido))

      {:error, reason} ->
        Result.failure(reason)
    end
  end

  defp validate_data(_value, _field, :local), do: :ok
  defp validate_data(value, field, :portable), do: Jido.Exec.Portable.validate(value, field)
end
