# defmodule RunicComprehensiveIntegrationTest do
#   @moduledoc """
#   Comprehensive integration tests for the Runic workflow framework.

#   This test suite covers:
#   1. Connecting different component types together
#   2. Input/output contract validation and compatibility
#   3. Multi-generation workflows with varieties of components
#   4. Workflow recovery from logs with many component types
#   5. Error handling and edge cases
#   6. Complex interaction patterns
#   """

#   use ExUnit.Case
#   require Runic
#   alias Runic.Workflow
#   alias Runic.Workflow.{Step, Rule, StateMachine, Accumulator, Condition}

#   # Test helpers for feeding inputs
#   defp feed_sequence(wrk, inputs) when is_list(inputs) do
#     Enum.reduce(inputs, wrk, fn x, acc ->
#       acc |> Workflow.plan_eagerly(x) |> Workflow.react_until_satisfied()
#     end)
#   end

#   defp feed_collection(wrk, coll) do
#     wrk |> Workflow.plan_eagerly(coll) |> Workflow.react_until_satisfied()
#   end

#   describe "connecting different component types" do
#     test "Step -> Rule connection produces expected results" do
#       step = Runic.step(fn x -> x * 2 end, name: :doubler)
#       rule = Runic.rule(fn x when is_integer(x) and x > 5 -> x + 10 end, name: :threshold_rule)

#       workflow =
#         Workflow.new()
#         |> Workflow.add(step)
#         |> Workflow.add(rule, to: step)

#       results =
#         workflow
#         |> Workflow.react_until_satisfied(3)
#         |> Workflow.raw_productions()

#       # 3 * 2 = 6, 6 > 5 so rule produces 6 + 10 = 16
#       assert 6 in results
#       assert 16 in results
#     end

#     test "Rule -> Step connection flows data correctly" do
#       rule = Runic.rule(fn :start -> 42 end, name: :init_rule)
#       step = Runic.step(fn x -> x * 2 end, name: :processor)

#       workflow =
#         Workflow.new()
#         |> Workflow.add(rule)
#         |> Workflow.add(step, to: rule)

#       results =
#         workflow
#         |> Workflow.react_until_satisfied(:start)
#         |> Workflow.raw_productions()

#       assert 42 in results
#       assert 84 in results
#     end

#     test "Step -> StateMachine connection maintains state correctly" do
#       input_step = Runic.step(fn x -> x end, name: :input)

#       state_machine =
#         Runic.state_machine(
#           name: :counter,
#           init: 0,
#           reducer: fn val, state when is_integer(val) -> state + val end
#         )

#       workflow =
#         Workflow.new()
#         |> Workflow.add(input_step)
#         |> Workflow.add(state_machine, to: input_step)

#       # Feed inputs one at a time to test state accumulation
#       results =
#         Enum.reduce([1, 2, 3], workflow, fn input, wrk ->
#           wrk
#           |> Workflow.plan_eagerly(input)
#           |> Workflow.react_until_satisfied()
#         end)
#         |> Workflow.raw_productions()

#       # State accumulates: 0+1=1, 1+2=3, 3+3=6
#       assert 1 in results
#       assert 2 in results
#       assert 3 in results
#       assert 6 in results
#     end

#     test "Map -> Reduce connection processes collections" do
#       mapper = Runic.map(fn x -> x * 2 end, name: :doubler_map)
#       reducer = Runic.reduce(0, fn x, acc -> x + acc end, name: :sum_reduce, map: :doubler_map)

#       workflow =
#         Runic.workflow(name: :map_reduce_workflow)
#         |> Workflow.add(mapper)
#         |> Workflow.add(reducer, to: :doubler_map)

#       results =
#         workflow
#         |> feed_collection([1, 2, 3])
#         |> Workflow.react_until_satisfied()
#         |> Workflow.raw_productions()

