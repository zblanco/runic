defmodule Runic.Bench.Issue19.Scenarios do
  @moduledoc false
  alias Runic.Workflow
  require Runic

  def build(kind, coordination) do
    mapper =
      case kind do
        :deep ->
          Runic.map(
            {Runic.step(fn x -> x + 1 end, name: :a),
             [
               {Runic.step(fn x -> x * 2 end, name: :b),
                [
                  {Runic.step(fn x -> x - 1 end, name: :c),
                   [Runic.step(fn x -> x + 3 end, name: :d)]}
                ]}
             ]},
            name: :items
          )

        :slow_first ->
          Runic.map(
            fn x ->
              if x == 1, do: Process.sleep(10)
              x
            end,
            name: :items
          )

        :latency ->
          Runic.map(
            fn x ->
              Process.sleep(2)
              x
            end,
            name: :items
          )

        _ ->
          Runic.map(fn x -> x end, name: :items)
      end

    reducer =
      if kind in [:sum, :deep, :repeated, :stream] do
        Runic.reduce(0, fn x, acc -> x + acc end,
          name: :output,
          map: :items,
          coordination: coordination
        )
      else
        Runic.reduce([], fn x, acc -> [x | acc] end,
          name: :output,
          map: :items,
          coordination: coordination
        )
      end

    Workflow.new() |> Workflow.add(mapper) |> Workflow.add(reducer, to: :items)
  end

  def inputs(:repeated, n),
    do: for(batch <- 0..3, do: Enum.to_list((batch * n + 1)..((batch + 1) * n)))

  def inputs(:binary, n), do: [for(i <- 1..n, do: {i, :binary.copy(<<rem(i, 251)>>, 1024)})]
  def inputs(:stream, n), do: [1..n]
  def inputs(_, n), do: [Enum.to_list(1..n)]

  def expected(kind, input) when kind in [:sum, :repeated, :stream], do: Enum.sum(input)
  def expected(:deep, input), do: Enum.sum(Enum.map(input, &((&1 + 1) * 2 - 1 + 3)))
  def expected(_, input), do: Enum.reverse(input)

  def verify!(workflow, kind, input) do
    outputs = Workflow.raw_productions(workflow, :output)
    expected = expected(kind, input)

    unless Enum.count(outputs, &(&1 == expected)) == 1,
      do: raise("incorrect output or multiplicity for #{kind}: #{inspect(outputs, limit: 5)}")

    :ok
  end
end
