defmodule Runic.Workflow.ConditionRef do
  @moduledoc """
  A lightweight compile-time placeholder for referencing named conditions in rule `where` clauses.

  `ConditionRef` is not a graph vertex — it exists only during macro expansion to represent
  `condition(:name)` inside a `where` clause before the condition is resolved at connect-time.

  At connect-time (when a rule with condition refs is added to a workflow via `Component.connect/3`),
  each ref is resolved to an existing named condition component in the workflow.
  """

  @type t :: %__MODULE__{
          name: atom()
        }

  defstruct [:name]
end