#       # [1,2,3] -> map [2,4,6] -> reduce sums to 12
#       # Only assert final reduced value
#       assert 12 in results
#     end

#     test "Rule -> Map connection distributes rule outputs" do
#       rule = Runic.rule(fn :start -> [1, 2, 3] end, name: :list_producer)
#       mapper = Runic.map(fn x -> x * 10 end, name: :multiplier)

#       workflow =
#         Workflow.new()
#         |> Workflow.add(rule)
#         |> Workflow.add(mapper, to: rule)

#       results =
#         workflow
#         |> Workflow.react_until_satisfied(:start)
#         |> Workflow.raw_productions()

#       assert [1, 2, 3] in results
#       assert 10 in results
#       assert 20 in results
#       assert 30 in results
#     end

#     test "Accumulator -> Step connection passes accumulated state" do
#       accumulator = Runic.accumulator(0, fn x, acc -> x + acc end, name: :adder)
#       step = Runic.step(fn x when is_integer(x) -> x * 2 end, name: :doubler)

#       workflow =
#         Workflow.new()
#         |> Workflow.add(accumulator)
#         |> Workflow.add(step, to: :adder)

#       # Feed inputs one at a time
#       results =
#         Enum.reduce([1, 2, 3], workflow, fn input, wrk ->
#           wrk
#           |> Workflow.plan_eagerly(input)
#           |> Workflow.react_until_satisfied()
#         end)
#         |> Workflow.raw_productions()

#       # Accumulated values: 1, 3, 6; doubled: 2, 6, 12
#       assert 1 in results
#       assert 3 in results
#       assert 6 in results
#       assert 2 in results
#       assert 6 in results
#       assert 12 in results
#     end

#     test "chaining Step -> Rule -> StateMachine" do
#       input = Runic.step(fn x -> x * 2 end, name: :input_processor)
#       filter = Runic.rule(fn x when is_integer(x) and x > 5 -> x end, name: :threshold_filter)

#       counter =
#         Runic.state_machine(
#           name: :event_counter,
#           init: 0,
#           reducer: fn _val, count -> count + 1 end
#         )

#       workflow =
#         Workflow.new()
#         |> Workflow.add(input)
#         |> Workflow.add(filter, to: input)
#         |> Workflow.add(counter, to: filter)

#       # Feed inputs one at a time
#       results =
#         Enum.reduce([1, 2, 3, 4, 5], workflow, fn value, wrk ->
#           wrk
#           |> Workflow.plan_eagerly(value)
#           |> Workflow.react_until_satisfied()
#         end)
#         |> Workflow.raw_productions()

#       # Doubled: [2,4,6,8,10], filtered (>5): [6,8,10], counter: [1,2,3]
#       assert 6 in results
#       assert 8 in results
#       assert 10 in results
#       assert 3 in results
#     end
#   end

#   describe "input/output contract validation" do
#     test "components with compatible types can be connected" do
#       # Step produces integer, Rule expects integer
#       step = Runic.step(fn -> 42 end, name: :producer, outputs: [step: [type: :integer]])

#       rule =
#         Runic.rule(fn x when is_integer(x) -> x * 2 end, inputs: [condition: [type: :integer]])

#       assert Runic.Component.connectable?(step, rule)
#     end

#     test "components with :any type are universally compatible" do
#       step1 = Runic.step(fn -> :anything end, outputs: [step: [type: :any]])
#       step2 = Runic.step(fn x -> x end, inputs: [step: [type: :any]])

#       assert Runic.Component.connectable?(step1, step2)
#     end

#     test "Map outputs are compatible with Reduce inputs" do
#       mapper = Runic.map(fn x -> x * 2 end, name: :mapper)
#       reducer = Runic.reduce(0, fn x, acc -> x + acc end, name: :reducer, map: :mapper)

#       assert Runic.Component.connectable?(mapper, reducer)
#     end

