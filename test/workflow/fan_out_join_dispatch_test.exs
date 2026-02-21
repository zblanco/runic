defmodule Workflow.FanOutJoinDispatchTest do
  @moduledoc """
  Tests for multi-branch DAG workflows where a shared parent step feeds
  both single-dependency steps and a multi-input Join.

  Topology mirrors a real-world turn processing pipeline:

      input
        └─ agent_resolve
             └─ compose
                  └─ execute_tools ─┬─ retrieve_context ──┐
                                    ├─ fetch_history ──────┤
                                    └──────────────────────┴─ classify (join of 3)
                                                                  └─ generate
                                                                       └─ process (join with execute_tools)

  Regression tests for two fixed bugs:

  1. Worker deadlock on task crash — the :DOWN handler now marks the crashed
     runnable as failed and calls dispatch_runnables to continue the loop.

  2. Failed step breaking Join completion — handle_failed_runnable now calls
     skip_downstream_subgraph to transitively mark all downstream nodes as
     :upstream_failed, so the workflow cleanly reaches fixpoint.
  """
  use ExUnit.Case
  require Runic

  alias Runic.Workflow

  describe "happy path: multi-branch DAG with join" do
    test "react_until_satisfied completes the full pipeline" do
      wrk = build_turn_workflow()
      wrk = Workflow.react_until_satisfied(wrk, %{text: "look around", state: %{hp: 50}})

      process_prods = Workflow.raw_productions(wrk, :process_turn)

      assert length(process_prods) > 0,
             "Expected :process_turn productions but got none. " <>
               "All productions: #{inspect(Workflow.raw_productions(wrk))}"
    end

    test "prepare_for_dispatch/apply_runnable loop completes the full pipeline" do
      wrk =
        build_turn_workflow()
        |> Workflow.plan_eagerly(%{text: "look around", state: %{hp: 50}})

      wrk = run_dispatch_loop(wrk, 0, 50)

      refute Workflow.is_runnable?(wrk),
             "Workflow should not be runnable after completion"

      process_prods = Workflow.raw_productions(wrk, :process_turn)

      assert length(process_prods) > 0,
             "Expected :process_turn productions via dispatch loop but got none. " <>
               "All productions: #{inspect(Workflow.raw_productions(wrk))}"
    end

    test "via Runner: multi-branch DAG with join completes" do
      runner_name = :"test_runner_#{System.unique_integer([:positive])}"
      start_supervised!({Runic.Runner, name: runner_name})

      workflow = build_turn_workflow()
      workflow_id = :"turn_test_#{System.unique_integer([:positive])}"
      test_pid = self()

      {:ok, _pid} =
        Runic.Runner.start_workflow(runner_name, workflow_id, workflow,
          on_complete: fn wf_id, wf ->
            send(test_pid, {:workflow_complete, wf_id, wf})
          end
        )

      :ok = Runic.Runner.run(runner_name, workflow_id, %{text: "look", state: %{hp: 50}})

      assert_receive {:workflow_complete, ^workflow_id, completed_wf}, 5_000

      process_prods = Workflow.raw_productions(completed_wf, :process_turn)

      assert length(process_prods) > 0,
             "Expected :process_turn productions from Runner but got none. " <>
               "All productions: #{inspect(Workflow.raw_productions(completed_wf))}"
    end
  end

  describe "Bug 1: Worker deadlock on task process crash" do
    @tag :task_crash
    test "Worker calls on_complete when a dispatched task's process crashes" do
      runner_name = :"test_runner_crash_#{System.unique_integer([:positive])}"
      start_supervised!({Runic.Runner, name: runner_name})

      workflow = build_turn_workflow_with_crashing_step()
      workflow_id = :"turn_crash_#{System.unique_integer([:positive])}"
      test_pid = self()

      {:ok, worker_pid} =
        Runic.Runner.start_workflow(runner_name, workflow_id, workflow,
          on_complete: fn wf_id, wf ->
            send(test_pid, {:workflow_complete, wf_id, wf})
          end
        )

      :ok = Runic.Runner.run(runner_name, workflow_id, %{text: "look", state: %{hp: 50}})

      # The Worker should not get stuck. It should mark the crashed step as
      # failed, call dispatch_runnables to continue with other steps, and
      # eventually call on_complete.
      receive do
        {:workflow_complete, ^workflow_id, _wf} ->
          :ok
      after
        3_000 ->
          if Process.alive?(worker_pid) do
            state = :sys.get_state(worker_pid)

            flunk(
              "Worker is stuck (deadlocked). " <>
                "Status: #{state.status}, " <>
                "active_tasks: #{map_size(state.active_tasks)}, " <>
                "is_runnable?: #{Workflow.is_runnable?(state.workflow)}\n\n" <>
                "The :DOWN handler in Worker does not call dispatch_runnables " <>
                "after removing the crashed task. The stale :runnable edge " <>
                "keeps is_runnable? true, preventing transition to idle."
            )
          else
            flunk("Worker process died unexpectedly")
          end
      end
    end
  end

  describe "failed step skips downstream subgraph" do
    @tag :failing_step
    test "failed step cleanly skips Join and all downstream nodes" do
      wrk =
        build_turn_workflow_with_failing_step()
        |> Workflow.plan_eagerly(%{text: "look", state: %{hp: 50}})

      wrk = run_dispatch_loop(wrk, 0, 50)

      # The workflow cleanly reaches fixpoint — no stuck runnables
      refute Workflow.is_runnable?(wrk)

      # No terminal productions since a dependency failed
      process_prods = Workflow.raw_productions(wrk, :process_turn)
      assert process_prods == []

      # Steps that don't depend on the failed step still completed
      all_prods = Workflow.raw_productions(wrk)
      assert Enum.any?(all_prods, &is_list/1), "fetch_history should still produce results"
    end

    test "failed step via Runner calls on_complete without hanging" do
      runner_name = :"test_runner_fail_#{System.unique_integer([:positive])}"
      start_supervised!({Runic.Runner, name: runner_name})

      workflow = build_turn_workflow_with_failing_step()
      workflow_id = :"turn_fail_#{System.unique_integer([:positive])}"
      test_pid = self()

      {:ok, _pid} =
        Runic.Runner.start_workflow(runner_name, workflow_id, workflow,
          on_complete: fn wf_id, wf ->
            send(test_pid, {:workflow_complete, wf_id, wf})
          end
        )

      :ok = Runic.Runner.run(runner_name, workflow_id, %{text: "look", state: %{hp: 50}})

      assert_receive {:workflow_complete, ^workflow_id, completed_wf}, 5_000

      refute Workflow.is_runnable?(completed_wf)
      assert Workflow.raw_productions(completed_wf, :process_turn) == []
    end
  end

  # ---- Workflow builders ----

  defp build_turn_workflow do
    build_workflow_with_steps(
      retrieve_context: fn _executed ->
        %{location: "town_square", npcs: ["guard"]}
      end,
      fetch_history: fn executed ->
        [%{role: :user, content: "Player: #{executed.raw_text}"}]
      end
    )
  end

  defp build_turn_workflow_with_failing_step do
    build_workflow_with_steps(
      retrieve_context: fn _executed ->
        raise KeyError, key: :companions, term: %{flags: %{}}
      end,
      fetch_history: fn executed ->
        [%{role: :user, content: "Player: #{executed.raw_text}"}]
      end
    )
  end

  defp build_turn_workflow_with_crashing_step do
    build_workflow_with_steps(
      retrieve_context: fn _executed ->
        Process.exit(self(), :kill)
      end,
      fetch_history: fn executed ->
        [%{role: :user, content: "Player: #{executed.raw_text}"}]
      end
    )
  end

  defp build_workflow_with_steps(step_fns) do
    agent_resolve =
      Runic.step(
        fn input ->
          %{tool_calls: [%{tool: "look", args: %{}}], raw_text: input.text, state: input.state}
        end,
        name: :agent_resolve
      )

    compose =
      Runic.step(
        fn resolved ->
          %{inner_workflow: :composed, raw_text: resolved.raw_text, state: resolved.state}
        end,
        name: :compose_workflow
      )

    execute_tools =
      Runic.step(
        fn composed ->
          %{
            tool_results: [%{tool: "look", result: %{message: "You see a room."}}],
            state: composed.state,
            raw_text: composed.raw_text
          }
        end,
        name: :execute_tools
      )

    retrieve_context =
      Runic.step(step_fns[:retrieve_context], name: :retrieve_context)

    fetch_history =
      Runic.step(step_fns[:fetch_history], name: :fetch_history)

    classify =
      Runic.step(
        fn executed, context, history ->
          %{
            tier: :standard,
            tool_results: executed.tool_results,
            state: executed.state,
            primary_action: :look,
            context: context,
            history: history
          }
        end,
        name: :classify_narration
      )

    generate =
      Runic.step(
        fn _narr_ctx ->
          {"You see a bustling town square.", false}
        end,
        name: :generate_narrative
      )

    process =
      Runic.step(
        fn {narrative, streamed}, executed ->
          %{
            narrative: narrative,
            narration_streamed: streamed,
            result: %{success: true},
            updated_state: executed.state
          }
        end,
        name: :process_turn
      )

    Workflow.new(name: :turn)
    |> Workflow.add(agent_resolve)
    |> Workflow.add(compose, to: :agent_resolve)
    |> Workflow.add(execute_tools, to: :compose_workflow)
    |> Workflow.add(retrieve_context, to: :execute_tools)
    |> Workflow.add(fetch_history, to: :execute_tools)
    |> Workflow.add(classify, to: [:execute_tools, :retrieve_context, :fetch_history])
    |> Workflow.add(generate, to: :classify_narration)
    |> Workflow.add(process, to: [:generate_narrative, :execute_tools])
  end

  # ---- Dispatch loop helpers ----

  defp run_dispatch_loop(wrk, iteration, max) when iteration >= max do
    raise "Dispatch loop exceeded #{max} iterations without completing. " <>
            "Runnable?: #{Workflow.is_runnable?(wrk)}, " <>
            "Productions: #{inspect(Workflow.raw_productions(wrk))}"
  end

  defp run_dispatch_loop(wrk, iteration, max) do
    {wrk, runnables} = Workflow.prepare_for_dispatch(wrk)

    if Enum.empty?(runnables) do
      wrk
    else
      wrk =
        Enum.reduce(runnables, wrk, fn runnable, acc ->
          executed = Runic.Workflow.Invokable.execute(runnable.node, runnable)
          Workflow.apply_runnable(acc, executed)
        end)

      run_dispatch_loop(wrk, iteration + 1, max)
    end
  end
end
