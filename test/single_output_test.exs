defmodule Runic.Workflow.SingleOutputTest do
  use ExUnit.Case, async: true

  require Runic

  alias Runic.TestSupport.OrdinaryComponent, as: Custom
  alias Runic.Workflow
  alias Runic.Workflow.{Fact, Invokable, PolicyDriver, Runnable, SchedulerPolicy}
  alias Runic.Workflow.SingleOutput.{Context, Result}

  test "a custom node completes through the ordinary lifecycle" do
    node = Custom.new(:add, :add, 2)
    workflow = Workflow.new() |> Workflow.add(node) |> Workflow.react_until_satisfied(3)
    assert Workflow.raw_productions(workflow, :add) == [5]
  end

  test "plain Steps and explicit values preserve error-shaped data" do
    for node <- [Runic.step(fn x -> x end, name: :data), Custom.new(:data, :data)] do
      result = execute(node, {:error, :business_value})
      assert result.status == :completed
      assert result.result.value == {:error, :business_value}
    end

    data = Result.failure(:data_not_control)
    assert execute(Runic.step(fn x -> x end), data).result.value == data
  end

  test "failure conversion is explicit and invalid callback returns fail closed" do
    assert %{status: :failed, error: :business_failure, events: nil} =
             execute(Custom.new(:fail, :failure, :business_failure), 1)

    assert %{status: :failed, error: {:invalid_single_output_result, {:ok, 1}}} =
             execute(Custom.new(:invalid, :invalid), 1)
  end

  test "runtime context, metadata, and current attempt are a bounded public view" do
    node = Custom.new(:context, :retry, 1)

    workflow =
      Workflow.new()
      |> Workflow.add(node)
      |> Workflow.put_run_context(%{_global: %{observer: self()}, context: %{offset: 2}})

    fact = Fact.new(value: 3, meta: %{domain: :input})
    {:ok, runnable} = Invokable.prepare(node, workflow, fact)
    result = PolicyDriver.execute(runnable, %SchedulerPolicy{max_retries: 1, backoff: :none})

    assert result.status == :completed
    assert_receive {:work, :context, %Context{attempt_number: 0} = first}
    assert_receive {:work, :context, %Context{attempt_number: 1} = second}
    assert first.runtime == %{observer: self(), offset: 2}
    assert first.input_metadata == %{domain: :input}
    assert first.activation_id == second.activation_id
    refute first.attempt_id == second.attempt_id
    refute Map.has_key?(first, :fan_out_context)
    refute Map.has_key?(first, :hooks)
  end

  test "metadata is explicit, never copied from runtime context" do
    node = Custom.new(:metadata, :metadata, :output)
    fact = Fact.new(value: 1, meta: %{domain: :input})

    workflow =
      Workflow.new()
      |> Workflow.add(node)
      |> Workflow.put_run_context(%{_global: %{secret: :secret}})

    {:ok, runnable} = Invokable.prepare(node, workflow, fact)
    result = Invokable.execute(node, runnable)
    assert result.result.meta == %{domain: :input, custom: :output}
    assert result.result.ancestry == {node.hash, fact.hash}
    assert execute(Custom.new(:data, :data), fact).result.meta == %{}
  end

  test "work raises, throws, and catchable exits become failed attempts" do
    assert %{status: :failed, error: %ArgumentError{}} = execute(Custom.new(:raise, :raise), 1)

    assert %{status: :failed, error: {:throw, :work_failed}} =
             execute(Custom.new(:throw, :throw), 1)

    assert %{status: :failed, error: {:exit, :work_failed}} = execute(Custom.new(:exit, :exit), 1)
  end

  test "component definitions rebuild and resolve fresh runtime context" do
    original = Workflow.new() |> Workflow.add(Custom.new(:add, :add, 2))
    log = original |> Workflow.build_log() |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    rebuilt = Workflow.from_log(log) |> Workflow.put_run_context(%{_global: %{offset: 7}})
    assert rebuilt.components.add == original.components.add
    assert rebuilt |> Workflow.react_until_satisfied(3) |> Workflow.raw_productions(:add) == [12]
  end

  test "hooks surround work and defer graph changes until successful apply" do
    node = Custom.new(:hooks, :add, 1)
    owner = self()

    before_hook = fn event, _ ->
      send(owner, {:hook, event.timing})

      {:apply,
       fn workflow ->
         send(owner, :applied_before)
         workflow
       end}
    end

    after_hook = fn event, _ ->
      send(owner, {:hook, event.timing, event.result.value})

      {:apply,
       fn workflow ->
         send(owner, :applied_after)
         Workflow.add(workflow, Custom.new(:dynamic, :add, 10), to: :hooks)
       end}
    end

    workflow =
      Workflow.new()
      |> Workflow.add(node)
      |> Workflow.put_run_context(%{_global: %{observer: owner}})
      |> Map.put(:before_hooks, %{node.hash => [before_hook]})
      |> Map.put(:after_hooks, %{node.hash => [after_hook]})
      |> Workflow.enable_event_emission()
      |> Workflow.plan_eagerly(3)

    {workflow, [runnable]} = Workflow.prepare_for_dispatch(workflow)
    executed = Invokable.execute(node, runnable)

    assert {:messages, [{:hook, :before}, {:work, :hooks, _}, {:hook, :after, 4}]} =
             Process.info(self(), :messages)

    assert_received {:hook, :before}
    assert_received {:work, :hooks, _}
    assert_received {:hook, :after, 4}
    refute_received :applied_before
    refute_received :applied_after

    applied = Workflow.apply_runnable(workflow, executed)
    assert {:messages, [:applied_before, :applied_after]} = Process.info(self(), :messages)
    assert_received :applied_before
    assert_received :applied_after
    assert Map.has_key?(applied.components, :dynamic)

    assert Enum.any?(
             applied.uncommitted_events,
             &match?(%Workflow.ComponentAdded{name: :dynamic}, &1)
           )
  end

  test "before hook failure prevents work; after hook failure publishes no result" do
    for timing <- [:before, :after] do
      node = Custom.new(timing, :data)

      workflow =
        Workflow.new()
        |> Workflow.add(node)
        |> Workflow.put_run_context(%{_global: %{observer: self()}})

      key = if timing == :before, do: :before_hooks, else: :after_hooks
      workflow = Map.put(workflow, key, %{node.hash => [fn _, _ -> {:error, :rejected} end]})
      {:ok, runnable} = Invokable.prepare(node, workflow, Fact.new(value: 1))
      executed = Invokable.execute(node, runnable)
      assert executed.status == :failed
      assert executed.events == nil
      assert executed.result == nil
      assert executed.hook_apply_fns == nil

      if timing == :before,
        do: refute_received({:work, ^timing, _}),
        else: assert_received({:work, ^timing, _})
    end
  end

  test "failed attempts discard deferred hooks and rerun hooks on retry" do
    owner = self()
    node = Custom.new(:retry, :retry, 1)

    workflow =
      Workflow.new()
      |> Workflow.add(node)
      |> Map.put(:before_hooks, %{
        node.hash => [
          fn _, _ ->
            send(owner, :before_attempt)

            {:apply,
             fn w ->
               send(owner, :accepted_hook)
               w
             end}
          end
        ]
      })
      |> Map.put(:after_hooks, %{
        node.hash => [
          fn _, _ ->
            send(owner, :after_success)
            :ok
          end
        ]
      })

    {:ok, runnable} = Invokable.prepare(node, workflow, Fact.new(value: 1))

    {executed, events} =
      PolicyDriver.execute(runnable, %SchedulerPolicy{max_retries: 1, backoff: :none},
        emit_events: true
      )

    assert_received :before_attempt
    assert_received :before_attempt
    assert_received :after_success
    refute_received :after_success
    refute_received :accepted_hook
    Workflow.apply_runnable(workflow, executed)
    assert_received :accepted_hook
    refute_received :accepted_hook
    assert Enum.count(events, &is_struct(&1, Workflow.RunnableDispatched)) == 2
    assert executed.attempt_number == 1
  end

  test "callback failure does not run success hooks" do
    owner = self()
    node = Custom.new(:failure, :failure, :rejected)
    workflow = Workflow.new() |> Workflow.add(node)

    workflow = %{
      workflow
      | after_hooks: %{
          node.hash => [
            fn _, _ ->
              send(owner, :after_failure)
              :ok
            end
          ]
        }
    }

    {:ok, runnable} = Invokable.prepare(node, workflow, Fact.new(value: 1))
    assert %{status: :failed} = Invokable.execute(node, runnable)
    refute_received :after_failure
  end

  test "legacy Invokable.invoke uses the same lifecycle for Steps and custom nodes" do
    for node <- [Runic.step(fn value -> value end, name: :node), Custom.new(:node, :data)] do
      owner = self()
      workflow = Workflow.new() |> Workflow.add(node) |> Workflow.plan_eagerly(1)

      workflow = %{
        workflow
        | before_hooks: %{
            node.hash => [
              fn _, _ ->
                send(owner, :before)
                :ok
              end
            ]
          }
      }

      [fact] = Workflow.facts(workflow)
      invoked = Invokable.invoke(node, workflow, fact)
      assert_received :before
      refute_received :before
      assert Workflow.raw_productions(invoked, :node) == [1]
    end
  end

  test "reserved metadata and malformed metadata fail before publication" do
    assert_raise ArgumentError, fn ->
      Result.value(1, metadata: %{runic: %{input_bindings: []}})
    end

    assert_raise ArgumentError, fn -> Result.value(1, metadata: []) end
    assert_raise ArgumentError, fn -> Result.value(1, unsupported: true) end
  end

  test "accepted event replay restores facts and metadata without running work" do
    node = Custom.new(:saved, :metadata, :persisted)

    workflow =
      Workflow.new()
      |> Workflow.add(node)
      |> Workflow.enable_event_emission()
      |> Workflow.put_run_context(%{_global: %{observer: self()}})
      |> Workflow.react_until_satisfied(Fact.new(value: 1, meta: %{domain: :input}))

    assert_received {:work, :saved, _}
    events = Workflow.build_log(workflow) ++ Enum.reverse(workflow.uncommitted_events)
    rebuilt = Workflow.from_events(events)
    assert Workflow.raw_productions(rebuilt, :saved) == [1]
    [output] = Workflow.productions(rebuilt, :saved)
    assert output.meta == %{domain: :input, custom: :persisted}
    assert rebuilt.run_context == %{}
    refute_received {:work, :saved, _}
  end

  defp execute(node, value) do
    fact = if is_struct(value, Fact), do: value, else: Fact.new(value: value)

    {:ok, %Runnable{} = runnable} =
      Invokable.prepare(node, Workflow.new() |> Workflow.add(node), fact)

    Invokable.execute(node, runnable)
  end
end
