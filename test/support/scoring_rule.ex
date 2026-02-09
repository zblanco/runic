defmodule Runic.Test.ScoringRule do
  @moduledoc false
  defstruct [:name, :threshold, :score, :comparator]

  def new(opts \\ []) do
    %__MODULE__{
      name: Keyword.get(opts, :name, :scoring_rule),
      threshold: Keyword.get(opts, :threshold, 0),
      score: Keyword.get(opts, :score, 1),
      comparator: Keyword.get(opts, :comparator, :gt)
    }
  end
end

defimpl Runic.Transmutable, for: Runic.Test.ScoringRule do
  alias Runic.Test.ScoringRule

  def transmute(scoring_rule), do: to_workflow(scoring_rule)

  def to_workflow(%ScoringRule{} = scoring_rule) do
    component = to_component(scoring_rule)
    Runic.Transmutable.to_workflow(component)
  end

  def to_component(%ScoringRule{} = scoring_rule) do
    comparator = scoring_rule.comparator
    threshold = scoring_rule.threshold
    score = scoring_rule.score

    work =
      case comparator do
        :gt -> fn x when is_number(x) -> if x > threshold, do: score, else: 0 end
        :lt -> fn x when is_number(x) -> if x < threshold, do: score, else: 0 end
        :gte -> fn x when is_number(x) -> if x >= threshold, do: score, else: 0 end
        :lte -> fn x when is_number(x) -> if x <= threshold, do: score, else: 0 end
        :eq -> fn x -> if x == threshold, do: score, else: 0 end
      end

    Runic.Workflow.Step.new(work: work, name: scoring_rule.name)
  end
end
