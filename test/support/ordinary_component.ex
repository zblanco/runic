defmodule Runic.TestSupport.OrdinaryComponent do
  @moduledoc false
  use Runic.Workflow.SingleOutput

  alias Runic.Workflow.SingleOutput.Result

  defstruct [:hash, :name, :operation, :config]

  def new(name, operation \\ :add, config \\ 1) do
    %__MODULE__{
      name: name,
      operation: operation,
      config: config,
      hash: Runic.Identity.digest(:component_definition, {name, operation, config})
    }
  end

  @impl true
  def run(node, value, context) do
    if pid = context.runtime[:observer], do: send(pid, {:work, node.name, context})

    case node.operation do
      :add ->
        Result.value(value + node.config + Map.get(context.runtime, :offset, 0))

      :data ->
        Result.value(value)

      :metadata ->
        Result.value(value, metadata: Map.put(context.input_metadata, :custom, node.config))

      :failure ->
        Result.failure(node.config)

      :retry ->
        if context.attempt_number < node.config,
          do: Result.failure(:again),
          else: Result.value(value)

      :raise ->
        raise ArgumentError, "work failed"

      :throw ->
        throw(:work_failed)

      :exit ->
        exit(:work_failed)

      :invalid ->
        {:ok, value}
    end
  end
end