#     test "Rule outputs are compatible with Step inputs" do
#       rule = Runic.rule(fn :trigger -> "output" end)
#       step = Runic.step(fn x -> String.upcase(x) end)

#       assert Runic.Component.connectable?(rule, step)
#     end

#     test "StateMachine is compatible with downstream Steps" do
#       state_machine =
#         Runic.state_machine(
#           name: :sm,
#           init: 0,
#           reducer: fn x, s -> s + x end
#         )

#       step = Runic.step(fn x -> x * 2 end)

#       assert Runic.Component.connectable?(state_machine, step)
#     end
#   end

#   describe "multi-generation workflows with variety of components" do
#     test "complex workflow with 4 generations of different components" do
#       # Generation 1: Input step
#       gen1 = Runic.step(fn x -> x end, name: :gen1_input)

#       # Generation 2: Rule that filters
#       gen2 = Runic.rule(fn x when is_integer(x) and x > 0 -> x * 2 end, name: :gen2_filter)

#       # Generation 3: StateMachine that accumulates
#       gen3 =
#         Runic.state_machine(
#           name: :gen3_accumulator,
#           init: 0,
#           reducer: fn val, state -> state + val end,
#           reactors: [
#             fn state when state >= 10 -> {:threshold_reached, state} end
#           ]
#         )

#       # Generation 4: Final processing step
#       gen4 = Runic.step(fn {:threshold_reached, val} -> val * 10 end, name: :gen4_amplifier)

#       workflow =
#         Workflow.new(name: :multi_gen_workflow)
#         |> Workflow.add(gen1)
#         |> Workflow.add(gen2, to: gen1)
#         |> Workflow.add(gen3, to: gen2)
#         |> Workflow.add(gen4, to: gen3)

#       results =
#         workflow
#         |> feed_sequence([1, 2, 3])
#         |> Workflow.raw_productions()

#       # 1->2, 2->4, 3->6; accumulator: 2, 6, 12; threshold at 12 -> 120
#       assert {:threshold_reached, 12} in results
#       assert 120 in results
#     end

#     test "parallel processing with multiple Maps and Reduces" do
#       # Map path 1
#       map1 = Runic.map(fn x -> x * 2 end, name: :map1)
#       reduce1 = Runic.reduce(0, fn x, acc -> x + acc end, name: :reduce1, map: :map1)

#       # Map path 2
#       map2 = Runic.map(fn x -> x * 3 end, name: :map2)
#       reduce2 = Runic.reduce(1, fn x, acc -> x * acc end, name: :reduce2, map: :map2)

#       # Join results
#       joiner = Runic.step(fn x when is_integer(x) -> x end, name: :collector)

#       workflow =
#         Workflow.new()
#         |> Workflow.add(map1)
#         |> Workflow.add(reduce1, to: map1)
#         |> Workflow.add(map2)
#         |> Workflow.add(reduce2, to: map2)
#         |> Workflow.add(joiner, to: reduce1)
#         |> Workflow.add(joiner, to: reduce2)

#       results =
#         workflow
#         |> feed_collection([1, 2, 3])
#         |> Workflow.raw_productions()

#       # map1: [2,4,6] -> reduce1: 12
#       # map2: [3,6,9] -> reduce2: 162
#       assert 12 in results
#       assert 162 in results
#     end

#     test "nested workflows with mixed component types" do
#       inner_workflow =
#         Workflow.new(name: :inner)
#         |> Workflow.add(Runic.step(fn x -> x + 1 end, name: :inner_step))

#       outer_rule = Runic.rule(fn x when is_integer(x) -> x * 2 end, name: :outer_rule)

#       workflow =
#         Workflow.new(name: :outer)
#         |> Workflow.add(outer_rule)
#         |> Workflow.add(inner_workflow, to: outer_rule)

#       results =
#         workflow
#         |> Workflow.react_until_satisfied(5)
#         |> Workflow.raw_productions()

