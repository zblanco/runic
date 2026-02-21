defmodule Runic.TestTelemetryHandler do
  @moduledoc false

  def handle_event(event, measurements, metadata, %{test_pid: test_pid}) do
    send(test_pid, {:telemetry, event, measurements, metadata})
  end
end
