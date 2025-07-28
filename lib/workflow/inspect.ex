# defimpl Inspect, for: Runic.Workflow.Step do
#   import Inspect.Algebra

#   def inspect(step, _opts) do
#     source =
#       step.source
#       |> Macro.to_string()
#       |> String.replace_trailing(")", ", hash: #{step.hash})")

#     concat([
#       source
#     ])
#   end
# end

defimpl Inspect, for: Runic.Workflow.ComponentAdded do
  import Inspect.Algebra

  def inspect(event, _opts) do
    concat([
      "%Runic.Workflow.ComponentAdded{",
      "source: ",
      Macro.to_string(event.source),
      ", to: ",
      Macro.to_string(event.to),
      "}"
    ])
  end
end

# defimpl Inspect, for: Runic.Workflow.Map do
#   import Inspect.Algebra

#   def inspect(map, _opts) do
#     source =
#       map.source
#       |> Macro.to_string()
#       |> String.replace_trailing(")", ", hash: #{map.hash})")

#     concat([
#       source
#     ])
#   end
# end

defimpl Inspect, for: Runic.Workflow.Reduce do
  import Inspect.Algebra

  def inspect(reduce, _opts) do
    source =
      reduce.source
      |> Macro.to_string()
      |> String.replace_trailing(")", ", hash: #{reduce.hash})")

    concat([
      source
    ])
  end
end