#       # 5 * 2 = 10, then 10 + 1 = 11
#       assert 10 in results
#       assert 11 in results
#     end

#     test "workflow with conditional branching using multiple rules" do
#       branch1 =
#         Runic.rule(fn x when is_integer(x) and x < 5 -> {:small, x * 2} end, name: :small_branch)

#       branch2 =
#         Runic.rule(fn x when is_integer(x) and x >= 5 -> {:large, x * 10} end,
#           name: :large_branch
#         )

#       processor1 = Runic.step(fn {:small, x} -> x + 1 end, name: :small_processor)
#       processor2 = Runic.step(fn {:large, x} -> x + 100 end, name: :large_processor)

#       workflow =
#         Workflow.new()
#         |> Workflow.add(branch1)
#         |> Workflow.add(branch2)
#         |> Workflow.add(processor1, to: branch1)
#         |> Workflow.add(processor2, to: branch2)

#       small_results =
#         workflow
#         |> Workflow.react_until_satisfied(3)
#         |> Workflow.raw_productions()

#       assert {:small, 6} in small_results
#       assert 7 in small_results

#       large_results =
#         workflow
#         |> Workflow.react_until_satisfied(10)
#         |> Workflow.raw_productions()

#       assert {:large, 100} in large_results
#       assert 200 in large_results
#     end
#   end

#   describe "workflow recovery from logs with many component types" do
#     test "recovers workflow with Step, Rule, and StateMachine" do
#       step = Runic.step(fn x -> x * 2 end, name: :doubler)
#       rule = Runic.rule(fn x when is_integer(x) -> x + 10 end, name: :adder)

#       state_machine =
#         Runic.state_machine(
#           name: :tracker,
#           init: 0,
#           reducer: fn val, state when is_integer(val) -> state + 1 end
#         )

#       original =
#         Workflow.new(name: :complex)
#         |> Workflow.add(step)
#         |> Workflow.add(rule, to: step)
#         |> Workflow.add(state_machine, to: rule)

#       original_results =
#         original
#         |> feed_sequence([1, 2, 3])
#         |> Workflow.raw_productions()

#       log = Workflow.build_log(original)

#       recovered = Workflow.from_log(log)

#       recovered_results =
#         recovered
#         |> feed_sequence([1, 2, 3])
#         |> Workflow.raw_productions()

#       for result <- original_results do
#         assert result in recovered_results
#       end
#     end

#     test "recovers workflow with Map and Reduce" do
#       mapper = Runic.map(fn x -> x * 3 end, name: :tripler)
#       reducer = Runic.reduce(0, fn x, acc -> x + acc end, name: :summer, map: :tripler)

#       original =
#         Workflow.new(name: :map_reduce_workflow)
#         |> Workflow.add(mapper)
#         |> Workflow.add(reducer, to: mapper)

#       original_results =
#         original
#         |> feed_collection([1, 2, 3, 4])
#         |> Workflow.raw_productions()

#       log = Workflow.build_log(original)
#       recovered = Workflow.from_log(log)

#       recovered_results =
#         recovered
#         |> feed_collection([1, 2, 3, 4])
#         |> Workflow.raw_productions()

#       for result <- original_results do
#         assert result in recovered_results
#       end
#     end

#     test "recovers workflow with Accumulators and bindings" do
#       multiplier = 5

#       acc = Runic.accumulator(0, fn x, state -> x * ^multiplier + state end, name: :custom_acc)
#       step = Runic.step(fn x -> x + 100 end, name: :final_step)

#       original =
#         Workflow.new(name: :accumulator_workflow)
#         |> Workflow.add(acc)
#         |> Workflow.add(step, to: :custom_acc)

#       original_results =
#         original
#         |> feed_sequence([1, 2])
#         |> Workflow.raw_productions()

#       log = Workflow.build_log(original)
#       recovered = Workflow.from_log(log)

