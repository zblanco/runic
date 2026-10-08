defmodule Runic.Workflow.Events.FanOutFactEmitted do
  @moduledoc """
  Event emitted when a FanOut node splits an enumerable input into individual facts.

  One event is produced per item in the enumerable. During `apply_event/2`, the emitted
  fact is logged, a `:fan_out` edge is drawn, and the `mapped` tracking state is updated
  for downstream FanIn coordination.
  """

  @type t :: %__MODULE__{
          fan_out_hash: term(),
          source_fact_hash: term(),
          emitted_fact_hash: term(),
          emitted_content_digest: Runic.Identity.t() | nil,
          emitted_payload_digest: Runic.Identity.t() | nil,
          emitted_value: term(),
          emitted_ancestry: {term(), term()} | nil,
          emitted_causal_ancestry: Runic.Workflow.FactAncestry.t() | nil,
          weight: non_neg_integer()
        }

  defstruct [
    :fan_out_hash,
    :source_fact_hash,
    :emitted_fact_hash,
    :emitted_content_digest,
    :emitted_payload_digest,
    :emitted_value,
    :emitted_ancestry,
    :emitted_causal_ancestry,
    :weight
  ]
end
