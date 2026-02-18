defmodule Runic.Workflow.PolicyDriver do
  @moduledoc """
  Executes a `%Runnable{}` according to a `%SchedulerPolicy{}`, handling retries,
  timeouts, backoff, fallbacks, and failure modes.

  The PolicyDriver is the bridge between the scheduler's declared execution policy
  and the actual invocation of a runnable's work function. It wraps `Invokable.execute/2`
  with policy-driven retry loops, timeout enforcement, and fallback resolution.

  ## Event Emission

  When `emit_events: true` is passed in options, `execute/3` returns
  `{%Runnable{}, [event]}` instead of just `%Runnable{}`. Events are:

    * `%RunnableDispatched{}` — emitted at each execution attempt
    * `%RunnableCompleted{}` — emitted on successful completion
    * `%RunnableFailed{}` — emitted on permanent failure (retries exhausted)
  """

  alias Runic.Workflow
  alias Runic.Workflow.{Runnable, Invokable, Fact, SchedulerPolicy}
  alias Runic.Workflow.{RunnableDispatched, RunnableCompleted, RunnableFailed}

  import Bitwise

  @doc """
  Execute a runnable according to the given scheduler policy.
  """
  @spec execute(Runnable.t(), SchedulerPolicy.t()) :: Runnable.t()
  def execute(%Runnable{} = runnable, %SchedulerPolicy{} = policy) do
    do_execute(runnable, policy, 0, [])
  end

  @doc """
  Execute a runnable according to the given scheduler policy with options.

  ## Options

    * `:deadline_at` - monotonic time deadline (used by Phase 3, plumbed now)
    * `:emit_events` - when `true`, returns `{%Runnable{}, [event]}` instead of `%Runnable{}`
  """
  @spec execute(Runnable.t(), SchedulerPolicy.t(), keyword()) ::
          Runnable.t() | {Runnable.t(), list()}
  def execute(%Runnable{} = runnable, %SchedulerPolicy{} = policy, opts) when is_list(opts) do
    if Keyword.get(opts, :emit_events, false) do
      {result, events} = do_execute_with_events(runnable, policy, 0, opts)
      {result, Enum.reverse(events)}
    else
      do_execute(runnable, policy, 0, opts)
    end
  end

  # ---------------------------------------------------------------------------
  # Non-event execution (original Phase 1 path)
  # ---------------------------------------------------------------------------

  defp do_execute(%Runnable{} = runnable, %SchedulerPolicy{} = policy, attempt, opts) do
    case check_deadline(opts) do
      :ok ->
        result = execute_with_timeout(runnable, policy, opts)

        case result.status do
          :completed ->
            result

          :skipped ->
            result

          :failed ->
            if attempt < policy.max_retries do
              delay = compute_delay(policy, attempt)
              if delay > 0, do: Process.sleep(delay)
              reset = reset_for_retry(runnable)
              do_execute(reset, policy, attempt + 1, opts)
            else
              case policy.fallback do
                nil ->
                  case policy.on_failure do
                    :skip -> skip_runnable(result)
                    :halt -> result
                  end

                fallback when is_function(fallback) ->
                  handle_fallback(result, result.error, policy)
              end
            end
        end

      {:deadline_exceeded, remaining_ms} ->
        Runnable.fail(runnable, {:deadline_exceeded, remaining_ms})
    end
  end

  # ---------------------------------------------------------------------------
  # Event-emitting execution
  # ---------------------------------------------------------------------------

  defp do_execute_with_events(%Runnable{} = runnable, %SchedulerPolicy{} = policy, attempt, opts) do
    case check_deadline(opts) do
      :ok ->
        dispatched_event = build_dispatched_event(runnable, policy, attempt)
        start_time = System.monotonic_time(:millisecond)

        result = execute_with_timeout(runnable, policy, opts)

        case result.status do
          :completed ->
            duration = System.monotonic_time(:millisecond) - start_time
            completed_event = build_completed_event(result, attempt, duration)
            {result, [completed_event, dispatched_event]}

          :skipped ->
            {result, [dispatched_event]}

          :failed ->
            if attempt < policy.max_retries do
              delay = compute_delay(policy, attempt)
              if delay > 0, do: Process.sleep(delay)
              reset = reset_for_retry(runnable)
              {final, rest_events} = do_execute_with_events(reset, policy, attempt + 1, opts)
              {final, rest_events ++ [dispatched_event]}
            else
              case policy.fallback do
                nil ->
                  failure_action =
                    case policy.on_failure do
                      :skip -> :skip
                      :halt -> :halt
                    end

                  failed_event = build_failed_event(result, attempt + 1, failure_action)

                  final =
                    case policy.on_failure do
                      :skip -> skip_runnable(result)
                      :halt -> result
                    end

                  {final, [failed_event, dispatched_event]}

                fallback when is_function(fallback) ->
                  fallback_result = handle_fallback(result, result.error, policy)

                  case fallback_result.status do
                    :completed ->
                      duration = System.monotonic_time(:millisecond) - start_time
                      completed_event = build_completed_event(fallback_result, attempt, duration)
                      {fallback_result, [completed_event, dispatched_event]}

                    :failed ->
                      failed_event = build_failed_event(fallback_result, attempt + 1, :halt)
                      {fallback_result, [failed_event, dispatched_event]}
                  end
              end
            end
        end

      {:deadline_exceeded, remaining_ms} ->
        failed = Runnable.fail(runnable, {:deadline_exceeded, remaining_ms})
        failed_event = build_failed_event(failed, attempt, :halt)
        {failed, [failed_event]}
    end
  end

  # ---------------------------------------------------------------------------
  # Event builders
  # ---------------------------------------------------------------------------

  defp build_dispatched_event(%Runnable{} = runnable, %SchedulerPolicy{} = policy, attempt) do
    %RunnableDispatched{
      runnable_id: runnable.id,
      node_name: runnable.node.name,
      node_hash: runnable.node.hash,
      input_fact: runnable.input_fact,
      dispatched_at: System.monotonic_time(:millisecond),
      policy: strip_non_serializable(policy),
      attempt: attempt
    }
  end

  defp build_completed_event(%Runnable{} = runnable, attempt, duration_ms) do
    %RunnableCompleted{
      runnable_id: runnable.id,
      node_hash: runnable.node.hash,
      result_fact: runnable.result,
      completed_at: System.monotonic_time(:millisecond),
      attempt: attempt,
      duration_ms: duration_ms
    }
  end

  defp build_failed_event(%Runnable{} = runnable, attempts, failure_action) do
    %RunnableFailed{
      runnable_id: runnable.id,
      node_hash: runnable.node.hash,
      error: runnable.error,
      failed_at: System.monotonic_time(:millisecond),
      attempts: attempts,
      failure_action: failure_action
    }
  end

  defp strip_non_serializable(%SchedulerPolicy{} = policy) do
    %{policy | fallback: nil, idempotency_key: nil}
  end

  # ---------------------------------------------------------------------------
  # Deadline checking
  # ---------------------------------------------------------------------------

  defp check_deadline(opts) do
    case Keyword.get(opts, :deadline_at) do
      nil ->
        :ok

      deadline_at ->
        remaining = deadline_at - System.monotonic_time(:millisecond)

        if remaining > 0 do
          :ok
        else
          {:deadline_exceeded, remaining}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Timeout, backoff, retry helpers (shared)
  # ---------------------------------------------------------------------------

  defp execute_with_timeout(%Runnable{} = runnable, %SchedulerPolicy{} = policy, opts) do
    timeout_ms = effective_timeout(policy, opts)

    case timeout_ms do
      :infinity ->
        Invokable.execute(runnable.node, runnable)

      ms ->
        task = Task.async(fn -> Invokable.execute(runnable.node, runnable) end)

        case Task.yield(task, ms) do
          {:ok, result} ->
            result

          nil ->
            Task.shutdown(task, :brutal_kill)
            Runnable.fail(runnable, {:timeout, ms})
        end
    end
  end

  defp effective_timeout(%SchedulerPolicy{timeout_ms: :infinity}, opts) do
    case Keyword.get(opts, :deadline_at) do
      nil -> :infinity
      deadline_at -> max(deadline_at - System.monotonic_time(:millisecond), 0)
    end
  end

  defp effective_timeout(%SchedulerPolicy{timeout_ms: timeout_ms}, opts) do
    case Keyword.get(opts, :deadline_at) do
      nil -> timeout_ms
      deadline_at -> min(timeout_ms, max(deadline_at - System.monotonic_time(:millisecond), 0))
    end
  end

  defp compute_delay(%SchedulerPolicy{backoff: :none}, _attempt), do: 0

  defp compute_delay(
         %SchedulerPolicy{backoff: :linear, base_delay_ms: base, max_delay_ms: max},
         attempt
       ) do
    min(base * (attempt + 1), max)
  end

  defp compute_delay(
         %SchedulerPolicy{backoff: :exponential, base_delay_ms: base, max_delay_ms: max},
         attempt
       ) do
    min(base * bsl(1, attempt), max)
  end

  defp compute_delay(
         %SchedulerPolicy{backoff: :jitter, base_delay_ms: base, max_delay_ms: max},
         attempt
       ) do
    raw = base * bsl(1, attempt)
    min(:rand.uniform(max(raw, 1)), max)
  end

  defp reset_for_retry(%Runnable{} = runnable) do
    %{runnable | status: :pending, result: nil, error: nil, apply_fn: nil}
  end

  defp handle_fallback(%Runnable{} = runnable, error, %SchedulerPolicy{fallback: fallback}) do
    case fallback.(runnable, error) do
      %Runnable{} = modified ->
        no_retry_policy = %SchedulerPolicy{max_retries: 0, fallback: nil}
        execute(modified, no_retry_policy)

      {:retry_with, %{} = overrides} ->
        merged_meta = Map.merge(runnable.context.meta_context, overrides)
        updated_context = %{runnable.context | meta_context: merged_meta}
        updated_runnable = reset_for_retry(%{runnable | context: updated_context})
        no_retry_policy = %SchedulerPolicy{max_retries: 0, fallback: nil}
        execute(updated_runnable, no_retry_policy)

      {:value, term} ->
        result_fact =
          Fact.new(value: term, ancestry: {runnable.node.hash, runnable.input_fact.hash})

        apply_fn = fn workflow ->
          workflow
          |> Workflow.log_fact(result_fact)
          |> Workflow.draw_connection(runnable.node, result_fact, :produced,
            weight: (runnable.context.ancestry_depth || 0) + 1
          )
          |> Workflow.mark_runnable_as_ran(runnable.node, runnable.input_fact)
          |> Workflow.prepare_next_runnables(runnable.node, result_fact)
        end

        Runnable.complete(runnable, result_fact, apply_fn)

      other ->
        Runnable.fail(runnable, {:invalid_fallback_return, other})
    end
  end

  defp skip_runnable(%Runnable{} = runnable) do
    apply_fn = fn workflow ->
      Workflow.mark_runnable_as_ran(workflow, runnable.node, runnable.input_fact)
    end

    Runnable.skip(runnable, apply_fn)
  end
end
