defmodule Runic.Workflow.Events.Serializer do
  @moduledoc """
  Serialization utilities for workflow events.

  Provides binary (ETF) serialization for event persistence and transport.
  Events are plain structs and serialize naturally via Erlang's external term format.

  ## Binary Serialization (ETF)

  The primary serialization format uses `:erlang.term_to_binary/1` which handles
  all Elixir/Erlang terms natively. This is the recommended format for same-system
  persistence (ETS, Mnesia, file-based stores).

      events = workflow.uncommitted_events
      binary = Serializer.to_binary(events)
      {:ok, ^events} = Serializer.from_binary(binary)

  ## Custom Events

  Custom event structs from external `Invokable` implementations serialize and
  deserialize automatically via ETF — no registration or adapter is needed.
  The only requirement is that the struct's module atom exists in the VM at
  deserialization time (which is guaranteed when using `:safe` mode and the
  application code is loaded).

  Custom events should implement the `Runic.Workflow.EventApplicator` protocol
  so that `Workflow.apply_event/2` knows how to fold them into the workflow
  during replay via `Workflow.from_events/1`.

  ## Considerations

  - Binary format is tied to the Erlang VM and struct module names.
    Schema migrations require versioned deserialization.
  - For cross-language interop, implement a JSON adapter at the Store level
    using the event struct fields directly (all fields are JSON-safe primitives
    except `value` in `FactProduced`, which is arbitrary user data).
  - For event schema versioning, add a `version` field to custom event structs
    and handle upcasting during deserialization at the Store adapter level.
  """

  @doc """
  Serializes a list of events to binary (Erlang External Term Format).
  """
  @spec to_binary([struct()]) :: binary()
  def to_binary(events) when is_list(events) do
    :erlang.term_to_binary(events)
  end

  @doc """
  Deserializes events from binary.

  Uses `:safe` mode to prevent atom table exhaustion from untrusted input.
  All event struct atoms must already exist in the VM.

  Returns `{:ok, events}` or `{:error, reason}`.
  """
  @spec from_binary(binary()) :: {:ok, [struct()]} | {:error, term()}
  def from_binary(binary) when is_binary(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    e -> {:error, e}
  end

  @doc """
  Serializes a single event to binary.
  """
  @spec event_to_binary(struct()) :: binary()
  def event_to_binary(event) when is_struct(event) do
    :erlang.term_to_binary(event)
  end

  @doc """
  Deserializes a single event from binary.
  """
  @spec event_from_binary(binary()) :: {:ok, struct()} | {:error, term()}
  def event_from_binary(binary) when is_binary(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    e -> {:error, e}
  end
end