#       recovered_results =
#         recovered
#         |> feed_sequence([1, 2])
#         |> Workflow.raw_productions()

#       for result <- original_results do
#         assert result in recovered_results
#       end
#     end

#     test "recovers complex multi-component workflow with all major types" do
#       factor = 2

#       input_step = Runic.step(fn x -> x * ^factor end, name: :input)
#       filter_rule = Runic.rule(fn x when is_integer(x) and x > 5 -> x end, name: :filter)
#       mapper = Runic.map(fn x -> x + 1 end, name: :incrementer)
#       reducer = Runic.reduce(0, fn x, acc -> x + acc end, name: :total, map: :incrementer)

#       accumulator = Runic.accumulator([], fn x, list -> [x | list] end, name: :collector)

#       state_machine =
#         Runic.state_machine(
#           name: :monitor,
#           init: :idle,
#           reducer: fn _val, _state -> :active end
#         )

#       original =
#         Workflow.new(name: :everything)
#         |> Workflow.add(input_step)
#         |> Workflow.add(filter_rule, to: input_step)
#         |> Workflow.add(mapper, to: filter_rule)
#         |> Workflow.add(reducer, to: mapper)
#         |> Workflow.add(accumulator, to: reducer)
#         |> Workflow.add(state_machine, to: accumulator)

#       original_results =
#         original
#         |> feed_sequence([1, 2, 3, 4, 5])
#         |> Workflow.raw_productions()

#       log = Workflow.build_log(original)
#       recovered = Workflow.from_log(log)

#       recovered_results =
#         recovered
#         |> feed_sequence([1, 2, 3, 4, 5])
#         |> Workflow.raw_productions()

#       assert Enum.count(original_results) == Enum.count(recovered_results)

#       for result <- original_results do
#         assert result in recovered_results
#       end
#     end
#   end

#   describe "error handling and edge cases" do
#     test "workflow handles empty input gracefully" do
#       mapper = Runic.map(fn x -> x * 2 end, name: :doubler)

#       workflow = Workflow.new() |> Workflow.add(mapper)

#       results =
#         workflow
#         |> Workflow.plan_eagerly([])
#         |> Workflow.react_until_satisfied()
#         |> Workflow.raw_productions()

#       assert results == []
#     end

#     test "rule with no matching input produces no output" do
#       rule = Runic.rule(fn :specific_atom -> :matched end, name: :strict_rule)

#       workflow = Workflow.new() |> Workflow.add(rule)

#       results =
#         workflow
#         |> Workflow.react_until_satisfied(:different_atom)
#         |> Workflow.raw_productions()

#       refute :matched in results
#     end

#     test "accumulator with zero inputs returns only initial state" do
#       acc = Runic.accumulator(42, fn x, state -> x + state end, name: :acc)

#       workflow = Workflow.new() |> Workflow.add(acc)

#       results =
#         workflow
#         |> feed_sequence([])
#         |> Workflow.raw_productions()

#       assert results == []
#     end

#     test "state machine with no matching clause maintains state" do
#       sm =
#         Runic.state_machine(
#           name: :selective,
#           init: :initial,
#           reducer: fn
#             :valid_input, _state -> :updated
#             _invalid, state -> state
#           end
#         )

#       workflow = Workflow.new() |> Workflow.add(sm)

#       results =
#         workflow
#         |> Workflow.plan_eagerly(:invalid_input)
#         |> Workflow.react_until_satisfied()
#         |> Workflow.raw_productions()

#       assert :initial in results
#     end

#     test "nested maps process correctly" do
#       outer_map = Runic.map(fn list -> list end, name: :outer)
#       inner_map = Runic.map(fn x -> x * 2 end, name: :inner)

#       workflow =
#         Workflow.new()
#         |> Workflow.add(outer_map)
#         |> Workflow.add(inner_map, to: outer_map)

#       results =
#         workflow
#         |> feed_collection([[1, 2], [3, 4]])
#         |> Workflow.raw_productions()

