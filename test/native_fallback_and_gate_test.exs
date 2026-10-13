defmodule Runic.NativeFallbackAndGateTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  require Runic
  alias Runic.Workflow

  alias Runic.Workflow.{
    Fact,
    Invokable,
    CausalContext,
    PolicyDriver,
    SchedulerPolicy,
    LocalBoundary,
    LocalFactError
  }

  defp input_binding do
    Workflow.InputBinding.new(
      target_component_hash: :target,
      source_order: [:left],
      input_ports: [in: [type: :any]],
      bindings: [
        %{
          id: :read,
          source_hash: :left,
          source_port: :out,
          source_port_index: 0,
          source_port_count: 1,
          target_port: :in,
          selector: [:missing],
          target_path: []
        }
      ]
    )
  end

  defp gate_workflow(node, input, parent) do
    gate = Workflow.Condition.new(fn _ -> true end)

    wf =
      Workflow.new()
      |> Workflow.add_step(gate)
      |> Workflow.add_step(gate, node)
      |> Workflow.log_fact(input)
      |> Workflow.log_fact(parent)

    event = %Workflow.Events.ConditionSatisfied{
      fact_hash: input.hash,
      condition_hash: gate.hash,
      meta_parents: [parent],
      weight: 1
    }

    Workflow.apply_event(wf, event)
  end

  defp prepared(:accumulator, conflicting?) do
    acc = Runic.accumulator(0, fn _, _ -> raise "attempt failed" end, name: :state)
    root = Fact.local(41)
    state = Fact.child(root, value: 41, ancestry: {acc.hash, root.hash})

    wf =
      Workflow.new()
      |> Workflow.add(acc)
      |> Workflow.log_fact(root)
      |> Workflow.log_fact(state)
      |> Workflow.draw_connection(acc, state, :state_produced, weight: 1)

    input = if conflicting?, do: Fact.local(7), else: Fact.new(value: 7)
    {:ok, runnable} = Invokable.prepare(acc, wf, input)

    runnable = %{
      runnable
      | context: %{runnable.context | hooks: {[fn _, _ -> {:error, :attempt_rejected} end], []}}
    }

    {runnable, state}
  end

  defp prepared(kind, conflicting?) do
    node =
      case kind do
        :binding ->
          input_binding()

        :fan_in ->
          %Workflow.FanIn{
            hash: Runic.Identity.digest(:component_definition, :fallback_reduce),
            name: :reduce,
            init: fn -> [] end,
            reducer: fn _, _ -> raise "attempt failed" end
          }
      end

    value = if kind == :fan_in, do: [7], else: 7
    input = if conflicting?, do: Fact.local(value), else: Fact.new(value: value)
    parent = Fact.local(41)
    wf = gate_workflow(node, input, parent)
    {:ok, runnable} = Invokable.prepare(node, wf, input)
    assert runnable.context.meta_parents == [parent]

    runnable = %{
      runnable
      | context: %{runnable.context | hooks: {[fn _, _ -> {:error, :attempt_rejected} end], []}}
    }

    {runnable, parent}
  end

  for kind <- [:accumulator, :binding, :fan_in] do
    test "#{kind} value fallback retains its actual local data parents" do
      {runnable, parent} = prepared(unquote(kind), false)

      policy =
        SchedulerPolicy.new(
          fallback: fn r, _ ->
            assert parent in CausalContext.data_parents(r.context, r.input_fact)
            {:value, 41}
          end
        )

      completed = PolicyDriver.execute(runnable, policy, [])
      assert completed.status == :completed
      assert completed.error == nil
      assert completed.result.value == 41
      assert completed.result.identity_mode == :local
      assert completed.result.local_scope == parent.local_scope
      assert {:error, %LocalFactError{}} = LocalBoundary.check(completed.result, :output)
    end

    test "#{kind} invalid scopes stop fallback callbacks" do
      {runnable, _} = prepared(unquote(kind), true)
      observer = self()

      policy =
        SchedulerPolicy.new(
          fallback: fn _, _ ->
            send(observer, :fallback_called)
            {:value, 41}
          end
        )

      rejected = PolicyDriver.execute(runnable, policy, [])
      assert rejected.status == :failed
      assert %ArgumentError{} = rejected.error
      refute_received :fallback_called
    end
  end

  for type <- [:step, :condition, :fan_in] do
    test "#{type} retains a parent LocalFactError before hooks" do
      input = Fact.new(value: [1])
      parent = Fact.local(41)
      foreign = %{parent | local_scope: %{parent.local_scope | vm: <<0::256>>}}

      node =
        case unquote(type) do
          :step ->
            Runic.step(fn x -> x end)

          :condition ->
            Workflow.Condition.new(fn _ -> true end)

          :fan_in ->
            %Workflow.FanIn{
              hash: Runic.Identity.digest(:component_definition, :error_shape),
              name: :reduce,
              init: fn -> [] end,
              reducer: fn x, acc -> [x | acc] end
            }
        end

      wf = Workflow.new() |> Workflow.add_step(node)
      {:ok, runnable} = Invokable.prepare(node, wf, input)
      observer = self()

      ctx = %{
        runnable.context
        | meta_parents: [foreign],
          hooks:
            {[
               fn _, _ ->
                 send(observer, :hook_called)
                 :ok
               end
             ], []}
      }

      rejected = Invokable.execute(node, %{runnable | context: ctx})
      assert rejected.status == :failed
      assert %LocalFactError{reason: :foreign_local_scope} = rejected.error
      refute_received :hook_called
    end
  end

  test "FanOut follows native gate parents in direct and prepared paths" do
    fan_out = %Workflow.FanOut{
      hash: Runic.Identity.digest(:component_definition, :gate_fan_out),
      name: :expand
    }

    source = Fact.new(value: [1, 2, 3])
    parent = Fact.local(41)
    wf = gate_workflow(fan_out, source, parent)
    {:ok, prepared} = Invokable.prepare(fan_out, wf, source)
    completed = Invokable.execute(fan_out, prepared)
    assert completed.status == :completed
    assert Enum.map(completed.result, & &1.value) == [1, 2, 3]

    assert Enum.all?(
             completed.result,
             &(&1.identity_mode == :local and &1.local_scope == parent.local_scope)
           )

    direct = Invokable.invoke(fan_out, wf, source)

    emitted =
      Enum.filter(
        Workflow.facts(direct),
        &match?({hash, _} when hash == fan_out.hash, &1.ancestry)
      )

    assert length(emitted) == 3

    assert Enum.all?(
             emitted,
             &(&1.identity_mode == :local and &1.local_scope == parent.local_scope)
           )
  end

  test "a native meta-reading Condition propagates through a Map" do
    acc = Runic.accumulator(0, fn _, _ -> 41 end, name: :source)

    gate =
      Workflow.Condition.new(
        work: fn _, ctx -> ctx.state > 0 end,
        arity: 2,
        meta_refs: [%{kind: :state_of, target: :source, field_path: [], context_key: :state}]
      )

    map = Runic.map(fn x -> x * 2 end, name: :double)
    root = Fact.local(41)
    state = Fact.child(root, value: 41, ancestry: {acc.hash, root.hash})
    wf = Workflow.new() |> Workflow.add(acc)
    wf = %{wf | graph: Multigraph.delete_edge(wf.graph, Workflow.root(), acc, :flow)}

    wf =
      wf
      |> Workflow.log_fact(root)
      |> Workflow.log_fact(state)
      |> Workflow.draw_connection(acc, state, :state_produced, weight: 1)
      |> Workflow.add(gate)
      |> Workflow.add(map, to: gate)

    {wf, execution} = Workflow.execute(wf, [1, 2, 3])
    assert execution.failures == []
    outputs = Workflow.productions(wf, :double)
    assert Enum.sort(Enum.map(outputs, & &1.value)) == [2, 4, 6]

    assert Enum.all?(
             outputs,
             &(&1.identity_mode == :local and &1.local_scope == state.local_scope)
           )
  end
end
