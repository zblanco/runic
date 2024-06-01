defmodule Runic.Workflow.Map do
  @moduledoc """
  Map steps are part of a map operator that expands enumerable facts into separate facts.

  Map just splits input facts - separate steps as defined in the map expression will do the processing.
  """
  alias Runic.Workflow.FanOut
  defstruct [:hash, :name, :pipeline, :components]

  def build_named_components(%__MODULE__{pipeline: pipeline} = map) do
    %__MODULE__{map | components: named_steps(pipeline, %{})}
  end

  defp named_steps({%FanOut{name: nil} = step, steps}, acc),
    do: named_steps(steps, acc |> Map.put(:fan_out, step))

  defp named_steps({%FanOut{name: name} = step, steps}, acc),
    do: named_steps(steps, acc |> Map.put(:fan_out, step) |> Map.put(name, step))

  defp named_steps({%{name: name} = step, steps}, acc),
    do: named_steps(steps, Map.put(acc, name, step))

  defp named_steps({_, steps}, acc), do: named_steps(steps, acc)

  defp named_steps(%{name: name} = step, acc),
    do: acc |> Map.put(name, step) |> Map.put(:leaf, step)

  defp named_steps([_ | _] = steps, acc) do
    Enum.reduce(steps, acc, fn step, acc ->
      named_steps(step, acc)
    end)
  end

  defp named_steps(_, acc), do: acc
end
