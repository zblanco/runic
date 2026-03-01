defmodule Runic.Runner.Scheduler.ContractTest do
  @moduledoc """
  Conformance test suite for `Runic.Runner.Scheduler` behaviour implementations.

  Verifies that a scheduler correctly implements the dispatch contract:

    * `init/1` returns `{:ok, state}`
    * `plan_dispatch/3` returns well-formed dispatch units
    * All input runnables are accounted for (no dropped runnables)
    * No duplicate runnables across dispatch units
    * No overlapping `node_hashes` between dispatch units
    * Promise `node_hashes` are supersets of their runnable hashes
    * Empty input produces empty output
    * State is properly threaded across calls

  ## Usage

      defmodule MySchedulerTest do
        use Runic.Runner.Scheduler.ContractTest,
          scheduler: MyApp.CustomScheduler,
          opts: [my_option: true]
      end
  """

  defmacro __using__(config) do
    scheduler = Keyword.fetch!(config, :scheduler)
    scheduler_opts = Keyword.get(config, :opts, [])

    quote location: :keep do
      use ExUnit.Case, async: true

      require Runic
      alias Runic.Workflow

      @scheduler unquote(scheduler)
      @scheduler_opts unquote(scheduler_opts)

      # --- Test Fixtures ---

      defp build_linear_chain do
        step_a = Runic.step(fn x -> x + 1 end, name: :ct_chain_a)
        step_b = Runic.step(fn x -> x * 2 end, name: :ct_chain_b)
        step_c = Runic.step(fn x -> x - 1 end, name: :ct_chain_c)
        workflow = Runic.workflow(steps: [{step_a, [{step_b, [step_c]}]}])
        workflow = Workflow.plan_eagerly(workflow, 1)
        Workflow.prepare_for_dispatch(workflow)
      end

      defp build_parallel_steps do
        step_a = Runic.step(fn x -> x + 1 end, name: :ct_par_a)
        step_b = Runic.step(fn x -> x * 2 end, name: :ct_par_b)
        workflow = Runic.workflow(steps: [step_a, step_b])
        workflow = Workflow.plan_eagerly(workflow, 1)
        Workflow.prepare_for_dispatch(workflow)
      end

      defp build_fan_out do
        step_a = Runic.step(fn x -> x + 1 end, name: :ct_fan_a)
        step_b = Runic.step(fn x -> x * 2 end, name: :ct_fan_b)
        step_c = Runic.step(fn x -> x * 3 end, name: :ct_fan_c)
        workflow = Runic.workflow(steps: [{step_a, [step_b, step_c]}])
        workflow = Workflow.plan_eagerly(workflow, 1)
        Workflow.prepare_for_dispatch(workflow)
      end

      defp build_single_step do
        step = Runic.step(fn x -> x + 1 end, name: :ct_single)
        workflow = Runic.workflow(steps: [step])
        workflow = Workflow.plan_eagerly(workflow, 1)
        Workflow.prepare_for_dispatch(workflow)
      end

      defp extract_runnable_ids(units) do
        Enum.flat_map(units, fn
          {:runnable, r} -> [r.id]
          {:promise, p} -> Enum.map(p.runnables, & &1.id)
        end)
      end

      defp extract_covered_hashes(units) do
        Enum.flat_map(units, fn
          {:runnable, r} -> [r.node.hash]
          {:promise, p} -> MapSet.to_list(p.node_hashes)
        end)
      end

      defp assert_valid_dispatch_units(units) do
        for unit <- units do
          assert match?({:runnable, %Runic.Workflow.Runnable{}}, unit) or
                   match?({:promise, %Runic.Runner.Promise{}}, unit),
                 "Expected {:runnable, %Runnable{}} or {:promise, %Promise{}}, got: #{inspect(unit)}"
        end
      end

      # --- Contract: Initialization ---

      describe "#{inspect(@scheduler)} contract: initialization" do
        test "init/1 returns {:ok, state}" do
          assert {:ok, _state} = @scheduler.init(@scheduler_opts)
        end
      end

      # --- Contract: Empty Input ---

      describe "#{inspect(@scheduler)} contract: empty input" do
        test "plan_dispatch with empty runnables returns empty units" do
          {:ok, state} = @scheduler.init(@scheduler_opts)
          {workflow, _runnables} = build_linear_chain()

          {units, _new_state} = @scheduler.plan_dispatch(workflow, [], state)
          assert units == []
        end
      end

      # --- Contract: Well-Formed Output ---

      describe "#{inspect(@scheduler)} contract: well-formed output" do
        test "all dispatch units are valid with parallel input" do
          {:ok, state} = @scheduler.init(@scheduler_opts)
          {workflow, runnables} = build_parallel_steps()

          {units, _new_state} = @scheduler.plan_dispatch(workflow, runnables, state)
          assert_valid_dispatch_units(units)
        end

        test "all dispatch units are valid with single runnable input" do
          {:ok, state} = @scheduler.init(@scheduler_opts)
          {workflow, runnables} = build_single_step()

          {units, _new_state} = @scheduler.plan_dispatch(workflow, runnables, state)
          refute Enum.empty?(units)
          assert_valid_dispatch_units(units)
        end

        test "all dispatch units are valid with fan-out input" do
          {:ok, state} = @scheduler.init(@scheduler_opts)
          {workflow, runnables} = build_fan_out()

          {units, _new_state} = @scheduler.plan_dispatch(workflow, runnables, state)
          assert_valid_dispatch_units(units)
        end

        test "all dispatch units are valid with linear chain input" do
          {:ok, state} = @scheduler.init(@scheduler_opts)
          {workflow, runnables} = build_linear_chain()

          {units, _new_state} = @scheduler.plan_dispatch(workflow, runnables, state)
          refute Enum.empty?(units)
          assert_valid_dispatch_units(units)
        end
      end

      # --- Contract: Runnable Accounting ---

      describe "#{inspect(@scheduler)} contract: runnable accounting" do
        test "every input runnable appears in output dispatch units" do
          {:ok, state} = @scheduler.init(@scheduler_opts)
          {workflow, runnables} = build_parallel_steps()

          {units, _new_state} = @scheduler.plan_dispatch(workflow, runnables, state)

          output_ids = MapSet.new(extract_runnable_ids(units))
          input_ids = MapSet.new(runnables, & &1.id)

          assert MapSet.subset?(input_ids, output_ids),
                 "Input runnables missing from output.\n" <>
                   "  Missing: #{inspect(MapSet.difference(input_ids, output_ids))}"
        end

        test "no runnable appears in more than one dispatch unit" do
          {:ok, state} = @scheduler.init(@scheduler_opts)
          {workflow, runnables} = build_parallel_steps()

          {units, _new_state} = @scheduler.plan_dispatch(workflow, runnables, state)

          all_ids = extract_runnable_ids(units)

          assert length(all_ids) == length(Enum.uniq(all_ids)),
                 "Duplicate runnable IDs in dispatch units: #{inspect(all_ids -- Enum.uniq(all_ids))}"
        end

        test "dispatch units only reference input runnables" do
          {:ok, state} = @scheduler.init(@scheduler_opts)
          {workflow, runnables} = build_parallel_steps()

          {units, _new_state} = @scheduler.plan_dispatch(workflow, runnables, state)

          output_ids = MapSet.new(extract_runnable_ids(units))
          input_ids = MapSet.new(runnables, & &1.id)

          assert MapSet.subset?(output_ids, input_ids),
                 "Scheduler introduced runnables not in input: #{inspect(MapSet.difference(output_ids, input_ids))}"
        end

        test "single runnable is accounted for" do
          {:ok, state} = @scheduler.init(@scheduler_opts)
          {workflow, runnables} = build_single_step()

          {units, _new_state} = @scheduler.plan_dispatch(workflow, runnables, state)

          output_ids = MapSet.new(extract_runnable_ids(units))
          input_ids = MapSet.new(runnables, & &1.id)
          assert MapSet.equal?(input_ids, output_ids)
        end
      end

      # --- Contract: Hash Isolation ---

      describe "#{inspect(@scheduler)} contract: hash isolation" do
        test "no overlapping node_hashes between dispatch units" do
          {:ok, state} = @scheduler.init(@scheduler_opts)
          {workflow, runnables} = build_parallel_steps()

          {units, _new_state} = @scheduler.plan_dispatch(workflow, runnables, state)

          all_hashes = extract_covered_hashes(units)

          assert length(all_hashes) == length(Enum.uniq(all_hashes)),
                 "Overlapping node hashes between dispatch units: #{inspect(all_hashes -- Enum.uniq(all_hashes))}"
        end

        test "promise node_hashes are non-empty" do
          {:ok, state} = @scheduler.init(@scheduler_opts)
          {workflow, runnables} = build_linear_chain()

          {units, _new_state} = @scheduler.plan_dispatch(workflow, runnables, state)

          for {:promise, promise} <- units do
            assert MapSet.size(promise.node_hashes) > 0,
                   "Promise #{inspect(promise.id)} has empty node_hashes"
          end
        end

        test "promise runnables hashes are subset of promise node_hashes" do
          {:ok, state} = @scheduler.init(@scheduler_opts)
          {workflow, runnables} = build_linear_chain()

          {units, _new_state} = @scheduler.plan_dispatch(workflow, runnables, state)

          for {:promise, promise} <- units do
            for r <- promise.runnables do
              assert MapSet.member?(promise.node_hashes, r.node.hash),
                     "Promise runnable hash #{inspect(r.node.hash)} not in node_hashes"
            end
          end
        end
      end

      # --- Contract: State Threading ---

      describe "#{inspect(@scheduler)} contract: state threading" do
        test "state is properly threaded across multiple plan_dispatch calls" do
          {:ok, state} = @scheduler.init(@scheduler_opts)
          {workflow, runnables} = build_parallel_steps()

          {_units1, state} = @scheduler.plan_dispatch(workflow, runnables, state)
          {units2, _state} = @scheduler.plan_dispatch(workflow, runnables, state)

          assert_valid_dispatch_units(units2)
        end

        test "repeated calls with same input produce consistent results" do
          {:ok, state} = @scheduler.init(@scheduler_opts)
          {workflow, runnables} = build_parallel_steps()

          {units1, state1} = @scheduler.plan_dispatch(workflow, runnables, state)
          {units2, _state2} = @scheduler.plan_dispatch(workflow, runnables, state)

          ids1 = extract_runnable_ids(units1) |> Enum.sort()
          ids2 = extract_runnable_ids(units2) |> Enum.sort()
          assert ids1 == ids2
        end
      end

      # --- Contract: on_complete (if implemented) ---

      describe "#{inspect(@scheduler)} contract: on_complete" do
        test "on_complete/3 returns state when implemented" do
          if function_exported?(@scheduler, :on_complete, 3) do
            {:ok, state} = @scheduler.init(@scheduler_opts)
            {workflow, runnables} = build_parallel_steps()
            {units, state} = @scheduler.plan_dispatch(workflow, runnables, state)

            for unit <- units do
              result = @scheduler.on_complete(unit, 100, state)
              assert result != nil, "on_complete/3 returned nil"
            end
          end
        end
      end
    end
  end
end
