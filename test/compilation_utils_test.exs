defmodule CompilationUtilsTest do
  use ExUnit.Case
  require Runic

  require Runic.Workflow.CompilationUtils
  alias Runic.Workflow.CompilationUtils
  alias Runic.Workflow

  test "workflow_of_pipeline with nested components" do
    wrk =
      CompilationUtils.workflow_of_pipeline(
        [
          {Runic.step(fn _ -> 1..4 end, name: :source_step),
           [
             Runic.map(
               [
                 Runic.step(fn num -> num * 2 end, name: :double_step),
                 Runic.step(fn num -> num + 1 end, name: :increment_step),
                 Runic.step(fn num -> num + 4 end, name: :add_four_step)
               ],
               name: :test_map
             )
           ]}
        ],
        :test_workflow
      )

    %Workflow{} = wrk

    assert wrk.name == :test_workflow

    for cmp_name <- [:source_step, :double_step, :increment_step, :add_four_step, :test_map] do
      assert Map.has_key?(wrk.components, cmp_name)
      assert not is_nil(Workflow.get_component(wrk, cmp_name))
    end
  end

  test "supports joins" do
    wrk =
      CompilationUtils.workflow_of_pipeline(
        [
          {Runic.step(fn num -> Enum.map(0..3, &(&1 + num)) end),
           [
             Runic.map(
               {[Runic.step(fn num -> num * 2 end), Runic.step(fn num -> num * 3 end)],
                [
                  Runic.step(fn num_1, num_2 -> num_1 * num_2 end)
                ]}
             )
           ]}
        ],
        :test_workflow_with_join
      )

    assert Enum.any?(Graph.vertices(wrk.graph), fn
             %Runic.Workflow.Join{} -> true
             _ -> false
           end)
  end

  test "pipelines can include nested map expressions" do
    wrk =
      CompilationUtils.workflow_of_pipeline(
        [
          {Runic.step(fn _ -> 1..4 end, name: :source_step),
           [
             Runic.map(
               [
                 Runic.step(fn num -> num * 2 end, name: :double_step),
                 Runic.map(
                   [
                     Runic.step(fn num -> num + 1 end, name: :increment_step),
                     Runic.step(fn num -> num + 4 end, name: :add_four_step)
                   ],
                   name: :nested_map
                 )
               ],
               name: :test_map
             )
           ]}
        ],
        :nested_map_workflow
      )

    assert wrk.name == :nested_map_workflow
    assert Map.has_key?(wrk.components, :nested_map)
  end

  test "map pipelines with nested map expressions can be compiled with depth first traversal" do
    wrk =
      CompilationUtils.workflow_of_pipeline(
        [
          {Runic.step(fn _ -> 1..4 end),
           [
             Runic.map(
               [
                 {Runic.step(fn num -> [num * 2, num * 3] end),
                  [
                    Runic.map(
                      [
                        Runic.step(fn num -> num + 6 end, name: :nested_plus_6),
                        Runic.step(fn num -> num + 8 end, name: :nested_plus_8)
                      ],
                      name: :inner_map
                    )
                  ]},
                 Runic.step(fn num -> num * 2 end, name: :x2),
                 Runic.step(fn num -> num + 1 end, name: :x1),
                 Runic.step(fn num -> num + 4 end, name: :x4)
               ],
               name: :first_map
             )
           ]}
        ],
        :nested_map_workflow
      )

    first_fan_out =
      Workflow.get_component(wrk, {:first_map, :fan_out}) |> List.first()

    inner_fan_out =
      Workflow.get_component(wrk, {:inner_map, :fan_out}) |> List.first()

    refute is_nil(first_fan_out)

    refute is_nil(inner_fan_out)

    assert [%{v1: %Runic.Workflow.Map{}}] =
             Graph.in_edges(wrk.graph, inner_fan_out, by: :component_of)

    assert Enum.count(Graph.vertices(wrk.graph), &match?(%Runic.Workflow.FanOut{}, &1)) == 2

    # assert Graph.out_edges(wrk.graph, first_fan_out, by: :flow) |> Enum.count() ==
    #          4
    assert Workflow.next_steps(wrk, first_fan_out) |> Enum.count() == 4

    assert Graph.in_edges(wrk.graph, first_fan_out, by: :flow) |> Enum.count() == 1
  end

  test "map pipelines with nested map expressions dependent on multiple sources can be compiled with depth first traversal" do
    wrk =
      CompilationUtils.workflow_of_pipeline(
        [
          {[
             Runic.step(fn _ -> 1..4 end, name: :source_1),
             Runic.step(fn _ -> 2..5 end, name: :source_2)
           ],
           [
             Runic.map(
               [
                 {Runic.step(fn num -> [num * 2, num * 3] end),
                  [
                    Runic.map(
                      [
                        Runic.step(fn num -> num + 6 end, name: :nested_plus_6),
                        Runic.step(fn num -> num + 8 end, name: :nested_plus_8)
                      ],
                      name: :inner_map
                    )
                  ]},
                 Runic.step(fn num -> num * 2 end, name: :x2),
                 Runic.step(fn num -> num + 1 end, name: :x1),
                 Runic.step(fn num -> num + 4 end, name: :x4)
               ],
               name: :first_map
             )
           ]}
        ],
        :nested_map_workflow
      )

    first_fan_out =
      Workflow.get_component(wrk, {:first_map, :fan_out}) |> List.first()

    inner_fan_out =
      Workflow.get_component(wrk, {:inner_map, :fan_out}) |> List.first()

    refute is_nil(inner_fan_out)

    assert [%{v1: %Runic.Workflow.Map{}}] =
             Graph.in_edges(wrk.graph, inner_fan_out, by: :component_of)

    assert Enum.count(Graph.vertices(wrk.graph), &match?(%Runic.Workflow.FanOut{}, &1)) == 2

    # assert Graph.out_edges(wrk.graph, first_fan_out, by: :flow) |> Enum.count() ==
    #          4
    assert Workflow.next_steps(wrk, first_fan_out) |> Enum.count() == 4

    assert Graph.in_edges(wrk.graph, first_fan_out, by: :flow) |> Enum.count() == 1
  end
end
