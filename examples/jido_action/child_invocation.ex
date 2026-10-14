defmodule Runic.Examples.JidoDispatchBoundary do
  @moduledoc """
  An Action Dispatch boundary built with Runic Call.

  Jido resolves the target and converts its result through the existing
  SingleOutput adapter. Runic owns child attachment and completion. Jido reads
  the completed Fact and puts its value and effects in the parent Frame.
  The real Flow compiler can use the same connection group for nested inputs.
  This example covers ordinary Action targets, not all Jido Flow primitives.
  """
  require Runic
  alias Runic.Examples.JidoAction
  alias Runic.Workflow
  alias Runic.Workflow.{Call, ChildInvocation}

  def workflow do
    request = Runic.step(&__MODULE__.request/1, name: :dispatch_request)
    Workflow.new() |> Workflow.add(Call.new(request, name: :dispatch))
  end

  def request(%{target: target, input: input}) do
    {:ok, instruction} = Jido.Instruction.resolve(target)
    ChildInvocation.new(target: JidoAction.new(instruction, name: :target), input: input)
  end

  def put_result(frame, component, fact) do
    effects = get_in(fact.meta, [:jido, :effects]) || []
    Jido.Exec.Frame.put_result(frame, component, fact.value, effects)
  end
end
