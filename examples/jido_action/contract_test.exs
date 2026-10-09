defmodule Runic.Examples.JidoActionContractTest do
  use ExUnit.Case, async: true

  alias Runic.Examples.{JidoAction, JidoActionFixture}
  alias Runic.Workflow
  alias Runic.Workflow.{Fact, FanIn, FanOut, Invokable, PolicyDriver, SchedulerPolicy}

  defp action do
    Jido.Instruction.new!(target: JidoActionFixture) |> JidoAction.new(name: :action)
  end

  defp workflow, do: Workflow.new() |> Workflow.add(action())

  test "definition identity includes captured Action configuration" do
    first =
      Jido.Instruction.new!(target: JidoActionFixture, params: %{value: 1})
      |> JidoAction.new(name: :action)

    second =
      Jido.Instruction.new!(target: JidoActionFixture, params: %{value: 2})
      |> JidoAction.new(name: :action)

    refute first.hash == second.hash
  end

  test "real Action validation, output, and effects use the standard lifecycle" do
    completed = workflow() |> Workflow.react_until_satisfied(%{value: 2})

    assert [%{value: %{value: 3}, meta: %{jido: %{effects: [:recorded]}}}] =
             Workflow.productions(completed, :action)
  end

  test "real Action errors fail the attempt instead of becoming successful data" do
    for input <- [%{value: -1}, %{value: "invalid"}] do
      node = action()
      {:ok, runnable} = Invokable.prepare(node, workflow(), Fact.new(value: input))
      result = Invokable.execute(node, runnable)
      assert result.status == :failed
      assert is_exception(result.error)
      assert result.events == nil
    end
  end

  test "Action source reconstructs and uses fresh context" do
    rebuilt = workflow() |> Workflow.build_log() |> Workflow.from_log()

    completed =
      rebuilt
      |> Workflow.put_run_context(%{action: %{offset: 5}})
      |> Workflow.react_until_satisfied(%{value: 2})

    assert Workflow.raw_productions(completed, :action) == [%{value: 7}]
  end

  test "managed Action results match direct execution" do
    owner = self()
    runner = :"jido_single_output_#{System.unique_integer([:positive])}"
    start_supervised!({Runic.Runner, name: runner})

    {:ok, _} =
      Runic.Runner.start_workflow(runner, :action, workflow(),
        on_complete: fn _, completed -> send(owner, {:done, completed}) end
      )

    assert :ok = Runic.Runner.run(runner, :action, %{value: 2})
    assert_receive {:done, completed}, 5_000

    assert [%{value: %{value: 3}, meta: %{jido: %{effects: [:recorded]}}}] =
             Workflow.productions(completed, :action)
  end

  test "an Action participates in custom FanOut/FanIn topology without event code" do
    node = action()

    fan_out = %FanOut{
      hash: Runic.Identity.digest(:component_definition, :jido_fan_out),
      name: :fan_out
    }

    fan_in = %FanIn{
      hash: Runic.Identity.digest(:component_definition, :jido_fan_in),
      name: :fan_in,
      init: fn -> [] end,
      reducer: fn value, acc -> acc ++ [value] end
    }

    completed =
      Workflow.new()
      |> Workflow.add_step(fan_out)
      |> Workflow.add(node, to: fan_out)
      |> Workflow.add_step(node, fan_in)
      |> Workflow.draw_connection(fan_out, fan_in, :fan_in)
      |> Workflow.react_until_satisfied([%{value: 1}, %{value: 1}, %{value: 2}], async: true)

    assert [%{value: 2}, %{value: 2}, %{value: 3}] in Workflow.raw_productions(completed)
  end

  test "Action attempt spans retain correlation and failure interpretation through retries" do
    owner = self()
    id = make_ref()

    :ok =
      :telemetry.attach_many(
        id,
        [[:jido, :action, :start], [:jido, :action, :stop]],
        &__MODULE__.telemetry/4,
        owner
      )

    on_exit(fn -> :telemetry.detach(id) end)
    node = action()
    {:ok, runnable} = Invokable.prepare(node, workflow(), Fact.new(value: %{value: -1}))
    result = PolicyDriver.execute(runnable, %SchedulerPolicy{max_retries: 1, backoff: :none})
    assert result.status == :failed
    assert result.result == nil
    assert_received {:span, [:jido, :action, :start], %{attempt: 0} = first}
    assert_received {:span, [:jido, :action, :stop], %{attempt: 0, outcome: :error}}
    assert_received {:span, [:jido, :action, :start], %{attempt: 1} = second}
    assert_received {:span, [:jido, :action, :stop], %{attempt: 1, outcome: :error}}
    assert first.activation_id == second.activation_id
    refute first.attempt_id == second.attempt_id
  end

  test "effect metadata survives accepted-event replay without replaying Action telemetry" do
    owner = self()
    id = make_ref()
    :ok = :telemetry.attach(id, [:jido, :action, :start], &__MODULE__.telemetry/4, owner)
    on_exit(fn -> :telemetry.detach(id) end)
    input = Fact.new(value: %{value: 2}, meta: %{jido: %{effects: [:prior]}})

    completed =
      workflow() |> Workflow.enable_event_emission() |> Workflow.react_until_satisfied(input)

    assert_received {:span, [:jido, :action, :start], _}

    rebuilt =
      Workflow.from_events(
        Workflow.build_log(completed) ++ Enum.reverse(completed.uncommitted_events)
      )

    assert [%{meta: %{jido: %{effects: [:prior, :recorded]}}}] =
             Workflow.productions(rebuilt, :action)

    refute_received {:span, [:jido, :action, :start], _}
  end

  def telemetry(event, _measurements, metadata, owner) do
    # Ignore unrelated concurrent test processes; all spans in these two tests
    # run synchronously in the owning test process.
    if self() == owner, do: send(owner, {:span, event, metadata})
  end
end
