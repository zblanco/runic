defmodule Runic.Runner.Scheduler.AdaptiveTest do
  use ExUnit.Case, async: true

  require Runic

  alias Runic.Workflow
  alias Runic.Runner.Scheduler.Adaptive
  alias Runic.Runner.Scheduler.Adaptive.Capability

  # ---------------------------------------------------------------------------
  # A. Initialization
  # ---------------------------------------------------------------------------

  describe "init/1" do
    test "returns {:ok, state} with defaults" do
      assert {:ok, state} = Adaptive.init([])
      assert state.profiles == %{}
      assert state.config.fast_threshold_ms == 1.0
      assert state.config.error_rate_threshold == 0.1
      assert state.config.warmup_samples == 3
      assert state.config.ema_alpha == 0.3
      assert state.config.min_chain_length == 2
      assert state.config.min_batch_size == 4
    end

    test "accepts custom thresholds" do
      assert {:ok, state} =
               Adaptive.init(
                 fast_threshold_ms: 5.0,
                 error_rate_threshold: 0.2,
                 warmup_samples: 10,
                 ema_alpha: 0.5
               )

      assert state.config.fast_threshold_ms == 5.0
      assert state.config.error_rate_threshold == 0.2
      assert state.config.warmup_samples == 10
      assert state.config.ema_alpha == 0.5
    end

    test "accepts custom capabilities" do
      custom_caps = [
        %Capability{
          name: :custom,
          description: "Custom capability",
          priority: 1,
          classifier: fn _ -> true end
        }
      ]

      assert {:ok, state} = Adaptive.init(capabilities: custom_caps)
      assert length(state.capabilities) == 1
      assert hd(state.capabilities).name == :custom
    end

    test "default capabilities include fast, unreliable, and batchable" do
      assert {:ok, state} = Adaptive.init([])

      names = Enum.map(state.capabilities, & &1.name)
      assert :fast in names
      assert :unreliable in names
      assert :batchable in names
    end
  end

  # ---------------------------------------------------------------------------
  # B. Classification
  # ---------------------------------------------------------------------------

  describe "classify_node/2" do
    test "untracked nodes default to :batchable during warmup" do
      {:ok, state} = Adaptive.init(warmup_samples: 3)
      runnable = build_runnable(:test_node)

      assert Adaptive.classify_node(runnable, state) == :batchable
    end

    test "fast nodes classified as :fast after warmup" do
      {:ok, state} = Adaptive.init(warmup_samples: 2, fast_threshold_ms: 1.0)
      runnable = build_runnable(:fast_node)

      # Simulate 2 fast completions
      state = Adaptive.on_complete({:runnable, %{runnable | status: :completed}}, 0, state)
      state = Adaptive.on_complete({:runnable, %{runnable | status: :completed}}, 0, state)

      assert Adaptive.classify_node(runnable, state) == :fast
    end

    test "unreliable nodes classified as :unreliable after warmup" do
      {:ok, state} = Adaptive.init(warmup_samples: 3, error_rate_threshold: 0.1)
      runnable = build_runnable(:unreliable_node)

      # Simulate 3 failures (100% error rate)
      state = Adaptive.on_complete({:runnable, %{runnable | status: :failed}}, 10, state)
      state = Adaptive.on_complete({:runnable, %{runnable | status: :failed}}, 10, state)
      state = Adaptive.on_complete({:runnable, %{runnable | status: :failed}}, 10, state)

      assert Adaptive.classify_node(runnable, state) == :unreliable
    end

    test "normal-duration successful nodes classified as :batchable after warmup" do
      {:ok, state} = Adaptive.init(warmup_samples: 3, fast_threshold_ms: 1.0)
      runnable = build_runnable(:normal_node)

      # Simulate 3 completions with moderate duration (well above fast threshold)
      state = Adaptive.on_complete({:runnable, %{runnable | status: :completed}}, 10, state)
      state = Adaptive.on_complete({:runnable, %{runnable | status: :completed}}, 10, state)
      state = Adaptive.on_complete({:runnable, %{runnable | status: :completed}}, 10, state)

      assert Adaptive.classify_node(runnable, state) == :batchable
    end

    test "fast classification takes priority over unreliable (lower priority number)" do
      # A node that is both fast AND has high error rate should be classified as :fast
      # because :fast has priority 1, :unreliable has priority 2
      {:ok, state} =
        Adaptive.init(warmup_samples: 2, fast_threshold_ms: 5.0, error_rate_threshold: 0.1)

      runnable = build_runnable(:fast_but_flaky)

      # Simulate: fast durations but all failures
      state = Adaptive.on_complete({:runnable, %{runnable | status: :failed}}, 0, state)
      state = Adaptive.on_complete({:runnable, %{runnable | status: :failed}}, 0, state)

      # :fast matches first (priority 1) since avg_duration 0.0 < 5.0
      assert Adaptive.classify_node(runnable, state) == :fast
    end

    test "custom classifier overrides default classification" do
      {:ok, state} = Adaptive.init(classifier: fn _profile, _runnable -> :custom_class end)
      runnable = build_runnable(:any)

      assert Adaptive.classify_node(runnable, state) == :custom_class
    end

    test "custom capabilities are used for classification" do
      custom_caps = [
        %Capability{
          name: :heavy,
          description: "Heavy nodes",
          priority: 1,
          classifier: fn profile -> profile.avg_duration_ms > 50.0 end
        },
        %Capability{
          name: :light,
          description: "Light nodes",
          priority: 100,
          classifier: fn _profile -> true end
        }
      ]

      {:ok, state} = Adaptive.init(capabilities: custom_caps, warmup_samples: 1)

      # Use distinct functions to get distinct node hashes
      heavy_step = Runic.step(fn x -> x * 999 end, name: :heavy_node)
      heavy_wf = Runic.workflow(steps: [heavy_step])
      heavy_wf = Workflow.plan_eagerly(heavy_wf, 1)
      {_, [heavy_runnable]} = Workflow.prepare_for_dispatch(heavy_wf)

      light_step = Runic.step(fn x -> x * 777 end, name: :light_node)
      light_wf = Runic.workflow(steps: [light_step])
      light_wf = Workflow.plan_eagerly(light_wf, 1)
      {_, [light_runnable]} = Workflow.prepare_for_dispatch(light_wf)

      # Verify distinct hashes
      assert heavy_runnable.node.hash != light_runnable.node.hash

      # After 1 sample with 100ms duration → :heavy
      state =
        Adaptive.on_complete({:runnable, %{heavy_runnable | status: :completed}}, 100, state)

      assert Adaptive.classify_node(heavy_runnable, state) == :heavy

      # After 1 sample with 1ms duration → :light (1.0 is not > 50.0)
      state = Adaptive.on_complete({:runnable, %{light_runnable | status: :completed}}, 1, state)
      assert Adaptive.classify_node(light_runnable, state) == :light
    end
  end

  # ---------------------------------------------------------------------------
  # C. Profiling via on_complete/3
  # ---------------------------------------------------------------------------

  describe "on_complete/3" do
    test "accumulates sample count for individual runnables" do
      {:ok, state} = Adaptive.init([])
      runnable = build_runnable(:test)

      state = Adaptive.on_complete({:runnable, %{runnable | status: :completed}}, 10, state)
      state = Adaptive.on_complete({:runnable, %{runnable | status: :completed}}, 20, state)

      profile = Adaptive.get_profile(state, runnable.node.hash)
      assert profile.sample_count == 2
    end

    test "first sample sets duration directly" do
      {:ok, state} = Adaptive.init([])
      runnable = build_runnable(:test)

      state = Adaptive.on_complete({:runnable, %{runnable | status: :completed}}, 42, state)

      profile = Adaptive.get_profile(state, runnable.node.hash)
      assert_in_delta profile.avg_duration_ms, 42.0, 0.01
    end

    test "subsequent samples use EMA" do
      {:ok, state} = Adaptive.init(ema_alpha: 0.5)
      runnable = build_runnable(:test)

      state = Adaptive.on_complete({:runnable, %{runnable | status: :completed}}, 10, state)
      state = Adaptive.on_complete({:runnable, %{runnable | status: :completed}}, 20, state)

      profile = Adaptive.get_profile(state, runnable.node.hash)
      # EMA: 0.5 * 20 + 0.5 * 10.0 = 15.0
      assert_in_delta profile.avg_duration_ms, 15.0, 0.01
    end

    test "third sample continues EMA" do
      {:ok, state} = Adaptive.init(ema_alpha: 0.5)
      runnable = build_runnable(:test)

      state = Adaptive.on_complete({:runnable, %{runnable | status: :completed}}, 10, state)
      state = Adaptive.on_complete({:runnable, %{runnable | status: :completed}}, 20, state)
      state = Adaptive.on_complete({:runnable, %{runnable | status: :completed}}, 30, state)

      profile = Adaptive.get_profile(state, runnable.node.hash)
      # EMA: 0.5 * 30 + 0.5 * 15.0 = 22.5
      assert_in_delta profile.avg_duration_ms, 22.5, 0.01
    end

    test "tracks error count" do
      {:ok, state} = Adaptive.init([])
      runnable = build_runnable(:test)

      state = Adaptive.on_complete({:runnable, %{runnable | status: :completed}}, 10, state)
      state = Adaptive.on_complete({:runnable, %{runnable | status: :failed}}, 10, state)
      state = Adaptive.on_complete({:runnable, %{runnable | status: :failed}}, 10, state)

      profile = Adaptive.get_profile(state, runnable.node.hash)
      assert profile.sample_count == 3
      assert profile.error_count == 2
    end

    test "distributes promise duration across node hashes" do
      {:ok, state} = Adaptive.init([])

      promise =
        Runic.Runner.Promise.new([],
          node_hashes: MapSet.new([1, 2, 3])
        )

      state = Adaptive.on_complete({:promise, promise}, 30, state)

      # 30ms / 3 nodes = 10ms each
      for hash <- [1, 2, 3] do
        profile = Adaptive.get_profile(state, hash)
        assert profile.sample_count == 1
        assert_in_delta profile.avg_duration_ms, 10.0, 0.01
      end
    end

    test "promise completion does not count as error" do
      {:ok, state} = Adaptive.init([])

      promise =
        Runic.Runner.Promise.new([],
          node_hashes: MapSet.new([42])
        )

      state = Adaptive.on_complete({:promise, promise}, 10, state)

      profile = Adaptive.get_profile(state, 42)
      assert profile.error_count == 0
    end

    test "updates last_seen timestamp" do
      {:ok, state} = Adaptive.init([])
      runnable = build_runnable(:test)

      before = System.monotonic_time(:millisecond)
      state = Adaptive.on_complete({:runnable, %{runnable | status: :completed}}, 10, state)

      profile = Adaptive.get_profile(state, runnable.node.hash)
      assert profile.last_seen >= before
    end
  end

  # ---------------------------------------------------------------------------
  # D. Plan Dispatch
  # ---------------------------------------------------------------------------

  describe "plan_dispatch/3" do
    test "empty runnables returns empty units" do
      {:ok, state} = Adaptive.init([])
      step = Runic.step(fn x -> x end, name: :dummy)
      workflow = Runic.workflow(steps: [step])

      {units, _state} = Adaptive.plan_dispatch(workflow, [], state)
      assert units == []
    end

    test "warmup period dispatches through structural analysis (chain detection)" do
      {:ok, state} = Adaptive.init(warmup_samples: 3, min_chain_length: 2)

      step_a = Runic.step(fn x -> x + 1 end, name: :ada_a)
      step_b = Runic.step(fn x -> x * 2 end, name: :ada_b)
      step_c = Runic.step(fn x -> x - 1 end, name: :ada_c)
      workflow = Runic.workflow(steps: [{step_a, [{step_b, [step_c]}]}])
      workflow = Workflow.plan_eagerly(workflow, 1)
      {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

      {units, _state} = Adaptive.plan_dispatch(workflow, runnables, state)

      # During warmup, all nodes are :batchable → chain detection applies
      # Chain a→b→c should form a promise
      promise_units = Enum.filter(units, &match?({:promise, _}, &1))
      assert length(promise_units) >= 1
    end

    test "fast nodes dispatched individually, skipping chain batching" do
      {:ok, state} = Adaptive.init(warmup_samples: 1, fast_threshold_ms: 5.0, min_chain_length: 2)

      step_a = Runic.step(fn x -> x + 1 end, name: :fast_chain_a)
      step_b = Runic.step(fn x -> x * 2 end, name: :fast_chain_b)
      step_c = Runic.step(fn x -> x - 1 end, name: :fast_chain_c)
      workflow = Runic.workflow(steps: [{step_a, [{step_b, [step_c]}]}])
      workflow = Workflow.plan_eagerly(workflow, 1)
      {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

      # Pre-load profiles with fast times for all nodes
      state =
        Enum.reduce(runnables, state, fn r, acc ->
          Adaptive.on_complete({:runnable, %{r | status: :completed}}, 0, acc)
        end)

      {units, _state} = Adaptive.plan_dispatch(workflow, runnables, state)

      # All nodes classified as :fast → dispatched individually, no promises
      assert Enum.all?(units, &match?({:runnable, _}, &1))
      assert length(units) == length(runnables)
    end

    test "unreliable nodes dispatched individually" do
      {:ok, state} =
        Adaptive.init(warmup_samples: 2, error_rate_threshold: 0.3, fast_threshold_ms: 0.001)

      step_a = Runic.step(fn x -> x + 1 end, name: :unrel_a)
      step_b = Runic.step(fn x -> x * 2 end, name: :unrel_b)
      workflow = Runic.workflow(steps: [{step_a, [step_b]}])
      workflow = Workflow.plan_eagerly(workflow, 1)
      {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

      # Pre-load profiles: all failures, moderate duration
      state =
        Enum.reduce(runnables, state, fn r, acc ->
          acc = Adaptive.on_complete({:runnable, %{r | status: :failed}}, 10, acc)
          Adaptive.on_complete({:runnable, %{r | status: :failed}}, 10, acc)
        end)

      {units, _state} = Adaptive.plan_dispatch(workflow, runnables, state)

      # All nodes classified as :unreliable → dispatched individually
      assert Enum.all?(units, &match?({:runnable, _}, &1))
    end

    test "mixed classification: fast + batchable" do
      {:ok, state} = Adaptive.init(warmup_samples: 1, fast_threshold_ms: 5.0, min_chain_length: 2)

      step_a = Runic.step(fn x -> x + 1 end, name: :mix_a)
      step_b = Runic.step(fn x -> x * 2 end, name: :mix_b)
      workflow = Runic.workflow(steps: [step_a, step_b])
      workflow = Workflow.plan_eagerly(workflow, 1)
      {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

      # Make one fast, one slow
      [r1, r2] = runnables
      state = Adaptive.on_complete({:runnable, %{r1 | status: :completed}}, 0, state)
      state = Adaptive.on_complete({:runnable, %{r2 | status: :completed}}, 50, state)

      {units, _state} = Adaptive.plan_dispatch(workflow, runnables, state)

      # Both should be dispatched individually (parallel steps don't chain)
      assert length(units) == 2
      assert Enum.all?(units, &match?({:runnable, _}, &1))
    end

    test "all input runnables accounted for in output" do
      {:ok, state} = Adaptive.init(warmup_samples: 1, fast_threshold_ms: 5.0)

      step_a = Runic.step(fn x -> x + 1 end, name: :acct_a)
      step_b = Runic.step(fn x -> x * 2 end, name: :acct_b)
      step_c = Runic.step(fn x -> x - 1 end, name: :acct_c)
      workflow = Runic.workflow(steps: [{step_a, [{step_b, [step_c]}]}])
      workflow = Workflow.plan_eagerly(workflow, 1)
      {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

      # Pre-load: make a fast, b+c batchable
      state =
        Enum.reduce(runnables, state, fn r, acc ->
          Adaptive.on_complete({:runnable, %{r | status: :completed}}, 50, acc)
        end)

      {units, _state} = Adaptive.plan_dispatch(workflow, runnables, state)

      output_ids =
        Enum.flat_map(units, fn
          {:runnable, r} -> [r.id]
          {:promise, p} -> Enum.map(p.runnables, & &1.id)
        end)

      input_ids = Enum.map(runnables, & &1.id)

      assert Enum.sort(output_ids) == Enum.sort(input_ids)
    end
  end

  # ---------------------------------------------------------------------------
  # E. Profile Summary
  # ---------------------------------------------------------------------------

  describe "profile_summary/1" do
    test "returns correct classification counts" do
      {:ok, state} = Adaptive.init(warmup_samples: 1, fast_threshold_ms: 5.0)

      # Use distinct functions to ensure distinct node hashes
      fast_step = Runic.step(fn x -> x + 100 end, name: :fast_sum)
      fast_wf = Runic.workflow(steps: [fast_step])
      fast_wf = Workflow.plan_eagerly(fast_wf, 1)
      {_, [fast]} = Workflow.prepare_for_dispatch(fast_wf)

      slow_step = Runic.step(fn x -> x + 200 end, name: :slow_sum)
      slow_wf = Runic.workflow(steps: [slow_step])
      slow_wf = Workflow.plan_eagerly(slow_wf, 1)
      {_, [slow]} = Workflow.prepare_for_dispatch(slow_wf)

      assert fast.node.hash != slow.node.hash

      state = Adaptive.on_complete({:runnable, %{fast | status: :completed}}, 1, state)
      state = Adaptive.on_complete({:runnable, %{slow | status: :completed}}, 100, state)

      summary = Adaptive.profile_summary(state)
      assert summary.total_tracked == 2
      assert summary.classifications[:fast] == 1
      assert summary.classifications[:batchable] == 1
    end

    test "untracked nodes not included in summary" do
      {:ok, state} = Adaptive.init([])

      summary = Adaptive.profile_summary(state)
      assert summary.total_tracked == 0
      assert summary.classifications == %{}
    end

    test "warmup nodes classified as :warmup in summary" do
      {:ok, state} = Adaptive.init(warmup_samples: 3)
      runnable = build_runnable(:warmup_node)

      # Only 1 sample, warmup requires 3
      state = Adaptive.on_complete({:runnable, %{runnable | status: :completed}}, 10, state)

      summary = Adaptive.profile_summary(state)
      assert summary.classifications[:warmup] == 1
    end
  end

  # ---------------------------------------------------------------------------
  # F. State Threading
  # ---------------------------------------------------------------------------

  describe "state threading" do
    test "profiles accumulate across multiple plan_dispatch calls" do
      {:ok, state} = Adaptive.init(warmup_samples: 1, fast_threshold_ms: 5.0)

      step = Runic.step(fn x -> x + 1 end, name: :thread_a)
      workflow = Runic.workflow(steps: [step])
      workflow = Workflow.plan_eagerly(workflow, 1)
      {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)

      # First dispatch — warmup
      {_units, state} = Adaptive.plan_dispatch(workflow, runnables, state)

      # Simulate completion
      [r] = runnables
      state = Adaptive.on_complete({:runnable, %{r | status: :completed}}, 0, state)

      # Second dispatch — should now classify as :fast
      {units, _state} = Adaptive.plan_dispatch(workflow, runnables, state)
      assert Enum.all?(units, &match?({:runnable, _}, &1))
    end

    test "on_complete correctly threads state through multiple updates" do
      {:ok, state} = Adaptive.init(ema_alpha: 0.5)
      runnable = build_runnable(:threading)

      state = Adaptive.on_complete({:runnable, %{runnable | status: :completed}}, 100, state)
      state = Adaptive.on_complete({:runnable, %{runnable | status: :completed}}, 200, state)
      state = Adaptive.on_complete({:runnable, %{runnable | status: :failed}}, 300, state)

      profile = Adaptive.get_profile(state, runnable.node.hash)
      assert profile.sample_count == 3
      assert profile.error_count == 1
      # EMA: 100 → 0.5*200 + 0.5*100 = 150 → 0.5*300 + 0.5*150 = 225
      assert_in_delta profile.avg_duration_ms, 225.0, 0.01
    end
  end

  # ---------------------------------------------------------------------------
  # G. Worker Integration
  # ---------------------------------------------------------------------------

  describe "Worker integration" do
    setup do
      runner_name = :"test_runner_adaptive_#{System.unique_integer([:positive])}"
      start_supervised!({Runic.Runner, name: runner_name})
      %{runner: runner_name}
    end

    test "produces correct results for a→b pipeline", %{runner: runner} do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      workflow = Runic.workflow(steps: [{step_a, [step_b]}])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_adaptive, workflow, scheduler: Adaptive)

      :ok = Runic.Runner.run(runner, :wf_adaptive, 5)
      assert_workflow_idle(runner, :wf_adaptive)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_adaptive)
      assert 12 in results
    end

    test "produces correct results for linear chain", %{runner: runner} do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      step_c = Runic.step(fn x -> x - 1 end, name: :c)
      workflow = Runic.workflow(steps: [{step_a, [{step_b, [step_c]}]}])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_adaptive_chain, workflow, scheduler: Adaptive)

      :ok = Runic.Runner.run(runner, :wf_adaptive_chain, 5)
      assert_workflow_idle(runner, :wf_adaptive_chain)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_adaptive_chain)
      # 5 -> 6 -> 12 -> 11
      assert 11 in results
    end

    test "behavioral equivalence with Default scheduler", %{runner: runner} do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      step_c = Runic.step(fn x -> x - 1 end, name: :c)
      workflow = Runic.workflow(steps: [{step_a, [{step_b, [step_c]}]}])

      {:ok, _} = Runic.Runner.start_workflow(runner, :wf_adaptive_equiv, workflow)
      :ok = Runic.Runner.run(runner, :wf_adaptive_equiv, 10)
      assert_workflow_idle(runner, :wf_adaptive_equiv)
      {:ok, default_results} = Runic.Runner.get_results(runner, :wf_adaptive_equiv)

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_adaptive_vs_default, workflow,
          scheduler: Adaptive
        )

      :ok = Runic.Runner.run(runner, :wf_adaptive_vs_default, 10)
      assert_workflow_idle(runner, :wf_adaptive_vs_default)
      {:ok, adaptive_results} = Runic.Runner.get_results(runner, :wf_adaptive_vs_default)

      assert Enum.sort(default_results) == Enum.sort(adaptive_results)
    end

    test "accumulates profiling state in Worker", %{runner: runner} do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      workflow = Runic.workflow(steps: [step_a])

      {:ok, pid} =
        Runic.Runner.start_workflow(runner, :wf_adaptive_state, workflow, scheduler: Adaptive)

      :ok = Runic.Runner.run(runner, :wf_adaptive_state, 5)
      assert_workflow_idle(runner, :wf_adaptive_state)

      state = :sys.get_state(pid)
      assert state.scheduler == Adaptive
      assert map_size(state.scheduler_state.profiles) > 0
    end

    test "with inline executor produces correct results", %{runner: runner} do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      step_c = Runic.step(fn x -> x - 1 end, name: :c)
      workflow = Runic.workflow(steps: [{step_a, [{step_b, [step_c]}]}])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_adaptive_inline, workflow,
          executor: :inline,
          scheduler: Adaptive
        )

      :ok = Runic.Runner.run(runner, :wf_adaptive_inline, 5)
      assert_workflow_idle(runner, :wf_adaptive_inline)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_adaptive_inline)
      assert 11 in results
    end

    test "parallel steps produce correct results", %{runner: runner} do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      workflow = Runic.workflow(steps: [step_a, step_b])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_adaptive_par, workflow, scheduler: Adaptive)

      :ok = Runic.Runner.run(runner, :wf_adaptive_par, 5)
      assert_workflow_idle(runner, :wf_adaptive_par)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_adaptive_par)
      assert 6 in results
      assert 10 in results
    end

    test "fan-out pattern produces correct results", %{runner: runner} do
      step_a = Runic.step(fn x -> x + 1 end, name: :a)
      step_b = Runic.step(fn x -> x * 2 end, name: :b)
      step_c = Runic.step(fn x -> x * 3 end, name: :c)
      workflow = Runic.workflow(steps: [{step_a, [step_b, step_c]}])

      {:ok, _} =
        Runic.Runner.start_workflow(runner, :wf_adaptive_fanout, workflow, scheduler: Adaptive)

      :ok = Runic.Runner.run(runner, :wf_adaptive_fanout, 5)
      assert_workflow_idle(runner, :wf_adaptive_fanout)

      {:ok, results} = Runic.Runner.get_results(runner, :wf_adaptive_fanout)
      # 5 -> 6 -> 12, 5 -> 6 -> 18
      assert 12 in results
      assert 18 in results
    end
  end

  # ---------------------------------------------------------------------------
  # H. Adaptive Decisions Stabilize
  # ---------------------------------------------------------------------------

  describe "decision stabilization" do
    test "classification is consistent with same profiling data" do
      {:ok, state} = Adaptive.init(warmup_samples: 2, fast_threshold_ms: 5.0)
      runnable = build_runnable(:stable)

      # Build up profile
      state = Adaptive.on_complete({:runnable, %{runnable | status: :completed}}, 0, state)
      state = Adaptive.on_complete({:runnable, %{runnable | status: :completed}}, 0, state)

      # Multiple classifications should be consistent
      c1 = Adaptive.classify_node(runnable, state)
      c2 = Adaptive.classify_node(runnable, state)
      c3 = Adaptive.classify_node(runnable, state)

      assert c1 == c2
      assert c2 == c3
      assert c1 == :fast
    end

    test "classification can change as profiling data evolves" do
      {:ok, state} = Adaptive.init(warmup_samples: 2, fast_threshold_ms: 5.0, ema_alpha: 0.9)
      runnable = build_runnable(:evolving)

      # Start fast
      state = Adaptive.on_complete({:runnable, %{runnable | status: :completed}}, 0, state)
      state = Adaptive.on_complete({:runnable, %{runnable | status: :completed}}, 0, state)
      assert Adaptive.classify_node(runnable, state) == :fast

      # Become slow (EMA alpha 0.9 = highly reactive to recent samples)
      state = Adaptive.on_complete({:runnable, %{runnable | status: :completed}}, 100, state)
      state = Adaptive.on_complete({:runnable, %{runnable | status: :completed}}, 100, state)
      state = Adaptive.on_complete({:runnable, %{runnable | status: :completed}}, 100, state)

      assert Adaptive.classify_node(runnable, state) == :batchable
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Each runnable needs a unique function to get a unique node hash,
  # since step hashes are function-based, not name-based.
  defp build_runnable(name) do
    # Use a unique anonymous function per call by closing over name
    # and a unique integer. The :erlang.phash2 of the closure differs
    # because the captured value differs.
    uniq = System.unique_integer()

    step = Runic.step(fn x -> {name, uniq, x} end, name: name)
    workflow = Runic.workflow(steps: [step])
    workflow = Workflow.plan_eagerly(workflow, 1)
    {_workflow, [runnable]} = Workflow.prepare_for_dispatch(workflow)
    runnable
  end

  defp assert_workflow_idle(runner, workflow_id, timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll_until_idle(runner, workflow_id, deadline)
  end

  defp poll_until_idle(runner, workflow_id, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      flunk("Workflow #{inspect(workflow_id)} did not reach idle within timeout")
    end

    case Runic.Runner.lookup(runner, workflow_id) do
      nil ->
        flunk("Workflow #{inspect(workflow_id)} not found")

      pid ->
        state = :sys.get_state(pid)

        if state.status == :idle and map_size(state.active_tasks) == 0 do
          :ok
        else
          Process.sleep(10)
          poll_until_idle(runner, workflow_id, deadline)
        end
    end
  end
end
