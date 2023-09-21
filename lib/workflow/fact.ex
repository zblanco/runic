defmodule Runic.Workflow.Fact do
  alias Runic.Workflow.Components
  defstruct [:hash, :value, :ancestry]

  @type hash() :: integer() | binary()

  @type t() :: %__MODULE__{
          value: term(),
          hash: hash(),
          ancestry: {hash(), hash()}
        }

        def new(params) do
          struct!(__MODULE__, params)
          |> maybe_set_hash()
        end

        defp maybe_set_hash(%__MODULE__{value: value, hash: nil} = fact) do
          %__MODULE__{fact | hash: Components.fact_hash(value)}
        end

        defp maybe_set_hash(%__MODULE__{hash: hash} = fact)
             when not is_nil(hash),
             do: fact
end
