defmodule ParallelWorkflowTest do
  @moduledoc """
  Tests for parallel workflow execution scenarios.

  These tests simulate the parallel WorkflowRunner pattern where:
  1. Multiple tasks are spawned for independent runnables
  2. Task results (workflows) are merged back into the main workflow
  3. The workflow is re-planned to find new runnables

  This tests the FanIn/Reduce behavior in parallel execution to catch
  infinite loop bugs where the FanIn never becomes "ready".
  """
  use ExUnit.Case
  require Runic

  alias Runic.Workflow

  describe "parallel FanIn/Reduce execution" do
    @tag timeout: 10_000
    test "FanIn completes with parallel step execution (simulated WorkflowRunner)" do
      # Workflow structure:
      # source (produces [1,2,3,4]) -> FanOut -> per_item_step -> FanIn/Reduce (sum)

      wrk =
        Runic.workflow(
          name: "parallel reduce test",
          steps: [
            {Runic.step(fn _input -> [1, 2, 3, 4] end, name: :source),
             [
               {Runic.map(fn num -> num * 2 end, name: :double_map),
                [
                  Runic.reduce(0, fn num, acc -> num + acc end, name: :sum_reduce, map: :double_map)
                ]}
             ]}
          ]
        )

      # Simulate parallel execution
      result = run_workflow_parallel(wrk, :start, max_iterations: 50)

      assert {:ok, final_wrk} = result
      refute Workflow.is_runnable?(final_wrk)

      productions = Workflow.raw_productions(final_wrk)
      # Sum of [2, 4, 6, 8] = 20
      assert 20 in productions
    end

    @tag timeout: 10_000
    test "FanIn + Join completes with parallel execution" do
      # Workflow structure similar to gatsby-workflow:
      # source -> step_a (produces string)
      # source -> FanOut -> per_item_step -> FanIn/Reduce
      # Both step_a and FanIn feed into a Join -> final_step

      chunk_step = Runic.step(fn input -> String.split(input, ",") end, name: :chunk)
      analysis_step = Runic.step(fn input -> "analyzed: #{input}" end, name: :overall_analysis)
      per_item_step = Runic.step(fn item -> "processed: #{item}" end, name: :per_item)

      combine_reduce =
        Runic.reduce("", fn item, acc -> acc <> item <> ";" end,
          name: :combined_items,
          map: :items_map
        )

      final_step =
        Runic.step(fn [overall, combined] -> "#{overall} | #{combined}" end, name: :final_report)

      wrk =
        Runic.workflow(name: "parallel join test")
        |> Workflow.add(Runic.step(fn input -> input end, name: :valid_inputs))
        |> Workflow.add(chunk_step, to: :valid_inputs)
        |> Workflow.add(analysis_step, to: :valid_inputs)
        |> Workflow.add(Runic.map(fn item -> item end, name: :items_map), to: :chunk)
        |> Workflow.add(per_item_step, to: {:items_map, :fan_out})
        |> Workflow.add(combine_reduce, to: :per_item)
        |> Workflow.add(final_step, to: [:overall_analysis, :combined_items])

      result = run_workflow_parallel(wrk, "a,b,c,d", max_iterations: 100)

      assert {:ok, final_wrk} = result
      refute Workflow.is_runnable?(final_wrk)

      productions = Workflow.raw_productions(final_wrk)
      # Should have the final combined report
      assert Enum.any?(productions, fn p -> is_binary(p) and String.contains?(p, "|") end)
    end

    @tag timeout: 10_000
    test "FanIn tracks mapped data correctly across workflow merges" do
      wrk =
        Runic.workflow(
          name: "merge tracking test",
          steps: [
            {Runic.step(fn _input -> [1, 2, 3] end, name: :source),
             [
               {Runic.map(fn num -> num + 10 end, name: :add_ten_map),
                [
                  Runic.reduce([], fn num, acc -> [num | acc] end,
                    name: :collect_reduce,
                    map: :add_ten_map
                  )
                ]}
             ]}
          ]
        )

      result = run_workflow_parallel(wrk, :go, max_iterations: 50)

      assert {:ok, final_wrk} = result
      refute Workflow.is_runnable?(final_wrk)

      productions = Workflow.raw_productions(final_wrk)
      # Should have collected [11, 12, 13] in some order
      # Find the list that contains the mapped values (11, 12, 13), not the source list [1, 2, 3]
      collected = Enum.find(productions, fn
        list when is_list(list) -> Enum.any?(list, &(&1 in [11, 12, 13]))
        _ -> false
      end)
      assert collected != nil, "Expected to find a list with values 11, 12, or 13 in productions: #{inspect(productions)}"
      assert Enum.sort(collected) == [11, 12, 13]
    end

    @tag timeout: 10_000
    test "parallel execution does not cause infinite loops with simple map-reduce" do
      wrk =
        Runic.workflow(
          name: "no infinite loop test",
          steps: [
            {Runic.step(fn _input -> Enum.to_list(1..5) end, name: :generate),
             [
               {Runic.map(fn n -> n * n end, name: :square_map),
                [
                  Runic.reduce(0, fn n, acc -> n + acc end, name: :sum_squares, map: :square_map)
                ]}
             ]}
          ]
        )

      result = run_workflow_parallel(wrk, :start, max_iterations: 100)

      assert {:ok, final_wrk} = result
      refute Workflow.is_runnable?(final_wrk)

      # Sum of squares: 1 + 4 + 9 + 16 + 25 = 55
      assert 55 in Workflow.raw_productions(final_wrk)
    end

    @tag timeout: 10_000
    test "verifies mapped tracking data is preserved during merge" do
      # This test specifically checks that workflow.mapped is correctly merged
      wrk =
        Runic.workflow(
          name: "mapped merge test",
          steps: [
            {Runic.step(fn _input -> [1, 2] end, name: :src),
             [
               {Runic.map(fn n -> n end, name: :identity_map),
                [
                  Runic.reduce(0, fn n, acc -> n + acc end, name: :sum, map: :identity_map)
                ]}
             ]}
          ]
        )

      # Plan to get initial runnables
      wrk = Workflow.plan_eagerly(wrk, :input)

      # Get FanOut step invoked first
      wrk = Workflow.react(wrk)

      # At this point, FanOut should have run and populated mapped tracking
      # Check that mapped contains the expected_key
      assert Map.has_key?(wrk.mapped, :mapped_paths)

      # Now run in parallel simulation
      result = run_workflow_parallel(wrk, nil, max_iterations: 50, already_planned: true)

      assert {:ok, final_wrk} = result
      refute Workflow.is_runnable?(final_wrk)

      assert 3 in Workflow.raw_productions(final_wrk)
    end
  end

  # Helper to simulate parallel workflow execution like WorkflowRunner
  defp run_workflow_parallel(workflow, input, opts \\ []) do
    max_iterations = Keyword.get(opts, :max_iterations, 100)
    already_planned = Keyword.get(opts, :already_planned, false)

    workflow =
      if already_planned do
        workflow
      else
        Workflow.plan_eagerly(workflow, input)
      end

    run_parallel_loop(workflow, 0, max_iterations, MapSet.new())
  end

  defp run_parallel_loop(workflow, iteration, max_iterations, dispatched) do
    if iteration >= max_iterations do
      {:error, :max_iterations_exceeded, workflow, iteration}
    else
      runnables = Workflow.next_runnables(workflow)

      # Filter out already-dispatched runnables (idempotency check)
      # For FanIn, we need to check by source_fact_hash, not individual fact hash
      # Also deduplicate within the same batch (e.g., 3 FanIn runnables with same source)
      {new_runnables, _seen_keys} =
        Enum.reduce(runnables, {[], MapSet.new()}, fn {step, fact}, {acc, seen} ->
          key =
            case step do
              %Runic.Workflow.FanIn{} ->
                source_hash = find_fan_out_source(workflow, fact)
                {step.hash, source_hash || fact.hash}

              _ ->
                {step.hash, fact.hash}
            end

          if MapSet.member?(dispatched, key) or MapSet.member?(seen, key) do
            {acc, seen}
          else
            {[{step, fact} | acc], MapSet.put(seen, key)}
          end
        end)

      new_runnables = Enum.reverse(new_runnables)

      if Enum.empty?(new_runnables) do
        if Workflow.is_runnable?(workflow) do
          # Still runnable but no new runnables - this is the infinite loop case
          {:error, :stuck_runnable, workflow, iteration}
        else
          {:ok, workflow}
        end
      else
        # Track what we're dispatching
        # For FanIn steps, deduplicate by {step_hash, source_batch_hash} 
        # since all facts in a batch should only trigger one FanIn execution
        new_dispatched =
          Enum.reduce(new_runnables, dispatched, fn {step, fact}, acc ->
            key =
              case step do
                %Runic.Workflow.FanIn{} ->
                  # For FanIn, find the source_fact_hash that started this batch
                  source_hash = find_fan_out_source(workflow, fact)
                  {step.hash, source_hash || fact.hash}

                _ ->
                  {step.hash, fact.hash}
              end

            MapSet.put(acc, key)
          end)

        # Simulate parallel execution: spawn tasks for each runnable
        tasks =
          Enum.map(new_runnables, fn {step, fact} ->
            Task.async(fn ->
              Workflow.invoke(workflow, step, fact)
            end)
          end)

        # Collect results and merge
        task_results = Task.await_many(tasks, 5000)

        # Merge all task results back into the main workflow
        merged_workflow =
          Enum.reduce(task_results, workflow, fn task_workflow, acc ->
            Workflow.merge(acc, task_workflow)
          end)

        # Don't call plan_eagerly() here - just use the merged workflow
        # The invokables should have already prepared next runnables
        run_parallel_loop(merged_workflow, iteration + 1, max_iterations, new_dispatched)
      end
    end
  end

  # Find the source_fact hash that triggered the FanOut batch for this fact
  defp find_fan_out_source(workflow, %Workflow.Fact{ancestry: {_producer, parent_hash}}) do
    do_find_fan_out_source(workflow, parent_hash)
  end

  defp find_fan_out_source(_workflow, _fact), do: nil

  defp do_find_fan_out_source(_workflow, nil), do: nil

  defp do_find_fan_out_source(workflow, fact_hash) do
    fact = workflow.graph.vertices[fact_hash]

    case fact do
      %Workflow.Fact{ancestry: {producer_hash, parent_fact_hash}} ->
        producer = workflow.graph.vertices[producer_hash]

        case producer do
          %Runic.Workflow.FanOut{} ->
            # Found FanOut - return the source_fact hash (parent of this fact)
            parent_fact_hash

          _ ->
            do_find_fan_out_source(workflow, parent_fact_hash)
        end

      _ ->
        nil
    end
  end
end
