defmodule Runic.Workflow.Definition do
  @moduledoc """
  Durable construction data for a workflow used as a nested component.

  A nested workflow cannot be reconstructed from its name and component
  registry alone. Its boundary ports and ordered build events are required to
  recreate both the internal graph and the boundary lowering. This struct is
  stored inside the parent workflow's `%Runic.Workflow.ComponentAdded{}` event
  and can itself contain nested workflow definitions recursively.

  Runtime facts, run context, hooks, and runnable state are intentionally not
  part of this construction definition.

  A workflow is treated as an authored nested boundary when it declares
  `input_ports`, `output_ports`, or both. Internal compiler workflows without
  boundary ports retain their existing composition behavior.

  Output ports with `from: component_name` retain the ownership needed for a
  parent to resolve downstream named connections after replay. Contract-only
  outputs without `:from` are preserved but are not resolved by inference.

  See the [Cheatsheet](cheatsheet.html#nested-workflow-components) and
  [Usage Rules](usage-rules.html#prefer-explicit-boundaries-for-reusable-workflows)
  for the public construction API. This definition is an internal persistence
  contract and is not normally constructed directly.
  """

  alias Runic.Component
  alias Runic.Workflow

  @version 1

  @type t :: %__MODULE__{
          version: pos_integer(),
          name: String.t() | atom(),
          hash: term(),
          input_ports: keyword() | nil,
          output_ports: keyword() | nil,
          build_log: list(struct())
        }

  @enforce_keys [:version, :name, :hash, :build_log]
  defstruct [:version, :name, :hash, :input_ports, :output_ports, :build_log]

  @doc false
  @spec from_workflow(Workflow.t()) :: t()
  def from_workflow(%{__struct__: Workflow} = workflow) do
    %__MODULE__{
      version: @version,
      name: workflow.name,
      hash: workflow.hash || Component.hash(workflow),
      input_ports: workflow.input_ports,
      output_ports: workflow.output_ports,
      build_log: Workflow.build_log(workflow)
    }
    |> validate!()
  end

  @doc false
  @spec rebuild(t()) :: Workflow.t()
  def rebuild(%__MODULE__{version: @version} = definition) do
    definition = validate!(definition)

    [
      name: definition.name,
      hash: definition.hash,
      input_ports: definition.input_ports,
      output_ports: definition.output_ports
    ]
    |> Workflow.new()
    |> Workflow.apply_events(definition.build_log)
  end

  def rebuild(%__MODULE__{version: version}) do
    raise ArgumentError,
          "unsupported nested workflow definition version: #{inspect(version)}"
  end

  defp validate!(%__MODULE__{} = definition) do
    unless is_atom(definition.name) or is_binary(definition.name) do
      raise ArgumentError,
            "nested workflow definition name must be an atom or string, got: #{inspect(definition.name)}"
    end

    unless ports?(definition.input_ports) and ports?(definition.output_ports) do
      raise ArgumentError, "nested workflow definition ports must be keyword lists or nil"
    end

    unless is_list(definition.build_log) and Enum.all?(definition.build_log, &is_struct/1) do
      raise ArgumentError, "nested workflow definition build log must contain event structs"
    end

    definition
  end

  defp ports?(nil), do: true
  defp ports?(ports), do: Keyword.keyword?(ports)
end