#       assert 2 in results
#       assert 4 in results
#       assert 6 in results
#       assert 8 in results
#     end

#     test "workflow with cyclic-looking structure processes correctly" do
#       # While Runic uses DAGs, we can test that feedback-like patterns work
#       step1 = Runic.step(fn x -> x + 1 end, name: :inc1)
#       step2 = Runic.step(fn x -> x * 2 end, name: :double)
#       step3 = Runic.step(fn x -> x - 1 end, name: :dec)

#       workflow =
#         Workflow.new()
#         |> Workflow.add(step1)
#         |> Workflow.add(step2, to: step1)
#         |> Workflow.add(step3, to: step2)

#       results =
#         workflow
#         |> Workflow.react_until_satisfied(5)
#         |> Workflow.raw_productions()

#       # 5 + 1 = 6, 6 * 2 = 12, 12 - 1 = 11
#       assert 6 in results
#       assert 12 in results
#       assert 11 in results
#     end
#   end

#   describe "complex component interactions" do
#     test "multiple rules feeding into single accumulator" do
#       rule1 = Runic.rule(fn x when is_integer(x) and x < 10 -> x * 2 end, name: :small_multiplier)
#       rule2 = Runic.rule(fn x when is_integer(x) and x >= 10 -> x + 5 end, name: :large_adder)

#       acc = Runic.accumulator(0, fn x, state -> x + state end, name: :collector)

#       workflow =
#         Workflow.new()
#         |> Workflow.add(rule1)
#         |> Workflow.add(rule2)
#         |> Workflow.add(acc, to: rule1)
#         |> Workflow.add(acc, to: rule2)

#       results =
#         workflow
#         |> feed_sequence([5, 15])
#         |> Workflow.raw_productions()

#       # 5 -> rule1 -> 10, 15 -> rule2 -> 20, accumulator: 10, 30
#       assert 10 in results
#       assert 20 in results
#       assert 30 in results
#     end

#     test "state machine with reactors producing into map" do
#       sm =
#         Runic.state_machine(
#           name: :batch_producer,
#           init: [],
#           reducer: fn val, list -> [val | list] end,
#           reactors: [
#             fn list when length(list) >= 3 -> Enum.reverse(list) end
#           ]
#         )

#       mapper = Runic.map(fn x -> x * 10 end, name: :amplifier)

#       workflow =
#         Workflow.new()
#         |> Workflow.add(sm)
#         |> Workflow.add(mapper, to: sm)

#       results =
#         workflow
#         |> feed_sequence([1, 2, 3])
#         |> Workflow.raw_productions()

#       # State: [1], [2,1], [3,2,1] -> reactor fires [1,2,3] -> map [10,20,30]
#       assert 10 in results
#       assert 20 in results
#       assert 30 in results
#     end

#     test "map-reduce chain with intermediate processing" do
#       map1 = Runic.map(fn x -> x * 2 end, name: :map1)
#       reduce1 = Runic.reduce(0, fn x, acc -> x + acc end, name: :reduce1, map: :map1)
#       step = Runic.step(fn x -> x * 100 end, name: :amplify)
#       map2 = Runic.map(fn x -> [x - 1, x, x + 1] end, name: :map2)

#       workflow =
#         Workflow.new()
#         |> Workflow.add(map1)
#         |> Workflow.add(reduce1, to: map1)
#         |> Workflow.add(step, to: reduce1)
#         |> Workflow.add(map2, to: step)

#       results =
#         workflow
#         |> feed_collection([1, 2, 3])
#         |> Workflow.raw_productions()

#       # [1,2,3] -> map1 [2,4,6] -> reduce1 12 -> step 1200 -> map2 [1199,1200,1201]
#       assert 12 in results
#       assert 1200 in results
#       assert 1199 in results
#       assert 1201 in results
#     end

