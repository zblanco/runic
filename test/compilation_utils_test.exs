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
end
