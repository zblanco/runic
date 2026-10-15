defmodule Runic.CustomRunnableOrderTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  require Runic
  alias Runic.{Runner, Workflow}
  alias Runic.Workflow.{Fact, FactRef}

  setup do
    runner = :"custom_order_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner})
    %{runner: runner}
  end

  for async? <- [false, true] do
    test "immediate admission uses a consumer key with async #{async?}" do
      owner = self()

      workflow =
        Runic.workflow(
          steps:
            for name <- [:z, :a] do
              Runic.step(
                fn input ->
                  send(owner, {:ran, name, input})
                  input
                end,
                name: name
              )
            end
        )

      for input <- [1, 1, 2] do
        {_workflow, execution} =
          Workflow.execute(workflow, input,
            async: unquote(async?),
            max_concurrency: 1,
            runnable_order: & &1.node.name
          )

        assert execution.quiescent?
        assert_receive {:ran, first, ^input}
        assert first == :a
        assert_receive {:ran, second, ^input}
        assert second == :z
      end
    end

    test "custom keys order eager Conditions and their outcomes with async #{async?}" do
      owner = self()

      workflow =
        Enum.reduce([:z, :a], Workflow.new(), fn name, workflow ->
          condition =
            Runic.condition(
              fn input ->
                send(owner, {:matched, name, input})
                false
              end,
              name: name
            )

          Workflow.add_step(workflow, condition)
        end)

      for names <- [[:a, :z], [:z, :a]], input <- [1, 1, 2] do
        order = fn %{node: node, input_fact: %Fact{value: value}} ->
          assert value == input
          Enum.find_index(names, &(&1 == node.name))
        end

        {_workflow, execution} =
          Workflow.execute(workflow, input,
            async: unquote(async?),
            runnable_order: order
          )

        assert execution.quiescent?
        assert Enum.map(execution.outcomes, & &1.node_name) == names

        for name <- names do
          assert_receive {:matched, first, ^input}
          assert first == name
        end
      end
    end

    test "custom keys order eager Rule predicates with async #{async?}" do
      owner = self()

      rules = [
        Runic.rule(
          condition: fn input ->
            send(owner, {:matched, :z, input})
            true
          end,
          reaction: fn input -> {:z, input} end,
          name: :z
        ),
        Runic.rule(
          condition: fn input ->
            send(owner, {:matched, :a, input})
            true
          end,
          reaction: fn input -> {:a, input} end,
          name: :a
        )
      ]

      workflow = Runic.workflow(rules: rules)
      names_by_hash = Map.new(rules, &{&1.condition_hash, &1.name})

      for names <- [[:a, :z], [:z, :a]] do
        order = fn %{node: node} ->
          Enum.find_index(names, &(&1 == names_by_hash[node.hash]))
        end

        {_workflow, execution} =
          Workflow.execute(workflow, 1,
            async: unquote(async?),
            max_concurrency: 1,
            runnable_order: order
          )

        assert execution.quiescent?

        assert Enum.map(Enum.take(execution.outcomes, 2), &names_by_hash[&1.node_hash]) == names

        for name <- names do
          assert_receive {:matched, first, 1}
          assert first == name
        end
      end
    end
  end

  test "custom keys select newly ready matches before remaining siblings" do
    parent = Runic.condition(fn _ -> true end, name: :b)
    child = Runic.condition(fn _ -> false end, name: :a)
    sibling = Runic.condition(fn _ -> false end, name: :z)

    workflow =
      Workflow.new()
      |> Workflow.add_step(parent)
      |> Workflow.add_step(parent, child)
      |> Workflow.add_step(sibling)

    {_workflow, execution} = Workflow.execute(workflow, 1, runnable_order: & &1.node.name)

    assert execution.quiescent?
    assert Enum.map(execution.outcomes, & &1.node_name) == [:b, :a, :z]
    assert Enum.map(execution.outcomes, & &1.result) == [true, false, false]
    assert length(Enum.uniq_by(execution.outcomes, & &1.activation_id)) == 3
  end

  test "an immediate key exception propagates before work starts" do
    owner = self()

    workflow =
      Runic.workflow(
        steps: [
          Runic.step(fn input ->
            send(owner, :ran)
            input
          end)
        ]
      )

    assert_raise ArgumentError, "bad order", fn ->
      Workflow.execute(workflow, 1, runnable_order: fn _ -> raise ArgumentError, "bad order" end)
    end

    refute_received :ran
  end

  test "an eager match key exception propagates before predicates and hooks start" do
    owner = self()

    condition =
      Runic.condition(
        fn _ ->
          send(owner, :predicate_ran)
          true
        end,
        name: :gate
      )

    hook = fn _, _ ->
      send(owner, :hook_ran)
      :ok
    end

    workflow =
      Workflow.new()
      |> Workflow.add_step(condition)
      |> Map.put(:before_hooks, %{condition.hash => [hook]})

    assert_raise ArgumentError, "bad match order", fn ->
      Workflow.execute(workflow, 1,
        runnable_order: fn _ -> raise ArgumentError, "bad match order" end
      )
    end

    refute_received :predicate_ran
    refute_received :hook_ran
  end

  for executor <- [:inline, Runic.Runner.Executor.Task] do
    test "managed keys order repeated inputs within a causal depth with #{inspect(executor)}",
         ctx do
      workflow =
        Runic.workflow(
          steps: [
            {Runic.step(& &1, name: :a), [Runic.step(& &1, name: :aa)]},
            Runic.step(& &1, name: :b),
            Runic.step(& &1, name: :c)
          ]
        )

      assert {:ok, _worker} =
               Runner.start_workflow(ctx.runner, :ordered, workflow,
                 executor: unquote(executor),
                 max_concurrency: 1,
                 runnable_order: & &1.node.name
               )

      for input <- [1, 1, 2] do
        assert {:ok, id} = Runner.start_execution(ctx.runner, :ordered, input)
        assert {:ok, observation} = Runner.await_execution(ctx.runner, :ordered, id)
        assert Enum.map(observation.outcomes, & &1.node_name) == [:a, :b, :c, :aa]
      end
    end
  end

  test "managed keys read resolved Facts after lazy resume and run before transform hooks", ctx do
    workflow = Runic.workflow(steps: [Runic.step(& &1, name: :z), Runic.step(& &1, name: :a)])

    assert {:ok, _} =
             Runner.start_workflow(ctx.runner, :restored, workflow, dispatch_mode: :manual)

    assert :ok = Runner.run(ctx.runner, :restored, 7)
    assert :ok = Runner.stop(ctx.runner, :restored)
    owner = self()

    order = fn %{node: node, input_fact: %Fact{value: value}} ->
      send(owner, {:key, node.name, value})
      node.name
    end

    transform = fn runnables, _workflow ->
      send(owner, {:transformed, Enum.map(runnables, & &1.node.name)})
      runnables
    end

    assert {:ok, _} =
             Runner.resume(ctx.runner, :restored,
               rehydration: :lazy,
               dispatch_mode: :manual,
               executor: :inline,
               runnable_order: order,
               hooks: [transform_runnables: transform]
             )

    assert {:ok, restored} = Runner.get_workflow(ctx.runner, :restored)
    assert Enum.any?(Multigraph.vertices(restored.graph), &is_struct(&1, FactRef))
    assert :ok = Runner.step(ctx.runner, :restored)
    assert_receive {:key, :a, 7}
    assert_receive {:key, :z, 7}
    assert_receive {:transformed, [:a, :z]}
  end

  test "a managed key exception terminates its admitting Worker", ctx do
    owner = self()

    workflow =
      Runic.workflow(
        steps: [
          Runic.step(fn input ->
            send(owner, :ran)
            input
          end)
        ]
      )

    assert {:ok, worker} =
             Runner.start_workflow(ctx.runner, :bad_key, workflow,
               owner: self(),
               dispatch_mode: :manual,
               runnable_order: fn _ -> raise ArgumentError, "bad order" end
             )

    assert :ok = Runner.run(ctx.runner, :bad_key, 1)
    monitor = Process.monitor(worker)

    assert {{%ArgumentError{message: "bad order"}, _}, {GenServer, :call, _}} =
             catch_exit(Runner.step(ctx.runner, :bad_key))

    assert_receive {:DOWN, ^monitor, :process, ^worker, {%ArgumentError{}, _}}
    assert Runner.lookup(ctx.runner, :bad_key) == nil
    refute_received :ran
  end
end
