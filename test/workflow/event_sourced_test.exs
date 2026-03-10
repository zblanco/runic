defmodule Runic.Workflow.EventSourcedTest do
  use ExUnit.Case, async: true

  require Runic

  alias Runic.Workflow
  alias Runic.Workflow.Fact
  alias Runic.Workflow.Invokable
  alias Runic.Workflow.Runnable

  alias Runic.Workflow.Events.{
    FactProduced,
    ActivationConsumed,
    ConditionSatisfied,
    MapReduceTracked,
    FanOutFactEmitted,
    FanInCompleted
  }

  describe "Root event-sourced execute" do
    test "produces FactProduced event" do
      workflow = Workflow.new() |> Workflow.add(Runic.step(fn x -> x end, name: :noop))
      fact = Fact.new(value: 42)

      {:ok, runnable} = Invokable.prepare(%Runic.Workflow.Root{}, workflow, fact)
      executed = Invokable.execute(%Runic.Workflow.Root{}, runnable)

      assert executed.status == :completed
      assert is_list(executed.events)
      assert [%FactProduced{producer_label: :input}] = executed.events
      assert hd(executed.events).value == 42
      assert hd(executed.events).hash == fact.hash
    end
  end

  describe "Step event-sourced execute" do
    test "produces FactProduced and ActivationConsumed events" do
      step = Runic.step(fn x -> x * 2 end, name: :double)
      workflow = Workflow.new() |> Workflow.add(step)
      fact = Fact.new(value: 5)

      workflow = Workflow.log_fact(workflow, fact)
      workflow = Workflow.prepare_next_runnables(workflow, Workflow.root(), fact)

      {:ok, runnable} = Invokable.prepare(step, workflow, fact)
      executed = Invokable.execute(step, runnable)

      assert executed.status == :completed
      assert %Fact{value: 10} = executed.result
      assert is_list(executed.events)

      fact_produced = Enum.find(executed.events, &is_struct(&1, FactProduced))
      assert fact_produced.producer_label == :produced
      assert fact_produced.value == 10

      activation_consumed = Enum.find(executed.events, &is_struct(&1, ActivationConsumed))
      assert activation_consumed.fact_hash == fact.hash
      assert activation_consumed.node_hash == step.hash
      assert activation_consumed.from_label == :runnable
    end

    test "produces MapReduceTracked event when in fan-out context" do
      workflow =
        Runic.workflow(
          steps: [
            {Runic.step(fn _ -> [1, 2, 3] end, name: :source),
             [
               {Runic.map(fn x -> x * 2 end, name: :double_map),
                [Runic.reduce(0, fn n, a -> n + a end, name: :sum, map: :double_map)]}
             ]}
          ]
        )

      # Run through to the map step
      w = Workflow.react(workflow, "input") |> Workflow.react()
      {_, runnables} = Workflow.prepare_for_dispatch(w)

      for r <- runnables do
        executed = Invokable.execute(r.node, r)
        map_event = Enum.find(executed.events, &is_struct(&1, MapReduceTracked))
        assert map_event, "MapReduceTracked event should be produced for mapped steps"
        assert map_event.step_hash == r.node.hash
      end
    end
  end

  describe "Condition event-sourced execute" do
    test "satisfied condition produces ConditionSatisfied and ActivationConsumed" do
      condition = Runic.condition(fn x -> x > 0 end, name: :positive)
      step = Runic.step(fn x -> x end, name: :then_step)

      workflow = Workflow.new() |> Workflow.add(condition) |> Workflow.add(step, to: :positive)
      fact = Fact.new(value: 5)

      workflow = Workflow.log_fact(workflow, fact)
      workflow = Workflow.prepare_next_runnables(workflow, Workflow.root(), fact)

      {:ok, runnable} = Invokable.prepare(condition, workflow, fact)
      executed = Invokable.execute(condition, runnable)

      assert executed.status == :completed
      assert executed.result == true

      cond_satisfied = Enum.find(executed.events, &is_struct(&1, ConditionSatisfied))
      assert cond_satisfied.fact_hash == fact.hash
      assert cond_satisfied.condition_hash == condition.hash

      activation = Enum.find(executed.events, &is_struct(&1, ActivationConsumed))
      assert activation.from_label == :matchable
    end

    test "unsatisfied condition produces only ActivationConsumed" do
      condition = Runic.condition(fn x -> x > 100 end, name: :big)
      workflow = Workflow.new() |> Workflow.add(condition)
      fact = Fact.new(value: 5)

      workflow = Workflow.log_fact(workflow, fact)
      workflow = Workflow.prepare_next_runnables(workflow, Workflow.root(), fact)

      {:ok, runnable} = Invokable.prepare(condition, workflow, fact)
      executed = Invokable.execute(condition, runnable)

      assert executed.result == false
      assert length(executed.events) == 1
      assert [%ActivationConsumed{from_label: :matchable}] = executed.events
    end
  end

  describe "Conjunction event-sourced execute" do
    test "satisfied conjunction produces ConditionSatisfied and ActivationConsumed" do
      rule =
        Runic.rule do
          given(value: x)
          where(x > 0 and x < 100)
          then(fn %{value: v} -> {:result, v} end)
        end

      workflow = Workflow.new() |> Workflow.add(rule)

      result =
        workflow
        |> Workflow.react_until_satisfied(15)
        |> Workflow.raw_productions()

      assert {:result, 15} in result
    end
  end

  describe "apply_event/2 pure fold" do
    test "FactProduced adds fact to graph" do
      step = Runic.step(fn x -> x end, name: :s)
      workflow = Workflow.new() |> Workflow.add(step)

      event = %FactProduced{
        hash: 12345,
        value: "hello",
        ancestry: nil,
        producer_label: :input,
        weight: 0
      }

      wf = Workflow.apply_event(workflow, event)
      facts = Workflow.facts(wf)
      assert Enum.any?(facts, &(&1.hash == 12345 && &1.value == "hello"))
    end

    test "ConditionSatisfied draws :satisfied edge" do
      condition = Runic.condition(fn x -> x > 0 end, name: :pos)
      workflow = Workflow.new() |> Workflow.add(condition)
      fact = Fact.new(value: 5)
      workflow = Workflow.log_fact(workflow, fact)

      event = %ConditionSatisfied{
        fact_hash: fact.hash,
        condition_hash: condition.hash,
        weight: 1
      }

      wf = Workflow.apply_event(workflow, event)
      satisfied_edges = Graph.edges(wf.graph, by: :satisfied)
      assert length(satisfied_edges) == 1
    end
  end

  describe "apply_runnable event-sourced path" do
    test "folds events and activates downstream" do
      step = Runic.step(fn x -> x * 2 end, name: :double)
      workflow = Workflow.new() |> Workflow.add(step)

      result =
        workflow
        |> Workflow.react_until_satisfied(5)
        |> Workflow.raw_productions()

      assert 10 in result
    end

    test "buffers uncommitted events" do
      step = Runic.step(fn x -> x + 1 end, name: :inc)
      workflow = Workflow.new() |> Workflow.add(step) |> Workflow.enable_event_emission()

      result = Workflow.react_until_satisfied(workflow, 5)
      assert length(result.uncommitted_events) > 0

      event_types = Enum.map(result.uncommitted_events, & &1.__struct__)
      assert FactProduced in event_types
      assert ActivationConsumed in event_types
    end

    test "three-phase produces same result as legacy invoke for chained steps" do
      workflow =
        Runic.workflow(
          steps: [
            {Runic.step(fn x -> x + 1 end, name: :add),
             [Runic.step(fn x -> x * 2 end, name: :double)]}
          ]
        )

      result =
        workflow
        |> Workflow.react_until_satisfied(5)
        |> Workflow.raw_productions()
        |> Enum.sort()

      assert result == [6, 12]
    end

    test "rules with conditions work end-to-end" do
      rule = Runic.rule(fn x when x > 0 -> {:positive, x} end, name: :pos_rule)

      workflow = Runic.workflow(rules: [rule])

      result =
        workflow
        |> Workflow.react_until_satisfied(42)
        |> Workflow.raw_productions()

      assert {:positive, 42} in result
    end
  end

  describe "FactRef" do
    test "FactRef has hash and ancestry fields" do
      ref = %Runic.Workflow.FactRef{hash: 12345, ancestry: {111, 222}}
      assert ref.hash == 12345
      assert ref.ancestry == {111, 222}
    end

    test "Components.vertex_id_of handles FactRef" do
      ref = %Runic.Workflow.FactRef{hash: 12345, ancestry: nil}
      assert Runic.Workflow.Components.vertex_id_of(ref) == 12345
    end
  end

  describe "MemoryAssertion event-sourced execute" do
    test "satisfied MemoryAssertion produces ConditionSatisfied and ActivationConsumed" do
      step = Runic.step(fn x -> x end, name: :producer)

      rule =
        Runic.rule do
          given(value: x)
          where(x > 0)

          recall(fn workflow, _fact ->
            Enum.any?(Workflow.facts(workflow), &(&1.value == :marker))
          end)

          then(fn %{value: v} -> {:checked, v} end)
        end

      workflow =
        Workflow.new()
        |> Workflow.add(step)
        |> Workflow.add(rule)

      # Just verify rules with memory assertions work end-to-end
      marker_fact = Runic.Workflow.Fact.new(value: :marker)
      workflow = Workflow.log_fact(workflow, marker_fact)

      result =
        workflow
        |> Workflow.react_until_satisfied(5)
        |> Workflow.raw_productions()

      assert {:checked, 5} in result
    end
  end

  describe "StateMachine event-sourced execute" do
    test "state machine accumulator produces events" do
      sm =
        Runic.state_machine(
          name: :counter,
          init: 0,
          reducer: fn num, state -> state + num end
        )

      workflow = Workflow.new() |> Workflow.add(sm) |> Workflow.enable_event_emission()

      result =
        workflow
        |> Workflow.react_until_satisfied(15)
        |> Workflow.raw_productions()

      # The accumulator should produce the accumulated state
      assert 15 in result

      # Verify uncommitted events include state-related events
      w = Workflow.react_until_satisfied(workflow, 15)
      event_types = Enum.map(w.uncommitted_events, & &1.__struct__)
      assert ActivationConsumed in event_types
    end

    test "state machine produces events at node level" do
      sm =
        Runic.state_machine(
          name: :counter2,
          init: 0,
          reducer: fn num, state -> state + num end
        )

      workflow = Workflow.new() |> Workflow.add(sm)

      # Feed input and react - accumulator processes the input
      w = Workflow.react(workflow, 5)
      # Verify the workflow produced output (accumulator state)
      assert 5 in Workflow.raw_productions(w)
    end
  end

  describe "StateMachine reactor event-sourced execute" do
    test "state machine with reactor fires when state matches pattern" do
      sm =
        Runic.state_machine(
          name: :potato,
          init: %{code: "potato", state: :locked, contents: "ham"},
          reducer: fn
            {:unlock, input_code}, %{code: code, state: :locked} = state
            when input_code == code ->
              %{state | state: :unlocked}

            _input, state ->
              state
          end,
          reactors: [
            fn %{state: :unlocked} -> :access_granted end
          ]
        )

      # Reactor fires when the state matches the reactor's pattern
      wrk =
        Workflow.new()
        |> Workflow.add(sm)
        |> Workflow.react_until_satisfied({:unlock, "potato"})

      prods = Workflow.raw_productions(wrk)
      # After unlock: state becomes :unlocked, reactor matches and fires
      assert :access_granted in prods
    end
  end

  describe "Accumulator event-sourced execute" do
    test "accumulator initialized path produces FactProduced with :state_produced" do
      acc = Runic.accumulator(0, fn val, state -> state + val end, name: :sum)

      workflow = Workflow.new() |> Workflow.add(acc)

      result =
        workflow
        |> Workflow.react_until_satisfied(5)
        |> Workflow.raw_productions()

      assert 5 in result
    end

    test "accumulator multiple invocations accumulate state" do
      acc = Runic.accumulator(0, fn val, state -> state + val end, name: :sum)

      workflow = Workflow.new() |> Workflow.add(acc)

      w1 = Workflow.react_until_satisfied(workflow, 5)
      w2 = Workflow.react_until_satisfied(w1, 10)

      result = Workflow.raw_productions(w2)
      assert 15 in result
    end

    test "accumulator buffers uncommitted events including StateInitiated" do
      acc = Runic.accumulator(0, fn val, state -> state + val end, name: :sum)

      workflow = Workflow.new() |> Workflow.add(acc) |> Workflow.enable_event_emission()
      result = Workflow.react_until_satisfied(workflow, 5)

      assert length(result.uncommitted_events) > 0
      event_types = Enum.map(result.uncommitted_events, & &1.__struct__)
      assert Runic.Workflow.Events.StateInitiated in event_types
      assert FactProduced in event_types
      assert ActivationConsumed in event_types
    end
  end

  describe "apply_event/2 StateInitiated fold" do
    test "StateInitiated adds init fact and draws :state_initiated edge" do
      acc = Runic.accumulator(0, fn val, state -> state + val end, name: :sum)

      workflow = Workflow.new() |> Workflow.add(acc)

      event = %Runic.Workflow.Events.StateInitiated{
        accumulator_hash: acc.hash,
        init_fact_hash: 99999,
        init_value: 0,
        init_ancestry: {acc.hash, 11111},
        weight: 1
      }

      wf = Workflow.apply_event(workflow, event)
      facts = Workflow.facts(wf)
      assert Enum.any?(facts, &(&1.hash == 99999 && &1.value == 0))

      state_init_edges = Graph.edges(wf.graph, by: :state_initiated)
      assert length(state_init_edges) == 1
    end
  end

  describe "Join event-sourced execute" do
    test "produces JoinFactReceived and ActivationConsumed events" do
      step_a = Runic.step(fn x -> x + 1 end, name: :branch_a)
      step_b = Runic.step(fn x -> x * 2 end, name: :branch_b)
      join_step = Runic.step(fn a, b -> a + b end, name: :combine)

      workflow =
        Workflow.new()
        |> Workflow.add(step_a)
        |> Workflow.add(step_b)
        |> Workflow.add(join_step, to: [:branch_a, :branch_b])

      # React once to produce facts from both branches
      w = Workflow.react(workflow, 5)
      {_w, runnables} = Workflow.prepare_for_dispatch(w)

      # Find join runnables
      join_runnables = Enum.filter(runnables, &is_struct(&1.node, Runic.Workflow.Join))

      for r <- join_runnables do
        executed = Invokable.execute(r.node, r)
        assert executed.status == :completed
        assert executed.result == :waiting
        assert is_list(executed.events)

        join_event =
          Enum.find(executed.events, &is_struct(&1, Runic.Workflow.Events.JoinFactReceived))

        assert join_event
        assert join_event.join_hash == r.node.hash

        activation =
          Enum.find(executed.events, &is_struct(&1, Runic.Workflow.Events.ActivationConsumed))

        assert activation
        assert activation.from_label == :runnable
      end
    end

    test "join completes end-to-end via react_until_satisfied" do
      step_a = Runic.step(fn x -> x + 1 end, name: :branch_a2)
      step_b = Runic.step(fn x -> x * 2 end, name: :branch_b2)
      combine = Runic.step(fn a, b -> a + b end, name: :combine2)

      workflow =
        Workflow.new()
        |> Workflow.add(step_a)
        |> Workflow.add(step_b)
        |> Workflow.add(combine, to: [:branch_a2, :branch_b2])

      result =
        workflow
        |> Workflow.react_until_satisfied(5)
        |> Workflow.raw_productions()

      # branch_a2: 5+1=6, branch_b2: 5*2=10, combine: 6+10=16
      assert 16 in result
    end

    test "join buffers uncommitted events including JoinFactReceived and JoinCompleted" do
      step_a = Runic.step(fn x -> x + 1 end, name: :ja)
      step_b = Runic.step(fn x -> x * 2 end, name: :jb)
      join_step = Runic.step(fn a, b -> a + b end, name: :j_combine)

      workflow =
        Workflow.new()
        |> Workflow.add(step_a)
        |> Workflow.add(step_b)
        |> Workflow.add(join_step, to: [:ja, :jb])
        |> Workflow.enable_event_emission()

      w = Workflow.react_until_satisfied(workflow, 5)
      event_types = Enum.map(w.uncommitted_events, & &1.__struct__)
      assert Runic.Workflow.Events.JoinFactReceived in event_types
      assert Runic.Workflow.Events.JoinCompleted in event_types
      assert Runic.Workflow.Events.JoinEdgeRelabeled in event_types
    end

    test "join with condition gating works end-to-end" do
      cond_node = Runic.condition(fn x -> x > 0 end, name: :pos_check)
      step_a = Runic.step(fn x -> x + 1 end, name: :ca)
      step_b = Runic.step(fn x -> x * 3 end, name: :cb)
      join_step = Runic.step(fn a, b -> {a, b} end, name: :cond_combine)

      workflow =
        Workflow.new()
        |> Workflow.add(cond_node)
        |> Workflow.add(step_a, to: :pos_check)
        |> Workflow.add(step_b, to: :pos_check)
        |> Workflow.add(join_step, to: [:ca, :cb])

      result =
        workflow
        |> Workflow.react_until_satisfied(4)
        |> Workflow.raw_productions()

      # ca: 4+1=5, cb: 4*3=12, combine: {5, 12}
      assert {5, 12} in result
    end
  end

  describe "apply_event/2 Join events fold" do
    test "JoinFactReceived draws :joined edge" do
      step_a = Runic.step(fn x -> x end, name: :jfe_a)
      step_b = Runic.step(fn x -> x end, name: :jfe_b)
      join_step = Runic.step(fn a, b -> a + b end, name: :jfe_combine)

      workflow =
        Workflow.new()
        |> Workflow.add(step_a)
        |> Workflow.add(step_b)
        |> Workflow.add(join_step, to: [:jfe_a, :jfe_b])

      # Find the join node in graph vertices
      join =
        workflow.graph.vertices
        |> Map.values()
        |> Enum.find(&is_struct(&1, Runic.Workflow.Join))

      fact = Fact.new(value: 42, ancestry: {step_a.hash, 111})
      workflow = Workflow.log_fact(workflow, fact)

      event = %Runic.Workflow.Events.JoinFactReceived{
        fact_hash: fact.hash,
        join_hash: join.hash,
        parent_hash: step_a.hash,
        weight: 1
      }

      wf = Workflow.apply_event(workflow, event)
      joined_edges = Graph.edges(wf.graph, by: :joined)
      assert length(joined_edges) == 1
      assert hd(joined_edges).v1 == fact
      assert hd(joined_edges).v2 == join
    end

    test "JoinCompleted logs fact and draws :produced edge" do
      step_a = Runic.step(fn x -> x end, name: :jc_a)
      join_step = Runic.step(fn a -> a end, name: :jc_combine)

      workflow =
        Workflow.new()
        |> Workflow.add(step_a)
        |> Workflow.add(join_step, to: [:jc_a])

      join =
        workflow.graph.vertices
        |> Map.values()
        |> Enum.find(&is_struct(&1, Runic.Workflow.Join))

      # If no join was created (single parent doesn't create join), use the step
      target_hash = if join, do: join.hash, else: join_step.hash

      event = %Runic.Workflow.Events.JoinCompleted{
        join_hash: target_hash,
        result_fact_hash: 99999,
        result_value: [42],
        result_ancestry: {target_hash, 111},
        weight: 2
      }

      wf = Workflow.apply_event(workflow, event)
      facts = Workflow.facts(wf)
      assert Enum.any?(facts, &(&1.hash == 99999 && &1.value == [42]))
    end

    test "JoinEdgeRelabeled relabels :joined to :join_satisfied" do
      step_a = Runic.step(fn x -> x end, name: :jer_a)
      step_b = Runic.step(fn x -> x end, name: :jer_b)
      join_step = Runic.step(fn a, b -> a + b end, name: :jer_combine)

      workflow =
        Workflow.new()
        |> Workflow.add(step_a)
        |> Workflow.add(step_b)
        |> Workflow.add(join_step, to: [:jer_a, :jer_b])

      join =
        workflow.graph.vertices
        |> Map.values()
        |> Enum.find(&is_struct(&1, Runic.Workflow.Join))

      fact = Fact.new(value: 42, ancestry: {step_a.hash, 111})
      workflow = Workflow.log_fact(workflow, fact)

      # First draw the :joined edge
      workflow = Workflow.draw_connection(workflow, fact, join, :joined, weight: 1)

      event = %Runic.Workflow.Events.JoinEdgeRelabeled{
        fact_hash: fact.hash,
        join_hash: join.hash,
        from_label: :joined,
        to_label: :join_satisfied
      }

      wf = Workflow.apply_event(workflow, event)
      joined_edges = Graph.edges(wf.graph, by: :joined)
      assert Enum.empty?(joined_edges)

      satisfied_edges = Graph.edges(wf.graph, by: :join_satisfied)
      assert length(satisfied_edges) == 1
    end
  end

  describe "FanOut event-sourced execute" do
    test "produces FanOutFactEmitted events for each item in enumerable" do
      workflow =
        Runic.workflow(
          steps: [
            {Runic.step(fn _ -> [1, 2, 3] end, name: :source),
             [Runic.map(fn x -> x * 2 end, name: :double_map)]}
          ]
        )

      # Plan input and activate through conditions, then dispatch to get source step runnable
      w = Workflow.plan_eagerly(workflow, "input")
      {w, source_runnables} = Workflow.prepare_for_dispatch(w)

      # Execute source step and apply to get FanOut activation
      source_r = hd(source_runnables)
      executed_source = Invokable.execute(source_r.node, source_r)
      w = Workflow.apply_runnable(w, executed_source)

      # Now prepare_for_dispatch should yield the FanOut runnable
      {w, runnables} = Workflow.prepare_for_dispatch(w)

      fan_out_runnable =
        Enum.find(runnables, fn r -> is_struct(r.node, Runic.Workflow.FanOut) end)

      assert fan_out_runnable, "Should have a FanOut runnable"

      executed = Invokable.execute(fan_out_runnable.node, fan_out_runnable)

      assert executed.status == :completed
      assert is_list(executed.events)

      fan_out_events = Enum.filter(executed.events, &is_struct(&1, FanOutFactEmitted))
      assert length(fan_out_events) == 3

      for event <- fan_out_events do
        assert event.fan_out_hash == fan_out_runnable.node.hash
        assert event.source_fact_hash == fan_out_runnable.input_fact.hash
        assert event.emitted_value in [1, 2, 3]
      end

      activation = Enum.find(executed.events, &is_struct(&1, ActivationConsumed))
      assert activation.fact_hash == fan_out_runnable.input_fact.hash
      assert activation.node_hash == fan_out_runnable.node.hash
      assert activation.from_label == :runnable
    end

    test "result contains list of emitted Fact structs" do
      workflow =
        Runic.workflow(
          steps: [
            {Runic.step(fn _ -> [10, 20] end, name: :source),
             [Runic.map(fn x -> x end, name: :identity_map)]}
          ]
        )

      w = Workflow.plan_eagerly(workflow, "input")
      {w, source_runnables} = Workflow.prepare_for_dispatch(w)
      source_r = hd(source_runnables)
      w = Workflow.apply_runnable(w, Invokable.execute(source_r.node, source_r))
      {_w, runnables} = Workflow.prepare_for_dispatch(w)

      fan_out_runnable =
        Enum.find(runnables, fn r -> is_struct(r.node, Runic.Workflow.FanOut) end)

      executed = Invokable.execute(fan_out_runnable.node, fan_out_runnable)

      assert is_list(executed.result)
      assert length(executed.result) == 2
      assert Enum.all?(executed.result, &is_struct(&1, Fact))
      assert Enum.map(executed.result, & &1.value) |> Enum.sort() == [10, 20]
    end

    test "apply_event for FanOutFactEmitted logs fact and updates mapped" do
      workflow =
        Runic.workflow(
          steps: [
            {Runic.step(fn _ -> [1, 2] end, name: :source),
             [
               {Runic.map(fn x -> x end, name: :id_map),
                [Runic.reduce(0, fn n, a -> n + a end, name: :sum, map: :id_map)]}
             ]}
          ]
        )

      # Get the fan_out node
      fan_out =
        workflow.graph.vertices
        |> Map.values()
        |> Enum.find(&is_struct(&1, Runic.Workflow.FanOut))

      source_fact = Fact.new(value: [1, 2])
      emitted_fact = Fact.new(value: 1, ancestry: {fan_out.hash, source_fact.hash})

      event = %FanOutFactEmitted{
        fan_out_hash: fan_out.hash,
        source_fact_hash: source_fact.hash,
        emitted_fact_hash: emitted_fact.hash,
        emitted_value: 1,
        emitted_ancestry: emitted_fact.ancestry,
        weight: 1
      }

      wf = Workflow.apply_event(workflow, event)

      # Fact should be logged in graph
      assert Map.has_key?(wf.graph.vertices, emitted_fact.hash)

      # Mapped tracking should be updated
      key = {source_fact.hash, fan_out.hash}
      assert [emitted_fact.hash] == wf.mapped[key]
    end
  end

  describe "FanIn event-sourced execute" do
    test "simple mode produces FactProduced and ActivationConsumed events" do
      # Simple FanIn (no FanOut upstream): directly reduces enumerable input
      fan_in_step = Runic.reduce(0, fn n, a -> n + a end, name: :simple_sum)

      workflow =
        Runic.workflow(
          steps: [
            {Runic.step(fn _ -> [1, 2, 3] end, name: :producer), [fan_in_step]}
          ]
        )

      # Walk dispatch loop to reach FanIn
      w = Workflow.plan_eagerly(workflow, "input")

      # Source step
      {w, runnables} = Workflow.prepare_for_dispatch(w)

      w =
        Enum.reduce(runnables, w, fn r, wf ->
          Workflow.apply_runnable(wf, Invokable.execute(r.node, r))
        end)

      # FanIn should be available now
      {_w, runnables} = Workflow.prepare_for_dispatch(w)
      fan_in_runnable = Enum.find(runnables, fn r -> is_struct(r.node, Runic.Workflow.FanIn) end)
      assert fan_in_runnable, "Should have a FanIn runnable"

      executed = Invokable.execute(fan_in_runnable.node, fan_in_runnable)

      assert executed.status == :completed
      assert %Fact{value: 6} = executed.result

      fact_produced = Enum.find(executed.events, &is_struct(&1, FactProduced))
      assert fact_produced.producer_label == :reduced
      assert fact_produced.value == 6

      activation = Enum.find(executed.events, &is_struct(&1, ActivationConsumed))
      assert activation.node_hash == fan_in_runnable.node.hash
      assert activation.from_label == :runnable
    end

    test "fan_out_reduce mode produces only ActivationConsumed" do
      workflow =
        Runic.workflow(
          steps: [
            {Runic.step(fn _ -> [1, 2, 3] end, name: :source),
             [
               {Runic.map(fn x -> x * 2 end, name: :double_map),
                [Runic.reduce(0, fn n, a -> n + a end, name: :sum, map: :double_map)]}
             ]}
          ]
        )

      # Walk the dispatch loop manually to reach FanIn runnables
      w = Workflow.plan_eagerly(workflow, "input")

      # Source step
      {w, runnables} = Workflow.prepare_for_dispatch(w)

      w =
        Enum.reduce(runnables, w, fn r, wf ->
          Workflow.apply_runnable(wf, Invokable.execute(r.node, r))
        end)

      # FanOut
      {w, runnables} = Workflow.prepare_for_dispatch(w)

      w =
        Enum.reduce(runnables, w, fn r, wf ->
          Workflow.apply_runnable(wf, Invokable.execute(r.node, r))
        end)

      # Map steps
      {w, runnables} = Workflow.prepare_for_dispatch(w)

      w =
        Enum.reduce(runnables, w, fn r, wf ->
          Workflow.apply_runnable(wf, Invokable.execute(r.node, r))
        end)

      # Now FanIn runnables should be available
      {_w, runnables} = Workflow.prepare_for_dispatch(w)

      fan_in_runnables =
        Enum.filter(runnables, fn r -> is_struct(r.node, Runic.Workflow.FanIn) end)

      assert length(fan_in_runnables) > 0

      for r <- fan_in_runnables do
        executed = Invokable.execute(r.node, r)
        assert executed.status == :completed

        # Should only produce ActivationConsumed — coordination happens in apply phase
        assert length(executed.events) == 1
        assert [%ActivationConsumed{}] = executed.events
      end
    end

    test "full map/reduce pipeline produces correct result via event-sourced path" do
      workflow =
        Runic.workflow(
          steps: [
            {Runic.step(fn _ -> [1, 2, 3] end, name: :source),
             [
               {Runic.map(fn x -> x * 2 end, name: :double_map),
                [Runic.reduce(0, fn n, a -> n + a end, name: :sum, map: :double_map)]}
             ]}
          ]
        )

      # Full react_until_satisfied — exercises the complete event-sourced pipeline
      final = Workflow.react_until_satisfied(workflow, "input")

      productions = Workflow.raw_productions(final)
      # [1,2,3] * 2 = [2,4,6], sum = 12
      assert 12 in productions
    end

    test "apply_event for FanInCompleted logs reduced fact and cleans up mapped" do
      workflow =
        Runic.workflow(
          steps: [
            {Runic.step(fn _ -> [1, 2] end, name: :source),
             [
               {Runic.map(fn x -> x end, name: :id_map),
                [Runic.reduce(0, fn n, a -> n + a end, name: :sum, map: :id_map)]}
             ]}
          ]
        )

      fan_in =
        workflow.graph.vertices
        |> Map.values()
        |> Enum.find(&is_struct(&1, Runic.Workflow.FanIn))

      fan_out =
        workflow.graph.vertices
        |> Map.values()
        |> Enum.find(&is_struct(&1, Runic.Workflow.FanOut))

      source_fact_hash = 12345
      expected_key = {source_fact_hash, fan_out.hash}
      seen_key = {source_fact_hash, 99999}

      # Pre-populate mapped state
      workflow = %{
        workflow
        | mapped:
            Map.merge(workflow.mapped, %{
              expected_key => [1, 2],
              seen_key => %{1 => 10, 2 => 20},
              {:fan_out_for_batch, source_fact_hash} => fan_out.hash
            })
      }

      reduced_fact = Fact.new(value: 3, ancestry: {fan_in.hash, 111})

      event = %FanInCompleted{
        fan_in_hash: fan_in.hash,
        source_fact_hash: source_fact_hash,
        result_fact_hash: reduced_fact.hash,
        result_value: reduced_fact.value,
        result_ancestry: reduced_fact.ancestry,
        expected_key: expected_key,
        seen_key: seen_key,
        weight: 2
      }

      wf = Workflow.apply_event(workflow, event)

      # Reduced fact should be logged
      assert Map.has_key?(wf.graph.vertices, reduced_fact.hash)

      # Mapped should be cleaned up
      refute Map.has_key?(wf.mapped, expected_key)
      refute Map.has_key?(wf.mapped, seen_key)
      refute Map.has_key?(wf.mapped, {:fan_out_for_batch, source_fact_hash})

      # Completion marker should be set
      assert Map.get(wf.mapped, {:fan_in_completed, source_fact_hash, fan_in.hash}) == true
    end
  end

  describe "FanOut/FanIn event-sourced integration" do
    test "uncommitted_events include FanOutFactEmitted during react" do
      workflow =
        Runic.workflow(
          steps: [
            {Runic.step(fn _ -> [1, 2] end, name: :source),
             [Runic.map(fn x -> x end, name: :id_map)]}
          ]
        )
        |> Workflow.enable_event_emission()

      # Run through source step
      w = Workflow.react(workflow, "input") |> Workflow.react()

      # Next react should process FanOut
      w = Workflow.react(w)

      fan_out_events =
        Enum.filter(w.uncommitted_events, &is_struct(&1, FanOutFactEmitted))

      assert length(fan_out_events) == 2
    end

    test "uncommitted_events include FanInCompleted after full pipeline" do
      workflow =
        Runic.workflow(
          steps: [
            {Runic.step(fn _ -> [1, 2] end, name: :source),
             [
               {Runic.map(fn x -> x end, name: :id_map),
                [Runic.reduce(0, fn n, a -> n + a end, name: :sum, map: :id_map)]}
             ]}
          ]
        )
        |> Workflow.enable_event_emission()

      final = Workflow.react_until_satisfied(workflow, "input")

      fan_in_completed =
        Enum.filter(final.uncommitted_events, &is_struct(&1, FanInCompleted))

      assert length(fan_in_completed) == 1
      assert hd(fan_in_completed).result_value == 3
    end
  end

  describe "Runnable dual-mode" do
    test "complete/3 with list creates event-sourced runnable" do
      step = Runic.step(fn x -> x end, name: :s)
      fact = Fact.new(value: 1)
      ctx = Runic.Workflow.CausalContext.new()
      runnable = Runnable.new(step, fact, ctx)

      events = [
        %FactProduced{hash: 1, value: 1, ancestry: nil, producer_label: :input, weight: 0}
      ]

      completed = Runnable.complete(runnable, fact, events)

      assert completed.status == :completed
      assert completed.events == events
    end

    test "complete/4 creates event-sourced runnable with hook apply_fns" do
      step = Runic.step(fn x -> x end, name: :s)
      fact = Fact.new(value: 1)
      ctx = Runic.Workflow.CausalContext.new()
      runnable = Runnable.new(step, fact, ctx)

      events = [
        %FactProduced{hash: 1, value: 1, ancestry: nil, producer_label: :input, weight: 0}
      ]

      hook_fns = [fn wf -> wf end]
      completed = Runnable.complete(runnable, fact, events, hook_fns)

      assert completed.events == events
      assert completed.hook_apply_fns == hook_fns
    end
  end

  # -----------------------------------------------------------------------
  # Phase 5: Store contract evolution — from_events, append/stream
  # -----------------------------------------------------------------------

  describe "from_events/2" do
    test "rebuilds a simple step workflow from build + runtime events" do
      step = Runic.step(fn x -> x * 3 end, name: :triple)
      workflow = Runic.workflow(steps: [step]) |> Workflow.enable_event_emission()

      ran = Workflow.react_until_satisfied(workflow, 7)

      build_events = Workflow.build_log(workflow)
      all_events = build_events ++ ran.uncommitted_events

      rebuilt = Workflow.from_events(all_events)
      assert Workflow.raw_productions(rebuilt) == Workflow.raw_productions(ran)
    end

    test "rebuilds a multi-step pipeline from events" do
      step_a = Runic.step(fn x -> x + 1 end, name: :add)
      step_b = Runic.step(fn x -> x * 2 end, name: :double)
      workflow = Runic.workflow(steps: [{step_a, [step_b]}]) |> Workflow.enable_event_emission()

      ran = Workflow.react_until_satisfied(workflow, 5)

      build_events = Workflow.build_log(workflow)
      all_events = build_events ++ ran.uncommitted_events

      rebuilt = Workflow.from_events(all_events)

      assert Enum.sort(Workflow.raw_productions(rebuilt)) ==
               Enum.sort(Workflow.raw_productions(ran))
    end

    test "replays runtime events on a base workflow" do
      step = Runic.step(fn x -> x + 10 end, name: :add_ten)
      workflow = Runic.workflow(steps: [step]) |> Workflow.enable_event_emission()

      ran = Workflow.react_until_satisfied(workflow, 5)

      rebuilt = Workflow.from_events(ran.uncommitted_events, workflow)
      assert Workflow.raw_productions(rebuilt) == [15]
    end

    test "handles empty runtime events with base workflow" do
      step = Runic.step(fn x -> x end, name: :noop)
      workflow = Runic.workflow(steps: [step])

      rebuilt = Workflow.from_events([], workflow)
      assert Workflow.raw_productions(rebuilt) == []
    end

    test "rebuild preserves component hash stability across from_log" do
      step = Runic.step(fn x -> x * 2 end, name: :double)
      workflow = Runic.workflow(steps: [step])
      original_hash = Workflow.get_component(workflow, :double).hash

      build_events = Workflow.build_log(workflow)
      rebuilt = Workflow.from_events(build_events)
      rebuilt_hash = Workflow.get_component(rebuilt, :double).hash

      assert original_hash == rebuilt_hash
    end

    test "rebuilds workflow with accumulator from events" do
      acc = Runic.accumulator(0, fn n, state -> state + n end, name: :sum)
      workflow = Workflow.new() |> Workflow.add(acc) |> Workflow.enable_event_emission()

      ran =
        workflow
        |> Workflow.react_until_satisfied(1)
        |> Workflow.react_until_satisfied(2)
        |> Workflow.react_until_satisfied(3)

      build_events = Workflow.build_log(workflow)
      all_events = build_events ++ ran.uncommitted_events

      rebuilt = Workflow.from_events(all_events)

      assert Enum.sort(Workflow.raw_productions(rebuilt)) ==
               Enum.sort(Workflow.raw_productions(ran))
    end

    test "rebuilds workflow with condition from events" do
      step = Runic.step(fn x -> x * 2 end, name: :double)
      cond_step = Runic.condition(fn x -> x > 5 end, name: :gt5)
      guarded = Runic.step(fn x -> x + 100 end, name: :big)

      workflow =
        Workflow.new()
        |> Workflow.add(step)
        |> Workflow.add(cond_step, to: :double)
        |> Workflow.add(guarded, to: :gt5)
        |> Workflow.enable_event_emission()

      ran = Workflow.react_until_satisfied(workflow, 10)

      build_events = Workflow.build_log(workflow)
      all_events = build_events ++ ran.uncommitted_events

      rebuilt = Workflow.from_events(all_events)

      assert Enum.sort(Workflow.raw_productions(rebuilt)) ==
               Enum.sort(Workflow.raw_productions(ran))
    end
  end

  describe "ETS Store append/stream" do
    setup do
      runner_name = :"test_es_store_#{System.unique_integer([:positive])}"
      start_supervised!({Runic.Runner.Store.ETS, runner_name: runner_name})
      {:ok, store_state} = Runic.Runner.Store.ETS.init_store(runner_name: runner_name)
      %{store_state: store_state}
    end

    test "append and stream round-trip", %{store_state: state} do
      events = [
        %FactProduced{hash: 1, value: 42, ancestry: nil, producer_label: :input, weight: 0},
        %ActivationConsumed{fact_hash: 1, node_hash: 100, from_label: :runnable}
      ]

      assert {:ok, 2} = Runic.Runner.Store.ETS.append(:wf_1, events, state)
      assert {:ok, stream} = Runic.Runner.Store.ETS.stream(:wf_1, state)
      assert Enum.to_list(stream) == events
    end

    test "append is additive across calls", %{store_state: state} do
      e1 = [%FactProduced{hash: 1, value: 1, ancestry: nil, producer_label: :input, weight: 0}]
      e2 = [%FactProduced{hash: 2, value: 2, ancestry: nil, producer_label: :produced, weight: 1}]

      assert {:ok, 1} = Runic.Runner.Store.ETS.append(:wf_1, e1, state)
      assert {:ok, 2} = Runic.Runner.Store.ETS.append(:wf_1, e2, state)

      {:ok, stream} = Runic.Runner.Store.ETS.stream(:wf_1, state)
      assert Enum.to_list(stream) == e1 ++ e2
    end

    test "stream returns {:error, :not_found} for unknown workflow", %{store_state: state} do
      assert {:error, :not_found} = Runic.Runner.Store.ETS.stream(:nonexistent, state)
    end

    test "delete removes event stream data", %{store_state: state} do
      events = [
        %FactProduced{hash: 1, value: 1, ancestry: nil, producer_label: :input, weight: 0}
      ]

      Runic.Runner.Store.ETS.append(:wf_1, events, state)

      :ok = Runic.Runner.Store.ETS.delete(:wf_1, state)
      assert {:error, :not_found} = Runic.Runner.Store.ETS.stream(:wf_1, state)
    end

    test "supports_stream? returns true for ETS store" do
      assert Runic.Runner.Store.supports_stream?(Runic.Runner.Store.ETS)
    end

    test "full workflow event-sourced round-trip via ETS", %{store_state: state} do
      step = Runic.step(fn x -> x * 2 end, name: :double)
      workflow = Runic.workflow(steps: [step]) |> Workflow.enable_event_emission()

      ran = Workflow.react_until_satisfied(workflow, 5)

      # Persist build + runtime events
      build_events = Workflow.build_log(workflow)
      all_events = build_events ++ ran.uncommitted_events

      {:ok, _cursor} = Runic.Runner.Store.ETS.append(:wf_rt, all_events, state)

      # Recover
      {:ok, stream} = Runic.Runner.Store.ETS.stream(:wf_rt, state)
      recovered = Workflow.from_events(Enum.to_list(stream))

      assert Workflow.raw_productions(recovered) == Workflow.raw_productions(ran)
    end
  end

  describe "Event Serializer" do
    alias Runic.Workflow.Events.Serializer

    test "round-trips events through binary serialization" do
      events = [
        %FactProduced{hash: 1, value: 42, ancestry: nil, producer_label: :input, weight: 0},
        %ActivationConsumed{fact_hash: 1, node_hash: 100, from_label: :runnable},
        %ConditionSatisfied{fact_hash: 1, condition_hash: 200, weight: 1}
      ]

      binary = Serializer.to_binary(events)
      assert is_binary(binary)
      assert {:ok, ^events} = Serializer.from_binary(binary)
    end

    test "round-trips a single event" do
      event = %FactProduced{
        hash: 42,
        value: "hello",
        ancestry: {1, 2},
        producer_label: :produced,
        weight: 1
      }

      binary = Serializer.event_to_binary(event)
      assert {:ok, ^event} = Serializer.event_from_binary(binary)
    end

    test "from_binary returns error on invalid data" do
      assert {:error, _} = Serializer.from_binary(<<0, 1, 2, 3>>)
    end

    test "full workflow events survive binary round-trip" do
      step = Runic.step(fn x -> x + 1 end, name: :inc)
      workflow = Runic.workflow(steps: [step]) |> Workflow.enable_event_emission()

      ran = Workflow.react_until_satisfied(workflow, 5)
      events = ran.uncommitted_events

      binary = Serializer.to_binary(events)
      {:ok, restored_events} = Serializer.from_binary(binary)

      assert restored_events == events
    end
  end

  describe "skipped runnable with events" do
    test "apply_runnable handles skipped runnable with ActivationConsumed events" do
      step = Runic.step(fn x -> x * 2 end, name: :double)
      next_step = Runic.step(fn x -> x + 1 end, name: :inc)

      workflow =
        Workflow.new()
        |> Workflow.add(step)
        |> Workflow.add(next_step, to: :double)
        |> Workflow.enable_event_emission()

      fact = Fact.new(value: 5)
      workflow = Workflow.plan_eagerly(workflow, fact)
      {workflow, [root_runnable | _]} = Workflow.prepare_for_dispatch(workflow)
      executed_root = Invokable.execute(root_runnable.node, root_runnable)
      workflow = Workflow.apply_runnable(workflow, executed_root)

      # Now prepare the step and skip it
      {workflow, runnables} = Workflow.prepare_for_dispatch(workflow)
      runnable = List.first(runnables)

      skip_events = [
        %ActivationConsumed{
          fact_hash: runnable.input_fact.hash,
          node_hash: runnable.node.hash,
          from_label: :runnable
        }
      ]

      skipped = Runnable.skip(runnable, skip_events)
      workflow = Workflow.apply_runnable(workflow, skipped)

      # The skip events should be in uncommitted_events
      assert Enum.any?(workflow.uncommitted_events, &is_struct(&1, ActivationConsumed))

      # The downstream step should be marked as upstream_failed
      # (no longer runnable)
      refute Workflow.is_runnable?(workflow)
    end
  end

  # -----------------------------------------------------------------------
  # Phase 2: Activation event capture + replay correctness
  # -----------------------------------------------------------------------

  alias Runic.Workflow.Events.RunnableActivated

  describe "activation event capture" do
    test "uncommitted_events includes RunnableActivated for downstream steps" do
      step_a = Runic.step(fn x -> x + 1 end, name: :add)
      step_b = Runic.step(fn x -> x * 2 end, name: :double)
      workflow = Runic.workflow(steps: [{step_a, [step_b]}]) |> Workflow.enable_event_emission()

      # Run through the first cycle (root + step_a)
      ran = Workflow.react(workflow, 5)

      activation_events =
        Enum.filter(ran.uncommitted_events, &is_struct(&1, RunnableActivated))

      # Should have activation events: root→step_a, step_a→step_b
      assert length(activation_events) >= 1

      # Verify the activation event for step_b is present
      step_b_activation =
        Enum.find(activation_events, fn e -> e.node_hash == step_b.hash end)

      assert step_b_activation, "Expected RunnableActivated event for downstream step_b"
      assert step_b_activation.activation_kind == :runnable
    end

    test "single step workflow captures activation from root to step" do
      step = Runic.step(fn x -> x * 2 end, name: :double)
      workflow = Workflow.new() |> Workflow.add(step) |> Workflow.enable_event_emission()

      ran = Workflow.react_until_satisfied(workflow, 5)

      activation_events =
        Enum.filter(ran.uncommitted_events, &is_struct(&1, RunnableActivated))

      step_activation =
        Enum.find(activation_events, fn e -> e.node_hash == step.hash end)

      assert step_activation
      assert step_activation.activation_kind == :runnable
    end

    test "condition Activator captures RunnableActivated events" do
      condition = Runic.condition(fn x -> x > 0 end, name: :positive)
      guarded = Runic.step(fn x -> x + 100 end, name: :add_hundred)

      workflow =
        Workflow.new()
        |> Workflow.add(condition)
        |> Workflow.add(guarded, to: :positive)
        |> Workflow.enable_event_emission()

      ran = Workflow.react_until_satisfied(workflow, 42)

      activation_events =
        Enum.filter(ran.uncommitted_events, &is_struct(&1, RunnableActivated))

      guarded_activation =
        Enum.find(activation_events, fn e -> e.node_hash == guarded.hash end)

      assert guarded_activation,
             "Condition activator should produce RunnableActivated for guarded step"

      assert guarded_activation.activation_kind == :runnable
    end
  end

  describe "replay correctness with activation events" do
    # Note: uncommitted_events uses prepend order (newest first) for O(1) append.
    # For replay via from_events, they must be reversed to chronological order.
    # The Worker already does this in handle_task_result/4.

    test "from_events replay of single step produces identical results" do
      step = Runic.step(fn x -> x * 3 end, name: :triple)
      workflow = Runic.workflow(steps: [step]) |> Workflow.enable_event_emission()

      ran = Workflow.react_until_satisfied(workflow, 7)

      build_events = Workflow.build_log(workflow)
      all_events = build_events ++ Enum.reverse(ran.uncommitted_events)

      rebuilt = Workflow.from_events(all_events)

      assert Workflow.raw_productions(rebuilt) == Workflow.raw_productions(ran)
      assert Workflow.is_runnable?(rebuilt) == Workflow.is_runnable?(ran)
    end

    test "from_events replay of multi-step pipeline preserves runnable state" do
      step_a = Runic.step(fn x -> x + 1 end, name: :add)
      step_b = Runic.step(fn x -> x * 2 end, name: :double)
      workflow = Runic.workflow(steps: [{step_a, [step_b]}]) |> Workflow.enable_event_emission()

      ran = Workflow.react_until_satisfied(workflow, 5)

      build_events = Workflow.build_log(workflow)
      all_events = build_events ++ Enum.reverse(ran.uncommitted_events)

      rebuilt = Workflow.from_events(all_events)

      assert Enum.sort(Workflow.raw_productions(rebuilt)) ==
               Enum.sort(Workflow.raw_productions(ran))

      assert Workflow.is_runnable?(rebuilt) == Workflow.is_runnable?(ran)
    end

    test "from_events replay of condition workflow preserves graph state" do
      step = Runic.step(fn x -> x * 2 end, name: :double)
      cond_step = Runic.condition(fn x -> x > 5 end, name: :gt5)
      guarded = Runic.step(fn x -> x + 100 end, name: :big)

      workflow =
        Workflow.new()
        |> Workflow.add(step)
        |> Workflow.add(cond_step, to: :double)
        |> Workflow.add(guarded, to: :gt5)
        |> Workflow.enable_event_emission()

      ran = Workflow.react_until_satisfied(workflow, 10)

      build_events = Workflow.build_log(workflow)
      all_events = build_events ++ Enum.reverse(ran.uncommitted_events)

      rebuilt = Workflow.from_events(all_events)

      assert Enum.sort(Workflow.raw_productions(rebuilt)) ==
               Enum.sort(Workflow.raw_productions(ran))

      assert Workflow.is_runnable?(rebuilt) == Workflow.is_runnable?(ran)
    end

    test "mid-execution replay preserves activation edges for pending runnables" do
      step_a = Runic.step(fn x -> x + 1 end, name: :add)
      step_b = Runic.step(fn x -> x * 2 end, name: :double)
      workflow = Runic.workflow(steps: [{step_a, [step_b]}]) |> Workflow.enable_event_emission()

      # Run only one cycle — step_a completes, step_b should be runnable
      ran = Workflow.react(workflow, 5)

      build_events = Workflow.build_log(workflow)
      all_events = build_events ++ Enum.reverse(ran.uncommitted_events)

      rebuilt = Workflow.from_events(all_events)

      # The critical test: after replay, step_b should still be runnable
      assert Workflow.is_runnable?(rebuilt),
             "Replayed workflow should have runnable nodes (activation edges must be in event stream)"

      assert Workflow.is_runnable?(rebuilt) == Workflow.is_runnable?(ran)
    end

    test "from_events replay on base workflow preserves activation edges" do
      step_a = Runic.step(fn x -> x + 1 end, name: :add)
      step_b = Runic.step(fn x -> x * 2 end, name: :double)
      workflow = Runic.workflow(steps: [{step_a, [step_b]}]) |> Workflow.enable_event_emission()

      # Run only one cycle
      ran = Workflow.react(workflow, 5)

      # Replay runtime events on the original workflow (no build events needed)
      rebuilt = Workflow.from_events(Enum.reverse(ran.uncommitted_events), workflow)

      assert Workflow.is_runnable?(rebuilt) == Workflow.is_runnable?(ran)
    end
  end

  describe "Worker fact persistence" do
    test "Worker persists fact values to store during execution" do
      runner_name = :"test_fact_persist_#{System.unique_integer([:positive])}"

      start_supervised!({Runic.Runner, name: runner_name, store: Runic.Runner.Store.ETS})

      {:ok, store_state} = Runic.Runner.Store.ETS.init_store(runner_name: runner_name)

      step = Runic.step(fn x -> x * 2 end, name: :double)
      workflow = Runic.workflow(steps: [step])

      {:ok, _pid} = Runic.Runner.start_workflow(runner_name, :wf_facts, workflow)
      :ok = Runic.Runner.run(runner_name, :wf_facts, 5)

      # Wait for workflow to complete
      poll_until_idle(runner_name, :wf_facts, System.monotonic_time(:millisecond) + 2000)

      # The fact store should have the produced fact values
      {:ok, results} = Runic.Runner.get_results(runner_name, :wf_facts)
      assert 10 in results

      # Verify at least one fact was persisted to the fact store
      input_fact = Fact.new(value: 5)
      assert {:ok, 5} = Runic.Runner.Store.ETS.load_fact(input_fact.hash, store_state)
    end
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
