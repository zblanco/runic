defmodule Runic.TestSupport.ChildTargets do
  @moduledoc false
  require Runic

  def blocked do
    Runic.step(
      fn input ->
        Process.flag(:trap_exit, true)
        send(context(:observer), {:child_started, self()})
        receive do: (:release -> input * 2)
      end,
      name: :target
    )
  end

  def contextual do
    Runic.step(fn input -> input + context(:offset) end, name: :target)
  end

  def grouped do
    Runic.workflow(
      name: :target,
      steps: [
        {[
           Runic.step(fn n -> n + 1 end, name: :left),
           Runic.step(fn n -> n * 2 end, name: :right)
         ], [Runic.step(fn a, b -> a + b end, name: :sum)]}
      ]
    )
    |> Map.put(:input_ports, in: [])
    |> Map.put(:output_ports, out: [from: :sum])
  end

  def many_returns do
    Runic.Workflow.new(
      name: :target,
      input_ports: [in: []],
      output_ports: [out: [from: :selected]]
    )
    |> Runic.Workflow.add(Runic.step(fn n -> n + 1 end, name: :left))
    |> Runic.Workflow.add(Runic.step(fn n -> n + 2 end, name: :right))
    |> Runic.Workflow.add(Runic.step(fn n -> n end, name: :selected),
      connections: [[from: {:left, :out}, to: :in], [from: {:right, :out}, to: :in]],
      input_mode: :any
    )
  end

  def sibling_failure do
    Runic.Workflow.new(
      name: :target,
      input_ports: [in: []],
      output_ports: [out: [from: :success]]
    )
    |> Runic.Workflow.add(Runic.TestSupport.OrdinaryComponent.new(:success, :add, 1))
    |> Runic.Workflow.add(Runic.TestSupport.OrdinaryComponent.new(:failure, :failure, :bad))
  end
end