#     test "workflow with multiple accumulators tracking different metrics" do
#       sum_acc = Runic.accumulator(0, fn x, s -> x + s end, name: :sum)
#       count_acc = Runic.accumulator(0, fn _x, s -> s + 1 end, name: :count)
#       product_acc = Runic.accumulator(1, fn x, s -> x * s end, name: :product)

#       input = Runic.step(fn x -> x end, name: :input)

#       workflow =
#         Workflow.new()
#         |> Workflow.add(input)
#         |> Workflow.add(sum_acc, to: input)
#         |> Workflow.add(count_acc, to: input)
#         |> Workflow.add(product_acc, to: input)

#       results =
#         workflow
#         |> feed_sequence([2, 3, 4])
#         |> Workflow.raw_productions()

#       # sum: 2, 5, 9
#       assert 2 in results
#       assert 5 in results
#       assert 9 in results

#       # count: 1, 2, 3
#       assert 1 in results
#       assert 3 in results

#       # product: 2, 6, 24
#       assert 6 in results
#       assert 24 in results
#     end

#     test "deeply nested component composition" do
#       # Level 1
#       l1_step = Runic.step(fn x -> x + 1 end, name: :l1)

#       # Level 2
#       l2_rule = Runic.rule(fn x when is_integer(x) -> x * 2 end, name: :l2)

#       # Level 3
#       l3_map = Runic.map(fn x -> x - 1 end, name: :l3)

#       # Level 4
#       l4_reduce = Runic.reduce(0, fn x, acc -> x + acc end, name: :l4, map: :l3)

#       # Level 5
#       l5_sm =
#         Runic.state_machine(
#           name: :l5,
#           init: :start,
#           reducer: fn _val, _state -> :processed end
#         )

#       workflow =
#         Workflow.new(name: :deeply_nested)
#         |> Workflow.add(l1_step)
#         |> Workflow.add(l2_rule, to: l1_step)
#         |> Workflow.add(l3_map, to: l2_rule)
#         |> Workflow.add(l4_reduce, to: l3_map)
#         |> Workflow.add(l5_sm, to: l4_reduce)

#       results =
#         workflow
#         |> feed_sequence([1, 2, 3])
#         |> Workflow.raw_productions()

#       # [1,2,3] -> l1 [2,3,4] -> l2 [4,6,8] -> l3 [3,5,7] -> l4 15 -> l5 :processed
#       assert 15 in results
#       assert :processed in results
#     end
#   end

#   describe "component protocol compliance" do
#     test "all components implement source/1" do
#       step = Runic.step(fn x -> x end, name: :s)
#       rule = Runic.rule(fn x -> x end, name: :r)
#       mapper = Runic.map(fn x -> x end, name: :m)
#       reducer = Runic.reduce(0, fn x, a -> a end, name: :red, map: :m)
#       acc = Runic.accumulator(0, fn x, a -> a end, name: :a)

#       sm =
#         Runic.state_machine(
#           name: :sm,
#           init: 0,
#           reducer: fn x, s -> s end
#         )

#       for component <- [step, rule, mapper, reducer, acc, sm] do
#         assert Runic.Component.source(component) != nil
#       end
#     end

#     test "all components implement hash/1" do
#       step = Runic.step(fn x -> x end, name: :s)
#       rule = Runic.rule(fn x -> x end, name: :r)
#       mapper = Runic.map(fn x -> x end, name: :m)
#       reducer = Runic.reduce(0, fn x, a -> a end, name: :red, map: :m)
#       acc = Runic.accumulator(0, fn x, a -> a end, name: :a)

#       sm =
#         Runic.state_machine(
#           name: :sm,
#           init: 0,
#           reducer: fn x, s -> s end
#         )

#       for component <- [step, rule, mapper, reducer, acc, sm] do
#         hash = Runic.Component.hash(component)
#         assert is_integer(hash)
#       end
#     end

