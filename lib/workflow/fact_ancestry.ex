defmodule Runic.Workflow.FactAncestry do
  @moduledoc """
  Explicit causal coordinates for a Fact occurrence.

  The legacy `{producer_hash, parent_fact_hash}` tuple remains available on
  `Runic.Workflow.Fact` during the alpha migration. This struct carries the
  additional activation and output coordinates needed to distinguish equal
  payloads produced at different positions.
  """

  alias Runic.Identity

  @type t :: %__MODULE__{
          producer_node_id: term() | nil,
          parent_fact_id: term() | nil,
          activation_id: Identity.t() | nil,
          output_port: atom(),
          output_index: non_neg_integer()
        }

  defstruct [
    :producer_node_id,
    :parent_fact_id,
    :activation_id,
    output_port: :out,
    output_index: 0
  ]

  @doc false
  def from_legacy(ancestry, opts \\ [])

  def from_legacy(nil, opts) do
    new(nil, nil, opts)
  end

  def from_legacy({producer_node_id, parent_fact_id}, opts) do
    new(producer_node_id, parent_fact_id, opts)
  end

  @doc false
  def to_document(%__MODULE__{} = ancestry) do
    %{
      producer_node_id: ancestry.producer_node_id,
      parent_fact_id: ancestry.parent_fact_id,
      activation_id: ancestry.activation_id,
      output_port: ancestry.output_port,
      output_index: ancestry.output_index
    }
  end

  defp new(producer_node_id, parent_fact_id, opts) do
    activation_id =
      Keyword.get_lazy(opts, :activation_id, fn ->
        Identity.derive(:activation, [:local, parent_fact_id, producer_node_id])
      end)

    %__MODULE__{
      producer_node_id: producer_node_id,
      parent_fact_id: parent_fact_id,
      activation_id: activation_id,
      output_port: Keyword.get(opts, :output_port, :out),
      output_index: Keyword.get(opts, :output_index, 0)
    }
  end
end
