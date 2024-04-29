defmodule Runic.Workflow.FanOut do
  @moduledoc """
  FanOut steps are part of a map operator that expands enumerable facts into separate facts.

  FanOut just splits input facts - separate steps as defined in the map expression will do the processing.
  """
  defstruct [:hash]
end
