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

  def delayed(kind) do
    names = if kind == :bad, do: [:s1, :s2, :s3, :s4, :s5, :s6], else: [:g1, :g2, :g3]

    nodes =
      Enum.with_index(names)
      |> Enum.map(fn {name, index} ->
        operation =
          cond do
            kind == :bad and name == :s6 -> :failure
            index == 0 -> :add
            true -> :data
          end

        Runic.TestSupport.OrdinaryComponent.new(
          name,
          operation,
          if(operation == :add, do: 100, else: :bad)
        )
      end)

    [first | rest] = nodes

    workflow =
      Runic.Workflow.new(
        name: :target,
        input_ports: [in: []],
        output_ports: [out: [from: List.last(names)]]
      )
      |> Runic.Workflow.add(first)

    Enum.reduce(rest, {workflow, first}, fn node, {wf, parent} ->
      {Runic.Workflow.add(wf, node, to: parent.name), node}
    end)
    |> elem(0)
  end
end
