defmodule Runic.Workflow.HookEvent do
  @moduledoc """
  Event struct passed to hooks during execution.

  This provides a uniform interface for hooks across all node types,
  eliminating the need for workflow access during the execute phase.

  ## Fields

  - `:timing` - `:before` or `:after` indicating when the hook is running
  - `:node` - The node struct being executed (Step, Condition, etc.)
  - `:node_hash` - Hash of the node for quick identification
  - `:input_fact` - The input fact triggering this execution
  - `:result` - For after hooks: the result of execution (Fact, boolean, etc.)

  ## Example

      # New-style hook (arity-2, workflow-free)
      fn %HookEvent{timing: :before, node: step}, ctx ->
        Logger.info("Executing step \#{step.name}")
        :ok
      end

      # Hook returning an apply_fn for workflow modifications
      fn %HookEvent{timing: :after, result: fact}, _ctx ->
        {:apply, fn workflow ->
          Workflow.add(workflow, some_step, to: fact)
        end}
      end
  """

  @type timing :: :before | :after

  @type t :: %__MODULE__{
          timing: timing(),
          node: struct(),
          node_hash: integer(),
          input_fact: Runic.Workflow.Fact.t(),
          result: term() | nil
        }

  defstruct [:timing, :node, :node_hash, :input_fact, :result]

  @doc """
  Creates a before-hook event.
  """
  @spec before(struct(), Runic.Workflow.Fact.t()) :: t()
  def before(node, input_fact) do
    %__MODULE__{
      timing: :before,
      node: node,
      node_hash: node.hash,
      input_fact: input_fact,
      result: nil
    }
  end

  @doc """
  Creates an after-hook event with the execution result.
  """
  @spec after_exec(struct(), Runic.Workflow.Fact.t(), term()) :: t()
  def after_exec(node, input_fact, result) do
    %__MODULE__{
      timing: :after,
      node: node,
      node_hash: node.hash,
      input_fact: input_fact,
      result: result
    }
  end
end
