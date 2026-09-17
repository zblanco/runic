require Runic
alias Runic.Workflow

map = Runic.map(fn x -> x end, name: :identity)
reduce = Runic.reduce([], fn x, acc -> [x | acc] end, name: :collect, map: :identity)
base = Workflow.new() |> Workflow.add(map) |> Workflow.add(reduce, to: :identity)

for n <- [512, 2_048, 8_192] do
  {us, done} =
    :timer.tc(fn ->
      base
      |> Workflow.plan_eagerly(Enum.to_list(1..n))
      |> Workflow.react_until_satisfied()
    end)

  result = Workflow.results(done, [:collect])[:collect]
  true = result == Enum.to_list(n..1//-1)
  IO.puts("n=#{n} result_ok=true elapsed_ms=#{us / 1000}")
end
