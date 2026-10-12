defmodule Runic.TestSupport.ChildTargets do
  @moduledoc false
  require Runic

  def blocked do
    Runic.step(
      fn input ->
        Process.flag(:trap_exit, true)
        send(context(:observer), {:child_started, self()})
        receive do: (:release -> input * 2)
      end,
      name: :target
    )
  end

  def contextual do
    Runic.step(fn input -> input + context(:offset) end, name: :target)
  end
end
