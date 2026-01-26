defmodule Runic.Workflow.HookRunner do
  @moduledoc """
  Runs hooks during the execute phase without requiring workflow access.

  This module provides a safe, parallel-friendly way to execute hooks.
  Hooks can be either:

  1. **New-style (arity-2)**: `fn event, context -> :ok | {:apply, fn} | {:error, term} end`
     - Executed during the execute phase
     - Can return `:ok` or an `apply_fn` for deferred workflow modifications

  2. **Legacy (arity-3)**: `fn step, workflow, fact -> workflow end`
     - Converted to apply_fn for backward compatibility
     - NOT executed during execute phase (requires workflow)

  ## Return Types

  Hooks can return:
  - `:ok` - Hook completed successfully, no workflow modifications
  - `{:apply, apply_fn}` - Hook completed, apply_fn will be called during apply phase
  - `{:apply, [apply_fn]}` - Multiple apply functions
  - `{:error, reason}` - Hook failed, will cause runnable to fail
  """

  alias Runic.Workflow.{HookEvent, CausalContext}

  @type apply_fn :: (Runic.Workflow.t() -> Runic.Workflow.t())
  @type hook_return :: :ok | {:apply, apply_fn()} | {:apply, [apply_fn()]} | {:error, term()}
  @type new_hook :: (HookEvent.t(), CausalContext.t() -> hook_return())
  @type legacy_hook :: (struct(), Runic.Workflow.t(), Runic.Workflow.Fact.t() ->
                          Runic.Workflow.t())
  @type hook :: new_hook() | legacy_hook()

  @doc """
  Runs before hooks and collects any apply_fns.

  Returns `{:ok, apply_fns}` or `{:error, reason}`.
  """
  @spec run_before(CausalContext.t(), struct(), Runic.Workflow.Fact.t()) ::
          {:ok, [apply_fn()]} | {:error, term()}
  def run_before(%CausalContext{} = ctx, node, input_fact) do
    hooks = CausalContext.before_hooks(ctx)
    event = HookEvent.before(node, input_fact)
    run_hooks(hooks, event, ctx, node, input_fact)
  end

  @doc """
  Runs after hooks with the execution result and collects any apply_fns.

  Returns `{:ok, apply_fns}` or `{:error, reason}`.
  """
  @spec run_after(CausalContext.t(), struct(), Runic.Workflow.Fact.t(), term()) ::
          {:ok, [apply_fn()]} | {:error, term()}
  def run_after(%CausalContext{} = ctx, node, input_fact, result) do
    hooks = CausalContext.after_hooks(ctx)
    event = HookEvent.after_exec(node, input_fact, result)
    run_hooks(hooks, event, ctx, node, input_fact)
  end

  defp run_hooks(hooks, event, ctx, node, input_fact) do
    Enum.reduce_while(hooks, {:ok, []}, fn hook, {:ok, apply_fns} ->
      case run_single_hook(hook, event, ctx, node, input_fact) do
        {:ok, new_apply_fns} ->
          {:cont, {:ok, apply_fns ++ new_apply_fns}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp run_single_hook(hook, event, ctx, _node, _input_fact) when is_function(hook, 2) do
    try do
      case hook.(event, ctx) do
        :ok ->
          {:ok, []}

        {:apply, apply_fn} when is_function(apply_fn, 1) ->
          {:ok, [apply_fn]}

        {:apply, apply_fns} when is_list(apply_fns) ->
          {:ok, apply_fns}

        {:error, reason} ->
          {:error, {:hook_error, reason}}

        other ->
          {:error, {:invalid_hook_return, other}}
      end
    rescue
      e ->
        {:error, {:hook_exception, e, __STACKTRACE__}}
    end
  end

  defp run_single_hook(hook, _event, _ctx, node, input_fact) when is_function(hook, 3) do
    apply_fn = fn workflow ->
      hook.(node, workflow, input_fact)
    end

    {:ok, [apply_fn]}
  end

  defp run_single_hook(_hook, _event, _ctx, _node, _input_fact) do
    {:error, :invalid_hook_arity}
  end
end
