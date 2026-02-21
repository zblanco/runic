defmodule Runic.Runner.TelemetryTest do
  use ExUnit.Case, async: true

  alias Runic.Runner.Telemetry

  describe "event_names/0" do
    test "returns 9 event names" do
      names = Telemetry.event_names()
      assert length(names) == 9
    end

    test "all event names start with :runic" do
      for name <- Telemetry.event_names() do
        assert hd(name) == :runic
      end
    end

    test "all event names are under [:runic, :runner]" do
      for name <- Telemetry.event_names() do
        assert Enum.take(name, 2) == [:runic, :runner]
      end
    end
  end

  describe "workflow_span/2" do
    test "emits start and stop events" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach_many(
        "test-workflow-span-#{inspect(ref)}",
        [
          [:runic, :runner, :workflow, :start],
          [:runic, :runner, :workflow, :stop]
        ],
        &Runic.TestTelemetryHandler.handle_event/4,
        %{test_pid: test_pid}
      )

      result = Telemetry.workflow_span(%{id: :test_wf}, fn -> :ok end)
      assert result == :ok

      assert_receive {:telemetry, [:runic, :runner, :workflow, :start], _, %{id: :test_wf}}

      assert_receive {:telemetry, [:runic, :runner, :workflow, :stop], measurements,
                      %{id: :test_wf}}

      assert is_integer(measurements.duration)

      :telemetry.detach("test-workflow-span-#{inspect(ref)}")
    end
  end

  describe "runnable_event/2" do
    test "dispatch emits :start event" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-runnable-dispatch-#{inspect(ref)}",
        [:runic, :runner, :runnable, :start],
        &Runic.TestTelemetryHandler.handle_event/4,
        %{test_pid: test_pid}
      )

      Telemetry.runnable_event(:dispatch, %{workflow_id: :wf1, node_name: :step1})

      assert_receive {:telemetry, [:runic, :runner, :runnable, :start], %{system_time: _},
                      %{workflow_id: :wf1, node_name: :step1}}

      :telemetry.detach("test-runnable-dispatch-#{inspect(ref)}")
    end

    test "complete emits :stop event with duration" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-runnable-complete-#{inspect(ref)}",
        [:runic, :runner, :runnable, :stop],
        &Runic.TestTelemetryHandler.handle_event/4,
        %{test_pid: test_pid}
      )

      Telemetry.runnable_event(:complete, %{duration: 42}, %{workflow_id: :wf1, node_name: :step1})

      assert_receive {:telemetry, [:runic, :runner, :runnable, :stop], %{duration: 42},
                      %{workflow_id: :wf1}}

      :telemetry.detach("test-runnable-complete-#{inspect(ref)}")
    end

    test "exception emits :exception event" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-runnable-exception-#{inspect(ref)}",
        [:runic, :runner, :runnable, :exception],
        &Runic.TestTelemetryHandler.handle_event/4,
        %{test_pid: test_pid}
      )

      Telemetry.runnable_event(:exception, %{workflow_id: :wf1, error: :boom})

      assert_receive {:telemetry, [:runic, :runner, :runnable, :exception], _,
                      %{workflow_id: :wf1, error: :boom}}

      :telemetry.detach("test-runnable-exception-#{inspect(ref)}")
    end
  end

  describe "store_span/3" do
    test "emits start and stop events with operation" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach_many(
        "test-store-span-#{inspect(ref)}",
        [
          [:runic, :runner, :store, :start],
          [:runic, :runner, :store, :stop]
        ],
        &Runic.TestTelemetryHandler.handle_event/4,
        %{test_pid: test_pid}
      )

      result = Telemetry.store_span(:save, %{workflow_id: :wf1}, fn -> :ok end)
      assert result == :ok

      assert_receive {:telemetry, [:runic, :runner, :store, :start], _,
                      %{operation: :save, workflow_id: :wf1}}

      assert_receive {:telemetry, [:runic, :runner, :store, :stop], measurements, _}
      assert is_integer(measurements.duration)

      :telemetry.detach("test-store-span-#{inspect(ref)}")
    end
  end
end