#     test "all components implement components/1" do
#       step = Runic.step(fn x -> x end, name: :s)
#       rule = Runic.rule(fn x -> x end, name: :r)
#       mapper = Runic.map(fn x -> x end, name: :m)
#       reducer = Runic.reduce(0, fn x, a -> a end, name: :red, map: :m)
#       acc = Runic.accumulator(0, fn x, a -> a end, name: :a)

#       sm =
#         Runic.state_machine(
#           name: :sm,
#           init: 0,
#           reducer: fn x, s -> s end
#         )

#       for component <- [step, rule, mapper, reducer, acc, sm] do
#         components = Runic.Component.components(component)
#         assert is_list(components)
#       end
#     end

#     test "all components implement inputs/1 and outputs/1" do
#       step = Runic.step(fn x -> x end, name: :s)
#       rule = Runic.rule(fn x -> x end, name: :r)
#       mapper = Runic.map(fn x -> x end, name: :m)
#       reducer = Runic.reduce(0, fn x, a -> a end, name: :red, map: :m)
#       acc = Runic.accumulator(0, fn x, a -> a end, name: :a)

#       sm =
#         Runic.state_machine(
#           name: :sm,
#           init: 0,
#           reducer: fn x, s -> s end
#         )

#       for component <- [step, rule, mapper, reducer, acc, sm] do
#         inputs = Runic.Component.inputs(component)
#         outputs = Runic.Component.outputs(component)
#         assert is_list(inputs)
#         assert is_list(outputs)
#       end
#     end
#   end

#   @tag :skip
#   describe "stress tests and performance" do
#     test "workflow handles large number of sequential components" do
#       steps =
#         for i <- 1..20 do
#           Runic.step(fn x -> x + i end, name: :"step_#{i}")
#         end

#       workflow =
#         Enum.reduce(steps, Workflow.new(name: :large_chain), fn step, wrk ->
#           case Workflow.steps(wrk) do
#             [] -> Workflow.add(wrk, step)
#             steps -> Workflow.add(wrk, step, to: List.last(steps))
#           end
#         end)

#       results =
#         workflow
#         |> Workflow.react_until_satisfied(0)
#         |> Workflow.raw_productions()

#       # Sum of 1..20 = 210
#       assert 210 in results
#     end

#     test "workflow handles large input sets" do
#       mapper = Runic.map(fn x -> x * 2 end, name: :doubler)
#       reducer = Runic.reduce(0, fn x, acc -> x + acc end, name: :summer, map: :doubler)

#       workflow =
#         Workflow.new()
#         |> Workflow.add(mapper)
#         |> Workflow.add(reducer, to: mapper)

#       large_input = Enum.to_list(1..100)

#       results =
#         workflow
#         |> feed_collection(large_input)
#         |> Workflow.raw_productions()

#       # Sum of 1..100 is 5050, doubled is 10100
#       assert 10100 in results
#     end

#     test "workflow with many parallel branches" do
#       input = Runic.step(fn x -> x end, name: :input)

#       branches =
#         for i <- 1..10 do
#           Runic.step(fn x -> x * i end, name: "branch_#{i}")
#         end

#       branch_hashes =
#         Enum.map(branches, &{&1.hash, &1.work_hash})
#         |> IO.inspect(label: "Branch Hashes")

#       workflow = Runic.workflow(steps: [input])

#       workflow =
#         Enum.reduce(branches, workflow, fn branch, wrk ->
#           Workflow.add(wrk, branch, to: :input)
#         end)

#       assert length(branch_hashes) == 10

#       assert Enum.uniq(branch_hashes) == branch_hashes

#       results =
#         workflow
#         |> Workflow.react_until_satisfied(10)
#         |> Workflow.raw_productions()

#       # 10 * 1 = 10, 10 * 2 = 20, ..., 10 * 10 = 100
#       for i <- 1..10 do
#         assert (10 * i) in results
#       end
#     end
#   end
# end
