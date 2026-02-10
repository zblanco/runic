defmodule RunicMetaAPITest do
  @moduledoc """
  Tests for Runic meta-API functions like state_of/1, step_ran?/1, etc.

  These functions enable rules to reference workflow runtime state such as:
  - Accumulated state of reducers/accumulators
  - Execution history of steps
  - Dynamic workflow composition patterns
  """

  use ExUnit.Case
  require Runic
  alias Runic.Workflow
  alias Runic.Workflow.{Rule, StateCondition, StateReaction, Accumulator, Step}

  describe "state_of/1 in rule conditions" do
    test "creates StateCondition component when used in condition" do
      acc = Runic.accumulator(0, fn x, acc -> x + acc end, name: :counter)

      rule =
        Runic.rule(
          condition: fn fact -> Runic.state_of(:counter) > 5 end,
          reaction: fn _fact -> :threshold_exceeded end,
          name: :threshold_rule
        )

      workflow =
        Workflow.new()
        |> Workflow.add(acc)
        |> Workflow.add(rule)

      # Assert StateCondition component exists in the graph
      state_condition_vertices =
        workflow.graph
        |> Graph.vertices()
        |> Enum.filter(&match?(%StateCondition{}, &1))

      assert length(state_condition_vertices) == 1
      state_condition = hd(state_condition_vertices)
      assert state_condition.state_hash == acc.hash

      # Assert StateCondition is connected to the rule with :component_of edge
      rule_vertex = Graph.vertices(workflow.graph) |> Enum.find(&match?(%Rule{}, &1))

      component_of_edges =
        workflow.graph
        |> Graph.edges(state_condition, rule_vertex)
        |> Enum.filter(&(&1.label == :component_of && &1.kind == :state_condition))

      assert length(component_of_edges) == 1

      # Assert StateCondition references the accumulator with :references_state_of edge
      acc_vertex = Graph.vertices(workflow.graph) |> Enum.find(&match?(%Accumulator{}, &1))

      references_edges =
        workflow.graph
        |> Graph.edges(acc_vertex, state_condition)
        |> Enum.filter(&(&1.label == :references_state_of))

      assert length(references_edges) == 1
    end

    test "evaluates accumulator state correctly during workflow execution" do
      acc = Runic.accumulator(0, fn x, acc -> x + acc end, name: :counter)

      rule =
        Runic.rule(
          condition: fn _fact -> Runic.state_of(:counter) > 10 end,
          reaction: fn _fact -> :triggered end,
          name: :threshold_rule
        )

      workflow =
        Workflow.new()
        |> Workflow.add(acc)
        |> Workflow.add(rule)

      # Feed values that accumulate to <= 10 (should not trigger)
      workflow1 =
        workflow
        |> Workflow.plan_eagerly(3)
        |> Workflow.react_until_satisfied()
        |> Workflow.plan_eagerly(4)
        |> Workflow.react_until_satisfied()

      productions1 = Workflow.raw_productions(workflow1)
      refute :triggered in productions1

      # Feed value that pushes accumulator > 10 (should trigger)
      workflow2 =
        workflow1
        |> Workflow.plan_eagerly(5)
        |> Workflow.react_until_satisfied()

      productions2 = Workflow.raw_productions(workflow2)
      assert :triggered in productions2
    end

    test "pattern matches on accumulator state" do
      acc =
        Runic.accumulator(
          %{status: :pending, count: 0},
          fn event, state ->
            case event do
              :increment -> %{state | count: state.count + 1}
              :complete -> %{state | status: :completed}
              _ -> state
            end
          end,
          name: :state_tracker
        )

      rule =
        Runic.rule(
          condition: fn _fact ->
            match?(
              %{status: :completed, count: count} when count > 2,
              Runic.state_of(:state_tracker)
            )
          end,
          reaction: fn _fact -> :completion_threshold_reached end,
          name: :completion_rule
        )

      workflow =
        Workflow.new()
        |> Workflow.add(acc)
        |> Workflow.add(rule)

      # Increment but don't complete
      workflow1 =
        workflow
        |> Workflow.plan_eagerly(:increment)
        |> Workflow.react_until_satisfied()
        |> Workflow.plan_eagerly(:increment)
        |> Workflow.react_until_satisfied()
        |> Workflow.plan_eagerly(:increment)
        |> Workflow.react_until_satisfied()

      productions1 = Workflow.raw_productions(workflow1)
      refute :completion_threshold_reached in productions1

      # Complete but count only 3
      workflow2 =
        workflow1
        |> Workflow.plan_eagerly(:complete)
        |> Workflow.react_until_satisfied()

      productions2 = Workflow.raw_productions(workflow2)
      assert :completion_threshold_reached in productions2
    end

    test "accesses nested fields in accumulator state" do
      acc =
        Runic.accumulator(
          %{cart: %{items: [], total: 0}, user: %{tier: :basic}},
          fn item, state ->
            %{
              state
              | cart: %{
                  items: [item | state.cart.items],
                  total: state.cart.total + item.price
                }
            }
          end,
          name: :shopping_cart
        )

      rule =
        Runic.rule(
          condition: fn _fact ->
            Runic.state_of(:shopping_cart).cart.total > 100
          end,
          reaction: fn _fact -> :eligible_for_discount end,
          name: :discount_rule
        )

      workflow =
        Workflow.new()
        |> Workflow.add(acc)
        |> Workflow.add(rule)

      workflow1 =
        workflow
        |> Workflow.plan_eagerly(%{name: "Widget", price: 60})
        |> Workflow.react_until_satisfied()

      productions1 = Workflow.raw_productions(workflow1)
      refute :eligible_for_discount in productions1

      workflow2 =
        workflow1
        |> Workflow.plan_eagerly(%{name: "Gadget", price: 50})
        |> Workflow.react_until_satisfied()

      productions2 = Workflow.raw_productions(workflow2)
      assert :eligible_for_discount in productions2
    end

    test "combines state_of with normal fact conditions" do
      acc = Runic.accumulator(0, fn x, acc -> x + acc end, name: :counter)

      rule =
        Runic.rule(
          condition: fn fact ->
            Runic.state_of(:counter) > 5 and is_integer(fact) and fact > 3
          end,
          reaction: fn fact -> {:triggered_for, fact} end,
          name: :combined_rule
        )

      workflow =
        Workflow.new()
        |> Workflow.add(acc)
        |> Workflow.add(rule)

      # Accumulator at 0, feed 2 (fact check fails)
      workflow1 =
        workflow
        |> Workflow.plan_eagerly(2)
        |> Workflow.react_until_satisfied()

      productions1 = Workflow.raw_productions(workflow1)
      refute Enum.any?(productions1, &match?({:triggered_for, _}, &1))

      # Accumulator at 2, feed 4 (state_of check fails: 2 + 4 = 6, but checks before adding)
      workflow2 =
        workflow1
        |> Workflow.plan_eagerly(4)
        |> Workflow.react_until_satisfied()

      # Accumulator at 6, feed 5 (both checks pass: 6 > 5 and 5 > 3)
      workflow3 =
        workflow2
        |> Workflow.plan_eagerly(5)
        |> Workflow.react_until_satisfied()

      productions3 = Workflow.raw_productions(workflow3)
      assert {:triggered_for, 5} in productions3
    end

    test "multiple state_of references in single condition" do
      acc1 = Runic.accumulator(0, fn x, acc -> x + acc end, name: :counter1)
      acc2 = Runic.accumulator(0, fn x, acc -> x + acc end, name: :counter2)

      rule =
        Runic.rule(
          condition: fn _fact ->
            Runic.state_of(:counter1) + Runic.state_of(:counter2) > 10
          end,
          reaction: fn _fact -> :combined_threshold_reached end,
          name: :dual_accumulator_rule
        )

      workflow =
        Workflow.new()
        |> Workflow.add(acc1)
        |> Workflow.add(acc2)
        |> Workflow.add(rule)

      # Verify two StateCondition components created
      state_conditions =
        workflow.graph
        |> Graph.vertices()
        |> Enum.filter(&match?(%StateCondition{}, &1))

      assert length(state_conditions) == 2

      # Verify both have :references_state_of edges
      acc1_vertex =
        Graph.vertices(workflow.graph) |> Enum.find(&match?(%Accumulator{name: :counter1}, &1))

      acc2_vertex =
        Graph.vertices(workflow.graph) |> Enum.find(&match?(%Accumulator{name: :counter2}, &1))

      acc1_refs =
        workflow.graph
        |> Graph.out_edges(acc1_vertex)
        |> Enum.filter(&(&1.label == :references_state_of))

      acc2_refs =
        workflow.graph
        |> Graph.out_edges(acc2_vertex)
        |> Enum.filter(&(&1.label == :references_state_of))

      assert length(acc1_refs) == 1
      assert length(acc2_refs) == 1
    end
  end

  describe "state_of/1 in rule reactions" do
    test "creates StateReaction component when used in reaction" do
      acc = Runic.accumulator(0, fn x, acc -> x + acc end, name: :counter)

      rule =
        Runic.rule(
          condition: fn fact -> is_integer(fact) end,
          reaction: fn fact -> {fact, Runic.state_of(:counter)} end,
          name: :state_reader_rule
        )

      workflow =
        Workflow.new()
        |> Workflow.add(acc)
        |> Workflow.add(rule)

      # Assert StateReaction component exists
      state_reactions =
        workflow.graph
        |> Graph.vertices()
        |> Enum.filter(&match?(%StateReaction{}, &1))

      assert length(state_reactions) == 1
      state_reaction = hd(state_reactions)
      assert state_reaction.state_hash == acc.hash

      # Assert StateReaction is connected to rule with :component_of edge
      rule_vertex = Graph.vertices(workflow.graph) |> Enum.find(&match?(%Rule{}, &1))

      component_of_edges =
        workflow.graph
        |> Graph.edges(state_reaction, rule_vertex)
        |> Enum.filter(&(&1.label == :component_of && &1.kind == :state_reaction))

      assert length(component_of_edges) == 1

      # Assert StateReaction references accumulator with :references_state_of edge
      acc_vertex = Graph.vertices(workflow.graph) |> Enum.find(&match?(%Accumulator{}, &1))

      references_edges =
        workflow.graph
        |> Graph.edges(acc_vertex, state_reaction)
        |> Enum.filter(&(&1.label == :references_state_of))

      assert length(references_edges) == 1
    end

    test "reaction can read and use accumulator state" do
      acc = Runic.accumulator(0, fn x, acc -> x + acc end, name: :counter)

      rule =
        Runic.rule(
          condition: fn fact -> is_integer(fact) end,
          reaction: fn fact -> {fact, Runic.state_of(:counter)} end,
          name: :state_reader
        )

      workflow =
        Workflow.new()
        |> Workflow.add(acc)
        |> Workflow.add(rule)

      workflow1 =
        workflow
        |> Workflow.plan_eagerly(5)
        |> Workflow.react_until_satisfied()
        |> Workflow.plan_eagerly(10)
        |> Workflow.react_until_satisfied()

      productions = Workflow.raw_productions(workflow1)

      # Should have pairs of (fact, accumulated_state)
      # After first fact (5): state = 5
      # After second fact (10): state = 15
      assert {5, 5} in productions
      assert {10, 15} in productions
    end

    test "reaction uses state_of multiple times" do
      acc1 = Runic.accumulator(0, fn x, acc -> x + acc end, name: :sum)
      acc2 = Runic.accumulator(1, fn x, acc -> x * acc end, name: :product)

      rule =
        Runic.rule(
          condition: fn fact -> is_integer(fact) end,
          reaction: fn _fact ->
            %{
              sum: Runic.state_of(:sum),
              product: Runic.state_of(:product),
              combined: Runic.state_of(:sum) + Runic.state_of(:product)
            }
          end,
          name: :state_combiner
        )

      workflow =
        Workflow.new()
        |> Workflow.add(acc1)
        |> Workflow.add(acc2)
        |> Workflow.add(rule)

      # Verify multiple StateReaction components
      state_reactions =
        workflow.graph
        |> Graph.vertices()
        |> Enum.filter(&match?(%StateReaction{}, &1))

      # Should have 4 StateReaction instances (one for each state_of call)
      assert length(state_reactions) == 4
    end
  end

  describe "state_of/1 in both condition and reaction" do
    test "creates both StateCondition and StateReaction components" do
      acc = Runic.accumulator(0, fn x, acc -> x + acc end, name: :counter)

      rule =
        Runic.rule(
          condition: fn _fact -> Runic.state_of(:counter) > 5 end,
          reaction: fn _fact -> {:current_state, Runic.state_of(:counter)} end,
          name: :dual_state_rule
        )

      workflow =
        Workflow.new()
        |> Workflow.add(acc)
        |> Workflow.add(rule)

      state_conditions =
        workflow.graph
        |> Graph.vertices()
        |> Enum.filter(&match?(%StateCondition{}, &1))

      state_reactions =
        workflow.graph
        |> Graph.vertices()
        |> Enum.filter(&match?(%StateReaction{}, &1))

      assert length(state_conditions) == 1
      assert length(state_reactions) == 1
    end

    test "condition and reaction see consistent state" do
      acc = Runic.accumulator(0, fn x, acc -> x + acc end, name: :counter)

      rule =
        Runic.rule(
          condition: fn _fact -> Runic.state_of(:counter) >= 10 end,
          reaction: fn fact -> {fact, :state_was, Runic.state_of(:counter)} end,
          name: :state_snapshot
        )

      workflow =
        Workflow.new()
        |> Workflow.add(acc)
        |> Workflow.add(rule)

      workflow1 =
        workflow
        |> Workflow.plan_eagerly(10)
        |> Workflow.react_until_satisfied()

      productions = Workflow.raw_productions(workflow1)
      assert {10, :state_was, 10} in productions
    end
  end

  describe "state_of/1 with anonymous function rules" do
    test "supports state_of in simple function rule left-hand side" do
      acc = Runic.accumulator(0, fn x, acc -> x + acc end, name: :counter)

      # Anonymous function where guard acts as condition
      rule =
        Runic.rule(fn _fact when Runic.state_of(:counter) > 5 ->
          :triggered
        end)

      workflow =
        Workflow.new()
        |> Workflow.add(acc)
        |> Workflow.add(rule)

      state_conditions =
        workflow.graph
        |> Graph.vertices()
        |> Enum.filter(&match?(%StateCondition{}, &1))

      assert length(state_conditions) == 1
    end

    test "supports state_of in function body (right-hand side)" do
      acc = Runic.accumulator(0, fn x, acc -> x + acc end, name: :counter)

      rule =
        Runic.rule(fn fact when is_integer(fact) ->
          {fact, Runic.state_of(:counter)}
        end)

      workflow =
        Workflow.new()
        |> Workflow.add(acc)
        |> Workflow.add(rule)

      state_reactions =
        workflow.graph
        |> Graph.vertices()
        |> Enum.filter(&match?(%StateReaction{}, &1))

      assert length(state_reactions) == 1
    end

    test "executes correctly with anonymous function rule" do
      acc = Runic.accumulator(0, fn x, acc -> x + acc end, name: :counter)

      rule =
        Runic.rule(fn fact when is_integer(fact) and Runic.state_of(:counter) >= fact ->
          :accumulator_caught_up
        end)

      workflow =
        Workflow.new()
        |> Workflow.add(acc)
        |> Workflow.add(rule)

      # Feed 3, accumulator becomes 3, rule should trigger (3 >= 3)
      workflow1 =
        workflow
        |> Workflow.plan_eagerly(3)
        |> Workflow.react_until_satisfied()

      productions1 = Workflow.raw_productions(workflow1)
      assert :accumulator_caught_up in productions1

      # Feed 10, accumulator becomes 13, rule should trigger (13 >= 10)
      workflow2 =
        workflow1
        |> Workflow.plan_eagerly(10)
        |> Workflow.react_until_satisfied()

      productions2 = Workflow.raw_productions(workflow2)
      # Should appear twice now
      assert Enum.count(productions2, &(&1 == :accumulator_caught_up)) == 2
    end
  end

  describe "state_of/1 with different stateful components" do
    test "references state_machine state" do
      sm =
        Runic.state_machine(
          name: :fsm,
          init: :idle,
          reducer: fn event, state ->
            case {state, event} do
              {:idle, :start} -> :running
              {:running, :stop} -> :stopped
              {s, _} -> s
            end
          end
        )

      rule =
        Runic.rule(
          condition: fn _fact -> Runic.state_of(:fsm) == :running end,
          reaction: fn _fact -> :machine_is_running end,
          name: :state_checker
        )

      workflow =
        Workflow.new()
        |> Workflow.add(sm)
        |> Workflow.add(rule)

      workflow1 =
        workflow
        |> Workflow.plan_eagerly(:start)
        |> Workflow.react_until_satisfied()

      productions = Workflow.raw_productions(workflow1)
      assert :machine_is_running in productions
    end

    test "references reduce component state" do
      reducer =
        Runic.reduce(
          name: :sum_reducer,
          init: 0,
          reducer: fn x, acc -> x + acc end
        )

      rule =
        Runic.rule(
          condition: fn _fact -> Runic.state_of(:sum_reducer) > 20 end,
          reaction: fn _fact -> :sum_exceeded_threshold end,
          name: :reduce_watcher
        )

      workflow =
        Workflow.new()
        |> Workflow.add(reducer)
        |> Workflow.add(rule)

      workflow1 =
        workflow
        |> Workflow.plan_eagerly([5, 10, 8])
        |> Workflow.react_until_satisfied()

      productions = Workflow.raw_productions(workflow1)
      assert :sum_exceeded_threshold in productions
    end
  end

  describe "state_of/1 error handling" do
    test "raises error when referenced component does not exist" do
      rule =
        Runic.rule(
          condition: fn _fact -> Runic.state_of(:nonexistent_component) > 5 end,
          reaction: fn _fact -> :will_not_work end,
          name: :invalid_rule
        )

      workflow = Workflow.new()

      assert_raise RuntimeError, ~r/Component.*nonexistent_component.*not found/, fn ->
        Workflow.add(workflow, rule)
      end
    end

    test "raises error when referenced component is not stateful" do
      step = Runic.step(fn x -> x * 2 end, name: :doubler)

      rule =
        Runic.rule(
          condition: fn _fact -> Runic.state_of(:doubler) > 5 end,
          reaction: fn _fact -> :invalid end,
          name: :invalid_rule
        )

      workflow =
        Workflow.new()
        |> Workflow.add(step)

      assert_raise RuntimeError, ~r/Component.*doubler.*is not stateful/, fn ->
        Workflow.add(workflow, rule)
      end
    end

    test "raises error when component name is ambiguous (multiple components with same name)" do
      acc1 = Runic.accumulator(0, fn x, acc -> x + acc end, name: :counter)
      acc2 = Runic.accumulator(0, fn x, acc -> x + acc end, name: :counter)

      rule =
        Runic.rule(
          condition: fn _fact -> Runic.state_of(:counter) > 5 end,
          reaction: fn _fact -> :ambiguous end,
          name: :ambiguous_rule
        )

      workflow =
        Workflow.new()
        |> Workflow.add(acc1)
        |> Workflow.add(acc2)

      assert_raise RuntimeError, ~r/Multiple components.*counter/, fn ->
        Workflow.add(workflow, rule)
      end
    end

    test "allows state_of with component hash instead of name" do
      acc = Runic.accumulator(0, fn x, acc -> x + acc end, name: :counter)
      hash = acc.hash

      rule =
        Runic.rule(
          condition: fn _fact -> Runic.state_of(^hash) > 5 end,
          reaction: fn _fact -> :hash_based_reference end,
          name: :hash_rule
        )

      workflow =
        Workflow.new()
        |> Workflow.add(acc)
        |> Workflow.add(rule)

      # Should not raise, hash is unambiguous
      assert match?(%Workflow{}, workflow)

      state_conditions =
        workflow.graph
        |> Graph.vertices()
        |> Enum.filter(&match?(%StateCondition{}, &1))

      assert length(state_conditions) == 1
    end
  end

  describe "state_of/1 complex scenarios" do
    test "CQRS event handler pattern: rule triggers based on aggregate state" do
      # Aggregate: accumulates events into state
      order_aggregate =
        Runic.accumulator(
          %{order_id: nil, status: :draft, items: [], total: 0},
          fn event, state ->
            case event do
              {:item_added, item} ->
                %{
                  state
                  | items: [item | state.items],
                    total: state.total + item.price
                }

              {:order_confirmed, order_id} ->
                %{state | status: :confirmed, order_id: order_id}

              _ ->
                state
            end
          end,
          name: :order_aggregate
        )

      # Process manager: issues commands based on aggregate state
      confirmation_rule =
        Runic.rule(
          condition: fn _event ->
            state = Runic.state_of(:order_aggregate)
            state.status == :confirmed and state.total > 100
          end,
          reaction: fn _event ->
            {:send_premium_confirmation, Runic.state_of(:order_aggregate).order_id}
          end,
          name: :premium_order_notification
        )

      workflow =
        Workflow.new()
        |> Workflow.add(order_aggregate)
        |> Workflow.add(confirmation_rule)

      workflow1 =
        workflow
        |> Workflow.plan_eagerly({:item_added, %{name: "Widget", price: 150}})
        |> Workflow.react_until_satisfied()

      productions1 = Workflow.raw_productions(workflow1)
      refute Enum.any?(productions1, &match?({:send_premium_confirmation, _}, &1))

      workflow2 =
        workflow1
        |> Workflow.plan_eagerly({:order_confirmed, "ORDER-123"})
        |> Workflow.react_until_satisfied()

      productions2 = Workflow.raw_productions(workflow2)
      assert {:send_premium_confirmation, "ORDER-123"} in productions2
    end

    test "coordinated multi-accumulator workflow" do
      payment_tracker =
        Runic.accumulator(
          %{confirmed: false, amount: 0},
          fn event, state ->
            case event do
              {:payment_received, amount} -> %{confirmed: true, amount: amount}
              _ -> state
            end
          end,
          name: :payment_state
        )

      inventory_tracker =
        Runic.accumulator(
          %{reserved: false, items: []},
          fn event, state ->
            case event do
              {:inventory_reserved, items} -> %{reserved: true, items: items}
              _ -> state
            end
          end,
          name: :inventory_state
        )

      # Saga coordinator: only create shipment when both payment confirmed and inventory reserved
      shipment_rule =
        Runic.rule(
          condition: fn _event ->
            payment = Runic.state_of(:payment_state)
            inventory = Runic.state_of(:inventory_state)
            payment.confirmed and inventory.reserved
          end,
          reaction: fn _event ->
            payment = Runic.state_of(:payment_state)
            inventory = Runic.state_of(:inventory_state)
            {:create_shipment, payment.amount, inventory.items}
          end,
          name: :saga_coordinator
        )

      workflow =
        Workflow.new()
        |> Workflow.add(payment_tracker)
        |> Workflow.add(inventory_tracker)
        |> Workflow.add(shipment_rule)

      # Payment confirmed but inventory not reserved
      workflow1 =
        workflow
        |> Workflow.plan_eagerly({:payment_received, 100})
        |> Workflow.react_until_satisfied()

      productions1 = Workflow.raw_productions(workflow1)
      refute Enum.any?(productions1, &match?({:create_shipment, _, _}, &1))

      # Now reserve inventory
      workflow2 =
        workflow1
        |> Workflow.plan_eagerly({:inventory_reserved, ["item1", "item2"]})
        |> Workflow.react_until_satisfied()

      productions2 = Workflow.raw_productions(workflow2)
      assert {:create_shipment, 100, ["item1", "item2"]} in productions2
    end

    test "dynamic threshold that changes based on accumulated state" do
      # Accumulator tracks running average
      stats_accumulator =
        Runic.accumulator(
          %{sum: 0, count: 0, avg: 0},
          fn value, state ->
            new_sum = state.sum + value
            new_count = state.count + 1
            %{sum: new_sum, count: new_count, avg: new_sum / new_count}
          end,
          name: :stats
        )

      # Rule triggers when new value is significantly above average
      outlier_detector =
        Runic.rule(
          condition: fn value ->
            is_number(value) and
              Runic.state_of(:stats).count > 0 and
              value > Runic.state_of(:stats).avg * 2
          end,
          reaction: fn value ->
            {:outlier_detected, value, Runic.state_of(:stats).avg}
          end,
          name: :outlier_rule
        )

      workflow =
        Workflow.new()
        |> Workflow.add(stats_accumulator)
        |> Workflow.add(outlier_detector)

      workflow1 =
        workflow
        |> Workflow.plan_eagerly(10)
        |> Workflow.react_until_satisfied()
        |> Workflow.plan_eagerly(12)
        |> Workflow.react_until_satisfied()
        |> Workflow.plan_eagerly(11)
        |> Workflow.react_until_satisfied()

      # avg ≈ 11, feed 30 (30 > 11*2)
      workflow2 =
        workflow1
        |> Workflow.plan_eagerly(30)
        |> Workflow.react_until_satisfied()

      productions = Workflow.raw_productions(workflow2)
      assert Enum.any?(productions, &match?({:outlier_detected, 30, _}, &1))
    end
  end

  describe "state_of/1 graph structure validation" do
    test "verifies correct edge labels and kinds for StateCondition" do
      acc = Runic.accumulator(0, fn x, acc -> x + acc end, name: :counter)

      rule =
        Runic.rule(
          condition: fn _fact -> Runic.state_of(:counter) > 5 end,
          reaction: fn _fact -> :triggered end,
          name: :test_rule
        )

      workflow =
        Workflow.new()
        |> Workflow.add(acc)
        |> Workflow.add(rule)

      state_condition =
        workflow.graph
        |> Graph.vertices()
        |> Enum.find(&match?(%StateCondition{}, &1))

      rule_vertex =
        workflow.graph
        |> Graph.vertices()
        |> Enum.find(&match?(%Rule{name: :test_rule}, &1))

      acc_vertex =
        workflow.graph
        |> Graph.vertices()
        |> Enum.find(&match?(%Accumulator{name: :counter}, &1))

      # Check StateCondition -> Rule edge
      sc_to_rule_edges = Graph.edges(workflow.graph, state_condition, rule_vertex)
      component_of_edge = Enum.find(sc_to_rule_edges, &(&1.label == :component_of))

      assert component_of_edge != nil
      assert component_of_edge.kind == :state_condition

      # Check Accumulator -> StateCondition edge
      acc_to_sc_edges = Graph.edges(workflow.graph, acc_vertex, state_condition)
      references_edge = Enum.find(acc_to_sc_edges, &(&1.label == :references_state_of))

      assert references_edge != nil
    end

    test "verifies correct edge labels and kinds for StateReaction" do
      acc = Runic.accumulator(0, fn x, acc -> x + acc end, name: :counter)

      rule =
        Runic.rule(
          condition: fn fact -> is_integer(fact) end,
          reaction: fn _fact -> Runic.state_of(:counter) end,
          name: :test_rule
        )

      workflow =
        Workflow.new()
        |> Workflow.add(acc)
        |> Workflow.add(rule)

      state_reaction =
        workflow.graph
        |> Graph.vertices()
        |> Enum.find(&match?(%StateReaction{}, &1))

      rule_vertex =
        workflow.graph
        |> Graph.vertices()
        |> Enum.find(&match?(%Rule{name: :test_rule}, &1))

      acc_vertex =
        workflow.graph
        |> Graph.vertices()
        |> Enum.find(&match?(%Accumulator{name: :counter}, &1))

      # Check StateReaction -> Rule edge
      sr_to_rule_edges = Graph.edges(workflow.graph, state_reaction, rule_vertex)
      component_of_edge = Enum.find(sr_to_rule_edges, &(&1.label == :component_of))

      assert component_of_edge != nil
      assert component_of_edge.kind == :state_reaction

      # Check Accumulator -> StateReaction edge
      acc_to_sr_edges = Graph.edges(workflow.graph, acc_vertex, state_reaction)
      references_edge = Enum.find(acc_to_sr_edges, &(&1.label == :references_state_of))

      assert references_edge != nil
    end

    test "complex graph with multiple state references has correct topology" do
      acc1 = Runic.accumulator(0, fn x, acc -> x + acc end, name: :acc1)
      acc2 = Runic.accumulator(0, fn x, acc -> x + acc end, name: :acc2)

      rule =
        Runic.rule(
          condition: fn _fact -> Runic.state_of(:acc1) + Runic.state_of(:acc2) > 10 end,
          reaction: fn _fact -> {Runic.state_of(:acc1), Runic.state_of(:acc2)} end,
          name: :complex_rule
        )

      workflow =
        Workflow.new()
        |> Workflow.add(acc1)
        |> Workflow.add(acc2)
        |> Workflow.add(rule)

      # Should have 2 StateConditions (one for each state_of in condition)
      state_conditions =
        workflow.graph
        |> Graph.vertices()
        |> Enum.filter(&match?(%StateCondition{}, &1))

      assert length(state_conditions) == 2

      # Should have 2 StateReactions (one for each state_of in reaction)
      state_reactions =
        workflow.graph
        |> Graph.vertices()
        |> Enum.filter(&match?(%StateReaction{}, &1))

      assert length(state_reactions) == 2

      # Each StateCondition should reference one of the accumulators
      acc1_vertex =
        Graph.vertices(workflow.graph) |> Enum.find(&match?(%Accumulator{name: :acc1}, &1))

      acc2_vertex =
        Graph.vertices(workflow.graph) |> Enum.find(&match?(%Accumulator{name: :acc2}, &1))

      acc1_state_refs =
        workflow.graph
        |> Graph.out_edges(acc1_vertex)
        |> Enum.filter(&(&1.label == :references_state_of))

      acc2_state_refs =
        workflow.graph
        |> Graph.out_edges(acc2_vertex)
        |> Enum.filter(&(&1.label == :references_state_of))

      # Each accumulator should have 2 references (1 from condition, 1 from reaction)
      assert length(acc1_state_refs) == 2
      assert length(acc2_state_refs) == 2
    end
  end
end
